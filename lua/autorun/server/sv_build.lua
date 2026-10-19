local CVAR_SERVER = FCVAR_ARCHIVE + FCVAR_NOTIFY
local CVAR_SHARED = FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED

CreateConVar("betterbuild_text", "Building", CVAR_SHARED, "The text that's gonna apear above the player")
CreateConVar("betterbuild_font", "DermaDefault", CVAR_SHARED, "Font")
CreateConVar("betterbuild_textcolor", "255, 165, 0", CVAR_SHARED, "The RGB color of the building text")
CreateConVar("betterbuild_enterBuildCommand", "!build", CVAR_SERVER, "The command to toggle build mode")
CreateConVar("betterbuild_enterLeaveCommand", "!pvp", CVAR_SERVER, "The command to leave build mode")
CreateConVar("betterbuild_chatCooldown", "5", CVAR_SERVER, "The chat commands cooldown")
CreateConVar("betterbuild_announceEnteringBuildMode", "true", CVAR_SERVER, "If the server should tell everyone who's entering build mode")
CreateConVar("betterbuild_announceEnterMessage", "{addonprefix} {player} has entered build mode!", CVAR_SERVER, "Entering notification message")
CreateConVar("betterbuild_announceEnterMessageColor", "255 255 255", CVAR_SERVER, "Color of the entering notification")
CreateConVar("betterbuild_announceExitingBuildMode", "true", CVAR_SERVER, "If the server should tell everyone who's leaving build mode")
CreateConVar("betterbuild_announceExitMessage", "{addonprefix} {player} has left build mode!", CVAR_SERVER, "Leaving notification message")
CreateConVar("betterbuild_announceExitMessageColor", "255 255 255", CVAR_SERVER, "Color of the exit notification")
CreateConVar("betterbuild_detectPVP", "true", CVAR_SERVER, "Only players not in combat can enter build mode")
CreateConVar("betterbuild_pvpCooldown", "60", CVAR_SERVER, "Time in seconds after combat before leaving PVP mode")
CreateConVar("betterbuild_pvpWarningMessage", "You can't join build mode while in combat!", CVAR_SHARED, "Warning shown when player tries to enter build while in combat")
CreateConVar("betterbuild_allowNoclipOutsideBuildMode", "false", CVAR_SERVER, "If false, players can only noclip while in build mode")
CreateConVar("betterbuild_allowNPCSpawn", "false", CVAR_SERVER, "If false, building players cannot spawn NPCs")
CreateConVar("betterbuild_blockNPCDamageInBuild", "true", CVAR_SERVER, "If NPCs owned by building players cannot deal damage")
CreateConVar("betterbuild_exitingBuildResultsinRespawn", "true", CVAR_SERVER, "If enabled, every player that leaves build mode will be respawned")


local addNetwork = util.AddNetworkString
local receive = net.Receive
local format = string.format

local BuildingPlayers = {}
local PvpPlayers = {}
local AllowedUserGroups = {
    superadmin = true,
    masteradmin = true,
    admin = true
}

addNetwork("BetterBuild_ChatMsg")
addNetwork("Betterbuild_enter")
addNetwork("BetterBuild_warning")
addNetwork("BetterBuild_SyncAll")

local function toBool(cvar)
    local val = cvar:GetString():lower()
    return val == "true" or val == "1"
end

local function parseColor(str)
    local r, g, b = string.match(str, "(%d+)%s*[, ]%s*(%d+)%s*[, ]%s*(%d+)")
    return Color(tonumber(r) or 255, tonumber(g) or 255, tonumber(b) or 255, 255)
end

local function isInBuild(steamID)
    return steamID and BuildingPlayers[steamID] == true
end

local function getEntityOwner(ent)
    if not IsValid(ent) then return nil end
    if ent.CPPIGetOwner then
        local o = ent:CPPIGetOwner()
        if IsValid(o) then return o end
    end
    if ent.FPPOwner then
        local o = Player(ent.FPPOwner)
        if IsValid(o) then return o end
    end
    local o = ent:GetOwner()
    if IsValid(o) then return o end
    if ent:IsVehicle() then
        local d = ent:GetDriver()
        if IsValid(d) then return d end
    end
    return nil
end

local function warning(ply)
    net.Start("BetterBuild_warning")
    net.WriteString(GetConVar("betterbuild_pvpWarningMessage"):GetString())
    net.Send(ply)
