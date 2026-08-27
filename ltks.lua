--TODO List
--BattleNet friend broadcasts are commented out
--Log classes on prey/predators
--Nemesis notifications
--Cross Character Killer Klvl Kclass KGuild Victim Vlvl VClass VGuild Timestamp Location Killshot_Log
--Cross server ranking system (bnet channels)
--Reduce externals/libs
--NPC Emote Targeting
--Blood Moon event tracking (spell ID 436097)
--Version bump and changelog for 12.0.7 changes


local version = "12.0.7"
local databaseversion = "1"
local addonName, ns = ...
local streak = 0
local deathstreak = 0
local multikill = 0
local lastrxkiller = ""
local lastrxvictim = ""
local lastrxtimestamp = 0
local recentKills = {}
local lastkill = 0
local timestamp = 0
-- Last source of damage against the player, used to name the killer on
-- PLAYER_DEAD. Only populated from non-secret combat log payloads (Midnight
-- restricts identity in instanced PvP, dungeons and raids).
local lastDamageSource = nil
local mkChain = false -- multikill chain active (combat window mode)
local myMinions = {} -- MINE-affiliated damage sources: pets, guardians, totems
local deadNameCache = {} -- destGUID -> name from damage/death events (kill attribution)
local pendingKills = {} -- retail: unresolved PARTY_KILL victims (guid -> {time}), awaiting UNIT_DIED
local knownNames = {} -- guid -> name from nameplates/target/mouseover (retail unit cache)
local newestconfigversion = 1
local frame, events = CreateFrame("Frame"), {};
local damageDealers = {}

-- Project discriminator (mainline/retail vs the Classic clients), per
-- Blizzard's ProjectConstants.lua (WOW_PROJECT_MAINLINE = 1). Declared before
-- any consumer: the old global IsRetail() no longer exists on Midnight, and a
-- file-local must be defined above its uses to be visible to them.
local function IsRetail()
    return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
end

-- Midnight restricts COMBAT_LOG_EVENT_UNFILTERED: registering it while addon
-- restrictions are active (instanced PvP, dungeons/raids, combat lockdown)
-- raises ADDON_ACTION_FORBIDDEN. Registration is deferred until an unrestricted
-- moment, retried on zone change and combat end, and pcall-guarded so a missed
-- restriction can never crash the addon.
local cleuRegistered = false
local function TryRegisterCLEU()
	-- Midnight (12.0+) refuses third-party registration of the unfiltered
	-- combat log: RegisterEvent returns false, and merely attempting it fires
	-- ADDON_ACTION_FORBIDDEN (spamming error addons like BugGrabber). The CLEU
	-- path is classic-only; retail kills come from PARTY_KILL/UNIT_DIED.
	if cleuRegistered or IsRetail() then return end
	if InCombatLockdown and InCombatLockdown() then return end
	local inInstance = IsInInstance()
	-- IsInInstance() returns (false, "none") in the open world: gate on the
	-- boolean or CLEU never registers outside instances.
	if inInstance then return end
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid("COMBAT_LOG_EVENT_UNFILTERED") then return end
	local ok, registered = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
	cleuRegistered = ok and registered ~= false
end
local targetList = {} -- Used for Execute
local playerName = UnitName("player")
local inArena = false
local inBG = false
local lastMessage, lastSender, lastTimestamp --Versionchecking duplicate detection
local soundPath = "Interface\\AddOns\\ltks\\sounds\\"
-- Per-pack sound tables: multikill chain follow-ups and per-kill base announcer
local packChain = {
	unreal2003 = { "doublekill.ogg", "multikill.ogg", "monsterkill.ogg", "holyshit.ogg" },
	lol = { "doublekill.ogg", "triplekill.ogg", "quadrakill.ogg", "pentakill.ogg", "hexakill.ogg", "legendary.ogg" },
}
local packLadder = {
	-- Early streak announcer (1-4); 5+ is milestone tiers, chains cover multikills
	unreal2003 = { "firstblood.ogg", "doublekill.ogg", "hattrick.ogg", "juggernaut.ogg" },
	lol = { "firstblood.ogg", "doublekill.ogg", "triplekill.ogg", "quadrakill.ogg", "pentakill.ogg", "hexakill.ogg", "legendary.ogg" },
}
local packTiers = {
	unreal2003 = {
		cycle = true, -- walk the whole set, then cycle
		list = { "killingspree.ogg", "rampage.ogg", "dominating.ogg", "unstoppable.ogg", "godlike.ogg", "whickedsick.ogg", "impressive.ogg", "outstanding.ogg", "megakill.ogg", "ultrakill.ogg", "eagleeye.ogg", "ownage.ogg", "comboking.ogg", "maniac.ogg", "ludicrouskill.ogg", "bullseye.ogg", "excellent.ogg", "pancake.ogg", "headhunter.ogg", "unreal.ogg", "assasin.ogg", "massacre.ogg", "killingmachine.ogg", "monsterkill.ogg", "holyshit.ogg" },
	},
	lol = {
		cycle = false, -- repeat the final line (Legendary) past the end
		list = { "killingspree.ogg", "rampage.ogg", "terminated.ogg", "unstoppable.ogg", "godlike.ogg", "legendary.ogg" },
	},
}

local packTierLabels = {
	unreal2003 = { "Killing Spree!", "Rampage!", "Dominating!", "Unstoppable!", "Godlike!", "Wicked Sick!", "Impressive!", "Outstanding!", "Mega Kill!", "Ultra Kill!", "Eagle Eye!", "Ownage!", "Combo King!", "Maniac!", "Ludicrous Kill!", "Bullseye!", "Excellent!", "Pancake!", "Head Hunter!", "Unreal!", "Assassin!", "Massacre!", "Killing Machine!", "Monster Kill!", "Holy Shit!" },
	lol = { "Killing Spree!", "Rampage!", "Terminated!", "Unstoppable!", "Godlike!", "Legendary!" },
}

local randomEmotes = {
	"AGREE","AMAZE","ANGRY","APOLOGIZE","APPLAUD","BELCH","BLOWKISS","BOGGLE",
	"BONK","BORED","BOUNCE","BOW","BRB","BURP","BYE","CACKLE","CALM",
	"CHEER","CHICKEN","CHUCKLE","CLAP","COMFORT","COMMEND","CONFUSED",
	"CONGRATULATE","COUGH","COWER","CRACK","CRINGE","CRY","CUDDLE","CURIOUS",
	"CURTSEY","DANCE","DOOM","DRINK","DROOL","EAT","EYE","FART","FIDGET",
	"FROWN","GASP","GLARE","GLOAT","GOLFCLAP","GREET","GRIN","GROAN",
	"GROWL","GUFFAW","HAIL","HAPPY","HISS","HUG","INSULT","INTRODUCE",
	"JK","KISS","KNEEL","KNUCKLES","LAUGH","LICK","LISTEN","LOST","LOVE",
	"ANGRY","MASSAGE","MOAN","MOCK","MOO","MOON","MOURN","NO","NOD",
	"NOSEPICK","PAT","PEER","SHOO","PITY","PLEAD","POINT","POKE","PONDER",
	"POUNCE","PULSE","PRAISE","PRAY","PURR","PUZZLE","TALKQ","RAISE",
	"RASP","READY","SHAKE","ROAR","ROFL","RUDE","SALUTE","SEXY","SHIMMY",
	"SHY","SIGH","JOKE","SLAP","SMELL","SMILE","SMIRK","SNARL","SNICKER",
	"SNIFF","SNUB","SOOTHE","APOLOGIZE","SPIT","STARE","SURPRISED","TAP",
	"TAUNT","TEASE","THANK","THREATEN","TICKLE","TIRED","VETO","VICTORY",
	"VIOLIN","WAVE","WELCOME","WHINE","WHISTLE","WINK","WORK","YAWN"
}

