-- dgks_lib.lua — self-contained replacements for AceAddon, AceConsole, AceDB, AceComm, AceSerializer, LibSink
-- Keeps: AceGUI-3.0, AceConfig-3.0, LibStub, CallbackHandler (for config panel)

local DGKS = {}
_G.DGKS = DGKS

local strbyte, strchar, gsub, format = string.byte, string.char, string.gsub, string.format
local tconcat = table.concat
local type, tostring, tonumber, select, unpack = type, tostring, tonumber, select, unpack
local pairs, frexp = pairs, math.frexp

---------------------------------------------------------------------------
-- Serialization (AceSerializer-compatible ^1 format)
---------------------------------------------------------------------------

local function SerializeStringHelper(ch)
	local n = strbyte(ch)
	if n == 30 then return "\126\122"
	elseif n <= 32 then return "\126" .. strchar(n + 64)
	elseif n == 94 then return "\126\125"
	elseif n == 126 then return "\126\124"
	elseif n == 127 then return "\126\123"
	end
end

local function SerializeValue(v, res, nres)
	local t = type(v)
	if t == "string" then
		res[nres + 1] = "^S"
		res[nres + 2] = gsub(v, "[%c \94\126\127]", SerializeStringHelper)
		nres = nres + 2
	elseif t == "number" then
		local str = tostring(v)
		if tonumber(str) == v then
			res[nres + 1] = "^N"
			res[nres + 2] = str
			nres = nres + 2
		else
			local m, e = frexp(v)
			res[nres + 1] = "^F"
			res[nres + 2] = format("%.0f", m * 2 ^ 53)
			res[nres + 3] = "^f"
			res[nres + 4] = tostring(e - 53)
			nres = nres + 4
		end
	elseif t == "table" then
		nres = nres + 1
		res[nres] = "^T"
		for key, value in pairs(v) do
			nres = SerializeValue(key, res, nres)
			nres = SerializeValue(value, res, nres)
		end
		nres = nres + 1
		res[nres] = "^t"
	elseif t == "boolean" then
		nres = nres + 1
		res[nres] = v and "^B" or "^b"
	elseif t == "nil" then
		nres = nres + 1
		res[nres] = "^Z"
	end
	return nres
end

local serializeTbl = { "^1" }

function DGKS.Serialize(...)
	local nres = 1
	for i = 1, select("#", ...) do
		nres = SerializeValue(select(i, ...), serializeTbl, nres)
	end
	serializeTbl[nres + 1] = "^^"
	return tconcat(serializeTbl, "", 1, nres + 1)
end

-- Deserializer: tokenize into control/data pairs, then interpret
local function DeserializeStringHelper(escape)
	if escape < "~\122" then
		return strchar(strbyte(escape, 2, 2) - 64)
	elseif escape == "~\122" then return "\030"
	elseif escape == "~\123" then return "\127"
	elseif escape == "~\124" then return "\126"
	elseif escape == "~\125" then return "\094"
	end
	return ""
end

local function DeserializeValue(tokens, pos)
	local tv = tokens[pos]
	if tv == "^S" then
		return gsub(tokens[pos + 1], "~.", DeserializeStringHelper), pos + 2
	elseif tv == "^N" then
		return tonumber(tokens[pos + 1]), pos + 2
	elseif tv == "^F" then
		local m = tonumber(tokens[pos + 1])
		local e = tonumber(tokens[pos + 3])
		return m * 2 ^ e, pos + 4
	elseif tv == "^B" then
		return true, pos + 2
	elseif tv == "^b" then
		return false, pos + 2
	elseif tv == "^Z" then
		return nil, pos + 2
	elseif tv == "^T" then
		local t = {}
		pos = pos + 1
		while tokens[pos] ~= "^t" do
			local k, v
			k, pos = DeserializeValue(tokens, pos)
			v, pos = DeserializeValue(tokens, pos)
			t[k] = v
		end
		return t, pos + 1
	end
	return nil, pos + 1
end

