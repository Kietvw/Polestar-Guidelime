-- Polestar Guidelime: every guide a Guidelime guide addon registers
-- (Guidelime.registerGuide) is also read into Polestar, as a guide of the
-- community pack "guidelime".
--
-- The folder's leading "!" makes the client load this addon before the
-- guide addons (it loads addons by name, after their dependencies), so the
-- hook is in place when they register. Guidelime keeps its guides to itself:
-- one registered before the hook can't be read.
local ADDON, B = ...
B.PACK = "guidelime"

local P = Polestar
local match, gsub, lower, format = string.match, string.gsub, string.lower, string.format

local function chat(msg)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff7fd0ffPolestar Guidelime:|r " .. msg) end
end

if not (P and P.RegisterPack and P.RegisterGuide) then
	chat("Polestar is not loaded: Guidelime guides won't show in Polestar.")
	return
end
if not (Guidelime and Guidelime.registerGuide) then
	chat("Guidelime is not loaded: nothing to read.")
	return
end

local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "0"
P.RegisterPack({
	addon = ADDON, id = B.PACK, format = 10,
	title = "Guidelime guides",
	author = "The guides' own authors",
	version = version,
	license = "Each guide's own; read from your installed Guidelime guide addons",
	notes = "The guides of your installed Guidelime guide addons (such as TUGs), played in Polestar.",
})

---------------------------------------------------------------------------
-- The quest database: titles, quest givers and their places
---------------------------------------------------------------------------

local function loadQuestDB()
	local Q = P.QuestDB
	if not Q then return false end
	if Q.IsLoaded() then return true end
	if P.Data and P.Data.Pack then
		pcall(P.Data.Pack, Q.ADDON)
	elseif C_AddOns and C_AddOns.LoadAddOn then
		pcall(C_AddOns.LoadAddOn, Q.ADDON)
	end
	if Q.IsLoaded() then B.loadedQuestDB = true end
	return Q.IsLoaded()
end

---------------------------------------------------------------------------
-- Next guides: [NX] names a guide of the same group, which may register
-- after this one, and guide authors' links are sometimes a level range off
-- ("6-12 Durotar" for "6-9 Durotar").
---------------------------------------------------------------------------

local ours = {} -- id -> { def, g }
local order = {}

local function normName(n)
	local lvl, rest = match(n, "^%s*(%d+)%s*%-?%s*%d*%s*(.*)$")
	return gsub(lower(rest or n), "[^%a]", ""), tonumber(lvl)
end

-- Both guides for the same side (or either for both).
local function sameSide(a, b)
	return not a.def.faction or not b.def.faction or a.def.faction == b.def.faction
end

local function resolveNext(e)
	for _, nx in ipairs(e.g.meta.nx) do
		local exact = B.PACK .. "/" .. B.Slug(e.g.groupName) .. "/" .. B.Slug(nx)
		if ours[exact] and exact ~= e.def.id and sameSide(e, ours[exact]) then return exact end
		local want, lvl = normName(nx)
		if want ~= "" then
			local best, bd
			for _, id in ipairs(order) do
				local o = ours[id]
				if id ~= e.def.id and o.g.groupName == e.g.groupName and sameSide(e, o) and normName(o.g.meta.n) == want then
					local d = math.abs((o.def.minLevel or 0) - (lvl or 0))
					if not bd or d < bd then best, bd = id, d end
				end
			end
			if best then return best end
		end
	end
	return nil
end

-- A leveling guide whose link leads nowhere usable (an author's copy-paste:
-- Coldridge Valley's [NX] names the Horde Barrens): the one guide of its
-- group and side in the same zone that starts at the level it ends.
local function fallbackNext(e)
	local d = e.def
	if not (d.maxLevel and d.zone) then return nil end
	local found
	for _, id in ipairs(order) do
		local o = ours[id]
		if id ~= d.id and o.g.groupName == e.g.groupName and sameSide(e, o)
			and o.def.minLevel == d.maxLevel and o.def.zone == d.zone then
			if found then return nil end -- more than one: no guess
			found = id
		end
	end
	return found
end

local function setNext(e, id)
	if e.def.next == id then return end
	e.def.next = id
	if e.registered and P.Guides and P.Guides.List then
		for _, h in ipairs(P.Guides.List()) do
			if h.id == e.def.id then h.next = id end
		end
	end
end

local function relink()
	for _, id in ipairs(order) do
		local e = ours[id]
		if not e.resolved then
			local nx = resolveNext(e)
			if nx then
				setNext(e, nx)
				e.resolved = true
			end
		end
	end
end

---------------------------------------------------------------------------
-- Registering
---------------------------------------------------------------------------

local stats = { guides = 0, steps = 0, failed = {} }

local function read(text, group)
	if not B.dbTried then
		B.dbTried = true
		if not loadQuestDB() then
			chat("Polestar's quest database (Polestar_QuestDB) could not be loaded: quests show without names or places.")
		end
	end
	local def, g = B.Convert(text, group)
	if not def then
		stats.failed[#stats.failed + 1] = tostring(group) .. ": " .. tostring(g)
		return
	end
	local e = ours[def.id]
	if not e then
		order[#order + 1] = def.id
	end
	e = { def = def, g = g }
	ours[def.id] = e
	-- Until a better one is found: the exact name, if that guide comes later.
	if g.meta.nx[1] then def.next = B.PACK .. "/" .. B.Slug(g.groupName) .. "/" .. B.Slug(g.meta.nx[1]) end
	local ok, err = P.RegisterGuide(def)
	if ok then
		e.registered = true
		stats.guides = stats.guides + 1
		stats.steps = stats.steps + #def.steps
	else
		stats.failed[#stats.failed + 1] = def.title .. ": " .. tostring(err)
	end
	relink()
end

local original = Guidelime.registerGuide
Guidelime.registerGuide = function(guide, group, ...)
	-- Guidelime's own copy first, as before.
	local result = original(guide, group, ...)
	local text = type(guide) == "string" and guide or (type(result) == "table" and result.text)
	if type(text) == "string" then
		local ok, err = pcall(read, text, group)
		if not ok then stats.failed[#stats.failed + 1] = tostring(group) .. ": " .. tostring(err) end
	end
	return result
end

B.Read = read -- for tests

---------------------------------------------------------------------------
-- At login: every guide addon is in
---------------------------------------------------------------------------

local function onLogin()
	relink()
	-- A next guide that never came (the author's link to a guide not shipped,
	-- or to the other side's): the zone's next guide if there is exactly one, else none.
	for _, id in ipairs(order) do
		local e = ours[id]
		if not e.resolved and (e.def.next == nil or not ours[e.def.next] or not sameSide(e, ours[e.def.next])) then
			setNext(e, e.g.meta.nx[1] and fallbackNext(e) or nil)
		end
	end
	if B.loadedQuestDB and P.QuestDB.IsWanted and P.QuestDB.IsWanted() and P.Fire then
		P.Fire("QUESTDB_LOADED")
	end
	if stats.guides > 0 or stats.failed[1] then
		chat(format("%d Guidelime guides ready in Polestar (%d steps).", stats.guides, stats.steps))
	end
	for i = 1, math.min(5, #stats.failed) do chat("|cffff8080could not read|r " .. stats.failed[i]) end
	if #stats.failed > 5 then chat(format("... and %d more.", #stats.failed - 5)) end
end
B.OnLogin = onLogin -- for tests

local f = CreateFrame and CreateFrame("Frame")
if f then
	f:RegisterEvent("PLAYER_LOGIN")
	f:SetScript("OnEvent", function()
		f:UnregisterEvent("PLAYER_LOGIN")
		onLogin()
	end)
end