local function GetFullUnitName(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function GetNameFromGUID(guid)
    if not guid then return nil end
    if UnitGUID("target") == guid then
        return GetFullUnitName("target")
    end
    if UnitGUID("focus") == guid then
        return GetFullUnitName("focus")
    end
    if UnitNameFromGUID then
        local name, realm = UnitNameFromGUID(guid)
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    return nil
end

ltks = LibStub("AceAddon-3.0"):NewAddon("ltks", "AceEvent-3.0", "AceConsole-3.0", "LibSink-2.0","AceComm-3.0","AceSerializer-3.0")

function sortListByLength(t,a,b)
	local acount, bcount = 0,0
	for _ in pairs(t[a]) do acount = acount + 1 end
	for _ in pairs(t[b]) do bcount = bcount + 1 end
	return acount > bcount
end

function spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys 
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

function getSortedList(mytable, count)
	local tempString = ""
	for i,v in spairs(mytable, function (t,a,b) return sortListByLength(t,a,b) end) do
		tempString = tempString .. #v .. " " .. i .. " " .. v[#v] .. "\n"
		if count ~= nil then
			count = count - 1
		end
		if count == 0 then return tempString end
	end
	return tempString
end

local function giveOptions() 
	local options = { 
		type = "group",
		name = "LT KillShot",
		--handler = ltks,/dgk
		get = function(k) return db[k.arg] end,
		set = function(k, v) db[k.arg] = v end,
		args = {
			version = {
				type = "description",
				name = "Version " .. version,
				order = 2
			},
			prey = {
				type = "description",
				name = "Top Prey:\n" .. getSortedList(ltks.db.profile.killList, 5),
				order = 5
			},
			predators = {
				type = "description",
				name = "Top Predators:\n" .. getSortedList(ltks.db.profile.deathList, 5),
				order = 10
			},
			killstreak = {
				type = "description",
				name = "Current killing streak: " .. (ltks.db.profile.lastStreak or 0) .. "\nLongest killing streak: " .. ltks.db.profile.maxstreak .. "\n",
				order = 12,
				width = 1
			},
			deathstreak = {
				type = "description",
				name = "Current death streak: " .. deathstreak .. "\nLongest death streak: " .. ltks.db.profile.maxdeathstreak .. "\n",
				order = 14,
				width = 2
			},
			maxks = {
				type = "description",
				name = "Last 20 Kills\n" .. ltks.getKillLog(),
				order = 15
			},
			resetmaxks = {
				type = 'execute',
				name = 'Reset Stats',
				func = function()
					streak = 0
					deathstreak = 0
					multikill = 0
					ltks.db.profile.maxstreak = ltks.db.defaults.profile.maxstreak
					ltks.db.profile.maxdeathstreak = ltks.db.defaults.profile.maxdeathstreak
					ltks.db.profile.killlog = ltks.db.defaults.profile.killlog
					ltks.db.profile.killList = ltks.db.defaults.profile.killList
					ltks.db.profile.deathList = ltks.db.defaults.profile.deathList
				end,
				width = "full",
				order = 20
			},
			resetltks = {
				type = 'execute',
				name = 'Reset All LT Killshot Settings',
				func = function()
					streak = 0
					deathstreak = 0
					multikill = 0
					ltks.db:ResetProfile()
				end,
				width = "full",
				order = 30
			},
			--[===[@debug@
			-- Dev Debugging functions
			testltkskill = {
				type = 'execute',
				name = 'Simulate Killshot',
				func = function()
					ltks:Test()
				end
			},
			testdgdeath = {
				type = 'execute',
				name = 'Simulate Death',
				func = function()
					ltks:TestPlayerDeath()
				end
			}
			--@end-debug@]===]
		}
	}
	return options
end

local function giveGeneral()
	local general = {
		type = "group",
		name = "General",
		handler = ltks,
		args = {
			style = {
				type = 'select',
				name = 'Select how often to trigger killshots notifications:',
				desc = 'DoTA plays sound on every kill, UT plays on new ranks',
				get = function()
					return ltks.db.profile.style
				end,
				set = function(info,b)
					ltks.db.profile.style = b
					
				end,
				values = {
					dota = "Every Killshot (DoTA/LoL Style)",
					ut = "Unreal Tournament Announcer (plays on every consecutive kill)"
				},
				order = 10,
				width = 2
			},
			mkwindow = {
				type = 'select',
				name = 'Multikill Window',
				desc = 'How long a multikill chain stays alive: a fixed timer in seconds, or until you leave combat.',
				values = {
					timer = "Timer",
					combat = "Until out of combat"
				},
				get = function()
					return ltks.db.profile.mkwindow
				end,
				set = function(info, b)
					ltks.db.profile.mkwindow = b
				end,
				order = 11,
				width = 1
			},
			mktime = {
				type = 'input',
				name = 'Multikill Timer (seconds)',
				desc = 'Seconds between kills that still counts as part of a multikill chain, when the window is set to Timer.',
				get = function()
					return tostring(ltks.db.profile.mktime)
				end,
				set = function(info, v)
					local n = tonumber(v)
					if n and n > 0 and n <= 3600 then
						ltks.db.profile.mktime = n
					else
						ltks:Print("Enter a number between 1 and 3600 seconds.")
					end
				end,
				order = 12,
				width = 1
			},
			dochatbox = {
				type = 'toggle',
				name = 'Print killshots and deaths in chatbox in addition to logging in /ltks',
				get = function()
					return ltks.db.profile.dochatbox
				end,
				set = function(info, b)
					ltks.db.profile.dochatbox = b
				end,
				width = "full",
				order = 15
			},
			dokillfeed = {
				type = 'toggle',
				name = 'Print all killshots in chat (including other players)',
				desc = 'Shows every received killshot broadcast in the chat box in addition to the /ltks log.',
				get = function()
					return ltks.db.profile.dokillfeed
				end,
				set = function(info, b)
					ltks.db.profile.dokillfeed = b
				end,
				width = "full",
				order = 16
			},
			dozonechange = {
				type = 'toggle',
				name = 'Clear Streaks on Zone Change',
				get = function()
					return ltks.db.profile.dozonechange
				end,
				set = function(info, b)
					ltks.db.profile.dozonechange = b
				end,
				width = "full",
				order = 20
			},
			doemote = {
				type = 'select',
				name = 'Do built in Emote',
				desc = 'Choose an Emote',
				get = function()
					return ltks.db.profile.doemote
				end,
				set = function(info, b)
					ltks.db.profile.doemote = b
				end,
				values = {
					none = "None",
					RANDOM = "Random",
					BELCH = "Belch",
					BOGGLE = "Boggle",
					BONK = "Bonk",
					BORED = "Bored",
					BOUNCE = "Bounce",
					BOW = "Bow",
					APPLAUD = "Bravo",
					BRB = "BRB",
					BURP = "Burp",
					BYE = "Bye",
					CACKLE = "Cackle",
					CALM = "Calm",
					SCRATCH = "Cat",
					CHEER = "Cheer",
					EAT = "Chew",
					CHICKEN = "Chicken",
					CHUCKLE = "Chuckle",
					CLAP = "Clap",
					COMFORT = "Comfort",
					COMMEND = "Commend",
					CONFUSED = "Confused",
					CONGRATULATE = "Congrats",
					COUGH = "Cough",
					COWER = "Cower",
					CRACK = "Crack Knuckles",
					CRINGE = "Cringe",
					CRY = "Cry",
					CUDDLE = "Cuddle",
					CURIOUS = "Curious",
					CURTSEY = "Curtsey",
					DANCE = "Dance",
					DOOM = "Doom",
					DRINK = "Drink",
					DROOL = "Drool",
					EYE = "Eye",
					FART = "Fart",
					FROWN = "Frown",
					GASP = "Gasp",
					GLARE = "Glare",
					GLOAT = "Gloat",
					GOLFCLAP = "Golf Clap",
					GREET = "Greet",
					GRIN = "Grin",
					GROAN = "Groan",
					GROWL = "Growl",
					GUFFAW = "Guffaw",
					HAIL = "Hail",
					HAPPY = "Happy",
					HISS = "Hiss",
					HUG = "Hug",
					FIDGET = "Impatient",
					INSULT = "Insult",
					INTRODUCE = "Introduce",
					JK = "JK",
					KISS = "Kiss",
					KNEEL = "Kneel",
					KNUCKLES = "Knuckles",
					LAUGH = "Laugh",
					LICK = "Lick",
					LISTEN = "Listen",
					LOST = "Lost",
					LOVE = "Love",
					ANGRY = "Mad",
					MASSAGE = "Massage",
					MOAN = "Moan",
					MOCK = "Mock",
					MOO = "Moo",
					MOON = "Moon",
					MOURN = "Mourn",
					NO = "No",
					NOD = "Nod",
					NOSEPICK = "Nosepick",
					PAT = "Pat",
					PEER = "Peer",
					SHOO = "Shoo",
					PITY = "Pity",
					PLEAD = "Plead",
					POINT = "Point",
					POKE = "Poke",
					PONDER = "Ponder",
					POUNCE = "Pounce",
					PULSE = "Pulse",
					PRAISE = "Praise",
					PRAY = "Pray",
					PURR = "Purr",
					PUZZLE = "Puzzled",
					TALKQ = "Question",
					RAISE = "Raise",
					RASP = "Rasp (Rude Gesture)",
					READY = "Ready",
					SHAKE = "Shake Rear",
					ROAR = "Roar",
					ROFL = "ROFL",
					RUDE = "Rude",
					SALUTE = "Salute",
					SEXY = "Sexy",
					SHIMMY = "Shimmy",
					SHY = "Shy",
					SIGH = "Sigh",
					JOKE = "Silly",
					SLAP = "Slap",
					SMELL = "Smell",
					SMILE = "Smile",
					SMIRK = "Smirk",
					SNARL = "Snarl",
					SNICKER = "Snicker",
					SNIFF = "Sniff",
					SNUB = "Snub",
					SOOTHE = "Soothe",
					APOLOGIZE = "Sorry",
					SPIT = "Spit",
					STARE = "Stare",
					SURPRISED = "Surprised",
					TAP = "Tap",
					TAUNT = "Taunt",
					TEASE = "Tease",
					THANK = "Thank",
					THREATEN = "Threaten",
					TICKLE = "Tickle",
					TIRED = "Tired",
					VETO = "Veto",
					VICTORY = "Victory",
					VIOLIN = "Violin",
					WAVE = "Wave",
					WELCOME = "Welcome",
					WHINE = "Whine",
					WHISTLE = "Whistle",
					WINK = "Wink",
					WORK = "Work",
					YAWN = "Yawn"
				},
				order = 25
				},
			dotxtemote = {
				type = 'toggle',
				name = 'Show Custom Emote',
				desc = 'Toggle Emote Spam',
				get = function()
					return ltks.db.profile.dotxtemote
				end,
				set = function(info, b)
					ltks.db.profile.dotxtemote = b
				end,
				width = "full",
				order = 30
			},
			ksemote = {
				type = 'input',
				name = 'Custom Emote Message',
				desc = "Use this to customize the emote message. $v = victim $s = streak",
				usage = "<message>",
				get = function()
					return ltks.db.profile.ksemote
				end,
				set = function(info, b)
					ltks.db.profile.ksemote = b
				end,
				width = "full",
				order = 40
			},
			docombattext = {
				type = 'toggle',
				name = "Show Combat Text (Game setting Combat->Scrolling Combat Text for Self must also be enabled.)",
				desc = 'Toggle Combat Text Spam',
				get = function()
					return ltks.db.profile.docombattext
				end,
				set = function(info, b)
					ltks.db.profile.docombattext = b
				end,
				width = "full",
				order = 50
			},
			kstext = {
				type = 'input',
				name = 'Scrolling Text Message',
				desc = 'Use this to customize the Scrolling Text Message. $k = killer, $v = victim',
				usage = "<message>",
				get = function()
					return ltks.db.profile.kstext
				end,
				set = function(info, b)
					ltks.db.profile.kstext = b
				end,
				width = "full",
				order = 60
			},
			--[[ dopet = {
				type = 'toggle',
				name = 'Summon Random Pet',
				desc = 'Summon Random Pet on Killshot',
				get = function()
					return ltks.db.profile.dopet
				end,
				set = function(info, b)
					ltks.db.profile.dopet = b
				end,
				width = "full",
				order = 30
			}, ]]--
			soundpack = {
				type = 'select',
				name = 'Sound Pack',
				desc = 'Choose a sound pack',
				get = "getSoundPack",
				set = "setSoundPack",
				values = {
					unreal2003 = "Unreal 2003",
					lol = "League of Legends"
				},
				order = 85
			},
			dosound = {
				type = 'toggle',
				name = "Play Sounds",
				desc = 'Toggle Sound Spam',
				get = function()
					return ltks.db.profile.dosound
				end,
				set = function(info, b)
					ltks.db.profile.dosound = b
				end,
				order = 70
			},
			soundchannel = {
				type = 'select',
				name = "Sound Channel",
				desc = 'Select the sound channel used for audio notifications. Default: Master',
				get = function()
					return ltks.db.profile.soundchannel
				end,
				set = function(info, b)
					ltks.db.profile.soundchannel = b
				end,
				values = {
					Master = "Master",
					SFX = "SFX",
					Ambience = "Ambience",
					Music = "Music"
				},
				order = 80
			},
			dopve = {
				type = 'toggle',
				name = "Debug",
				desc = "Trigger off NPC/PVE Killshots - VERY SPAMMY, use for testing.",
				get = function()
					return ltks.db.profile.dopve
				end,
				set = function(info, b)
					ltks.db.profile.dopve = b
				end,
				width = "full",
				order = 90
			}
		}
	}
	return general
end

local function giveBroadcasts()
	local broadcasts = {
		type = "group",
		name = "Broadcasts",
		handler = ltks,
		args = {
			dobroadcasts = {
				type = 'toggle',
				name = 'Enable Broadcasts',
				desc = 'Enable/Disable all broadcasts',
				get = function()
					return ltks.db.profile.dobroadcasts
				end,
				set = function(info, b)
					ltks.db.profile.dobroadcasts = b
				end,
				width = "full",
				order = 80
			},
			doguild = {
				type = 'toggle',
				name = 'Broadcasts to/from Guild',
				desc = 'Broadcast killshot to ltks users in guild.',
				get = function()
					return ltks.db.profile.doguild
				end,
				set = function(info, c)
					ltks.db.profile.doguild = c
				end,
				disabled = function()
					return not ltks.db.profile.dobroadcasts
				end,
				width = "full",
				order = 90
			},
			doraid = {
				type = 'toggle',
				name = 'Broadcasts to/from Party/Raid/Instance',
				desc = 'Broadcast killshot to ltks users in your paty or raid.',
				get = function()
					return ltks.db.profile.doraid
				end,
				set = function(info, d)
					ltks.db.profile.doraid = d
				end,
				disabled = function()
					return not ltks.db.profile.dobroadcasts
				end,
				width = "full",
				order = 110
			},
			dobg = {
				type = 'toggle',
				name = 'Broadcast to/from Battleground',
				desc = 'Broadcast killshot to battleground.',
				get = function()
					return ltks.db.profile.dobg
				end,
				set = function(info, e)
					ltks.db.profile.dobg = e
				end,
				disabled = function()
					return not ltks.db.profile.dobroadcasts
				end,
				width = "full",
				order = 120
			},
			dofriends = {
				type = 'toggle',
				name = 'Broadcast to Friends',
				desc = 'Broadcast killshot to friends.',
				get = function()
					return ltks.db.profile.dofriends
				end,
				set = function(info, e)
					ltks.db.profile.dofriends = e
				end,
				disabled = function()
					return not ltks.db.profile.dobroadcasts
				end,
				width = "full",
				order = 125
			},
			versioncheck = {
				type = 'execute',
				width = "full",
				name = 'Check other players versions',
				desc = 'Check Versions',
				func = "VersionCheck",
				order = 130
			}
		}
	}
	return broadcasts 
end

local function giveScreenshots()
	local screenshots = {
		type = "group",
		name = "Screenshots",
		handler = ltks,
		args = {
			doscreenshotonkill = {
				type = 'toggle',
				name = 'Enable Screenshot on Killshot',
				desc = 'Enable Screenshot on Killshot',
				get = function()
					return ltks.db.profile.doscreenshotonkill
				end,
				set = function(info, b)
					ltks.db.profile.doscreenshotonkill = b
				end,
				width = "full",
				order = 80
			},
			doscreenshotonstreak = {
				type = 'toggle',
				name = 'Enable Screenshot on new max killing streak',
				desc = 'Enable Screenshot on new max killing streak',
				get = function()
					return ltks.db.profile.doscreenshotonstreak
				end,
				set = function(info, b)
					ltks.db.profile.doscreenshotonstreak = b
				end,
				width = "full",
				order = 90
			},
			doscreenshotonmultikill = {
				type = 'toggle',
				name = 'Enable Screenshot on multikill',
				desc = 'Enable Screenshot on multikill',
				get = function()
					return ltks.db.profile.doscreenshotonmultikill
				end,
				set = function(info, b)
					ltks.db.profile.doscreenshotonmultikill = b
				end,
				width = "full",
				order = 100
			},
			doscreenshotonduelwin = {
				type = 'toggle',
				name = 'Enable Screenshot on duel win',
				desc = '',
				get = function()
					return ltks.db.profile.doscreenshotonduelwin
				end,
				set = function(info, b)
					ltks.db.profile.doscreenshotonduelwin = b
				end,
				width = "full",
				order = 105
			},
			doscreenshotonduelloss = {
				type = 'toggle',
				name = 'Enable Screenshot on duel loss',
				desc = '',
				get = function()
					return ltks.db.profile.doscreenshotonduelloss
				end,
				set = function(info, b)
					ltks.db.profile.doscreenshotonduelloss = b
				end,
				width = "full",
				order = 106
			},
			doscreenshotondeath = {
				type = 'toggle',
				name = 'Enable Screenshot on death',
				desc = 'Enable Screenshot on death',
				get = function()
					return ltks.db.profile.doscreenshotondeath
				end,
				set = function(info, b)
					ltks.db.profile.doscreenshotondeath = b
				end,
				width = "full",
				order = 110
			},	
			versioncheck = {
				type = 'execute',
				width = "full",
				name = 'Test Screenshot Lag',
				desc = 'Enable screenshots will cause a short lag, please test first.',
				func = function() Screenshot() end,
				order = 130
			}
		}
	}
	return screenshots 
end

local function giveDuels()
	local duels = {
		type = "group",
		name = "Duels",
		handler = ltks,
		args = {
			duelhumiliation = {
				type = 'toggle',
				name = 'Play humiliation when player flees a duel',
				desc = '',
				get = function()
					return ltks.db.profile.duelhumiliation
				end,
				set = function(info, b)
					ltks.db.profile.duelhumiliation = b
				end,
				width = "full",
				order = 10
			},
			duelemotewin = {
				type = 'select',
				name = 'Emote for Duel Win',
				desc = 'Choose an Emote',
				get = function()
					return ltks.db.profile.duelemotewin
				end,
				set = function(info, b)
					ltks.db.profile.duelemotewin = b
				end,
				values = {
					none = "None",
					RANDOM = "Random",
					BELCH = "Belch",
					BOGGLE = "Boggle",
					BONK = "Bonk",
					BORED = "Bored",
					BOUNCE = "Bounce",
					BOW = "Bow",
					APPLAUD = "Bravo",
					BRB = "BRB",
					BURP = "Burp",
					BYE = "Bye",
					CACKLE = "Cackle",
					CALM = "Calm",
					SCRATCH = "Cat",
					CHEER = "Cheer",
					EAT = "Chew",
					CHICKEN = "Chicken",
					CHUCKLE = "Chuckle",
					CLAP = "Clap",
					COMFORT = "Comfort",
					COMMEND = "Commend",
					CONFUSED = "Confused",
					CONGRATULATE = "Congrats",
					COUGH = "Cough",
					COWER = "Cower",
					CRACK = "Crack Knuckles",
					CRINGE = "Cringe",
					CRY = "Cry",
					CUDDLE = "Cuddle",
					CURIOUS = "Curious",
					CURTSEY = "Curtsey",
					DANCE = "Dance",
					DOOM = "Doom",
					DRINK = "Drink",
					DROOL = "Drool",
					EYE = "Eye",
					FART = "Fart",
					FROWN = "Frown",
					GASP = "Gasp",
					GLARE = "Glare",
					GLOAT = "Gloat",
					GOLFCLAP = "Golf Clap",
					GREET = "Greet",
					GRIN = "Grin",
					GROAN = "Groan",
					GROWL = "Growl",
					GUFFAW = "Guffaw",
					HAIL = "Hail",
					HAPPY = "Happy",
					HUG = "Hug",
					FIDGET = "Impatient",
					INSULT = "Insult",
					INTRODUCE = "Introduce",
					JK = "JK",
					KISS = "Kiss",
					KNEEL = "Kneel",
					KNUCKLES = "Knuckles",
					LAUGH = "Laugh",
					LICK = "Lick",
					LISTEN = "Listen",
					LOST = "Lost",
					LOVE = "Love",
					ANGRY = "Mad",
					MASSAGE = "Massage",
					MOAN = "Moan",
					MOCK = "Mock",
					MOO = "Moo",
					MOON = "Moon",
					MOURN = "Mourn",
					NO = "No",
					NOD = "Nod",
					NOSEPICK = "Nosepick",
					PAT = "Pat",
					PEER = "Peer",
					SHOO = "Shoo",
					PITY = "Pity",
					PLEAD = "Plead",
					POINT = "Point",
					POKE = "Poke",
					PONDER = "Ponder",
					POUNCE = "Pounce",
					PULSE = "Pulse",
					PRAISE = "Praise",
					PRAY = "Pray",
					PURR = "Purr",
					PUZZLE = "Puzzled",
					TALKQ = "Question",
					RAISE = "Raise",
					RASP = "Rasp (Rude Gesture)",
					READY = "Ready",
					SHAKE = "Shake Rear",
					ROAR = "Roar",
					ROFL = "ROFL",
					RUDE = "Rude",
					SALUTE = "Salute",
					SEXY = "Sexy",
					SHIMMY = "Shimmy",
					SHY = "Shy",
					SIGH = "Sigh",
					JOKE = "Silly",
					SLAP = "Slap",
					SMELL = "Smell",
					SMILE = "Smile",
					SMIRK = "Smirk",
					SNARL = "Snarl",
					SNICKER = "Snicker",
					SNIFF = "Sniff",
					SNUB = "Snub",
					SOOTHE = "Soothe",
					APOLOGIZE = "Sorry",
					SPIT = "Spit",
					STARE = "Stare",
					SURPRISED = "Surprised",
					TAP = "Tap",
					TAUNT = "Taunt",
					TEASE = "Tease",
					THANK = "Thank",
					THREATEN = "Threaten",
					TICKLE = "Tickle",
					TIRED = "Tired",
					VETO = "Veto",
					VICTORY = "Victory",
					VIOLIN = "Violin",
					WAVE = "Wave",
					WELCOME = "Welcome",
					WHINE = "Whine",
					WHISTLE = "Whistle",
					WINK = "Wink",
					WORK = "Work",
					YAWN = "Yawn"
				},
				order = 25
				},
				duelemoteloss = {
				type = 'select',
				name = 'Emote for Duel Loss',
				desc = 'Choose an Emote',
				get = function()
					return ltks.db.profile.duelemoteloss
				end,
				set = function(info, b)
					ltks.db.profile.duelemoteloss = b
				end,
				values = {
					none = "None",
					RANDOM = "Random",
					BELCH = "Belch",
					BLOWKISS = "Blow Kiss",
					BOGGLE = "Boggle",
					BONK = "Bonk",
					BORED = "Bored",
					BOUNCE = "Bounce",
					BOW = "Bow",
					APPLAUD = "Bravo",
					BRB = "BRB",
					BURP = "Burp",
					BYE = "Bye",
					CACKLE = "Cackle",
					CALM = "Calm",
					SCRATCH = "Cat",
					CHEER = "Cheer",
					EAT = "Chew",
					CHICKEN = "Chicken",
					CHUCKLE = "Chuckle",
					CLAP = "Clap",
					COMFORT = "Comfort",
					COMMEND = "Commend",
					CONFUSED = "Confused",
					CONGRATULATE = "Congrats",
					COUGH = "Cough",
					COWER = "Cower",
					CRACK = "Crack Knuckles",
					CRINGE = "Cringe",
					CRY = "Cry",
					CUDDLE = "Cuddle",
					CURIOUS = "Curious",
					CURTSEY = "Curtsey",
					DANCE = "Dance",
					DOOM = "Doom",
					DRINK = "Drink",
					DROOL = "Drool",
					EYE = "Eye",
					FART = "Fart",
					FROWN = "Frown",
					GASP = "Gasp",
					GLARE = "Glare",
					GLOAT = "Gloat",
					GOLFCLAP = "Golf Clap",
					GREET = "Greet",
					GRIN = "Grin",
					GROAN = "Groan",
					GROWL = "Growl",
					GUFFAW = "Guffaw",
					HAIL = "Hail",
					HAPPY = "Happy",
					HUG = "Hug",
					FIDGET = "Impatient",
					INSULT = "Insult",
					INTRODUCE = "Introduce",
					JK = "JK",
					KISS = "Kiss",
					KNEEL = "Kneel",
					KNUCKLES = "Knuckles",
					LAUGH = "Laugh",
					LICK = "Lick",
					LISTEN = "Listen",
					LOST = "Lost",
					LOVE = "Love",
					ANGRY = "Mad",
					MASSAGE = "Massage",
					MOAN = "Moan",
					MOCK = "Mock",
					MOO = "Moo",
					MOON = "Moon",
					MOURN = "Mourn",
					NO = "No",
					NOD = "Nod",
					NOSEPICK = "Nosepick",
					PAT = "Pat",
					PEER = "Peer",
					SHOO = "Shoo",
					PITY = "Pity",
					PLEAD = "Plead",
					POINT = "Point",
					POKE = "Poke",
					PONDER = "Ponder",
					POUNCE = "Pounce",
					PULSE = "Pulse",
					PRAISE = "Praise",
					PRAY = "Pray",
					PURR = "Purr",
					PUZZLE = "Puzzled",
					TALKQ = "Question",
					RAISE = "Raise",
					RASP = "Rasp (Rude Gesture)",
					READY = "Ready",
					SHAKE = "Shake Rear",
					ROAR = "Roar",
					ROFL = "ROFL",
					RUDE = "Rude",
					SALUTE = "Salute",
					SEXY = "Sexy",
					SHIMMY = "Shimmy",
					SHY = "Shy",
					SIGH = "Sigh",
					JOKE = "Silly",
					SLAP = "Slap",
					SMELL = "Smell",
					SMILE = "Smile",
					SMIRK = "Smirk",
					SNARL = "Snarl",
					SNICKER = "Snicker",
					SNIFF = "Sniff",
					SNUB = "Snub",
					SOOTHE = "Soothe",
					APOLOGIZE = "Sorry",
					SPIT = "Spit",
					STARE = "Stare",
					SURPRISED = "Surprised",
					TAP = "Tap",
					TAUNT = "Taunt",
					TEASE = "Tease",
					THANK = "Thank",
					THREATEN = "Threaten",
					TICKLE = "Tickle",
					TIRED = "Tired",
					VETO = "Veto",
					VICTORY = "Victory",
					VIOLIN = "Violin",
					WAVE = "Wave",
					WELCOME = "Welcome",
					WHINE = "Whine",
					WHISTLE = "Whistle",
					WINK = "Wink",
					WORK = "Work",
					YAWN = "Yawn",
					NOD = "Yes"
				},
				order = 26
				},
			dueltxtemote = {
				type = 'toggle',
				name = 'Show Custom Emote',
				desc = 'Toggle Emote Spam',
				get = function()
					return ltks.db.profile.dueltxtemote
				end,
				set = function(info, b)
					ltks.db.profile.dueltxtemote = b
				end,
				width = "full",
				order = 30
			},
			duelcustomemote = {
				type = 'input',
				name = 'Custom Emote Message',
				desc = "Use this to customize the emote message. $v = victim $s = streak",
				usage = "<message>",
				get = function()
					return ltks.db.profile.duelcustomemote
				end,
				set = function(info, b)
					ltks.db.profile.duelcustomemoteemote = b
				end,
				width = "full",
				order = 40
			},		
			dueltext = {
				type = 'input',
				name = 'Scrolling Text Message',
				desc = 'Use this to customize the Scrolling Text Message. $k = killer, $v = victim',
				usage = "<message>",
				get = function()
					return ltks.db.profile.dueltext
				end,
				set = function(info, b)
					ltks.db.profile.dueltext = b
				end,
				width = "full",
				order = 60
			},
		}
	}
	return duels 
end

local function giveRanks()
	local ranks = {
		type = "group",
		name = "Rank Tuning",
		desc = "0 is disabled",
		args = {
			ksrank1 = {
				type = 'range',
				name = 'KS Rank 1',
				desc = 'Number of kills to reach Rank 1',
				width = "full",
				get = function() return ltks.db.profile.ksrank[1] end,
				set = function(info, v) ltks.db.profile.ksrank[1] = v end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 1,
				max = 50,
				step = 1
			},
			ksrank2 = {
				type = 'range',
				name = 'KS Rank 2',
				desc = 'Number of kills to reach Rank 2',
				width = "full",
				get = function() return ltks.db.profile.ksrank[2] end,
				set = function(info, v) ltks.db.profile.ksrank[2] = v end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 0,
				max = 50,
				step = 1
			},
			ksrank3 = {
				type = 'range',
				name = 'KS Rank 3',
				desc = 'Number of kills to reach Rank 3',
				width = "full",
				get = function()
					return ltks.db.profile.ksrank[3]
				end,
				set = function(info, v)
					ltks.db.profile.ksrank[3] = v
				end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 0,
				max = 50,
				step = 1
			},
			ksrank4 = {
				type = 'range',
				name = 'KS Rank 4',
				desc = 'Number of kills to reach Rank 4',
				width = "full",
				get = function()
					return ltks.db.profile.ksrank[4]
				end,
				set = function(info, v)
					ltks.db.profile.ksrank[4] = v
				end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 0,
				max = 50,
				step = 1
			},
			ksrank5 = {
				type = 'range',
				name = 'KS Rank 5',
				desc = 'Number of kills to reach Rank 5',
				width = "full",
				get = function()
					return ltks.db.profile.ksrank[5]
				end,
				set = function(info, v)
					ltks.db.profile.ksrank[5] = v
				end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 0,
				max = 50,
				step = 1
			},
			ksrank6 = {
				type = 'range',
				name = 'KS Rank 6',
				desc = 'Number of kills to reach Rank 6',
				width = "full",
				get = function() return ltks.db.profile.ksrank[6] end,
				set = function(info, v)	ltks.db.profile.ksrank[6] = v end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 0,
				max = 50,
				step = 1
			},
			ksrank7 = {
				type = 'range',
				name = 'KS Rank 7',
				desc = 'Number of kills to reach Rank 7',
				width = "full",
				get = function() return ltks.db.profile.ksrank[7] end,
				set = function(info, v)	ltks.db.profile.ksrank[7] = v end,
				disabled = function() if (ltks.db.profile.style == "dota") then return false else return true end end,
				min = 0,
				max = 50,
				step = 1
			},
			utrank = {
				type = 'range',
				name = 'Unreal Tournament Multiplier',
				width = "double",
				desc = 'Number of kills between notifies, ex: 3 would play sounds at 3,9,12,...',
				get = function() return ltks.db.profile.utrank end,
				set = function(info, v) ltks.db.profile.utrank = v end,
				disabled = function() if (ltks.db.profile.style == "ut") then return false else return true end end,
				min = 1,
				max = 10,
				step = 1
			}
	
		}
	}
	return ranks
end

local function giveSoundFileSetup()
	local soundfilesetup = {
		type = "group",
		name = "Sound File Setup",
		desc = "For setting up custom sounds only",
		args = {
			resetkssound = {
				type = 'execute',
				width = "full",
				name = 'Reset to default files',
				func = function() ltks.db.profile.kssound = ltks.db.defaults.profile.kssound end,
			},
			kssound1 = {
				type = 'input',
				name = 'KS Sound 1',
				desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
					return ltks.db.profile.kssound[1]
				end,
				set = function(info, v)
					ltks.db.profile.kssound[1] = v
				end
			},
			kssound2 = {
				type = 'input',
				name = 'KS Sound 2',
			desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
				return ltks.db.profile.kssound[2]
					end,
				set = function(info, v)
					ltks.db.profile.kssound[2] = v
				end
				},
			kssound3 = {
				type = 'input',
				name = 'KS Sound 3',
				desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
					return ltks.db.profile.kssound[3]
				end,
				set = function(info, v)
					ltks.db.profile.kssound[3] = v
				end
			},
			kssound4 = {
				type = 'input',
				name = 'KS Sound 4',
				desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
					return ltks.db.profile.kssound[4]
				end,
				set = function(info, v)
					ltks.db.profile.kssound[4] = v
				end
			},
			kssound5 = {
				type = 'input',
				name = 'KS Sound 5',
				desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
					return ltks.db.profile.kssound[5]
				end,
				set = function(info, v)
					ltks.db.profile.kssound[5] = v
				end
			},
			kssound6 = {
				type = 'input',
				name = 'KS Sound 6',
				desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
					return ltks.db.profile.kssound[6]
				end,
				set = function(info, v)
					ltks.db.profile.kssound[6] = v
				end
			},
			kssound7 = {
				type = 'input',
				name = 'KS Sound 7',
				desc = 'Choose a sound file',
				usage = "End the name of a sound file",
				get = function()
					return ltks.db.profile.kssound[7]
				end,
				set = function(info, v)
					ltks.db.profile.kssound[7] = v
				end
			},
			prepare = {
				type = 'input',
				name = 'Prepare Sound',
				desc = 'Choose a sound file',
				usage = "Enter the name of the sound file",
				get = function()
					return ltks.db.profile.kssoundP
				end,
				set = function(info, v)
					ltks.db.profile.kssoundP = v
				end
			},
			executesound = {
				type = 'input',
				name = 'Execute Sound',
				desc = 'Choose a sound file',
				usage = "Enter the name of the sound file",
				get = function()
					return ltks.db.profile.kssoundE
				end,
				set = function(info, v)
					ltks.db.profile.kssoundE = v
				end
			}
		}
	}
	return soundfilesetup
end

local function giveOutput()
	local output = {
		name = "Combat Message Output",
		type = "group",
		args = {
			desc = {
				type = "description",
				name = "You can select where you want LT Killshot Combat messages displayed from this screen.",
				order = 0
			},
			sink = ltks:GetSinkAce3OptionsDataTable(),
		}
	}
	-- hacks borrowed from Witch Hunt
	output.args.sink.order = 1
	output.args.sink.inline = true
	--output.args.sink.name = ""
	return output
end

local defaults = {
	profile = {
		configversion = newestconfigversion,
		maxstreak = 0,
		maxdeathstreak = 0,
		ksemote = "has killed $v! Streak of $s!",
		dueltxtemote = false,
		duelcustomemote = "has defended his honor against $v! Streak of $s!",
		kstext = "$k killed $v!",
		dueltext = "$k has defeated $v!",
		soundpack = "unreal2003",
		soundpath = "Interface\\AddOns\\ltks\\sounds\\",
		dotxtemote = false,
		doemote = "none",
		duelemotewin = "BOW",
		duelemoteloss = "BOW",
		duelhumiliation = true,
		doscreenshotonkill = false,
		doscreenshotonstreak = false,
		doscreenshotonmultikill = false,
		doscreenshotonduelwin = false,
		doscreenshotonduelloss = false,
		doscreenshotondeath = false,
		--dopet = false,
		style = "ut",
		docombattext = true,
		dobroadcasts = true,
		doguild = true,
		dobg = true,
		doraid = true,
		dofriends = true,
		dosound = true,
		soundchannel = "Master",
		dopve = false,
		dozonechange = false,
		dopreparesound = false,
		doexecutesound = false,
		doexecutesoundpve = false,
		doexecutepercent = 25,
		dochatbox = true,
		dokillfeed = false,
		utrank = 3,
		mkwindow = "timer",
		mktime = 10,
		ksrank = {1, 2, 4, 6, 8, 10, 12},
		kssound = {"ownage.ogg", "killingspree.ogg", "rampage.ogg", "dominating.ogg", "unstoppable.ogg", "godlike.ogg", "whickedsick.ogg"},
		kssoundM = {"firstblood.ogg", "doublekill.ogg", "multikill.ogg", "monsterkill.ogg", "holyshit.ogg"},
		kssoundP = "prepare.ogg",
		kssoundE = "finishhim.ogg",
		kstextM = {"Double Kill!", "Triple Kill!", "Quadra Kill!", "Penta Kill!", "Hexakill!", "Legendary!"},
		lastStreak = 0,
		killlog = {},
		damageDealers = {},
		killList = {},
		deathList = {},
		kssoundH = "humiliation.ogg",
		sink20Sticky = true,
		sink20OutputSink = "Default",
		sink20ScrollArea = "Outgoing",
	},
}

function ltks:OnInitialize()

	-- Migrate legacy saved variables (pre-rename era): the client creates the
	-- new ltksDB global empty, so copy the old data over once if present.
	if (not ltksDB or not next(ltksDB)) and dgksDB and next(dgksDB) then
		ltksDB = dgksDB
	end

	-- Migrate legacy sound pack paths (baby/female/sexy folders removed) to the
	-- single Unreal 2003 pack at the sounds root.

	-- Setup DB
	self.db = LibStub("AceDB-3.0"):New("ltksDB", defaults, true)
	local legacyPath = self.db.profile.soundpath or ""
	if legacyPath:find("\\baby\\") or legacyPath:find("\\female\\") or legacyPath:find("\\sexy\\") then
		self.db.profile.soundpath = soundPath
		self.db.profile.soundpack = "unreal2003"
	end

	self:SetSinkStorage(self.db.profile)

	-- Increment newestconfigversion to reset db to defaults when needed
	if (ltks.db.profile.configversion < newestconfigversion ) then
		ltks:Print("Config outdated, reverting to defaults.")
		ltks.db:ResetProfile()
	end
	-- Repair stored sound paths: collapse doubled backslashes and fix any
	-- pre-rename dgks folder references (both break PlaySoundFile silently).
	local storedPath = self.db.profile.soundpath or ""
	local fixedPath = storedPath:gsub("\\\\+", "\\"):gsub("AddOns\\dgks\\", "AddOns\\ltks\\")
	if fixedPath ~= storedPath then
		self.db.profile.soundpath = fixedPath
	end

	if (addonName == "ltks_classic") then
		SendSystemMessage("Please switch to LT Killshot, the classic specific version, LT Killshot Classic, is no longer getting updates.")
		self.db.soundPath = "Interface\\AddOns\\ltks_classic\\sounds\\"
	end

	-- Setup Config Screens
	local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

	AceConfigRegistry:RegisterOptionsTable("LT KillShot", giveOptions)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot General", giveGeneral)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot Broadcasts", giveBroadcasts)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot Screenshots", giveScreenshots)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot Duels", giveDuels)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot Ranks", giveRanks)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot File Setup", giveSoundFileSetup)
	AceConfigRegistry:RegisterOptionsTable("LT KillShot Output", giveOutput)	
	
	local AceConfigDialog = LibStub("AceConfigDialog-3.0")
	
	local _, mainCategoryID = AceConfigDialog:AddToBlizOptions("LT KillShot", "LT KillShot")
	AceConfigDialog:AddToBlizOptions("LT KillShot General", "General", "LT KillShot")
	AceConfigDialog:AddToBlizOptions("LT KillShot Broadcasts", "Broadcasts", "LT KillShot")
	AceConfigDialog:AddToBlizOptions("LT KillShot Screenshots", "Screenshots", "LT KillShot")
	AceConfigDialog:AddToBlizOptions("LT KillShot Duels", "Duels", "LT KillShot")
	AceConfigDialog:AddToBlizOptions("LT KillShot Ranks", "Ranks", "LT KillShot")
	-- Clean up UI
	-- AceConfigDialog:AddToBlizOptions("LT KillShot File Setup", "Sound File Setup", "LT KillShot")
	AceConfigDialog:AddToBlizOptions("LT KillShot Output", "Combat Text Output", "LT KillShot")

	-- Setup slash commands
	-- The triple call fixes bug that doesn't open on first run and expans the sub pages
	local function OpenSettings()
		if mainCategoryID then
			Settings.OpenToCategory(mainCategoryID)
		else
			Settings.OpenToCategory("LT KillShot")
		end
	end
	self:RegisterChatCommand("ltks", OpenSettings)
	self:RegisterChatCommand("ks", OpenSettings)
	
	
	-- Setup Comms
	self:RegisterComm("ltks") --Killshots
	self:RegisterComm("ltksV") --Version check
	self:RegisterComm("ltksVR") --Version check responses
	self:RegisterComm("ltksDUEL") --Duels
