#!/usr/bin/env python3
"""Captures the screens listed by scripts/screenshots.sh (its `shot <name> <screen> <light|dark>` lines).

usage: shots.py <udid> <bundle id> <out dir> <list file>
env:   SHOTS  "all" (default), "none", or a regex on the screen name or the shot name
       SHARD  "i/n": the i-th of n parallel jobs (screens are dealt out in turn)

Faster than one launch per picture (2026-11-18, the app job took an hour):
- one launch per screen: its other appearance is captured by switching the simulator's
  appearance, without launching again;
- the first launch of a job is a warm-up (a cold launch is slow), then a fixed 6 s per launch.
"""
import os, re, subprocess, sys, time

udid, bundle, out, listfile = sys.argv[1:5]
want = os.environ.get("SHOTS", "all").strip() or "all"
i, n = (int(x) for x in (os.environ.get("SHARD", "1/1").strip() or "1/1").split("/"))


def simctl(*a, quiet=True):
    return subprocess.run(["xcrun", "simctl", *a], stdout=subprocess.DEVNULL if quiet else None, stderr=subprocess.DEVNULL if quiet else None)


def args(screen):
    if screen == "signin": return []
    if screen.startswith("signin-"): return ["-signin", screen[7:]]
    if screen.startswith("guest-"): return ["-guest", screen[6:]]
    if screen.startswith("member-"): return ["-demo", "-member", "-screen", screen[7:]]
    # a to-do's levels (one shape): todo-pulled, todo-folded, todo-done
    if screen.startswith("todo-"): return ["-demo", "-screen", "todo", "-todo", screen[5:]]
    # printed cards: card-<ID> scanned signed out, card-in-<ID> signed in, card-code / card-taken (steps)
    if screen == "card-code": return ["-card", "K7Q2MX", "-screen", "cardcode"]
    if screen == "card-taken": return ["-card", "K7Q2MX", "-screen", "cardtaken"]
    if screen.startswith("card-in-"): return ["-demo", "-card", screen[8:]]
    if screen.startswith("card-"): return ["-card", screen[5:]]
    if screen == "join": return ["-join"]
    if screen == "join-member": return ["-join", "member"]
    return ["-demo", "-screen", screen]


def frame(path):
    simctl("io", udid, "screenshot", path)
    try: return open(path, "rb").read()
    except OSError: return b""


def blank(path, name):
    """A frame with nearly nothing on it (a white screen is about 77 KB) is an app that hangs or
    never drew: say so and keep what its main thread is doing (`sample`, 3 s) beside the pictures
    (run 45082572612: three blank screens passed for done)."""
    try: size = os.path.getsize(path)
    except OSError: return
    if size > 90_000: return
    print(f"WARNING {name}: a blank frame ({size} bytes); sampling the app", flush=True)
    pid = subprocess.run(["pgrep", "-n", "-f", "Belfry.app/Belfry"], capture_output=True, text=True).stdout.strip()
    if pid: subprocess.run(["sample", pid, "3", "-file", os.path.join(out, f"sample-blank-{name}.txt")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Run 45092295271: both blank frames were an app still inside AppModel.init when sampled, a
    # launch that took over 6 s on a slow simulator, not a hang. The sample took 3 s: take the
    # picture again, and twice more 4 s apart while it stays blank.
    for _ in range(3):
        frame(path)
        try: size = os.path.getsize(path)
        except OSError: return
        if size > 90_000:
            print(f"{name}: drawn on a later frame ({size} bytes)", flush=True)
            return
        time.sleep(4)
    print(f"WARNING {name}: STILL blank after 15 s", flush=True)


def settle(path):
    """The demo's scripted steps (a sheet opened, a screen pushed) run for several seconds after a
    launch, and a cold launch is slower still: a fixed wait, as before. (Ending the wait when two
    frames were the same was tried on run 44396079158: it took a blank launch screen and a screen
    before its scripted push for finished ones.)"""
    time.sleep(float(os.environ.get("WAIT", "6")))
    frame(path)


shots = []  # (name, screen, mode)
for line in open(listfile, encoding="utf-8"):
    p = line.split()
    if len(p) == 3: shots.append(tuple(p))
order = []
for _, s, _ in shots:
    if s not in order: order.append(s)
mine = [s for k, s in enumerate(order) if k % n == i - 1]
if want == "none": mine = []
elif want != "all":
    rx = re.compile(want)
    named = {s for name, s, _ in shots if rx.fullmatch(name)}
    mine = [s for s in mine if rx.fullmatch(s) or s in named]
print(f"shots: {len(mine)} of {len(order)} screens (SHOTS={want[:80]}, SHARD={i}/{n})", flush=True)
t_all = time.time()
if mine:
    # a cold first launch takes far longer than the rest: one launch that is not photographed
    simctl("launch", udid, bundle, "-demo", "-screen", "home")
    time.sleep(float(os.environ.get("WARMUP", "12")))
for s in mine:
    todo = [(name, mode) for name, sc, mode in shots if sc == s]
    first = todo[0][1]
    simctl("ui", udid, "appearance", first)
    simctl("terminate", udid, bundle)
    simctl("launch", udid, bundle, *args(s))
    current = first
    settled = False
    before = b""  # the last frame taken in the other appearance
    for name, mode in sorted(todo, key=lambda x: x[1] != first):
        path = os.path.join(out, name + ".png")
        if mode != current:
            simctl("ui", udid, "appearance", mode)
            current = mode
            # a sheet takes longer than a screen to redraw in the other appearance (run 44568521053:
            # 06c-invite-external was still dark after 1.5 s)
            time.sleep(float(os.environ.get("SWITCH", "3")))
            got = frame(path)
            # the switch had not been drawn yet (main run 44510312803: 100b-home-dark was the
            # light frame, byte for byte): wait and take it again, a few times
            tries = 0
            while before and got == before and tries < 4:
                tries += 1
                time.sleep(2)
                got = frame(path)
            if before and got == before: print(f"WARNING {name}: the same frame as the other appearance", flush=True)
            before = got
        elif not settled:
            settle(path)
            settled = True
            before = open(path, "rb").read() if os.path.exists(path) else b""
        else:
            before = frame(path)
        print("captured " + name, flush=True)
        blank(path, name)
simctl("ui", udid, "appearance", "light")
print(f"shots done in {time.time() - t_all:.0f} s", flush=True)
