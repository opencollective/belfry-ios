#!/usr/bin/env python3
"""What a CI run has to do (Xavier, 2026-11-18: "only test what could likely be impacted"; the full
suite of screenshots and UI tests only for a release with a new minor version).

Reads the changed files (git diff BASE..HEAD) and prints GitHub outputs:
  core=true|false     run the core tests (BelfryCore, its tests, the vectors)
  app=true|false      app code changed: main uploads to TestFlight (after the core tests)
  parts=<JSON list>   simulator jobs: {name, shots, shard, uitests, uimodes}; [] = none
  shared=true|false   more than one simulator job: the app is built once (the build job)
  full=true|false     this run is the full suite (when it passes, the commit gets the status
                      "full-suite")
  why=<one line>

Full suite (Xavier, 2026-11-22: once per release, not twice): the workflow's `full` input, a tag
vX.Y.0, or main with a new major or minor MARKETING_VERSION whose tree has not passed it yet. A
version bump on a branch no longer forces it. On main, a tree that already passed the full suite
(the status "full-suite" on this commit, or on a merged parent with the same tree) runs no
simulator job at all: the core tests and TestFlight only.
Otherwise the screens and UI tests mapped from the changed files (MAP below: keep it current when
a screen moves to another file), a small smoke set for shared code. A changed UI test file
(App/UITests/<Area>Shots.swift) runs its own tests; ShotCase.swift (their base) the smoke tests.
Dark mode UI tests: the full suite, and changes to colours / the theme.
"""
import json, math, os, re, subprocess, sys

