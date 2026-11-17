#!/usr/bin/env python3
"""Reference for SPEC 19.34 (channel categories) and the generator of vectors/categories.json.
Run: python3 tools/vectors/categories.py > vectors/categories.json"""
import json

LIFE, BUILDING = "life", "building"
DEFAULT_NAMES = {LIFE: "Community life", BUILDING: "Building together"}
BUILDING_DEFAULT = ["proposals", "website"]
GENERAL = "general"


def parse(content):
    try:
        obj = json.loads(content) if content else {}
    except Exception:
        obj = {}
    if not isinstance(obj, dict):
        obj = {}
    order = [x for x in obj.get("order", []) if isinstance(x, str)][:1000] if isinstance(obj.get("order"), list) else []
    cats = None
    if isinstance(obj.get("categories"), list):
        cats = []
        ids = set()
        for c in obj["categories"][:100]:
            if not isinstance(c, dict) or not isinstance(c.get("id"), str):
                continue
            cid = c["id"].strip()[:64]
            if not cid or cid == "town" or cid in ids:
                continue
            ids.add(cid)
            name = c.get("name").strip()[:60] if isinstance(c.get("name"), str) else ""
            chans = [x for x in c.get("channels", []) if isinstance(x, str)][:1000] if isinstance(c.get("channels"), list) else []
            cats.append({"id": cid, "name": name, "channels": chans})
    return order, cats


def in_order(ids, order):
    at = {}
    for i, x in enumerate(order):
        at.setdefault(x, i)
    return [x for _, x in sorted(enumerate(ids), key=lambda p: at.get(p[1], 1_000_000 + p[0]))]


def arrange(content, channels):
    """channels: the town's listed channels in their natural order (general included or not)."""
    order, cats = parse(content)
    visible = [c for c in channels if c != GENERAL]
    vis = set(visible)
    ordered = in_order(visible, order)
    out = []
    if cats is None:
        out.append({"id": LIFE, "name": DEFAULT_NAMES[LIFE], "channels": [c for c in ordered if c not in BUILDING_DEFAULT]})
        out.append({"id": BUILDING, "name": DEFAULT_NAMES[BUILDING], "channels": [c for c in ordered if c in BUILDING_DEFAULT]})
        return out
    seen = set()
    for c in cats:
        chans = []
        for x in c["channels"]:
            if x in vis and x not in seen:
                seen.add(x)
                chans.append(x)
        out.append({"id": c["id"], "name": c["name"] or DEFAULT_NAMES.get(c["id"], c["id"]), "channels": chans})
    ids = [c["id"] for c in out]
    if BUILDING not in ids:
        chans = [x for x in ordered if x in BUILDING_DEFAULT and x not in seen]
        seen.update(chans)
        out.append({"id": BUILDING, "name": DEFAULT_NAMES[BUILDING], "channels": chans})
    if LIFE not in ids:
        out.insert(0, {"id": LIFE, "name": DEFAULT_NAMES[LIFE], "channels": []})
    life = next(c for c in out if c["id"] == LIFE)
    life["channels"] += [x for x in ordered if x not in seen]
    return out


def shown(cats, admin):
    return [c["id"] for c in cats if c["channels"] or (admin and c["id"] != BUILDING)]


def encode(cats, previous, known):
    """cats: the full arrangement as edited. previous: the last event's content (unknown ids kept)."""
    _, prev = parse(previous)
    prev = {c["id"]: c["channels"] for c in (prev or [])}
    known = set(known)
    written = set()
    out = []
    for c in cats:
        chans = []
        for x in c["channels"]:
            if x not in written:
                written.add(x)
                chans.append(x)
        out.append((c, chans))
    res = []
    order = [GENERAL]
    for c, chans in out:
        for x in prev.get(c["id"], []):
            if x not in known and x not in written and x != GENERAL:
                written.add(x)
                chans.append(x)
        if c["id"] == BUILDING and not chans:
            continue
        item = {"id": c["id"]}
        name = c["name"].strip()
        if name and not (c["id"] in DEFAULT_NAMES and name == DEFAULT_NAMES[c["id"]]):
            item["name"] = name
        item["channels"] = chans
        res.append(item)
        order += chans
    return {"order": order, "categories": res}


def rebuild(cats, flat):
    """flat: ["h:<category>", "c:<channel>"...] after a move; categories not in it keep their channels."""
    heads = [x[2:] for x in flat if x.startswith("h:")]
    new = {h: [] for h in heads}
    cur = heads[0] if heads else LIFE
    for x in flat:
        if x.startswith("h:"):
            cur = x[2:]
        else:
            new.setdefault(cur, []).append(x[2:])
    return [{"id": c["id"], "name": c["name"], "channels": new.get(c["id"], c["channels"]) if c["id"] in new else c["channels"]} for c in cats]


