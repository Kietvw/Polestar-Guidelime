"""Simulate a game load of Polestar + Guidelime + a guide addon + !Polestar_Guidelime in Lua 5.1.

Uses Polestar's real guide validator and QuestDB record decoder, the real
Polestar_QuestDB data files, a stand-in Guidelime, the bridge, then every file
of the guide addon in its TOC order, then the bridge's login step.

    pip install lupa
    python tools/test_bridge.py [--addons DIR] [--guides GuideLime_TUGs_Forever]

DIR holds Polestar, Polestar_QuestDB and the guide addon (default:
$POLESTAR_ADDONS, else the folder above this repository).
"""
import argparse
import os
import re
import sys

import lupa.lua51 as lua51

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ap = argparse.ArgumentParser(description="Simulate a game load of the bridge.")
ap.add_argument("--addons", default=os.environ.get("POLESTAR_ADDONS") or os.path.dirname(REPO))
ap.add_argument("--guides", default="GuideLime_TUGs_Forever", help="the Guidelime guide addon's folder name")
ARGS = ap.parse_args()


def read(*p):
    base = REPO if p[0] == "!Polestar_Guidelime" else ARGS.addons
    return open(os.path.join(base, *p), encoding="utf-8").read()


def lines_between(text, start_pat, end_pat, include_end=False):
    lines = text.splitlines()
    s = next(i for i, l in enumerate(lines) if re.match(start_pat, l))
    e = next(i for i, l in enumerate(lines) if i > s and re.match(end_pat, l))
    return "\n".join(lines[s:e + (1 if include_end else 0)])


def toc_files(folder, toc):
    out = []
    for line in read(folder, toc).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line.replace("\\", os.sep))
    return out


L = lua51.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()

# Polestar's validator.
guides_src = read("Polestar", "Core", "Guides.lua")
validate = L.execute("local Guides, Own = {}, {}\nlocal SIDES = { alliance = 'Alliance', horde = 'Horde' }\n"
                     + lines_between(guides_src, r"local function isNum\(v\)", r"Guides\.Validate = validate")
                     + "\nreturn validate")
G.validate = validate

# Polestar's QuestDB decoder.
qdb_src = read("Polestar", "Quests", "QuestDB.lua")
decode = L.execute("local byte, sub, find, gmatch, gsub, char = string.byte, string.sub, string.find, string.gmatch, string.gsub, string.char\n"
                   "local unpack, floor = unpack, math.floor\n"
                   + lines_between(qdb_src, r"local function hex\(h\)", r"local function view\(kind\)")
                   + "\nreturn decode")
G.decode = decode

L.execute(r"""
chatlog = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chatlog, m) end }
C_AddOns = { GetAddOnMetadata = function(a, f) return "0.1.0" end }
results = { pack = nil, guides = {}, order = {}, errors = {} }
local recs = { quests = {}, npcs = {}, objects = {}, items = {} }
local cache = {}
local meta
Polestar = {
  RegisterPack = function(m) results.pack = m; return true end,
  RegisterGuide = function(def)
    local err = validate(def)
    if err then table.insert(results.errors, def.id .. ": " .. err); return false, err end
    if def.pack ~= "guidelime" or def.id:sub(1, 10) ~= "guidelime/" then return false, "prefix" end
    if not results.guides[def.id] then table.insert(results.order, def.id) end
    results.guides[def.id] = def
    return true
  end,
  Guides = { List = function()
    local out = {}
    for _, id in ipairs(results.order) do out[#out + 1] = results.guides[id] end
    return out
  end },
  QuestDB = {
    ADDON = "Polestar_QuestDB",
    IsLoaded = function() return meta ~= nil end,
    IsWanted = function() return true end,
    SetMeta = function(m) meta = m end,
    AddChunk = function(kind, lo, hi, text)
      local t = recs[kind]
      for id, payload in text:gmatch("(%-?%d+)\t([^\n]*)") do t[tonumber(id)] = payload end
    end,
  },
  Data = { Pack = function(name) results.packLoaded = name; return loadQuestDB() end },
  Fire = function(msg) results.fired = msg end,
}
local function rec(kind) return function(id)
  local p = recs[kind][id]; if not p then return nil end
  return decode(p)
end end
Polestar.QuestDB.QuestRecord = rec("quests")
Polestar.QuestDB.NpcRecord = rec("npcs")
Polestar.QuestDB.ObjectRecord = rec("objects")
Polestar.QuestDB.ItemRecord = rec("items")
Guidelime = { registerGuide = function(text, group) return { text = text, name = group } end }
""")

qdb_files = toc_files("Polestar_QuestDB", "Polestar_QuestDB.toc")


def load_questdb():
    for f in qdb_files:
        fn = L.eval("loadstring")(read("Polestar_QuestDB", f), "=" + f)
        if isinstance(fn, tuple):
            raise SystemExit(f"{f}: {fn[1]}")
        fn("Polestar_QuestDB", L.table())
    # MapFrames.lua may not call SetMeta in this stand-in: mark it loaded.
    if not L.eval("Polestar.QuestDB.IsLoaded()"):
        L.execute("Polestar.QuestDB.SetMeta({})")
    return True


G.loadQuestDB = load_questdb

# The bridge.
B = L.table()
for f in toc_files("!Polestar_Guidelime", "!Polestar_Guidelime.toc"):
    fn = L.eval("loadstring")(read("!Polestar_Guidelime", f), "=" + f)
    if isinstance(fn, tuple):
        raise SystemExit(f"{f}: syntax error: {fn[1]}")
    fn("!Polestar_Guidelime", B)

# The guide addon, in its TOC order.
pack = ARGS.guides
for f in toc_files(pack, pack + ".toc"):
    fn = L.eval("loadstring")(read(pack, f), "=" + f)
    if isinstance(fn, tuple):
        raise SystemExit(f"{f}: syntax error: {fn[1]}")
    fn(pack, L.table())

B.OnLogin()

r = G.results
order = list(r.order.values())
steps = sum(len(r.guides[i].steps) for i in order)
print("pack:", r.pack and r.pack.id, "| questdb loaded via:", r.packLoaded, "| fired:", r.fired)
print(f"guides: {len(order)}, steps: {steps}")
errs = list(r.errors.values())
print(f"validator errors: {len(errs)}")
for e in errs[:20]:
    print("  ", e)
ids = set(order)
broken = [(i, r.guides[i].next) for i in order if r.guides[i].next and r.guides[i].next not in ids]
print(f"next links: {sum(1 for i in order if r.guides[i].next)}, broken: {len(broken)}")
for b in broken[:10]:
    print("  ", b)
cross = [(i, r.guides[i].next) for i in order if r.guides[i].next in ids
         and r.guides[i].faction and r.guides[r.guides[i].next].faction
         and r.guides[i].faction != r.guides[r.guides[i].next].faction]
print(f"links to the other faction: {len(cross)}")
for c in cross[:10]:
    print("  ", c)
broken += cross
print("chat:")
for m in r and G.chatlog.values():
    print("  ", m)
# Spot check: the first guide's first steps.
if order:
    first = r.guides[order[0]]
    print(f"{first.id}: {first.title} -> {first.next}")
    for s in list(first.steps.values())[:3]:
        print("   step:", s.title, [dict(g) for g in s.goals.values()])
sys.exit(1 if errs or broken else 0)