end

local function broadcastMsg(msgCvar, colorCvar, ply)
    local template = GetConVar(msgCvar):GetString()
    local msg = string.gsub(template, "{player}", ply:Nick())
    local showPrefix = string.find(msg, "{addonprefix}") ~= nil
    msg = string.Trim(string.gsub(msg, "{addonprefix}", ""))
    net.Start("BetterBuild_ChatMsg")
    net.WriteString(msg)
    net.WriteBool(showPrefix)
    net.WriteColor(parseColor(GetConVar(colorCvar):GetString()))
    net.Broadcast()
end

local function toggleBuildMode(ply)
    local steamID = ply:SteamID64()

    if PvpPlayers[steamID] then
        BuildSystem:print(format("%s is in combat, declining", ply:Nick()))
        warning(ply)
        return
    end

    if BuildingPlayers[steamID] then
        BuildSystem:print(format("Removed %s from buildmode", ply:Nick()))
        BuildingPlayers[steamID] = nil
        ply:SetNWBool("InBuildMode", false)
        ply:SetNoTarget(false)
        ply:SetMoveType(MOVETYPE_WALK)

        if toBool(GetConVar("betterbuild_exitingBuildResultsinRespawn"))
        and not ply:IsFrozen() then
            local spawn = hook.Run("PlayerSelectSpawn", ply)
            if not IsValid(spawn) then return end

            ply:SetPos(spawn:GetPos())
            ply:SetEyeAngles(Angle(0, spawn:GetAngles().y, 0))
        end

        if toBool(GetConVar("betterbuild_announceExitingBuildMode")) then
            broadcastMsg("betterbuild_announceExitMessage", "betterbuild_announceExitMessageColor", ply)
        end
        return
    end

    BuildSystem:print(format("Added %s to build mode", ply:Nick()))
    BuildingPlayers[steamID] = true
    ply:SetNWBool("InBuildMode", true)
    ply:SetNoTarget(true)
    if toBool(GetConVar("betterbuild_announceEnteringBuildMode")) then
        broadcastMsg("betterbuild_announceEnterMessage", "betterbuild_announceEnterMessageColor", ply)
    end
end

receive("Betterbuild_enter", function(len, ply)
    toggleBuildMode(ply)
end)

hook.Add("PlayerSpawnNPC", "BetterBuild.BlockNPCSpawn", function(ply, npcType)
    if not toBool(GetConVar("betterbuild_allowNPCSpawn")) and isInBuild(ply:SteamID64()) then
        ply:ChatPrint("[BetterBuild] NPC spawning is disabled in build mode.")
        return false
    end
end)

hook.Add("EntityTakeDamage", "BetterBuild.PreventDamage", function(target, dmg)
    if not IsValid(target) then return end

    local attacker = dmg:GetAttacker()
    local inflictor = dmg:GetInflictor()

    if target:IsPlayer() and isInBuild(target:SteamID64()) then
        dmg:SetDamage(0)
        return true
    end

    local targetOwner = getEntityOwner(target)

    if IsValid(targetOwner)
    and targetOwner:IsPlayer()
    and isInBuild(targetOwner:SteamID64()) then
        dmg:SetDamage(0)
        return true
    end

    if IsValid(attacker) then
        local buildPlayer

        if attacker:IsPlayer() then
            buildPlayer = attacker
        elseif attacker:IsVehicle() then
            buildPlayer = attacker:GetDriver()
        end

        if IsValid(buildPlayer)
        and isInBuild(buildPlayer:SteamID64()) then
            dmg:SetDamage(0)
            return true
        end

        if attacker:IsNPC()
        and toBool(GetConVar("betterbuild_blockNPCDamageInBuild")) then
            local owner = getEntityOwner(attacker)

            if IsValid(owner)
            and owner:IsPlayer()
            and isInBuild(owner:SteamID64()) then
                dmg:SetDamage(0)
                return true
            end
        end

        local owner = getEntityOwner(attacker)

        if IsValid(owner)
        and owner:IsPlayer()
        and isInBuild(owner:SteamID64()) then
            dmg:SetDamage(0)
            return true
        end
    end

    if IsValid(inflictor)
    and inflictor ~= attacker then
        local owner = getEntityOwner(inflictor)

        if IsValid(owner)
        and owner:IsPlayer()
        and isInBuild(owner:SteamID64()) then
            dmg:SetDamage(0)
            return true
        end
    end
end)

