#!/usr/bin/env python3
"""What a CI run has to do (Xavier, 2026-11-18: "only test what could likely be impacted"; the full
suite of screenshots and UI tests only for a release with a new minor version).

Reads the changed files (git diff BASE..HEAD) and prints GitHub outputs:
  core=true|false     run the core tests (BelfryCore, its tests, the vectors)
  app=true|false      app code changed: main uploads to TestFlight (after the core tests)
  parts=<JSON list>   simulator jobs: {name, shots, shard, uitests, uimodes}; [] = none
  why=<one line>

Full suite: a tag vX.Y.0, a change of the major or minor of MARKETING_VERSION in project.yml, or
the workflow's `full` input. Otherwise the screens and UI tests mapped from the changed files
(MAP below: keep it current when a screen moves to another file), a small smoke set for shared code.
"""
import json, math, os, re, subprocess, sys

SMOKE = "home|feed|drawer|pulldown|event|charter|members|composer"
SMOKE_TESTS = "testKeyboardComposer testMessageMenu"
# file (regex on its path) → screens (regex on the screenshot script's screen names), UI tests
MAP = [
    (r"App/Sources/(InviteSheet|AgentUI)", "invite.*|membersinvite.*|addagent|myprofile", ""),
    (r"App/Sources/(CharterUI|AppModel\+Charter)", "charter|whoagreed|agreement|welcomecharter|guest-apply|home", ""),
    (r"App/Sources/WelcomeUI", "welcome.*", ""),
    (r"App/Sources/(Composer|MessageField)", "composer.*|feed|thread|mailreply", "testKeyboardComposer testAddMenu testEventChatTyping"),
    (r"App/Sources/(ChannelView|MessageRow|MarkdownText|MessageButtons|RefBox)", "feed|thread|threadscreen|website|composer|mailfeed|town", "testMessageMenu testKeyboardComposer"),
    (r"App/Sources/MessageActions", "menu|delete|edit|feed|thread|threadscreen", "testMessageMenu"),
    (r"App/Sources/ThreadView", "thread|threadscreen|mentions", ""),
    (r"App/Sources/(PullDown|ChannelPlaces|ChannelDetails|NotifySheet)", "pull.*|member-pulldown|pinned|chsettings|chvisibility|chpublic|notify|members|membersinvitech|todos|files|log|closedrequests", ""),
    (r"App/Sources/TodoScreen", "todo.*|mytodos", "testTodoAssign"),
    (r"App/Sources/(TownDrawer|Tabs)", ".*drawer|home|town|calendar|groups", "testDrawerSwipe testDrawerDrag testHomeDrawer testCalendarAndGroupsDrawer"),
    (r"App/Sources/(HomeView|AppModel\+Home)", "home|homedrawer|guest-home|guest-applied|mytodos", "testHomeDrawer"),
    (r"App/Sources/CalendarView", "calendar.*|guest-calendar", ""),
    (r"App/Sources/(GroupsView|GroupPage|ArchiveUI|AppModel\+Archive)", "groups.*|group.*|pod|archivedlist", ""),
    (r"App/Sources/(EventScreen|EventsUI|Tickets|AppModel\+Events|AppModel\+Checkin|GroupRoles)", "event.*|events|ticket|checkin.*|calendar", "testEventHeaderDrag testEventChatTyping"),
    (r"App/Sources/(MeetingUI|AppModel\+Meetings)", "meeting.*", ""),
    (r"App/Sources/(GuestUI|JoinUI|AppModel\+Guest|AppModel\+MemberLink|AppModel\+Apply)", "guest-.*|join-member", "testMemberLinkSignUp"),
    (r"App/Sources/(SignInView|AppModel\+SignIn|NoLinkUI|WayInUI|AppModel\+WayIn)", "signin.*", ""),
    (r"App/Sources/(PeopleUI|MembersDirectory|RequestsView|AppModel\+People)", "profile|editprofile|me|meplace|mycard|myprofile|members|directory|requests|rolepicker|eventrole", ""),
    (r"App/Sources/(BelfrySettings|RolesSettings|ChannelEnd)", "settings.*|channelend.*|channelarchive|rolepicker", "testDeleteEmptyChannel"),
    (r"App/Sources/MailUI", "mail.*|fullmail", ""),
    (r"App/Sources/ProposalScreen", "proposal.*", ""),
    (r"App/Sources/(MessagesView|MentionsView)", "messages|conversation|mentions|mail", ""),
    (r"App/Sources/(AccountsSheet|AppModel\+Accounts|AboutScreen)", "accounts|about", ""),
    (r"App/Sources/CreateMenu", "create|add", "testAddMenu"),
    (r"App/Sources/AppModel\+Push", "notifications", ""),
]
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
                tests = ["all"]; why.append("the UI tests")
            elif APP.search(f) or f.startswith(("scripts/", ".github/")):
                want.append(SMOKE); tests += SMOKE_TESTS.split(); why.append(os.path.basename(f) + " (shared: smoke)")
    rx = "|".join(dict.fromkeys(want))
    n = len([s for s in screens() if rx and re.fullmatch(rx, s)])
    ui = "all" if "all" in tests else " ".join(dict.fromkeys(tests)) or "none"
    if n == 0 and ui == "none":
        return core, app, [], "no screen touched" if code else "documentation only"
    jobs = min(3, max(1, math.ceil(n / PER_JOB)))
    parts = [{"name": f"selected-{i}" if jobs > 1 else "selected", "shots": rx or "none", "shard": f"{i}/{jobs}",
              "uitests": ui if i == 1 else "none", "uimodes": "light"} for i in range(1, jobs + 1)]
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
    if base and version(base) and version("HEAD") and version(base) != version("HEAD"):
        full = True
    core, app, parts, why = plan(changed, full, os.environ.get("INPUT_SHOTS", "").strip(), os.environ.get("INPUT_UITESTS", "").strip())
    lines = [f"core={'true' if core else 'false'}", f"app={'true' if app else 'false'}", "parts=" + json.dumps(parts), f"why={why}"]
    print(f"base {base[:9]}: {len(changed)} files changed")
    print("\n".join(lines))
    if os.environ.get("GITHUB_OUTPUT"):
        open(os.environ["GITHUB_OUTPUT"], "a").write("\n".join(lines) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(f"**Plan**: core tests {core}, app changed {app}, {len(parts)} simulator job(s): {why}\n")


if __name__ == "__main__":
    main()
