# Polestar-Guidelime

A bridge between [Guidelime](https://www.curseforge.com/wow/addons/guidelime) guides and
[Polestar](https://polestar.guide): install it next to Guidelime and any Guidelime guide addon
(such as TUGs), and Polestar plays those guides, with its own arrow, quest tracking and step list.

Nothing is converted ahead of time: the guides are read from the guide addons you have
installed, every time you log in.

## Install

Put these in your `Interface\AddOns` folder:

| Addon | Where from |
| --- | --- |
| Polestar (all its folders) | Polestar's own download |
| Guidelime | CurseForge |
| A Guidelime guide addon, e.g. `GuideLime_TUGs_Forever` | its author |
| `!Polestar_Guidelime` | this repository |

Log in: the chat says how many guides were read, and they show in Polestar's guide list under
the guide pack's name (e.g. "TUGs The Ultimate (Leveling) Guides").

Guidelime's `.toc` may target an older game version than your client: tick **Load out of date
AddOns** if the client won't load it. Guidelime keeps running beside Polestar; if its window or
its auto-accept gets in your way, turn them off in its settings (`/lime`).

## How it works

- **The hook.** Guide addons register their guides with `Guidelime.registerGuide(text, group)`.
  The bridge wraps that function: Guidelime still gets every guide as before, and the bridge
  reads the same text into Polestar (`Polestar.RegisterGuide`) as a guide of its community
  pack `guidelime`.
- **The `!` in the folder name.** The client loads addons by name, after their dependencies,
  so `!Polestar_Guidelime` loads before the guide addons and its hook is in place when they
  register. Guidelime keeps its guides to itself, so a guide registered before the hook
  can't be read.
- **Converting.** Each Guidelime line becomes a Polestar step: quest accepts, turn-ins and
  objectives, coordinates, class/race/faction lines, optional steps, hearth, flights and
  flight paths, setting your hearth, levels, buying and using items, trainers, vendors and
  skills. Lines at the same quest NPC are merged into one step; plain advice becomes the next
  step's note.
- **Quest data.** Quest titles, quest givers and enders and where they stand come from
  Polestar's quest database (`Polestar_QuestDB`), which the bridge loads. Flight points, inns
  and zone names are in `Data.lua`, generated from Polestar's travel data.
- **Next guides.** `[NX]` links are matched to the guide they name, within the same group and
  faction; a link a level range off ("6-12 Durotar" for "6-9 Durotar") still finds its guide.
  A link to a guide that isn't installed, or to the other faction's, falls back to the one
  guide of the same zone and faction that starts where this one ends, else to none.

## Development

```sh
pip install lupa
python tools/gen_data.py      # regenerate !Polestar_Guidelime/Data.lua after a Polestar update
python tools/test_bridge.py   # simulate a game load and check every guide
```

Both tools look for the addons in the folder above this repository; point them elsewhere
with `--addons DIR` (or `POLESTAR_ADDONS`). `test_bridge.py` takes the guide addon's folder
with `--guides` (default `GuideLime_TUGs_Forever`). It runs Lua 5.1 (the game's) with
Polestar's real guide validator and quest database, a stand-in Guidelime, the bridge, then
every file of the guide addon in its TOC order, and checks that every guide is accepted and
every next-guide link leads to a guide of the same faction.

## License

GPL-3.0; see [LICENSE](LICENSE). Polestar, Guidelime and the guide addons are not part of this
repository and keep their own licences.