end

function ltks:SoundEventHandler(info, sound)
	if (ltks.db.profile.dosound) then
		-- Only gate on the channel this addon actually plays on; the old check
		-- forced the SFX cvar even for Master/Music playback (and "0" strings
		-- are truthy, so the AllSound half never worked anyway).
		local channel = ltks.db.profile.soundchannel or "Master"
		local cvar = "Sound_EnableAllSound"
		if channel == "SFX" then cvar = "Sound_EnableSFX"
		elseif channel == "Ambience" then cvar = "Sound_EnableAmbience"
		elseif channel == "Music" then cvar = "Sound_EnableMusic" end
		if (GetCVar(cvar) == "1") then
			--[===[@debug@
				-- Dev Debugging functions
				self.Print("DEBUG: Sound: " .. sound )
				self.Print("DEBUG: Soundchannel: " .. channel )
			--@end-debug@]===]
			PlaySoundFile(sound,channel)
		end
	end
end

function ltks:OnDisable()
    -- Called when the addon is disabled
end

function ltks:CombatLogEventHandler(info, timestamp, event, hideCaster, sourceGUID, sourceName, sourceFlags, sourceFlags2, destGUID, destName, destFlags, destFlags2, ...)
	
	-- Example of player kill
	-- 7/21 01:23:16.879  PARTY_KILL,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0,Player-3676-09BED6E0,"Kruulmokthan-Area52",0x10548,0x0
	-- 7/21 01:23:16.879  SPELL_DAMAGE,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0,Player-3676-09BED6E0,"Kruulmokthan-Area52",0x10548,0x0,585,"Smite",0x2,0000000000000000,0000000000000000,0,0,0,0,0,-1,0,0,0,0.00,0.00,628,0.0000,0,930,969,249,2,0,0,0,nil,nil,nil
    -- 7/21 01:23:16.879  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3676-09BED6E0,"Kruulmokthan-Area52",0x10548,0x0
	
	-- FIXME Use party_kill for all kills by player, use unit_died for owned pets only
	-- Remove Party Kill to test damageDealers table This maybe required to detect Feign Death
	if event == "PARTY_KILL" then
		if (destFlags == nil) then return end
		if (bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == COMBATLOG_OBJECT_TYPE_PLAYER) or ltks.db.profile.dopve then
			-- A unit has died to someone in our party
				
			if string.format("%s", sourceGUID) == string.format("%s", UnitGUID("player")) then
							
				--[===[@debug@
				-- Dev Debugging functions
				self.Print("DEBUG: " .. UnitName("player") .. " has landed the kill.")
				self.Print("DEBUG: " .. "Sending "..destName.." and "..timestamp.." to KillshotTX." )
				--@end-debug@]===]
				
				-- The player has landed a killshot - use full name with realm
				local fullDestName = GetNameFromGUID(destGUID) or destName
				self:KillshotTX(fullDestName, timestamp)
			end
		end
	end
	-- Check for player death by pet
	-- FIXME limit this to pet kills only
	if event == "UNIT_DIED" then
		if destName == playerName then
			-- Player has died
			local fullDestName = GetNameFromGUID(destGUID) or destName
			local myKiller = damageDealers[fullDestName]			
			self:PlayerDeath(myKiller)
			-- Test is probably broken
		elseif bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == COMBATLOG_OBJECT_TYPE_PLAYER or ltks.db.profile.dopve or destName == "Test-Victim" then
				local fullDestName = GetNameFromGUID(destGUID) or destName
					if damageDealers[fullDestName] == "PlayerPet" then
				-- Last damage dealt to dead unit was from player
				--[===[@debug@
				-- Dev Debugging functions
				self:Print("DEBUG: " .. UnitName("player") .. " has landed the kill.")
				self:Print("DEBUG: " .. "Sending "..destName.." and "..timestamp.." to KillshotTX." )
				--@end-debug@]===]
				-- The player has landed a killshot,this detection method is fooled by Feign Death so we do PARTY_KILL ALSO - use full name with realm
				local fullDestName = GetNameFromGUID(destGUID) or destName
				self:KillshotTX(fullDestName, timestamp)
			end
		end
	end
	
	-- Record last damage source for pet kill and player death tracking
	if string.find(event, "_DAMAGE") then
		-- This should log pets and creatures under players control to the player
		-- This worked, but we need to superate pets -- if sourceName ~= playerName and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0 then sourceName = playerName end
		if sourceName ~= playerName and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0 then sourceName = "PlayerPet" end
		-- Use full name with realm for damageDealers table

		local fullDestName = GetNameFromGUID(destGUID) or destName

		damageDealers[fullDestName] = sourceName

		
		-- Check for execute if enabled
		if ltks.db.profile.doexecutesound or ltks.db.profile.doexecutesoundpve then
		--Only do execute if we have a target and they are hostile 
			if GetFullUnitName("target") == destName then
				-- This _DAMAGE event is for out target
				if UnitIsEnemy("player","target") then 
					-- This is an enemy
					if bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) == COMBATLOG_OBJECT_TYPE_PLAYER or ltks.db.profile.doexecutesoundpve then
						-- dest is a player or pve is enabled
						local targetHealthPercent = floor(UnitHealth("target") / UnitHealthMax("target") * 100,0)
						if targetHealthPercent <= ltks.db.profile.doexecutepercent and targetHealthPercent > 1 then
							-- Target is under threshold
							--[===[@debug@
							-- Dev Debugging functions
							--ltks:Print("DEBUG: " .. GetFullUnitName("target") .. " " .. destName .. " " .. targetHealthPercent)
							--@end-debug@]===]
							if targetList[GetFullUnitName("target")] == nil then
								--First time we have seen this target in execute range
								ltks:ltks_SoundPack(ltks.db.profile.kssoundE)
							elseif targetList[GetFullUnitName("target")] <= ltks.db.profile.doexecutepercent then
								--Target was already under threshold don't spam
							else
								-- Target is now below threshhold play sound
								ltks:ltks_SoundPack(ltks.db.profile.kssoundE)
							end
						end
						--Store target health in table so we can filter repeat executes
						targetList[GetFullUnitName("target")] = targetHealthPercent
						--ltks:Print(targetList[GetFullUnitName("target")])
					end
				end
			end
		end
	end 