hook.Add("PlayerHurt", "BetterBuild.DetectPVP", function(victim, attacker)
    if not toBool(GetConVar("betterbuild_detectPVP")) then return end
    if not IsValid(victim) or not IsValid(attacker) then return end
    if not victim:IsPlayer() or not attacker:IsPlayer() then return end

    local pvpCooldown = GetConVar("betterbuild_pvpCooldown"):GetInt()
    local vid = victim:SteamID64()
    local aid = attacker:SteamID64()

    if BuildingPlayers[vid] or BuildingPlayers[aid] then return end

    PvpPlayers[vid] = true
    PvpPlayers[aid] = true

    timer.Create("PVP_COOLDOWN_" .. vid, pvpCooldown, 1, function() PvpPlayers[vid] = nil end)
    timer.Create("PVP_COOLDOWN_" .. aid, pvpCooldown, 1, function() PvpPlayers[aid] = nil end)
end)

hook.Add("NPC_ShouldIgnore", "BetterBuild.NPCIgnoreBuild", function(npc, ent)
    if IsValid(ent) and ent:IsPlayer() and isInBuild(ent:SteamID64()) then return true end
end)

hook.Add("PlayerNoClip", "BetterBuild.RestrictNoclip", function(ply, desiredState)
    if not IsValid(ply) then return false end

    if AllowedUserGroups[ply:GetUserGroup()] then return true end
    if toBool(GetConVar("betterbuild_allowNoclipOutsideBuildMode")) then return end
    if desiredState and not BuildingPlayers[ply:SteamID64()] then return false end
end)

hook.Add("PlayerDisconnected", "BetterBuild.Cleanup", function(ply)
    local id = ply:SteamID64()
    BuildingPlayers[id] = nil
    PvpPlayers[id] = nil
    timer.Remove("PVP_COOLDOWN_" .. id)
end)

hook.Add("PlayerDeath", "BetterBuild.RemovePvP", function(victim)
    if not IsValid(victim) then return end
    local id = victim:SteamID64()
    timer.Remove("PVP_COOLDOWN_" .. id)
    PvpPlayers[id] = nil
end)

local function normalizeCmd(str)
    return string.Trim(string.lower(str or ""))
end

local function canUseChatCommand(ply)
    local cd = GetConVar("betterbuild_chatCooldown"):GetFloat()
    if cd <= 0 then return true end
    ply._bbNextChatCmd = ply._bbNextChatCmd or 0
    if CurTime() < ply._bbNextChatCmd then return false end
    ply._bbNextChatCmd = CurTime() + cd
    return true
end

hook.Add("PlayerSay", "BetterBuild.ChatCommands", function(ply, text)
    local msg = normalizeCmd(text)
    local buildCmd = normalizeCmd(GetConVar("betterbuild_enterBuildCommand"):GetString())
    local leaveCmd = normalizeCmd(GetConVar("betterbuild_enterLeaveCommand"):GetString())
    if msg ~= buildCmd and msg ~= leaveCmd then return end
    if not canUseChatCommand(ply) then return "" end
    toggleBuildMode(ply)
    return ""
end)

local function sendConfig(ply)
    net.Start("BetterBuild_SyncAll")
    net.WriteString(GetConVar("betterbuild_text"):GetString())
    net.WriteString(GetConVar("betterbuild_font"):GetString())
    net.WriteColor(parseColor(GetConVar("betterbuild_textcolor"):GetString()))
    net.WriteString(GetConVar("betterbuild_pvpWarningMessage"):GetString())
    if ply then net.Send(ply) else net.Broadcast() end
end

hook.Add("PlayerInitialSpawn", "BetterBuild.SyncOnJoin", function(ply)
    timer.Simple(2, function() if IsValid(ply) then sendConfig(ply) end end)
end)

cvars.AddChangeCallback("betterbuild_text", function() sendConfig() end, "BB_Sync_Text")
cvars.AddChangeCallback("betterbuild_font", function() sendConfig() end, "BB_Sync_Font")
cvars.AddChangeCallback("betterbuild_textcolor", function() sendConfig() end, "BB_Sync_Color")
cvars.AddChangeCallback("betterbuild_pvpWarningMessage", function() sendConfig() end, "BB_Sync_Warning")
