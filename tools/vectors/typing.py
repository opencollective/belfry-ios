#!/usr/bin/env python3
"""vectors/typing.json: typing indicators (collective-belfry docs/typing.md @7750419, SPEC 19.66).
Written by belfry-ios on 2026-11-21; Android and the web copy the file byte for byte.
Run: python3 -I tools/vectors/typing.py > vectors/typing.json"""
import json

SEND_GAP = 4      # s between two typing events for one place
SHOW_FOR = 6      # s a person shows as typing after their latest event
SKEW = 10         # s: an event further than this from now (past or future) is ignored
STOP_WINDOW = 6   # s: a stop goes only if a typing event went out this recently

def text(names):
    if not names: return ""
    if len(names) == 1: return f"{names[0]} is typing…"
    if len(names) == 2: return f"{names[0]} and {names[1]} are typing…"
    return "Several people are typing…"

def accepted(created_at, now):
    return abs(now - created_at) <= SKEW

def board(steps, me):
    """steps: events / messages / queries in time order; returns each query's typers (by first
    shown, earliest first)."""
    until, since, out = {}, {}, []
    for s in steps:
        t, now = s["type"], s["now"]
        if t == "event":
            a = s["author"]
            if a == me or not accepted(s["created_at"], now): continue
            if s.get("stop"):
                until.pop(a, None); since.pop(a, None); continue
            if a not in until or until[a] <= now: since[a] = now
            until[a] = now + SHOW_FOR
        elif t == "message":
            until.pop(s["author"], None); since.pop(s["author"], None)
        elif t == "query":
            live = [a for a, u in until.items() if u > now]
            out.append(sorted(live, key=lambda a: (since[a], a)))
    return out

def sender(steps):
    """steps: keystrokes (the field's text after it), clears (emptied without sending), sends;
    returns what went out: ["typing", now] / ["stop", now]."""
    last, out = None, []
    for s in steps:
        t, now = s["type"], s["now"]
        if t == "key":
            if s.get("restored") or s.get("editing") or not s["text"].strip(): continue
            if last is None or now - last >= SEND_GAP:
                out.append(["typing", now]); last = now
        elif t == "clear":
            if last is not None and now - last < STOP_WINDOW: out.append(["stop", now])
            last = None
        elif t == "send":
            last = None
    return out

ME, LINA, BEN, CHLOE = "aa" * 32, "bb" * 32, "cc" * 32, "dd" * 32
NAMES = {LINA: "Lina Moreau", BEN: "Ben Okafor", CHLOE: "Chloé Martin"}

texts = [
    {"names": [], "text": ""},
    {"names": ["Lina Moreau"], "text": text(["Lina Moreau"])},
    {"names": ["Lina Moreau", "Ben Okafor"], "text": text(["Lina Moreau", "Ben Okafor"])},
    {"names": ["Lina Moreau", "Ben Okafor", "Chloé Martin"], "text": text(["a", "b", "c"])},
    {"names": ["Somebody"], "text": text(["Somebody"])},
]
accept = [{"created_at": c, "now": 1000, "accepted": accepted(c, 1000), "note": n} for c, n in [
    (1000, "now"), (990, "10 s old: kept"), (989, "11 s old: stale"), (1010, "10 s ahead: kept"), (1011, "11 s ahead: from the future"), (700, "a replay 5 minutes old")]]

def B(note, steps):
    return {"note": note, "me": ME, "steps": steps, "expect": board(steps, ME)}