end

function ltks:PartyKillHandler(attackerGUID, targetGUID)
    -- In instanced PvP and other identity-restricted contexts (Midnight 12.0+),
    -- PARTY_KILL's GUID payload arrives as secret strings. Tainted code cannot
    -- compare, format, or inspect them (immediate Lua error), and there is no
    -- identity data left to attribute the kill, so bail out instead of crashing.
    if not attackerGUID or not targetGUID then return end
    if issecretvalue and (issecretvalue(attackerGUID) or issecretvalue(targetGUID)) then return end
    ltks:Print("[LTKS-PK] attacker=" .. tostring(attackerGUID) .. " target=" .. tostring(targetGUID) .. " pet=" .. tostring(UnitGUID("pet")) .. " mine=" .. tostring(myMinions[attackerGUID] == true))
    local playerGUID = UnitGUID("player")
    local petGUID = UnitGUID("pet")
    -- A pet's killing blow counts as the player's kill.
    if attackerGUID ~= playerGUID and attackerGUID ~= petGUID and not myMinions[attackerGUID] then return end
    local targetName = deadNameCache[targetGUID] or knownNames[targetGUID] or GetNameFromGUID(targetGUID)
    if targetName then
        local isPlayer = targetGUID:sub(1, 6) == "Player"
        if isPlayer or ltks.db.profile.dopve then
            self:KillshotTX(targetName, GetTime())
        end
    else
        -- Victim name not resolvable right now (off-target pet kill): park the
        -- kill keyed by victim GUID (concurrent kills can't overwrite each
        -- other), resolve it when UNIT_DIED fires with the matching GUID, and
        -- fall back to a short timeout so the streak/multikill never drops.
        pendingKills[targetGUID] = { time = GetTime() }
        C_Timer.After(2, function()
            local rec = pendingKills[targetGUID]
            if rec then
                pendingKills[targetGUID] = nil
                local name = deadNameCache[targetGUID] or knownNames[targetGUID] or GetNameFromGUID(targetGUID) or "Unknown"
                if targetGUID:sub(1, 6) == "Player" or ltks.db.profile.dopve then
                    ltks:KillshotTX(name, rec.time)
                end
            end
        end)
    end