NAT = ["general", "garden", "kitchen", "repair", "proposals", "website", "hello"]
READ = [
    ("absent: as before (life, then building with proposals and website)", json.dumps({"order": ["kitchen", "general", "website", "garden"]})),
    ("no event at all", None),
    ("not JSON", "{oops"),
    ("categories: a custom one first, life renamed, building left out (keeps its defaults)",
     json.dumps({"order": [], "categories": [
         {"id": "making-4b1c", "name": "Making & mending", "channels": ["repair", "kitchen"]},
         {"id": "life", "name": "Everyday", "channels": ["hello"]}]})),
    ("life left out (first, gets the rest); building named with no name (default title)",
     json.dumps({"order": ["hello", "garden"], "categories": [
         {"id": "building", "channels": ["website"]},
         {"id": "making-4b1c", "name": "Making", "channels": ["repair"]}]})),
    ("a channel in two categories counts in the first; unknown ids and general ignored; duplicate and bad entries skipped",
     json.dumps({"order": [], "categories": [
         {"id": "a-1111", "name": "A", "channels": ["garden", "nope", "general"]},
         {"id": "b-2222", "name": "B", "channels": ["garden", "kitchen"]},
         {"id": "a-1111", "name": "A again", "channels": ["hello"]},
         {"name": "no id"}, "text", {"id": "town", "name": "Town", "channels": ["website"]},
         {"id": "empty-3333", "name": "Empty", "channels": []}]})),
    ("building named explicitly but empty: proposals and website go to life; building hidden",
     json.dumps({"order": ["proposals"], "categories": [{"id": "life", "channels": ["garden"]}, {"id": "building", "channels": []}]})),
]

WRITE = [
    ("built-in names left out, empty building left out, general first in order",
     [{"id": "life", "name": "Community life", "channels": ["garden", "kitchen", "proposals"]},
      {"id": "making-4b1c", "name": "Making", "channels": ["repair"]},
      {"id": "building", "name": "Building together", "channels": []}], None, ["garden", "kitchen", "proposals", "repair"]),
    ("renamed built-in keeps its name; ids the writer can't see (archived) stay in their category",
     [{"id": "life", "name": "Everyday", "channels": ["garden"]},
      {"id": "building", "name": "Building together", "channels": ["website"]}],
     json.dumps({"order": [], "categories": [{"id": "life", "channels": ["old-archived", "garden", "kitchen"]}, {"id": "gone-9999", "name": "Gone", "channels": ["lost"]}]}),
     ["garden", "website", "kitchen"]),
]

FLAT = [
    ("garden dragged into Making, under repair",
     [{"id": "life", "name": "Community life", "channels": ["garden", "kitchen"]},
      {"id": "making-4b1c", "name": "Making", "channels": ["repair"]},
      {"id": "building", "name": "Building together", "channels": []}],
     ["h:life", "c:kitchen", "h:making-4b1c", "c:repair", "c:garden"]),
    ("dragged above the first header: into the first category; building not in the list keeps its channels",
     [{"id": "life", "name": "Community life", "channels": ["garden"]},
      {"id": "making-4b1c", "name": "Making", "channels": ["repair"]},
      {"id": "building", "name": "Building together", "channels": ["website"]}],
     ["c:repair", "h:life", "c:garden", "h:making-4b1c"]),
]


def main():
    out = {
        "about": "SPEC 19.34 channel categories: 30078 d=belfry:channel-order by a belfry admin, content {order, categories}. "
                 "read: arrange(content, channels in natural order) -> categories with their visible channels; shown_member / shown_admin = the "
                 "categories the drawer shows. write: encode(categories, previous content, channels the writer sees). flat: a drag in the flat "
                 "list of headers (h:) and channels (c:) -> categories.",
        "generated_by": "belfry-ios tools/vectors/categories.py (2026-11-17)",
        "default_names": DEFAULT_NAMES,
        "building_default": BUILDING_DEFAULT,
        "read": [], "write": [], "flat": [],
    }
    for name, content in READ:
        cats = arrange(content, NAT)
        out["read"].append({"name": name, "content": content, "channels": NAT, "expected": cats,
                            "shown_member": shown(cats, False), "shown_admin": shown(cats, True)})
    for name, cats, prev, known in WRITE:
        out["write"].append({"name": name, "categories": cats, "previous": prev, "known": known, "expected": encode(cats, prev, known)})
    for name, cats, flat in FLAT:
        out["flat"].append({"name": name, "categories": cats, "flat": flat, "expected": rebuild(cats, flat)})
    print(json.dumps(out, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