SMOKE = "home|feed|drawer|pulldown|event|charter|members|composer"
SMOKE_TESTS = "testKeyboardComposer testMessageMenu"
# file (regex on its path) → screens (regex on the screenshot script's screen names), UI tests
MAP = [
    (r"App/Sources/Theme", "brand.*|feed|home", ""),
    (r"App/Sources/(InviteSheet|AgentUI)", "invite.*|membersinvite.*|addagent|myprofile", ""),
    (r"App/Sources/(CharterUI|AppModel\+Charter)", "charter|whoagreed|agreement|welcomecharter|guest-apply|home", ""),
    (r"App/Sources/WelcomeUI", "welcome.*", ""),
    (r"App/Sources/(Composer|MessageField)", "composer.*|feed|thread|mailreply", "testKeyboardComposer testAddMenu testEventChatTyping"),
    (r"App/Sources/(ChannelView|MessageRow|MarkdownText|MessageButtons|RefBox)", "feed|thread|threadscreen|website|reqclose|reqcloseconfirm|composer|mailfeed|town|linkboxes", "testMessageMenu testKeyboardComposer"),
    (r"App/Sources/MessageActions", "menu|delete|edit|feed|thread|threadscreen", "testMessageMenu"),
    (r"App/Sources/DmThreadUI", "dmthread|conversation", "testDmMenu"),
    (r"App/Sources/ThreadView", "thread|threadscreen|mentions", ""),
    (r"App/Sources/(OneShapeUI|ChannelHeader|ActivityPreview)", "feed|thread|threadscreen|pulldown|mailfeed|inbox.*|town|todos", ""),
    (r"App/Sources/(PullDown|ChannelPlaces|ChannelDetails|NotifySheet)", "inbox.*|pull.*|member-pulldown|pinned|chsettings|chvisibility|chpublic|notify|members|membersinvitech|todos|files|log|closedrequests", ""),
    (r"App/Sources/(TodoScreen|AppModel\+Due)", "todo.*|mytodos", "testTodoAssign"),
    (r"App/Sources/(TownDrawer|Tabs)", ".*drawer|home|town|calendar|groups|messagestab", "NavShots"),
    (r"App/Sources/(Nav2UI|AppModel\+Nav)", "addchannel.*|channelpreview|channelpin|member-channelpin|.*drawer|messagestab|feed", "testDrawerSwipe"),
    (r"App/Sources/(HomeView|AppModel\+Home)", "home|homedrawer|guest-home|guest-applied|mytodos", "testHomeDrawer"),
    (r"App/Sources/CalendarView", "calendar.*|guest-calendar", ""),
    (r"App/Sources/(GroupsView|GroupPage|NewGroupUI|ArchiveUI|AppModel\+Archive)", "groups.*|group.*|pod|archivedlist", ""),
    (r"App/Sources/(EventScreen|EventsUI|Tickets|AppModel\+Events|AppModel\+Checkin|GroupRoles)", "event.*|events|ticket|checkin.*|calendar", "testEventHeaderDrag testEventChatTyping"),
    (r"Sources/BelfryCore/Model/EventShape", "event.*", ""),
    (r"App/Sources/(MeetingUI|AppModel\+Meetings)", "meeting.*", ""),
    (r"App/Sources/(GuestUI|JoinUI|AppModel\+Guest|AppModel\+MemberLink|AppModel\+Apply)", "guest-.*|join-member", "testMemberLinkSignUp"),
    (r"App/Sources/(SignInView|AppModel\+SignIn|NoLinkUI|WayInUI|AppModel\+WayIn)", "signin.*", ""),
    (r"App/Sources/(PeopleUI|MembersDirectory|RequestsView|AppModel\+People)", "profile|guestprofile|guestagentprofile|editprofile|me|meplace|enconlydevice|mycard|myprofile|members.*|directory|requests|rolepicker|eventrole", ""),
    (r"App/Sources/(BelfrySettings|RolesSettings|ChannelEnd)", "settings.*|channelend.*|channelarchive|rolepicker", "testDeleteEmptyChannel"),
    (r"App/Sources/(MailUI|AppModel\+MailReply)", "mail.*|fullmail", ""),
    (r"App/Sources/ProposalScreen", "proposal.*", ""),
    (r"App/Sources/PicturesUI", "mailpictures|feed|mailfeed|mailthread|thread|conversation", "testMessageMenu"),
    (r"App/Sources/(MessagesView|MentionsView)", "messages|homemessages|conversation|dmthread|mentions|mail|mailpictures|enc.*|sendstill|sendnotyet|dmfiles|dmfilessending", "testPushedHasNoDrawer testDmMenu"),
    (r"App/Sources/SendLine", "sendstill|sendnotyet|diagnostics|feed|dmfilessending", ""),
    (r"App/Sources/DmFilesUI", "dmfiles|dmfilessending|conversation", ""),
    (r"App/Sources/TypingUI", "typing.*", ""),
    (r"App/Sources/(AccountsSheet|AppModel\+Accounts|AboutScreen)", "accounts|about|diagnostics|enclinked", ""),
    (r"App/Sources/(Sealed|EncryptionUI)", "enc.*|messages|conversation", ""),
    (r"App/Sources/CreateMenu", "create|add", "testAddMenu"),
    (r"App/Sources/AppModel\+Push", "notifications", ""),
]
# colours and the theme: their UI tests run in dark too
THEME = re.compile(r"^App/(Sources/Theme|Assets\.xcassets/|Resources/.*\.xcassets/)")
DOCS = re.compile(r"(\.md$|^LICENSE|^\.gitignore$|^tools/)")
CORE = re.compile(r"^(Sources/|Tests/|vectors/|Package\.(swift|resolved)$)")
APP = re.compile(r"^(App/Sources/|App/NotificationService/|Sources/|project\.yml$|Package\.(swift|resolved)$)")
PER_JOB = 45  # app launches one simulator job takes in about ten minutes


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True).stdout.strip()


def version(ref):
    m = re.search(r'MARKETING_VERSION:\s*"?(\d+)\.(\d+)', git("show", f"{ref}:project.yml"))
    return (m.group(1), m.group(2)) if m else None


def screens():
    out = []
    for line in open("scripts/screenshots.sh", encoding="utf-8"):
        p = line.split()
        if len(p) >= 4 and p[0] == "shot" and p[2] not in out:
            out.append(p[2])
    return out


def tests_in(path):
    """The UI tests of one App/UITests file (none when it was deleted)."""
    try:
        return re.findall(r"func (test\w+)\(\)", open(path, encoding="utf-8").read())
    except OSError:
        return []