end

-- UNIT_DIED carries a secret GUID when unit identity is restricted on Retail,
-- so PLAYER_DEAD (no payload) is the death trigger. The killer name comes from
-- the CLEUF damage tracker, which only records non-secret payloads; restricted
-- contexts leave it nil and PlayerDeath falls back to "Unknown Entity".
function ltks:PlayerDeadHandler()
    local killer = lastDamageSource
    lastDamageSource = nil
    self:PlayerDeath(killer)
end

function ltks:KillshotTX(txvictim,txtimestamp)
	-- Process the detect killshot
	-- Increment killshot streak 
	streak = streak + 1
	ltks.db.profile.lastStreak = streak
	-- Check and set multikill
	if (ltks.db.profile.mkwindow == "combat") then
		-- Chain persists until combat ends (reset by PLAYER_REGEN_ENABLED)
		if mkChain then
			multikill = multikill + 1;
		else
			multikill = 0; -- chain starts; base announcer plays instead
			mkChain = true;
		end
	elseif (lastkill + (ltks.db.profile.mktime or 10)) > txtimestamp then
		-- Ladies and Gentlemen we have a multikill
		multikill = multikill + 1;
	else
		multikill = 0; -- chain starts; base announcer plays instead
	end
	
	-- New Multikill timer
	lastkill = txtimestamp

	ltks:Print("[LTKS-KILL] streak=" .. streak .. " mk=" .. multikill .. " victim=" .. txvictim)
	
	-- Reset deathstreak
	deathstreak = 0
	
	-- Broadcast our Killshot
	self:SendCM("ltks",ltks:Serialize(playerName,txvictim,txtimestamp,streak,multikill))
	
end

function ltks:DuelTX(txvictim,txtimestamp)
	-- Process the detect killshot
	-- Increment killshot streak 
	streak = streak + 1
	
	-- Reset deathstreak
	deathstreak = 0
	
	-- Broadcast our duel win
	self:SendCM("ltksDUEL",ltks:Serialize(playerName,txvictim,txtimestamp,streak,multikill))
end