boards = [
    B("one person: shown for 6 s after their latest event", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 100},
        {"type": "query", "now": 103}, {"type": "query", "now": 105.9}, {"type": "query", "now": 106}]),
    B("events every 4 s keep it on", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 100},
        {"type": "event", "now": 104, "author": LINA, "created_at": 104},
        {"type": "query", "now": 109}, {"type": "query", "now": 110}]),
    B("a stop ends it at once", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 100},
        {"type": "event", "now": 102, "author": LINA, "created_at": 102, "stop": True},
        {"type": "query", "now": 102.5}]),
    B("their message ends it", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 100},
        {"type": "message", "now": 101, "author": LINA},
        {"type": "query", "now": 101.5}]),
    B("someone else's message doesn't", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 100},
        {"type": "message", "now": 101, "author": BEN},
        {"type": "query", "now": 101.5}]),
    B("two, then three people: ordered by who started first", [
        {"type": "event", "now": 100, "author": BEN, "created_at": 100},
        {"type": "event", "now": 101, "author": LINA, "created_at": 101},
        {"type": "query", "now": 102},
        {"type": "event", "now": 102, "author": CHLOE, "created_at": 102},
        {"type": "query", "now": 103},
        {"type": "query", "now": 106.5}]),
    B("stale and future events are ignored; my own too", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 80},
        {"type": "event", "now": 100, "author": BEN, "created_at": 115},
        {"type": "event", "now": 100, "author": ME, "created_at": 100},
        {"type": "query", "now": 100.5}]),
    B("a replayed event 5 minutes old shows nothing", [
        {"type": "event", "now": 400, "author": LINA, "created_at": 100},
        {"type": "query", "now": 400.5}]),
    B("typing again after it ended starts a new turn", [
        {"type": "event", "now": 100, "author": LINA, "created_at": 100},
        {"type": "event", "now": 101, "author": BEN, "created_at": 101},
        {"type": "query", "now": 107.5},
        {"type": "event", "now": 108, "author": LINA, "created_at": 108},
        {"type": "query", "now": 108.5}]),
]

def S(note, steps):
    return {"note": note, "steps": steps, "expect": sender(steps)}

senders = [
    S("one event per 4 s while typing", [{"type": "key", "now": t, "text": "h" * (i + 1)} for i, t in enumerate([0, 1, 2, 3.9, 4, 5, 7.9, 8.5])]),
    S("only spaces, a restored draft, an edit: nothing", [
        {"type": "key", "now": 0, "text": "   "}, {"type": "key", "now": 1, "text": "draft", "restored": True},
        {"type": "key", "now": 2, "text": "fixed typo", "editing": True}]),
    S("cleared within 6 s of the last event: a stop", [
        {"type": "key", "now": 0, "text": "h"}, {"type": "key", "now": 2, "text": "he"}, {"type": "clear", "now": 5}]),
    S("cleared later: no stop", [
        {"type": "key", "now": 0, "text": "h"}, {"type": "clear", "now": 6}]),
    S("sending needs no stop; the next keystroke sends at once", [
        {"type": "key", "now": 0, "text": "hi"}, {"type": "send", "now": 1}, {"type": "key", "now": 2, "text": "a"}, {"type": "clear", "now": 3}]),
]

print(json.dumps({
    "about": "Typing indicators (collective-belfry docs/typing.md @7750419; SPEC 19.66 on iOS). Kind 20100, empty content: in a channel, group, event chat or proposal signed by the person with [\"h\", group] (and [\"e\", root] inside a thread; absent = the conversation itself) on the groups relay; in a direct message an unsigned 20100 rumor tagged p for every other participant, sealed (kind 13) and wrapped in a kind 21059 ephemeral gift wrap (created_at = the real time) to each other participant on the community relay, no copy to oneself. Optional [\"status\", \"stop\"]. Send on a keystroke that leaves the field non-empty when nothing went out for this place in the last 4 s; never for a restored draft, an edit, or only spaces; a stop when the field is emptied without sending and an event went out in the last 6 s; never through the outbox, never retried, dropped when the socket is down or the signer takes over 3 s; a refused one (rate limited) pauses that relay 30 s; off with the device setting \"Show others when I'm typing\". Show a person from an event until 6 s after their latest one, their stop, or a message of theirs (kind 9, 1111, 14 or 15) landing in that place; ignore events more than 10 s in the past or future, one's own (any device), and people muted, removed or not in the group. Order: who started first. Times in seconds; \"now\" is the reader's clock when it arrives.",
    "generated_by": "tools/vectors/typing.py (belfry-ios)",
    "constants": {"send_gap": SEND_GAP, "show_for": SHOW_FOR, "skew": SKEW, "stop_window": STOP_WINDOW, "refused_pause": 30, "signer_wait": 3, "kind": 20100, "wrap_kind": 21059},
    "names": NAMES,
    "texts": texts,
    "accept": accept,
    "board": boards,
    "sender": senders,
}, ensure_ascii=False, indent=1))
