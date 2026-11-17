-- Guidelime guide text -> a Polestar guide definition (Polestar.RegisterGuide).
--
-- One Guidelime line becomes one Polestar step (lines at the same quest NPC
-- merge into one, as in Polestar's own guides); plain advice lines become the
-- next step's note. Quest titles, quest givers and enders and their places
-- come from Polestar's quest database (Polestar_QuestDB), flight points,
-- inns and zone names from Data.lua.
local _, B = ...

local find, match, gsub, sub, lower, upper, format = string.find, string.match, string.gsub, string.sub, string.lower, string.upper, string.format
local floor, sqrt = math.floor, math.sqrt
local tinsert, tconcat = table.insert, table.concat

local CLASSES = { warrior = "WARRIOR", paladin = "PALADIN", hunter = "HUNTER", rogue = "ROGUE", priest = "PRIEST",
	shaman = "SHAMAN", mage = "MAGE", warlock = "WARLOCK", druid = "DRUID" }
local RACES = { human = "Human", dwarf = "Dwarf", gnome = "Gnome", nightelf = "NightElf", ["night elf"] = "NightElf",
	orc = "Orc", troll = "Troll", tauren = "Tauren", undead = "Scourge", scourge = "Scourge", skyborne = "Skyborne" }
local FACTIONS = { alliance = "Alliance", horde = "Horde" }
local RACE_FACTION = { Human = "Alliance", Dwarf = "Alliance", Gnome = "Alliance", NightElf = "Alliance",
	Orc = "Horde", Troll = "Horde", Tauren = "Horde", Scourge = "Horde" }
local PROFESSIONS = { alchemy = true, blacksmithing = true, cooking = true, enchanting = true, engineering = true,
	["first aid"] = true, fishing = true, herbalism = true, leatherworking = true, mining = true, skinning = true,
	tailoring = true, jewelcrafting = true }

local function trim(s) return (gsub(s or "", "^%s+", ""):gsub("%s+$", "")) end
local function round2(v) return floor(v * 100 + 0.5) / 100 end

function B.Slug(s)
	s = lower(s or ""):gsub("'", ""):gsub("&", "-and-"):gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	return s
end

---------------------------------------------------------------------------
-- Lookups
---------------------------------------------------------------------------

local zoneId -- lower-case name -> uiMapID
local function zoneByName(name)
	if not zoneId then
		zoneId = {}
		for id, n in pairs(B.ZONE_NAMES) do zoneId[lower(n)] = id end
	end
	local key = lower(trim(name))
	local id = zoneId[key]
	if id or key == "" then return id end
	-- A zone Data.lua lacks: ask the client once for every map it knows.
	if not B.mapsScanned and C_Map and C_Map.GetMapInfo then
		B.mapsScanned = true
		for i = 1, 3000 do
			local info = C_Map.GetMapInfo(i)
			if info and info.name and info.mapType == 3 then -- Enum.UIMapType.Zone
				local n = lower(info.name)
				if not zoneId[n] then zoneId[n] = i end
				if not B.ZONE_NAMES[i] then B.ZONE_NAMES[i] = info.name end
			end
		end
		return zoneId[key]
	end
	return nil
end
B.ZoneByName = zoneByName

local function QDB()
	local Q = Polestar and Polestar.QuestDB
	return Q and Q.IsLoaded and Q.IsLoaded() and Q or nil
end

local function questInfo(id)
	local Q = QDB()
	local r = Q and Q.QuestRecord(id)
	if not r then return nil end
	local function ids(v)
		if type(v) == "number" then return { v } end
		return type(v) == "table" and v or {}
	end
	local startItem = r[9]
	if type(startItem) == "table" then startItem = startItem[1] end -- several items start it: the first
	if type(startItem) ~= "number" then startItem = nil end
	return { title = r[1], level = r[2], minLevel = r[3], start = ids(r[7]), finish = ids(r[8]), startItem = startItem }
end

-- name, { map, x, y, frame } of an NPC (kind "npc") or object ("object").
local function spawn(kind, id, preferMap)
	local Q = QDB()
	local r = Q and (kind == "npc" and Q.NpcRecord(id) or Q.ObjectRecord(id))
	if not r then return nil end
	local best
	local i = 2
	while type(r[i]) == "number" and type(r[i + 2]) == "number" do
		local mp, frame, n = r[i], r[i + 1], r[i + 2]
		local x, y = r[i + 3], r[i + 4]
		if n > 0 and type(x) == "number" and type(y) == "number"
			and (not best or (preferMap and mp == preferMap and best.map ~= preferMap)) then
			best = { map = mp, x = x, y = y, frame = frame }
		end
		i = i + 3 + 3 * n
	end
	return r[1], best
end

local function npcName(id)
	local name = spawn("npc", id)
	return name or ("NPC " .. id)
end

local function itemName(id, fallback)
	local Q = QDB()
	local r = Q and Q.ItemRecord(id)
	if r and type(r[1]) == "string" and r[1] ~= "" then return r[1] end
	local n = GetItemInfo and GetItemInfo(id)
	if n then return n end
	if fallback and fallback ~= "" then return fallback end
	return "Item " .. id
end

local function putSpot(goal, pt)
	if not pt then return end
	goal.map, goal.x, goal.y = pt.map, round2(pt.x), round2(pt.y)
	if pt.frame == 0 then goal.f = "e" end -- QuestDB frame 0: the Era map frame
end

-- The first known quest giver/ender of `list` (NPC ids > 0, objects < 0) on goal.
local function placeGoal(goal, list, preferMap)
	for _, ident in ipairs(list) do
		local kind, id = "npc", ident
		if ident < 0 then kind, id = "object", -ident end
		local name, pt = spawn(kind, id, preferMap)
		if name then
			if kind == "npc" then goal.npc, goal.npcName = id, name else goal.object, goal.objName = id, name end
			putSpot(goal, pt)
			return true
		end
	end
	return false
end

local function maskOf(faction)
	return faction == "Alliance" and 1 or faction == "Horde" and 2 or nil
end

local function taxiByName(name, faction)
	local want = lower(trim(name))
	if want == "" then return nil end
	local mask = maskOf(faction)
	local exact, loose
	for _, t in ipairs(B.TAXI) do
		local first = lower(trim(match(t[6], "^([^,]+)") or t[6]))
		local own = not mask or (t[5] % (mask * 2) >= mask)
		if first == want then
			if own then return t end
			exact = exact or t
		elseif find(lower(t[6]), want, 1, true) then
			if own and not loose then loose = t end
		end
	end
	return exact or loose
end

local function taxiNear(map, x, y, faction)
	local mask = maskOf(faction)
	local best, bd
	for _, t in ipairs(B.TAXI) do
		if t[2] == map and (not mask or t[5] % (mask * 2) >= mask) then
			local d = sqrt((t[3] - x) ^ 2 + (t[4] - y) ^ 2)
			if not bd or d < bd then best, bd = t, d end
		end
	end
	return bd and bd < 8 and best or nil
end

local function innNear(map, x, y)
	local best, bd
	for _, inn in ipairs(B.INNS) do
		if inn[2] == map then
			local d = sqrt((inn[3] - x) ^ 2 + (inn[4] - y) ^ 2)
			if not bd or d < bd then best, bd = inn, d end
		end
	end
	return bd and bd < 6 and best or nil
end

local function taxiName(t) return trim(match(t[6], "^([^,]+)") or t[6]) end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local function parseOnly(arg, only, problems)
	for raw in string.gmatch(arg .. ",", "([^,]*),") do
		local w = lower(trim(raw))
		if w ~= "" then
			if CLASSES[w] then
				only.classes = only.classes or {}
				tinsert(only.classes, CLASSES[w])
			elseif RACES[w] then
				only.races = only.races or {}
				tinsert(only.races, RACES[w])
			elseif FACTIONS[w] then
				only.factions = only.factions or {}
				tinsert(only.factions, FACTIONS[w])
			elseif not match(w, "^%d+$") and problems then
				problems["unknown [A] value " .. w] = true
			end
		end
	end
end

local function parseCoord(arg, lastZone)
	local x, y, rest = match(arg, "^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)(.*)$")
	if not x then return nil end
	local _, rest2 = match(rest, "^%s*,%s*(%d+%.?%d*)(.*)$")
	if rest2 then rest = rest2 end
	local zone = trim(rest)
	if zone == "" then zone = lastZone end
	local map = zone and zoneByName(zone)
	if not (map and tonumber(x) and tonumber(y)) then return nil end
	return { map = map, x = round2(tonumber(x)), y = round2(tonumber(y)), zone = zone }
end

-- "783", "33- ", "123,2 Name" -> id, objective index, shown text, hidden
local function questRef(arg)
	local id, rest = match(arg, "^%s*(%d+)(.*)$")
	if not id then return nil end
	local oi, rest2 = match(rest, "^%s*,%s*(%d+)(.*)$")
	if rest2 then rest = rest2 end
	local hidden = find(rest, "^%-") ~= nil
	rest = trim(gsub(rest, "^%-", ""))
	return tonumber(id), tonumber(oi), (not hidden and rest ~= "") and rest or nil, hidden
end

local function hasWord(text, word)
	return find(" " .. text .. " ", "[^%a]" .. word .. "[^%a]") ~= nil
end

-- Two steps of nothing but accepts and hand-ins at the same NPC or object.
local function whoOf(g)
	if g.t ~= "accept" and g.t ~= "turnin" then return nil end
	if g.npc then return "n" .. g.npc end
	if g.object then return "o" .. g.object end
	return nil
end
local function sameSpot(a, b)
	local w
	for _, list in ipairs({ a.goals, b.goals }) do
		for _, g in ipairs(list) do
			local k = whoOf(g)
			if not k then return false end
			if w and k ~= w then return false end
			w = k
		end
	end
	return w ~= nil
end

local function sameOnly(a, b)
	if a == nil or b == nil then return a == b end
	for _, key in ipairs({ "classes", "races", "factions" }) do
		local x, y = a[key], b[key]
		if (x == nil) ~= (y == nil) then return false end
		if x then
			if #x ~= #y then return false end
			for i = 1, #x do if x[i] ~= y[i] then return false end end
		end
	end
	return true
end

local Guide = {}
Guide.__index = Guide

local function newGuide(group)
	return setmetatable({ group = group, meta = { nx = {} }, steps = {}, pendingNote = {}, zoneCounts = {}, problems = {} }, Guide)
end

function Guide:header(code, arg)
	local m = self.meta
	if code == "N" then
		m.n = trim(arg)
		local lo, hi, rest = match(m.n, "^(%d+)%s*%-%s*(%d+)%s*(.*)$")
		if lo then
			m.minLevel, m.maxLevel, m.name = tonumber(lo), tonumber(hi), trim(rest)
		else
			local lvl, rest2 = match(m.n, "^(%d+)%s+(.*)$")
			if lvl then m.minLevel, m.maxLevel, m.name = tonumber(lvl), tonumber(lvl), trim(rest2) else m.name = m.n end
		end
		if m.name == "" then m.name = m.n end
	elseif code == "NX" then
		tinsert(m.nx, trim(arg))
	elseif code == "GA" then
		local only = {}
		parseOnly(arg, only)
		if only.factions then m.faction = only.factions[1] end
		if only.races then
			m.races = only.races
			m.faction = m.faction or RACE_FACTION[only.races[1]]
		end
		if only.classes then m.classes = only.classes end
	elseif code == "D" then
		m.why = trim(gsub(gsub(arg, "{", "("), "}", ")"))
	end
end

-- Codes run together with their text: [NXAlchemy], [NTailoring].
local function normCode(code, arg)
	if sub(code, 1, 2) == "NX" and code ~= "NX" then return "NX", sub(code, 3) .. arg end
	if sub(code, 1, 1) == "N" and code ~= "N" and code ~= "NX" then return "N", sub(code, 2) .. arg end
	return code, arg
end

local TAG = "%[(%u+)([^%]]*)%]"
local HEADER = { N = true, NX = true, GA = true, D = true, DL = true, LI = true }

function Guide:line(raw)
	raw = trim(gsub(raw, "%-%-.*$", "")) -- Guidelime comments
	if raw == "" then return end

	-- Header lines: nothing but [N], [NX], [GA], [D].
	local onlyHeaders, any = true, false
	for code in string.gmatch(raw, TAG) do
		any = true
		code = normCode(code, "")
		if not HEADER[code] then onlyHeaders = false end
	end
	if any and onlyHeaders and trim(gsub(raw, TAG, "")) == "" then
		for code, arg in string.gmatch(raw, TAG) do self:header(normCode(code, arg)) end
		return
	end

	local only, coords, optional = {}, {}, false
	local quests, ci, tar, sk, sp, xp, fly, getfp, flags = {}, {}, {}, {}, {}, {}, {}, {}, {}
	local parts = {}
	local pos = 1
	while true do
		local s, e, code, arg = find(raw, TAG, pos)
		if not s then break end
		tinsert(parts, sub(raw, pos, s - 1))
		pos = e + 1
		code, arg = normCode(code, arg)
		if code == "QA" or code == "QT" or code == "QC" or code == "QS" or code == "QP" or code == "QW" then
			if code == "QP" then code = "QA" end
			if code == "QW" then code, optional = "QC", true end
			local id, oi, shown, hidden = questRef(arg)
			if id then
				local q = questInfo(id)
				local title = (q and q.title) or shown or ("Quest " .. id)
				tinsert(quests, { code = code, id = id, oi = oi, title = title, q = q })
				tinsert(parts, hidden and (title .. ", ") or (shown or title))
			end
		elseif code == "G" or code == "L" then
			local c = parseCoord(arg, self.lastZone)
			if c then
				self.lastZone = c.zone
				self.zoneCounts[c.map] = (self.zoneCounts[c.map] or 0) + 1
				if code == "G" then tinsert(coords, c) end
			end
		elseif code == "A" then
			parseOnly(arg, only, self.problems)
		elseif code == "O" or code == "OC" then
			optional = true
		elseif code == "F" then
			tinsert(fly, trim(arg))
			tinsert(parts, trim(arg))
		elseif code == "P" then
			tinsert(getfp, trim(arg))
			tinsert(parts, "flight path")
		elseif code == "H" then
			flags.H = true
			tinsert(parts, trim(arg) ~= "" and trim(arg) or "Hearthstone")
		elseif code == "S" then
			flags.S = true
			tinsert(parts, trim(arg) ~= "" and trim(arg) or "Hearthstone")
		elseif code == "T" then
			flags.T = true
			tinsert(parts, trim(arg) ~= "" and trim(arg) or "train")
		elseif code == "V" or code == "R" then
			flags.V = true
			tinsert(parts, trim(arg) ~= "" and trim(arg) or (code == "V" and "vendor" or "repair"))
		elseif code == "XP" then
			tinsert(xp, trim(arg))
			local lvl, txt = match(trim(arg), "^(%d+)[%.%d%+%-]*%s*(.*)$")
			tinsert(parts, (txt and txt ~= "" and txt) or ("level " .. (lvl or arg)))
		elseif code == "CI" or code == "UI" then
			local id, count, name = match(arg, "^%s*(%d+)%s*,?%s*(%d*)%s*(.*)$")
			if id then
				id = tonumber(id)
				local n = itemName(id, trim(name))
				tinsert(ci, { id = id, count = tonumber(count) or 1, name = n, use = code == "UI" })
				tinsert(parts, n)
			end
		elseif code == "TAR" then
			local id = tonumber(match(arg, "^%s*(%d+)"))
			if id then
				tinsert(tar, id)
				tinsert(parts, npcName(id))
			end
		elseif code == "SK" then
			local name, lvl = match(arg, "^%s*(.-)%s+(%d+)%s*$")
			if name then
				tinsert(sk, { name = name, level = tonumber(lvl) })
				tinsert(parts, name .. " " .. lvl)
			end
		elseif code == "SP" or code == "LE" then
			tinsert(sp, trim(arg))
			tinsert(parts, "spell " .. trim(arg))
		elseif HEADER[code] then
			self:header(code, arg)
		elseif code == "GG" or code == "GL" or code == "GI" or code == "GT" or code == "C" then
			-- Guidelime display switches: nothing to show.
		else
			self.problems["unhandled tag [" .. code .. "]"] = true
			tinsert(parts, arg)
		end
	end
	tinsert(parts, sub(raw, pos))
	local text = tconcat(parts)
	text = trim(gsub(gsub(text, "{", "("), "}", ")"):gsub("%s+", " "))
	text = gsub(text, "%s+([,.:!?])", "%1"):gsub(",(%S)", ", %1"):gsub(",%s*$", "")
	for _, p in ipairs({ "^[Aa]ccept%s*:%s*", "^[Tt]urn ?[Ii]n%s*:%s*", "^[Dd]o%s*:%s*", "^[Cc]omplete%s*:%s*" }) do
		text = gsub(text, p, "")
	end
	local low = lower(text)

	local preferMap = coords[1] and coords[1].map
	local faction = self.meta.faction
	local goals = {}

	-- Quests.
	for _, qq in ipairs(quests) do
		local g
		if (qq.code == "QC" or qq.code == "QS") and qq.oi then
			-- One objective: done when that objective line is.
			g = { t = "kill", quest = qq.id, title = qq.title, target = qq.title, oi = qq.oi }
		else
			g = { t = (qq.code == "QA" and "accept") or (qq.code == "QT" and "turnin") or "complete", quest = qq.id, title = qq.title }
			local q = qq.q
			if qq.code == "QA" and q then
				if q.level and q.level > 0 then g.qlvl = q.level end
				if q.minLevel and q.minLevel > 0 then g.minLevel = q.minLevel end
				if not placeGoal(g, q.start, preferMap) and q.startItem then
					g.item, g.itemName = q.startItem, itemName(q.startItem)
				end
			elseif qq.code == "QT" and q then
				placeGoal(g, q.finish, preferMap)
			end
		end
		tinsert(goals, g)
	end

	-- Coordinates: on quest goals that have none, else a goto of their own.
	if coords[1] then
		local c = coords[1]
		local placed = false
		for _, g in ipairs(goals) do
			if not g.map then g.map, g.x, g.y = c.map, c.x, c.y end
			placed = true
		end
		if not placed then
			for i = #coords, 1, -1 do
				local cc = coords[i]
				tinsert(goals, 1, { t = "goto", map = cc.map, x = cc.x, y = cc.y, text = text ~= "" and text or cc.zone })
			end
		end
	end

	-- NPC targets.
	local buying = ci[1] and hasWord(low, "buy")
	for _, id in ipairs(tar) do
		if not buying then
			local name, pt = spawn("npc", id, preferMap)
			name = name or ("NPC " .. id)
			local g = { npc = id, npcName = name }
			if pt then putSpot(g, pt) elseif coords[1] then g.map, g.x, g.y = coords[1].map, coords[1].x, coords[1].y end
			if hasWord(low, "learn") or hasWord(low, "train") then
				g.t = "train"
			elseif flags.V or hasWord(low, "vendor") or hasWord(low, "sell") or hasWord(low, "repair") then
				g.t = "vendor"
			elseif g.map then
				g = { t = "goto", map = g.map, x = g.x, y = g.y, f = g.f, text = name }
			end
			if g.t then
				-- The NPC's own spot is better than the line's goto.
				for i = #goals, 1, -1 do if goals[i].t == "goto" then table.remove(goals, i) end end
				tinsert(goals, g)
			end
		end
	end
	if flags.V and not tar[1] then
		local g = { t = "vendor" }
		if coords[1] then g.map, g.x, g.y = coords[1].map, coords[1].x, coords[1].y end
		for i = #goals, 1, -1 do if goals[i].t == "goto" then table.remove(goals, i) end end
		tinsert(goals, g)
	end

	-- Items.
	for _, it in ipairs(ci) do
		local g
		if it.use then
			g = { t = "use", item = it.id, itemName = it.name }
		elseif buying then
			g = { t = "buy", item = it.id, itemName = it.name, count = it.count }
			if tar[1] then
				local name, pt = spawn("npc", tar[1], preferMap)
				g.npc, g.npcName = tar[1], name or ("NPC " .. tar[1])
				putSpot(g, pt)
			end
		else
			g = { t = "collect", item = it.id, itemName = it.name, count = it.count }
		end
		tinsert(goals, g)
	end

	-- Travel.
	for _, name in ipairs(fly) do
		local t = name ~= "" and taxiByName(name, faction)
		if t then
			tinsert(goals, { t = "fly", location = taxiName(t), node = t[1] })
		else
			tinsert(goals, { t = "fly", location = name ~= "" and name or "flight master" })
		end
	end
	for _, name in ipairs(getfp) do
		local t = coords[1] and taxiNear(coords[1].map, coords[1].x, coords[1].y, faction)
		if not t and name ~= "" then t = taxiByName(name, faction) end
		if t then
			local g = { t = "getfp", location = taxiName(t), node = t[1], map = t[2], x = round2(t[3]), y = round2(t[4]) }
			if t[2] < 2000 then g.f = "e" end -- TravelData's taxi spots are on the Era frame where there is one
			for i = #goals, 1, -1 do if goals[i].t == "goto" then table.remove(goals, i) end end
			tinsert(goals, g)
		else
			tinsert(goals, { t = "task", text = text ~= "" and text or "Get the flight path" })
		end
	end
	if flags.S then
		local inn = coords[1] and innNear(coords[1].map, coords[1].x, coords[1].y)
		local g
		if inn then
			g = { t = "sethome", location = inn[7], area = inn[1], npc = inn[6], npcName = npcName(inn[6]),
				map = inn[2], x = inn[3], y = inn[4], f = inn[5] == "e" and "e" or nil }
			self.home = inn
		elseif coords[1] then
			g = { t = "sethome", candidates = { { map = coords[1].map, x = coords[1].x, y = coords[1].y } } }
			self.home = nil
		else
			g = { t = "task", text = text ~= "" and text or "Set your Hearthstone" }
			self.home = nil
		end
		for i = #goals, 1, -1 do if goals[i].t == "goto" then table.remove(goals, i) end end
		tinsert(goals, g)
	end
	if flags.T or (not goals[1] and (hasWord(low, "learn") or hasWord(low, "train"))
		and (find(low, "skill") or find(low, "spell") or find(low, "abilit"))) then
		tinsert(goals, { t = "train", class = true })
	end
	for _, v in ipairs(xp) do
		local lvl, frac = match(v, "^(%d+)(%.%d+)")
		lvl = lvl or match(v, "^(%d+)")
		if lvl then
			local g = { t = "level", level = tonumber(lvl) }
			frac = tonumber(frac and ("0" .. frac))
			if frac and frac > 0 and frac < 1 then g.frac = frac end
			tinsert(goals, g)
		end
	end
	for _, s in ipairs(sk) do tinsert(goals, { t = "skill", skill = s.name, level = s.level }) end
	if sp[1] then tinsert(goals, { t = "task", text = text ~= "" and text or "Cast the spell" }) end

	if flags.H then
		-- Done on arrival: it goes on the next step, whose work is where it leads.
		self.pendingHearth = true
		local bare = gsub(gsub(gsub(low, "use", ""), "your", ""), "[%s%.]", "")
		if text ~= "" and bare ~= "hearthstone" then tinsert(self.pendingNote, text) end
		if not goals[1] then return end
	end

	if not goals[1] then
		if text ~= "" then tinsert(self.pendingNote, text) end
		return
	end

	if optional then for _, g in ipairs(goals) do g.optional = true end end

	local step = { title = sub(text, 1, 120), goals = goals }
	if step.title == "" then step.title = goals[1].title or goals[1].npcName or "Step" end
	if self.pendingHearth then
		local loc, area
		if self.home then
			loc, area = self.home[7], self.home[1]
		else
			for _, g in ipairs(goals) do
				if g.map then loc = B.ZONE_NAMES[g.map]; break end
			end
		end
		if loc then
			tinsert(goals, 1, { t = "hearth", location = loc, area = area })
		else
			tinsert(self.pendingNote, 1, "Use your Hearthstone.")
		end
		self.pendingHearth = false
	end
	if self.pendingNote[1] then
		step.note = tconcat(self.pendingNote, "\n")
		self.pendingNote = {}
	end
	if next(only) then step.only = only end

	local prev = self.steps[#self.steps]
	if prev and not step.note and sameOnly(prev.only, step.only) and sameSpot(prev, step) and #prev.goals < 8 then
		for _, g in ipairs(goals) do tinsert(prev.goals, g) end
		local g0 = prev.goals[1]
		prev.title = g0.npcName or g0.objName or prev.title
	else
		tinsert(self.steps, step)
	end
end

function Guide:finish()
	if self.pendingNote[1] or self.pendingHearth then
		local note = tconcat(self.pendingNote, "\n")
		if self.pendingHearth then note = "Use your Hearthstone." .. (note ~= "" and ("\n" .. note) or "") end
		tinsert(self.steps, { title = "Done", goals = { { t = "note", text = note } } })
	end
end

---------------------------------------------------------------------------
-- Guide text -> definition
---------------------------------------------------------------------------

-- -> def, guide (parse state), or nil, reason
function B.Convert(text, group)
	if type(text) ~= "string" then return nil, "no guide text" end
	local g = newGuide(group)
	for raw in string.gmatch(gsub(text, "\r", "") .. "\n", "([^\n]*)\n") do g:line(raw) end
	g:finish()
	local m = g.meta
	if not m.n then return nil, "the guide has no [N] name" end
	if not g.steps[1] then return nil, "the guide has no steps" end

	local groupName = trim(gsub(group or "Guidelime", "^Guidelime_", ""))
	local name = m.name
	-- A guide named just "Part": named after its zones instead.
	if lower(name) == "part" and next(g.zoneCounts) then
		local zs = {}
		for map, n in pairs(g.zoneCounts) do tinsert(zs, { map = map, n = n }) end
		table.sort(zs, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.map < b.map end)
		local names = {}
		for i = 1, math.min(3, #zs) do tinsert(names, B.ZONE_NAMES[zs[i].map] or tostring(zs[i].map)) end
		name = tconcat(names, ", ")
	end
	local def = {
		id = B.PACK .. "/" .. B.Slug(groupName) .. "/" .. B.Slug(m.n),
		pack = B.PACK,
		title = m.minLevel and format("%s (%d-%d)", name, m.minLevel, m.maxLevel) or name,
		author = groupName,
		version = 1,
		why = m.why or ("A Guidelime guide from " .. groupName .. ", read by Polestar."),
		folder = groupName,
	}
	if m.minLevel then
		def.category, def.minLevel, def.maxLevel = "Leveling", m.minLevel, m.maxLevel
	else
		local base = lower(trim(gsub(name, "%s*[Ss]hopping%s*[Ll]ist%s*$", "")))
		def.category = PROFESSIONS[base] and "Professions" or "Miscellaneous"
	end
	def.faction, def.races, def.classes = m.faction, m.races, m.classes
	local bestMap, bestN
	for map, n in pairs(g.zoneCounts) do
		if not bestN or n > bestN or (n == bestN and map < bestMap) then bestMap, bestN = map, n end
	end
	if bestMap then def.zone, def.zoneName = bestMap, B.ZONE_NAMES[bestMap] end
	def.keywords = { "guidelime", lower(groupName) }
	for w in string.gmatch(lower(name), "[%a']+") do if #w > 2 then tinsert(def.keywords, w) end end
	def.steps = g.steps
	g.def = def
	g.groupName = groupName
	return def, g
end