function DGKS.Deserialize(msg)
	if type(msg) ~= "string" then return nil end
	if #msg < 2 or msg:sub(1, 2) ~= "^1" then return nil end
	-- tokenize: split on ^ but keep control chars
	local tokens = {}
	local i = 3
	while i <= #msg do
		local c = msg:sub(i, i)
		if c == "^" then
			local nextc = msg:sub(i + 1, i + 1)
			if nextc == "^" then
				break
			elseif nextc == "S" then
				-- string: read until next ^ control
				local start = i + 2
				local j = start
				while j <= #msg do
					local ch = msg:sub(j, j)
					if ch == "^" then
						local nc = msg:sub(j + 1, j + 1)
						if nc == "S" or nc == "N" or nc == "F" or nc == "B" or nc == "b" or nc == "Z" or nc == "T" or nc == "t" or nc == "^" then
							break
						end
					end
					j = j + 1
				end
				tokens[#tokens + 1] = "^S"
				tokens[#tokens + 1] = msg:sub(start, j - 1)
				i = j
			elseif nextc == "N" or nextc == "F" or nextc == "B" or nextc == "b" or nextc == "Z" or nextc == "T" or nextc == "t" then
				tokens[#tokens + 1] = "^" .. nextc
				if nextc == "F" then
					tokens[#tokens + 1] = msg:sub(i + 2, i + 2 + 14)
					tokens[#tokens + 1] = "^f"
					tokens[#tokens + 1] = msg:sub(i + 2 + 16, i + 2 + 16)
					i = i + 2 + 17
				else
					tokens[#tokens + 1] = msg:sub(i + 2, #msg)
					i = #msg + 1
				end
			else
				i = i + 1
			end
		else
			i = i + 1
		end
	end
	-- parse tokens
	local result = {}
	local pos = 1
	while pos <= #tokens do
		local v
		v, pos = DeserializeValue(tokens, pos)
		result[#result + 1] = v
	end
	return unpack(result)
end

---------------------------------------------------------------------------
-- Saved Variables (AceDB-compatible)
---------------------------------------------------------------------------

local function deepCopy(t)
	local c = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			c[k] = deepCopy(v)
		else
			c[k] = v
		end
	end
	return c
end

function DGKS.NewDB(savedVariable, defaults, defaultProfile)
	local sv = _G[savedVariable]
	if type(sv) ~= "table" then
		sv = {}
		_G[savedVariable] = sv
	end

	local db = {}
	db.defaults = defaults and { profile = deepCopy(defaults.profile) } or {}

	local profileName = (defaultProfile == true) and "default" or (defaultProfile or "default")

	sv.profiles = sv.profiles or {}
	if not sv.profiles[profileName] then
		sv.profiles[profileName] = {}
	end

	local profile = sv.profiles[profileName]

	-- merge defaults into profile
	if defaults and defaults.profile then
		for k, v in pairs(defaults.profile) do
			if profile[k] == nil then
				profile[k] = type(v) == "table" and deepCopy(v) or v
			elseif type(v) == "table" and type(profile[k]) == "table" then
				for sk, sv2 in pairs(v) do
					if profile[k][sk] == nil then
						profile[k][sk] = type(sv2) == "table" and deepCopy(sv2) or sv2
					end
				end
			end
		end
	end

	db.profile = profile

	function db:ResetProfile()
		for k, v in pairs(db.defaults.profile) do
			profile[k] = type(v) == "table" and deepCopy(v) or v
		end
	end

	return db
end

---------------------------------------------------------------------------
-- Addon lifecycle (AceAddon-compatible)
-- Provides: Print, RegisterChatCommand, RegisterComm, SendCommMessage,
--           Serialize, Deserialize, GetSinkAce3OptionsDataTable, SetSinkStorage
-- Calls OnInitialize then OnEnable on ADDON_LOADED event
---------------------------------------------------------------------------

local slashCommands = {}

function DGKS.NewAddon(name)
	local addon = { name = name }

	function addon:Print(msg)
		DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff" .. name .. ":|r " .. tostring(msg))
	end

	-- AceConsole-compatible
	function addon:RegisterChatCommand(cmd, func)
		slashCommands[cmd:lower()] = func
		if not _G["SLASH_" .. name .. cmd] then
			_G["SLASH_" .. name .. cmd .. "1"] = "/" .. cmd
			SlashCmdList[name .. cmd] = function(msg)
				slashCommands[cmd:lower()]()
			end
		end
	end

	-- AceComm-compatible
	local commPrefixes = {}

	function addon:RegisterComm(prefix)
		if C_ChatInfo then
			C_ChatInfo.RegisterAddonMessagePrefix(prefix)
		else
			RegisterAddonMessagePrefix(prefix)
		end
		commPrefixes[prefix] = true
	end

	function addon:SendCommMessage(prefix, text, distribution, target)
		if C_ChatInfo then
			C_ChatInfo.SendAddonMessage(prefix, text, distribution, target or "")
		else
			SendAddonMessage(prefix, text, distribution, target or "")
		end
	end

	-- AceSerializer-compatible
	addon.Serialize = DGKS.Serialize
	addon.Deserialize = DGKS.Deserialize

	-- LibSink-2.0 shim (removed, no-op)
	function addon:SetSinkStorage(profile) end

	function addon:GetSinkAce3OptionsDataTable()
		return {
			name = "Output",
			type = "group",
			args = {
				desc = {
					type = "description",
					name = "Combat text output uses custom scrolling text.",
					order = 0,
				},
			},
		}
	end

	-- Lifecycle: call OnInitialize then OnEnable on ADDON_LOADED
	local loadFrame = CreateFrame("Frame")
	loadFrame:RegisterEvent("ADDON_LOADED")
	loadFrame:SetScript("OnEvent", function(_, event, loadedAddon)
		if loadedAddon == name then
			loadFrame:UnregisterEvent("ADDON_LOADED")
			if addon.OnInitialize then addon:OnInitialize() end
			if addon.OnEnable then addon:OnEnable() end
		end
	end)

	return addon
end

---------------------------------------------------------------------------
-- Comm event handler (shared frame for all addon instances)
---------------------------------------------------------------------------

local commFrame = CreateFrame("Frame")

commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:SetScript("OnEvent", function(_, event, prefix, message, distribution, sender)
	if event == "CHAT_MSG_ADDON" then
		local addon = _G.dgks
		if addon and addon.db and addon.OnCommReceived then
			addon:OnCommReceived(prefix, message, distribution, sender)
		end
	end
end)