function ltks:PlayerLoss(myKiller)
	-- A duel loss is not a death: it no longer resets the kill streak. Only the
	-- death streak is counted here.
	deathstreak = deathstreak + 1;
	if (deathstreak > ltks.db.profile.maxdeathstreak) then ltks.db.profile.maxdeathstreak = deathstreak end
	if (myKiller == nil) then myKiller = "Unknown Entity" end
	-- Add to log
    tinsert(ltks.db.profile.killlog, 1, "[" .. date() .. "]" .. " You were defeated by " .. myKiller .. ".")
	-- If log is too long prune it
    if (ltks.db.profile.killlog[21]) then tremove(ltks.db.profile.killlog,21) end
	-- Store in deathList
	-- If deathList doesn't exist create it
	if not ltks.db.profile.deathList[myKiller] then ltks.db.profile.deathList[myKiller] = {} end
	tinsert(ltks.db.profile.deathList[myKiller], date("%m/%d/%y %H:%M:%S"))
	if (ltks.db.profile.dochatbox) then ltks:Print("You been defeated by "..myKiller.." "..#ltks.db.profile.deathList[myKiller].." times.") end
	if ltks.db.profile.doscreenshotonduelloss then Screenshot() end
	if ltks.db.profile.duelemoteloss ~= "none" then
		local emote = ltks.db.profile.duelemoteloss
		if emote == "RANDOM" then
			emote = randomEmotes[math.random(#randomEmotes)]
		end
		DoEmote(emote, myKiller)
	end
end

function ltks:OnCommReceived(cchan, message, distribution, sender)
	
	--If broadcast type is off return
	if not ltks.db.profile.dobroadcasts and sender ~= playerName then return end
	-- If Guild broadcast is off and we received a guild broadcast just return
	if not ltks.db.profile.doguild and distribution == "GUILD" then return end
	-- If raid broadcast is off and we received a raid broadcast just return
	if not ltks.db.profile.doraid and distribution == "RAID" then return end
	if not ltks.db.profile.doraid and distribution == "PARTY" then return end
	if not ltks.db.profile.doraid and distribution == "INSTANCE_CHAT" then return end

	local timestamp = time()
	
	--Process non-serialized cchan
	--[===[@debug@
	self:Print("OnCommReceived: CChan= " .. cchan .. " " .. message .. distribution .. sender)
	--@end-debug@]===]
	if cchan == "ltksVR" then
		if sender ~= playerName then self:Print(sender .. " is on version " .. message) end

	elseif cchan == "ltksV" then
		-- Check for duplicates here
		if sender == lastSender and message == lastMessage and timestamp == lastTimestamp then return end
		-- Respond with our version

		--[===[@debug@
		-- No need to print unless debugging
		self:Print(sender .. " is on version " .. message)
		--@end-debug@]===]

		--This should always be a direct whisper
		self:SendCommMessage("ltksVR",version,WHISPER,sender)

	elseif cchan == "ltks" or cchan == "ltksDUEL" then
		--Verify we have a valid event	
		local ok,rxkiller,rxvictim,rxtimestamp,rxstreak,rxmultikill = ltks:Deserialize(message)
		if not ok then return else
		
			-- Check for duplicates using recentKills table
			local killKey = rxkiller .. "|" .. rxvictim .. "|" .. tostring(rxtimestamp)
			if recentKills[killKey] then return end
			recentKills[killKey] = true
			-- Keep recentKills small
			local count = 0
			for _ in pairs(recentKills) do count = count + 1 end
			if count > 20 then
				local oldest_key
				for k in pairs(recentKills) do oldest_key = k break end
				recentKills[oldest_key] = nil
			end
			-- Set duplicate prevention variables
			lastrxkiller, lastrxvictim, lastrxtimestamp = rxkiller, rxvictim, rxtimestamp
		
			-- Generate Text
			if cchan == "ltks" then 
				killshottext = string.gsub(string.gsub(ltks.db.profile.kstext, "$k", rxkiller), "$v", rxvictim)
				-- Killshot Emotes
				if (ltks.db.profile.dotxtemote and playerName == rxkiller) then
					emotestring=string.gsub(string.gsub(ltks.db.profile.ksemote, "$v", rxvictim), "$s", rxstreak)
					SendChatMessage(emotestring, "EMOTE")
				end
				if (ltks.db.profile.doemote ~= "none" and playerName == rxkiller) then
					-- fixme targeting doesn't seem to work with NPCs
					local emote = ltks.db.profile.doemote
					if emote == "RANDOM" then
						emote = randomEmotes[math.random(#randomEmotes)]
					end
					DoEmote(emote, rxvictim)
				end
			else
				killshottext = string.gsub(string.gsub(ltks.db.profile.dueltext, "$k", rxkiller), "$v", rxvictim)
				--Duel Emotes
			if (ltks.db.profile.dueltxtemote and playerName == rxkiller) then
				emotestring=string.gsub(string.gsub(ltks.db.profile.duelcustomemote, "$v", rxvictim), "$s", rxstreak)
				SendChatMessage(emotestring, "EMOTE")
			end
			if (ltks.db.profile.duelemotewin ~= "none" and playerName == rxkiller) then
				-- fixme targeting doesn't seem to work with NPCs
				local emote = ltks.db.profile.duelemotewin
				if emote == "RANDOM" then
					emote = randomEmotes[math.random(#randomEmotes)]
				end
				DoEmote(emote, rxvictim)
			end
			end
			
			-- Send to sink for local output
			self:ScrollText(killshottext)
			
			-- Process multikill and play appropiate sound and text
			-- Priority: milestone tier > multikill chain > base announcer
			local sound = ltks:GetKillshotSound(rxstreak)
			if sound and playerName == rxkiller and ltks.db.profile.style == "ut" then
				-- Streak milestone: announce big on the raid warning frame
				local tierPack = packTiers[ltks.db.profile.soundpack] or packTiers.unreal2003
				local idx = (rxstreak / 5 - 1)
				if tierPack.cycle then
					idx = idx % #tierPack.list + 1
				else
					idx = math.min(idx + 1, #tierPack.list)
				end
				local labels = packTierLabels[ltks.db.profile.soundpack] or packTierLabels.unreal2003
				if labels[idx] then
					RaidWarningFrame:AddMessage(labels[idx], { r = 1, g = 0.82, b = 0 })
				end
			end
			if not sound and rxmultikill > 0 then
				local chain = packChain[ltks.db.profile.soundpack] or packChain.unreal2003
				sound = chain[math.min(rxmultikill, #chain)]
				if sound and self.db.profile.kstextM[rxmultikill] then
					self:ScrollText(rxkiller .. " got a " .. self.db.profile.kstextM[rxmultikill] .. "!")
				end
			end
			if not sound then
				local ladder = packLadder[ltks.db.profile.soundpack] or packLadder.unreal2003
				sound = ladder[rxstreak] or ladder[#ladder]
			end
			ltks:Print("[LTKS-RX] rxstreak=" .. tostring(rxstreak) .. " rxmk=" .. tostring(rxmultikill) .. " style=" .. tostring(ltks.db.profile.style) .. " pack=" .. tostring(ltks.db.profile.soundpack) .. " win=" .. tostring(ltks.db.profile.mkwindow) .. " mktime=" .. tostring(ltks.db.profile.mktime) .. " sound=" .. tostring(sound))
			if sound and playerName == rxkiller then self:ltks_SoundPack(sound) end

			-- We have landed a kill
			if playerName == rxkiller then
				if (ltks.db.profile.dochatbox) then ltks:Print(killshottext) end
				local setMaxStreak = false
				
				-- Increment maxstreak if this is a record high
				if ( streak > ltks.db.profile.maxstreak ) then 
					ltks.db.profile.maxstreak = streak
					setMaxStreak = true
				end
						
				-- This now triggers a global cool and most likely cannot work anymore
				-- if ltks.db.profile.dopet then C_PetJournal.SummonRandomPet(allPets) end
				
				if ltks.db.profile.doscreenshotonkill then Screenshot()
				elseif ltks.db.profile.doscreenshotonstreak and setMaxStreak then Screenshot()
				elseif ltks.db.profile.doscreenshotonmultikill and rxmultikill > 0 then Screenshot() end
				
				-- Store in killList
				if not ltks.db.profile.killList[rxvictim] then ltks.db.profile.killList[rxvictim] = {} end
				tinsert(ltks.db.profile.killList[rxvictim], date("%m/%d/%y %H:%M:%S"))
				--fixme this count my be inaccurate due to the way lua handles tables without numeric index
				if (ltks.db.profile.dochatbox) then ltks:Print("You have killed "..rxvictim.." "..#ltks.db.profile.killList[rxvictim].." times.") end
			elseif (ltks.db.profile.dokillfeed) then
				-- Kill feed: other players' killshots in chat
				ltks:Print(killshottext)
			end
		end
	end

	--Set duplicate prevention variables
	lastMessage, lastSender, lastTimestamp = message, sender, timestamp

end

function ltks:PlayerDeath(myKiller)
	streak = 0;
	ltks:Print("[LTKS-DEATH] streak reset")
	ltks.db.profile.lastStreak = 0;
	deathstreak = deathstreak + 1;
	if (deathstreak > ltks.db.profile.maxdeathstreak) then ltks.db.profile.maxdeathstreak = deathstreak end
	-- Remember whether the killer is unidentified (fall, environmental damage,
	-- or a restricted context) so the death is recorded but not announced.
	local isUnknownKiller = (myKiller == nil)
	if (isUnknownKiller) then myKiller = "Unknown Entity" end
	-- Add to log
    tinsert(ltks.db.profile.killlog, 1, "[" .. date() .. "]" .. " You were killed by " .. myKiller .. ".")
	-- If log is too long prune it
    if (ltks.db.profile.killlog[21]) then tremove(ltks.db.profile.killlog,21) end
	-- Store in deathList
	-- If deathList doesn't exist create it
	if not ltks.db.profile.deathList[myKiller] then ltks.db.profile.deathList[myKiller] = {} end
	tinsert(ltks.db.profile.deathList[myKiller], date("%m/%d/%y %H:%M:%S"))
	if (ltks.db.profile.dochatbox and not isUnknownKiller) then ltks:Print("You been murdered by "..myKiller.." "..#ltks.db.profile.deathList[myKiller].." times.") end
	if ltks.db.profile.doscreenshotondeath then Screenshot() end
end

function ltks:GetKillshotSound(streak)
	if (ltks.db.profile.style == "dota") then
		-- DoTA Style
		for x = 7, 0, -1 do
			if (ltks.db.profile.ksrank[x] > 0) and (streak >= ltks.db.profile.ksrank[x]) then return ltks.db.profile.kssound[x]; end
		end
	else
		-- UT Style: streak milestones every 5 kills; the sound set walks per pack
		-- (Unreal 2003 cycles the whole set, League repeats its final line)
		local pack = packTiers[ltks.db.profile.soundpack] or packTiers.unreal2003
		if (streak % 5 == 0) then
			local idx = (streak / 5 - 1)
			if pack.cycle then
				idx = idx % #pack.list + 1
			else
				idx = math.min(idx + 1, #pack.list)
			end
			return pack.list[idx]
		end
		return
	end
    --If we get here the user has messed up their config we could build some sort of safety someday but for now we will just default to kssound1 FIXME
	return ltks.db.profile.kssound[1];
end

local ltks_ctFrame
local ltks_ctActive = {}

local ltks_ctQueue = {}
local ltks_CT_OnUpdate -- forward declaration (assigned below)

local function ltks_ShowNextCT()
	local entry = tremove(ltks_ctQueue, 1)
	if not entry then return end
	local fs = ltks_ctFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	fs:SetText(entry.msg)
	fs:SetTextColor(entry.r, entry.g, entry.b)
	local prev = ltks_ctActive[#ltks_ctActive]
	fs.spawnY = 0
	if prev then
		-- stack 28px above the newest active text (line-height gap, constant as all rise together)
		fs.spawnY = (prev.spawnY or 0) + 60 * (prev.elapsed_total or 0) + 28
	end
	fs:SetPoint("CENTER", ltks_ctFrame, "CENTER", 0, fs.spawnY)
	fs.elapsed_total = 0
	tinsert(ltks_ctActive, fs)
	ltks_ctFrame:SetScript("OnUpdate", ltks_CT_OnUpdate)
end

ltks_CT_OnUpdate = function(self, elapsed)
	for i = #ltks_ctActive, 1, -1 do
		local fs = ltks_ctActive[i]
		fs.elapsed_total = (fs.elapsed_total or 0) + elapsed
		local t = fs.elapsed_total
		fs:SetPoint("CENTER", ltks_ctFrame, "CENTER", 0, (fs.spawnY or 0) + 60 * t)
		if t > 1.5 then
			fs:SetAlpha(max(0, 1 - (t - 1.5)))
		end
		if t > 2.5 then
			fs:Hide()
			fs:SetParent(nil)
			tremove(ltks_ctActive, i)
		end
	end
	-- Release queued texts after a short spacing window so they never overlap
	-- (all texts rise at the same speed, so the stack gap stays constant)
	if #ltks_ctQueue > 0 then
		local newest = ltks_ctActive[#ltks_ctActive]
		if not newest or (newest.elapsed_total or 0) >= 0.1 then
			ltks_ShowNextCT()
		end
	elseif #ltks_ctActive == 0 then
		self:SetScript("OnUpdate", nil)
	end
end

local function ltks_ShowScrollText(msg, r, g, b)
	if not ltks_ctFrame then
		ltks_ctFrame = CreateFrame("Frame", "ltksCombatText", UIParent)
		ltks_ctFrame:SetSize(1, 1)
		ltks_ctFrame:SetPoint("CENTER", 0, -120)
		ltks_ctFrame:SetFrameStrata("HIGH")
	end
	tinsert(ltks_ctQueue, { msg = msg, r = r or 1, g = g or 0.1, b = b or 0.1 })
	if #ltks_ctActive == 0 then
		ltks_ShowNextCT()
	end
end

function ltks:ScrollText(msg)
	
	tinsert(ltks.db.profile.killlog, 1, "[" .. date() .. "] " .. msg)
	if (ltks.db.profile.killlog[21]) then tremove(ltks.db.profile.killlog,21) end
	
	if (ltks.db.profile.docombattext) then
		ltks_ShowScrollText(msg, 1.0, 0.1, 0.1)
	end
end

-- FIXME Entire version checking needs cleanup for duplicate sends
function ltks:VersionCheck()
    self:SendCM("ltksV",version)
end

function ltks:ltks_SoundPack(sound)
	-- FIXME	
	if not sound then sound = 1 end
    local soundfile = self.db.profile.soundpath .. sound
    ltks:SoundEventHandler(nil, soundfile)
end

function ltks:getSoundPack()
    return self.db.profile.soundpack;
end

function ltks:setSoundPack(info, newsoundset)
    if (newsoundset == "unreal2003") then
        self.db.profile.soundpack = newsoundset
        self.db.profile.soundpath = soundPath
    elseif (newsoundset == "lol") then
        self.db.profile.soundpack = newsoundset
        self.db.profile.soundpath = soundPath .. "\\lol\\"
    else
        ltks:Print("Error: That is not a valid option")
    end
end

function ltks:getKillLog()
	local plog = ""
	for _, v in ipairs(ltks.db.profile.killlog) do plog = plog .. v .. "\n" end
	return plog
end

function ltks:SendCM(cchan,msg)
	-- Example usage: self:SendCM("ltksDUEL",ltks:Serialize(playerName,txvictim,txtimestamp,streak,multikill)

	-- Whisper to ourselves if broadcasts are off or guild is off or we are not in a guild
	if not ltks.db.profile.dobroadcasts or not ltks.db.profile.doguild or not IsInGuild() then
		--[===[@debug@
		self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to WHISPER " .. playerName)
		--@end-debug@]===]
		self:SendCommMessage(cchan,msg,"WHISPER",playerName)
	end

	if ltks.db.profile.dobroadcasts then

		-- If not Retail, send to yell
		-- https://wowpedia.fandom.com/wiki/WOW_PROJECT_ID
		if WOW_PROJECT_ID ~= 1 then
			self:SendCommMessage(cchan,msg,"YELL")
			--[===[@debug@
			self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to YELL")
			--@end-debug@]===]

		end

		if ltks.db.profile.doguild and IsInGuild() then
			self:SendCommMessage(cchan,msg,"GUILD")
			--[===[@debug@
			self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to GUILD")
			--@end-debug@]===]

		end

		-- Send to Battleground / Arena	
		if ltks.db.profile.dobg then
			if inBG or inArena then 
				--[===[@debug@
				self:Print("Sending: BG CChan= " .. cchan .. " " .. msg .. " to INSTANCE_CHAT")
				--@end-debug@]===]
				self:SendCommMessage(cchan,msg,"INSTANCE_CHAT")
			end
		end

		-- Send to Raid
		-- LFG style parties and raids use INSTANCE_CHAT
		if ltks.db.profile.doraid then
			-- Raid/Party Broadcast on

			--Standard Raid
			if IsInRaid(LE_PARTY_CATEGORY_HOME) and not inArena and not inBG then
				--[===[@debug@
				self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to RAID")
				--@end-debug@]===]
				self:SendCommMessage(cchan,msg,"RAID") 
			end

				-- LFG or Group Finder Raid
			if IsInRaid(LE_PARTY_CATEGORY_INSTANCE) and not inArena and not inBG then
				--[===[@debug@
				self:Print("Sending: RAID CChan= " .. cchan .. " " .. msg .. " to INSTANCE_CHAT")
				--@end-debug@]===]
				self:SendCommMessage(cchan,msg,"INSTANCE_CHAT")
			end

			if UnitInParty("player") and not inArena and not inBG then
				self:SendCommMessage(cchan,msg,"PARTY")
				--[===[@debug@
				self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to PARTY")
				--@end-debug@]===]

			end
		end

		--Whisper to friends
		if ltks.db.profile.dofriends then
			for i = 1, C_FriendList.GetNumFriends() do
				local info = C_FriendList.GetFriendInfoByIndex(i)
				if info and info.connected then
					self:SendCommMessage(cchan,msg,"WHISPER",info.name)
					--[===[@debug@
					self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to WHISPER " .. " Name: " .. info.name)
					--@end-debug@]===]
					--C_ChatInfo.SendAddonMessage(prefix, message, "WHISPER", info.name)
				end
			end
			--Battle.net friends

			--[===[@debug@
			--for i = 1, BNGetNumFriends() do
			--	for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) do
			--		local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
			--		if game.isOnline and game.factionName then
			--			print(game.gameAccountID, game.isOnline, game.factionName, UnitFactionGroup("player"), game.realmName, GetRealmName())
			--		end
			--	end
			--end
			--@end-debug@]===]

			local totalBFriends, onlineBFriends = BNGetNumFriends()
			for i = 1, onlineBFriends  do
				for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) do
					local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
					if game.characterName == nil or game.realmName == nil or game.factionName == nil then
						break
					end
							--[===[@debug@
							self:Print("BNET: " .. j .. "Name: " .. game.characterName .. "Realm: " .. game.realmName .. GetRealmName())
							--@end-debug@]===]
					--if game.realmName == GetRealmName() and game.factionName == UnitFactionGroup("player") then
					if game.factionName == UnitFactionGroup("player") then
						self:SendCommMessage(cchan,msg,"WHISPER",game.characterName)
						
						--[===[@debug@
						self:Print("Sending: CChan= " .. cchan .. " " .. msg .. " to WHISPER " .. game.characterName)
						--@end-debug@]===]
						--C_ChatInfo.SendAddonMessage(prefix, message, "WHISPER", info.name)
					end
				end
			end
		end
	end
end

--[===[@debug@
-- Dev Debugging functions
function ltks:Test()
	-- Dev Debugging functions
	self:Print("DEBUG: " .. "Sending KillShot Event...")
	-- Example combat log entries
	-- Old 12/6 10:49:47.392  UNIT_DIED,0x0000000000000000,nil,0x80000000,0x80000000,0x0300000007362B6E,"Vvatsitchy-Caelestrasz",0x512,0x0
	-- Old 12/6 10:51:35.342  PARTY_KILL,0x0300000000064F35,"Ratchet",0x511,0x0,0xF130388200000029,"Horde Battle Standard",0x2148,0x0
	-- 9/12 20:28:09.501  PARTY_KILL,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0,Player-9-0A43E636,"Liinx-Kil'jaeden",0x10548,0x0
	-- 7/21 01:23:16.879  PARTY_KILL,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0,Player-3676-09BED6E0,"Kruulmokthan-Area52",0x10548,0x0
	-- 7/21 01:23:16.879  SPELL_DAMAGE,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0,Player-3676-09BED6E0,"Kruulmokthan-Area52",0x10548,0x0,585,"Smite",0x2,0000000000000000,0000000000000000,0,0,0,0,0,-1,0,0,0,0.00,0.00,628,0.0000,0,930,969,249,2,0,0,0,nil,nil,nil
    -- 7/21 01:23:16.879  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3676-09BED6E0,"Kruulmokthan-Area52",0x10548,0x0
	self:CombatLogEventHandler(info,GetTime(),"PARTY_KILL",false,"Player-9-00064F35","Ratchet-Kil'jaeden",0x511,0x0,"Player-3676-09BED6E0","Test-Victim",0x10548,0x0)
	self:CombatLogEventHandler(info,GetTime(),"SPELL_DAMAGE",false,"Player-9-00064F35","Ratchet-Kil'jaeden",0x511,0x0,"Player-3676-09BED6E0","Test-Victim",0x10548,0x0,585,"Smite",0x2,0000000000000000,0000000000000000,0,0,0,0,0,-1,0,0,0,0.00,0.00,628,0.0000,0,930,969,249,2,0,0,0,nil,nil,nil)
	self:CombatLogEventHandler(info,GetTime(),"UNIT_DIED",false,0000000000000000,nil,0x80000000,0x80000000,"Player-3676-09BED6E0","Test-Victim",0x10548,0x0)
end

function ltks:TestPlayerDeath()
	-- Example from combat log
	-- Old 12/6 10:50:47.727  RANGE_DAMAGE,0x0300000006B14637,"Kumonu-Ner'zhul",0x10548,0x0,0x0300000000064F35,"Ratchet",0x511,0x0,75,"Auto Shot",0x1,10990,-1,1,0,0,0,nil,nil,nil
	-- Old 12/6 10:50:48.308  UNIT_DIED,0x0000000000000000,nil,0x80000000,0x80000000,0x0300000000064F35,"Ratchet",0x511,0x0
	-- 07202018 7/21 00:34:33.944  SPELL_PERIODIC_DAMAGE,Player-11-0A947E83,"Invictusgg-Tichondrius",0x548,0x0,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0,198097,"Creeping Venom",0x8,0000000000000000,0000000000000000,0,0,0,0,0,-1,0,0,0,0.00,0.00,92,0.0000,0,116,134,97,8,0,0,0,nil,nil,nil
	-- 07202018 7/21 00:34:33.944  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-9-00064F35,"Ratchet-Kil'jaeden",0x511,0x0
	self:Print("DEBUG: " .. "Sending Player Death Event...")
	self:CombatLogEventHandler(info,GetTime(),"RANGE_DAMAGE",false,0x030000000086920F,"KillerName",0x548,0x0,UnitGUID("player"),playerName,0x511,50622,"Auto Shot",0x1,10990,-1,1,0,0,0,nil,nil,nil)
	self:CombatLogEventHandler(info,GetTime(),"UNIT_DIED",false,0x0000000000000000,nil,0x80000000,0x80000000,UnitGUID("player"),playerName,0x511,0x0)
end
--@end-debug@]===]

if IsRetail() then
-- Combat state: resets the multikill chain and the killer tracker. Defined for
-- both clients so the "until out of combat" multikill window works everywhere.
function events:PLAYER_REGEN_DISABLED()
    -- Combat-mode chains reset at combat boundaries; timer-mode chains only
    -- care about the window, so leave them alone here.
    if (ltks.db.profile.mkwindow == "combat") then
        mkChain = false
        multikill = 0
    end
end

function events:PLAYER_REGEN_ENABLED()
    if (ltks.db.profile.mkwindow == "combat") then
        mkChain = false
        multikill = 0
    end
    wipe(myMinions)
    lastDamageSource = nil
    TryRegisterCLEU()
end

	local function ltks_DumpCurrentEntry(tag)
		if not (C_CombatLog and C_CombatLog.GetCurrentEntryInfo) then return end
		pcall(function()
			local n = select("#", C_CombatLog.GetCurrentEntryInfo())
			local dump = {}
			for i = 1, n do
				local v = select(i, C_CombatLog.GetCurrentEntryInfo())
				local ok, s = pcall(tostring, v)
				dump[i] = (ok and s) or "<secret>"
			end
			ltks:Print("[LTKS-CE-" .. tag .. "] n=" .. n .. " " .. table.concat(dump, "|"))
		end)
	end
	function events:PARTY_KILL(...)
		local dump = {}
		for i = 1, select("#", ...) do
			local ok, v = pcall(tostring, select(i, ...))
			dump[i] = (ok and v) or "<secret>"
		end
		ltks:Print("[LTKS-PKARGS] n=" .. select("#", ...) .. " " .. table.concat(dump, "|"))
		ltks_DumpCurrentEntry("PK")
		ltks:PartyKillHandler(...)
	end

	function events:UNIT_DIED(unitGUID)
		if issecretvalue and unitGUID and issecretvalue(unitGUID) then return end
		local ptOk, petTarget = pcall(UnitGUID, "pettarget")
		local ptStr = "?"
		if ptOk and petTarget then
			local sOk, s = pcall(tostring, petTarget)
			ptStr = (sOk and s) or "<secret>"
		end
		local match = false
		if ptOk and petTarget and unitGUID then
			local mOk, m = pcall(function() return petTarget == unitGUID end)
			match = mOk and m
		end
		local nmStr = "?"
		do
			local nOk, nm = pcall(GetNameFromGUID, unitGUID)
			if nOk and nm then
				local sOk, s = pcall(tostring, nm)
				nmStr = (sOk and s) or "<secret>"
			end
		end
		ltks:Print("[LTKS-UD] guid=" .. tostring(unitGUID) .. " pettarget=" .. ptStr .. " match=" .. tostring(match) .. " pending=" .. tostring(pendingKills[unitGUID] ~= nil) .. " name=" .. nmStr)
		local rec = pendingKills[unitGUID]
		if rec then
			pendingKills[unitGUID] = nil
			local name = deadNameCache[unitGUID] or knownNames[unitGUID] or GetNameFromGUID(unitGUID) or "Unknown"
			if unitGUID:sub(1, 6) == "Player" or ltks.db.profile.dopve then
				ltks:KillshotTX(name, rec.time)
			end
		end
	end

	-- J.A.R.V.I.S-style unit cache: nameplates/target/mouseover give a live
	-- guid -> name map of every visible unit, resolving PARTY_KILL victims that
	-- are neither our target nor focus (off-target pet kills).
	local function ltks_StoreUnitName(unit)
		if not unit then return end
		local guid, name = UnitGUID(unit), UnitName(unit)
		if guid and name and not (issecretvalue and (issecretvalue(guid) or issecretvalue(name))) then
			knownNames[guid] = name
			local c = 0
			for _ in pairs(knownNames) do c = c + 1 end
			if c > 100 then wipe(knownNames) end
		end
	end
	function events:NAME_PLATE_UNIT_ADDED(unit)
		ltks_StoreUnitName(unit)
	end
	function events:PLAYER_TARGET_CHANGED()
		ltks_StoreUnitName("target")
	end
	function events:UPDATE_MOUSEOVER_UNIT()
		ltks_StoreUnitName("mouseover")
	end

    function events:PLAYER_DEAD()
        ltks:PlayerDeadHandler()
    end

    -- Track the last source of damage against the player so deaths can name a
    -- killer. Midnight (12.0+) delivers secret payloads in restricted contexts
    -- (instanced PvP, dungeons, raids); those are skipped and the death falls
    -- back to "Unknown Entity" -- this is the last known damage source, not an
    -- authoritative killer.
    local cleuSeen = false
    function events:COMBAT_LOG_EVENT_UNFILTERED(...)
        if not cleuSeen then
            cleuSeen = true
            ltks:Print("[LTKS-CLEU] handler live")
        end
        -- Capture the full current combat log entry (standard fields + advanced
        -- payload) from the API itself, so owner-pair scanning never depends on
        -- how the event dispatcher forwards its arguments. Midnight moved the
        -- function to C_CombatLog; the legacy global only exists pre-12.0.
        local getCurrentEvent = C_CombatLog and C_CombatLog.GetCurrentEventInfo or CombatLogGetCurrentEventInfo
        local n = select("#", getCurrentEvent())
        local info = { getCurrentEvent() }
        local event = info[2]
        local sourceGUID, sourceName, sourceFlags, destGUID, destName = info[4], info[5], info[6], info[8], info[9]
        if issecretvalue then
            if (sourceGUID and issecretvalue(sourceGUID)) or (sourceName and issecretvalue(sourceName)) or (sourceFlags and issecretvalue(sourceFlags)) or (destGUID and issecretvalue(destGUID)) or (destName and issecretvalue(destName)) then return end
        end
        -- Any unit under our control that deals damage (pet, guardian, totem)
        -- can land the killing blow; remember it for PARTY_KILL attribution.
        local playerGuid = UnitGUID("player")
        if sourceGUID and sourceGUID ~= playerGuid and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0 then
            myMinions[sourceGUID] = true
        end
        -- Advanced-payload owner pairs (combatLogParser convention): a non-player
        -- actor directly followed by the player's GUID is one of our minions.
        for i = 12, n - 1 do
            local unitGuid, ownerGuid = info[i], info[i + 1]
            if type(unitGuid) == "string" and type(ownerGuid) == "string"
                and not (issecretvalue and (issecretvalue(unitGuid) or issecretvalue(ownerGuid)))
                and ownerGuid == playerGuid and unitGuid ~= playerGuid then
                myMinions[unitGuid] = true
            end
        end
        if event == "UNIT_DIED" then
            local dump = {}
            for i = 1, n do dump[i] = tostring(info[i]) end
            ltks:Print("[LTKS-DIE] src=" .. tostring(sourceGUID) .. " " .. tostring(sourceName) .. " flags=" .. tostring(sourceFlags) .. " dest=" .. tostring(destGUID) .. " payload=" .. table.concat(dump, "|"))
        end
        -- Remember every damaged/dying unit's name so PARTY_KILL can resolve
        -- victims that are not (or no longer) our target or focus.
        if destGUID and destName then
            deadNameCache[destGUID] = destName
            local c = 0
            for _ in pairs(deadNameCache) do c = c + 1 end
            if c > 60 then wipe(deadNameCache) end
        end
        if destGUID ~= UnitGUID("player") then return end
        if string.find(event, "_DAMAGE") then
            lastDamageSource = sourceName
        end
    end

else
	function events:COMBAT_LOG_EVENT_UNFILTERED(info, event, ...)
		local timestamp, event, hideCaster, sourceGUID, sourceName, sourceFlags, sourceFlags2, destGUID, destName, destFlags, destFlags2 = CombatLogGetCurrentEventInfo()
		ltks:CombatLogEventHandler(info, timestamp, event, hideCaster, sourceGUID, sourceName, sourceFlags, sourceFlags2, destGUID, destName, destFlags, destFlags2, ...)
	end
end

function events:ZONE_CHANGED_NEW_AREA(info, event, ...)
	TryRegisterCLEU()

	if (ltks.db.profile.dozonechange) then
		streak = 0
		deathstreak = 0
		ltks.db.profile.lastStreak = 0
	end

	-- Check for Arena and Battleground
	if IsActiveBattlefieldArena() ~=nil then inArena = true else inArena = false end
	if UnitInBattleground("player") ~= nil then inBG = true else inBG = false end

	--if (ltks.db.profile.dopreparesound) then
		--local junk
		--junk, inbg = IsInInstance()
		--if inbg == "pvp" or IsActiveBattlefieldArena() then
			--fixme ltks:ltks_SoundPack(ltks.db.profile.kssoundP)
		--end
	--end
end

function events:CHAT_MSG_BG_SYSTEM_NEUTRAL(msg, ...)
	-- Midnight (12.0+) delivers chat messages as secret strings in restricted
	-- contexts (dungeons, raids, PvP matches); they cannot be compared or parsed.
	if issecretvalue and issecretvalue(msg) then return end
	-- Prepare for Battleground
	if (ltks.db.profile.dopreparesound) then
		if msg == "The battle begins in 30 seconds!" then ltks:ltks_SoundPack(ltks.db.profile.kssoundP) end
	end
end

function events:CHAT_MSG_SYSTEM(msg, ...)
	-- Midnight (12.0+) delivers chat messages as secret strings in restricted
	-- contexts (dungeons, raids, PvP matches); they cannot be compared or parsed.
	if issecretvalue and issecretvalue(msg) then return end
	-- Prepare for Duel
	if (ltks.db.profile.dopreparesound) then
		if msg == format(DUEL_COUNTDOWN,3) then ltks:ltks_SoundPack(ltks.db.profile.kssoundP) end
	end
	-- Player fled from Duel
	if strmatch(msg, format(DUEL_WINNER_RETREAT, "(.-%--.-)", playerName)) then
		if ltks.db.profile.duelhumiliation then ltks:ltks_SoundPack(ltks.db.profile.kssoundH) end
		opponent = strmatch(msg, format(DUEL_WINNER_RETREAT, "(.-%--.-)", playerName))
		self:PlayerLoss(opponent)
	--fixme should probably create new msgs for duels in the future
	-- Opponent fled from Duel
	elseif strmatch(msg, format(DUEL_WINNER_RETREAT, playerName, "(.-%--.-)")) then
		opponent = strmatch(msg, format(DUEL_WINNER_RETREAT, playerName, "(.-%--.-)"))
		ltks:DuelTX(opponent,GetTime())
	-- Won Duel
	elseif strmatch(msg, format(DUEL_WINNER_KNOCKOUT, playerName, "(.-%--.-)")) then
		opponent = strmatch(msg, format(DUEL_WINNER_KNOCKOUT, playerName, "(.-%--.-)"))
		ltks:DuelTX(opponent,GetTime())
	-- Lost Duel
	elseif strmatch(msg, format(DUEL_WINNER_KNOCKOUT, "(.-%--.-)", playerName)) then
		opponent = strmatch(msg, format(DUEL_WINNER_KNOCKOUT, "(.-%--.-)", playerName))
		ltks:PlayerLoss(opponent,GetTime())
	else
		--[===[@debug@
		-- Dev Debugging functions
		--ltks:Print("DEBUG: " .. msg)
		--@end-debug@]===]
	end
end

function ltks:OnEnable()
	ltks:Print("[LTKS-LOAD] code version=" .. version .. " toc=12.1.6")
	--self:RegisterEvent("CHAT_MSG_ADDON", "AddonMessageHandler")
	--OnEvent runs the function events:event
	frame:SetScript("OnEvent", function(self, event, ...)
		events[event](self,...);
	end);
	--Regeister all events with function events:event
	for k, v in pairs(events) do
		-- CLEU is registered separately: Midnight forbids registering it while
		-- addon restrictions are active (ADDON_ACTION_FORBIDDEN)
		if k ~= "COMBAT_LOG_EVENT_UNFILTERED" or not IsRetail() then
			frame:RegisterEvent(k);
		end
	end
	TryRegisterCLEU()
	--self:SetSinkStorage(self.db.profile)
	--Check if this is ltks_classic, if so print warning and set path correctly
	streak = ltks.db.profile.lastStreak or 0
	deathstreak = 0
end