def passed_full():
    """The run that passed the full suite on this tree (a line of text), else ""."""
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo or not os.environ.get("GH_TOKEN"):
        return ""
    tree = git("rev-parse", "HEAD^{tree}")
    shas = [git("rev-parse", "HEAD")] + [p for p in git("rev-list", "--parents", "-n", "1", "HEAD").split()[1:]
                                         if git("rev-parse", p + "^{tree}") == tree]
    for sha in shas:
        r = subprocess.run(["gh", "api", f"repos/{repo}/commits/{sha}/statuses", "--jq",
                            '[.[] | select(.context == "full-suite" and .state == "success")][0].description // ""'],
                           capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return f"{r.stdout.strip()} on {sha[:9]}"
    return ""


def plan(changed, full=False, shots="", uitests=""):
    code = [f for f in changed if not DOCS.search(f)]
    core = any(CORE.search(f) for f in code)
    app = any(APP.search(f) for f in code)
    if full:
        parts = [{"name": f"shots-{i}", "shots": "all", "shard": f"{i}/3", "uitests": "none", "uimodes": ""} for i in (1, 2, 3)]
        parts += [{"name": f"ui-{m}", "shots": "none", "shard": "1/1", "uitests": "all", "uimodes": m} for m in ("light", "dark")]
        return True, True, parts, "the full suite"
    want, tests, why = [], [], []
    if shots or uitests:
        want, tests, why = [shots] if shots else [], uitests.split(), ["asked for"]
    else:
        for f in code:
            hit = [m for m in MAP if re.match(m[0], f)]
            if hit:
                for _, s, t in hit:
                    want.append(s); tests += t.split()
                why.append(os.path.basename(f))
            elif f.startswith("App/UITests/"):
                # one area's tests; their base class: the smoke tests
                tests += SMOKE_TESTS.split() if f.endswith("/ShotCase.swift") else tests_in(f)
                why.append(os.path.basename(f))
            elif APP.search(f) or f.startswith(("scripts/", ".github/")):
                want.append(SMOKE); tests += SMOKE_TESTS.split(); why.append(os.path.basename(f) + " (shared: smoke)")
    rx = "|".join(dict.fromkeys(want))
    n = len([s for s in screens() if rx and re.fullmatch(rx, s)])
    ui = "all" if "all" in tests else " ".join(dict.fromkeys(tests)) or "none"
    if n == 0 and ui == "none":
        return core, app, [], "no screen touched" if code else "documentation only"
    jobs = min(3, max(1, math.ceil(n / PER_JOB)))
    dark = any(THEME.search(f) for f in code)
    if dark and ui == "none":
        ui = SMOKE_TESTS
    parts = [{"name": f"selected-{i}" if jobs > 1 else "selected", "shots": rx or "none", "shard": f"{i}/{jobs}",
              "uitests": ui if i == 1 else "none", "uimodes": "light dark" if dark else "light"} for i in range(1, jobs + 1)]
    return core, app, parts, f"{n} screens, UI tests: {ui} ({', '.join(dict.fromkeys(why))[:300]})"


def main():
    ref, event, before = os.environ.get("GITHUB_REF", ""), os.environ.get("GITHUB_EVENT_NAME", ""), os.environ.get("BEFORE", "")
    full = os.environ.get("INPUT_FULL", "") == "true" or bool(re.fullmatch(r"refs/tags/v\d+\.\d+\.0", ref))
    base = ""
    if event == "push" and re.fullmatch(r"[0-9a-f]{40}", before) and set(before) != {"0"} and git("cat-file", "-t", before) == "commit":
        base = before
    if not base:
        mb = git("merge-base", "origin/main", "HEAD")
        base = mb if mb and mb != git("rev-parse", "HEAD") else git("rev-parse", "HEAD~1")
    changed = [f for f in git("diff", "--name-only", base, "HEAD").splitlines() if f]
    shots, uitests = os.environ.get("INPUT_SHOTS", "").strip(), os.environ.get("INPUT_UITESTS", "").strip()
    bumped = bool(base and version(base) and version("HEAD") and version(base) != version("HEAD"))
    done = ""
    if ref == "refs/heads/main" and event == "push" and not full:
        # the full suite once per release: a tree that passed it on its branch is not tested again
        done = passed_full()
        if bumped and not done:
            full = True
    core, app, parts, why = plan(changed, full, shots, uitests)
    if done:
        parts, why = [], f"this tree passed the full suite ({done}): core tests and TestFlight only"
    lines = [f"core={'true' if core else 'false'}", f"app={'true' if app else 'false'}", "parts=" + json.dumps(parts),
             f"shared={'true' if len(parts) > 1 else 'false'}", f"full={'true' if full and parts else 'false'}", f"why={why}"]
    print(f"base {base[:9]}: {len(changed)} files changed")
    print("\n".join(lines))
    if os.environ.get("GITHUB_OUTPUT"):
        open(os.environ["GITHUB_OUTPUT"], "a").write("\n".join(lines) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(f"**Plan**: core tests {core}, app changed {app}, {len(parts)} simulator job(s): {why}\n")


if __name__ == "__main__":
    main()
