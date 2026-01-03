-- FPSClient LocalScript
-- // SERVICES //
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- // MODULE IMPORT //
local FPSModule = require(ReplicatedStorage.FPSModule)

-- // INSTANCES //
local ValidateSuspiciousPlayer = ReplicatedStorage:WaitForChild("ValidateSuspiciousPlayer")
local UpdateAverageFPS = ReplicatedStorage:WaitForChild("UpdateAverage")
local player = Players.LocalPlayer

-- // VARIABLES //
local temporalIgnorePlayers = {}
local locallyHiddenAccessories = {}

-- Configuration values
local Config = {
	MaxEquips = 4,              -- Number of equips/unequips within a short window to trigger suspicious detection
	ToolCounterTime = 2,        -- Time window (seconds) for counting equips/unequips
	ClientFPS = 60,             -- Default FPS value (updated dynamically)
	FPSMeasureWindow = 0.25,    -- Time window (seconds) to measure FPS
	CooldownTime = 5,           -- Old cooldown logic (now handled differently)
	
	SmallServerThreshold = 10,   -- Max players for local protection to activate
	LowFPSThreshold = 40,       -- FPS threshold for considering spam + low FPS dangerous
	MacroDetectionTime = 0.01  -- Maximum time between equips to consider it macro abuse
}

local macroDetection = {}
local FrameUpdateTable = {}

-- // FPS MONITORING //
local function HeartbeatUpdate()
	local now = FPSModule.GetCurrentTime()
	FPSModule.CleanOldEntries(FrameUpdateTable, Config.FPSMeasureWindow, now)
	table.insert(FrameUpdateTable, now)
	Config.ClientFPS = math.floor(#FrameUpdateTable / Config.FPSMeasureWindow)
end

RunService.Heartbeat:Connect(HeartbeatUpdate)

-- // LOCAL PROTECTION FUNCTIONS //
local function LocallyHideAccessories(accusedPlayer)
	local userId = accusedPlayer.UserId
	local character = accusedPlayer.Character

	if not character then
		FPSModule.LogWarning("Character not found for %s", accusedPlayer.Name)
		return
	end

	if locallyHiddenAccessories[userId] then
		FPSModule.LogInfo("Accessories already hidden for %s", accusedPlayer.Name)
		return
	end

	if not FPSModule.HasAccessories(character) then
		FPSModule.LogInfo("No accessories found on %s", accusedPlayer.Name)
		return
	end

	local hiddenCount = FPSModule.RemoveAllAccessories(character)

	if hiddenCount > 0 then
		locallyHiddenAccessories[userId] = true
		FPSModule.LogWarning("Hidden %d accessories from %s locally", hiddenCount, accusedPlayer.Name)
	end
end

local function ShouldActivateLocalProtection()
	local currentPlayers = #Players:GetPlayers()
	return currentPlayers <= Config.SmallServerThreshold
end

local function DetectMacroAbuse(accusedPlayer, currentTime)
	local userId = accusedPlayer.UserId

	if not macroDetection[userId] then
		macroDetection[userId] = {
			lastEquipTime = currentTime,
			isMacroDetected = false
		}
		return false
	end

	local timeDifference = currentTime - macroDetection[userId].lastEquipTime
	macroDetection[userId].lastEquipTime = currentTime

	if FPSModule.DetectMacroTiming(timeDifference, Config.MacroDetectionTime) then
		if not macroDetection[userId].isMacroDetected then
			macroDetection[userId].isMacroDetected = true
			FPSModule.LogWarning("Detected macro abuse from %s | Time between equips: %f", accusedPlayer.Name, timeDifference)
			return true
		end
	end

	return macroDetection[userId].isMacroDetected
end

-- // REMOTE FUNCTION HANDLER //
UpdateAverageFPS.OnClientInvoke = function()
	local processedFPS = FPSModule.ProcessFPSValue(Config.ClientFPS)
	return processedFPS
end

-- // CHARACTER MONITORING //
local function MonitorPlayerCharacter(plrChar)
	local EquipmentLogs = {}
	FPSModule.LogEvent("Monitor", "Started monitoring character for player: %s", plrChar.Name)

	local function RegisterEquip()
		local now = FPSModule.GetCurrentTime()
		local accusedPlayer = FPSModule.GetPlayerFromCharacter(plrChar)
		if not accusedPlayer then
			FPSModule.LogWarning("Failed to resolve player from character: %s", plrChar.Name)
			return
		end

		local userId = accusedPlayer.UserId
		local isMacroAbuse = DetectMacroAbuse(accusedPlayer, now)
		FPSModule.CleanOldEntries(EquipmentLogs, Config.ToolCounterTime, now)
		table.insert(EquipmentLogs, now)

		if #EquipmentLogs >= Config.MaxEquips then
			local currentFps = Config.ClientFPS
			if ShouldActivateLocalProtection() then
				local shouldApplyLocalProtection = false
				local reason = ""

				if currentFps < Config.LowFPSThreshold then
					shouldApplyLocalProtection = true
					reason = "spam + low FPS (" .. currentFps .. ")"
				end

				if isMacroAbuse then
					shouldApplyLocalProtection = true
					reason = reason == "" and "macro abuse detected" or (reason .. " + macro abuse")
				end

				if shouldApplyLocalProtection then
					FPSModule.LogWarning("Activating local protection for %s | Reason: %s | Players: %d", accusedPlayer.Name, reason, #Players:GetPlayers())
					LocallyHideAccessories(accusedPlayer)
				end
			end

			if not temporalIgnorePlayers[userId] then
				FPSModule.LogWarning("Player %s exceeded equip threshold.", accusedPlayer.Name)
				temporalIgnorePlayers[userId] = currentFps
				FPSModule.LogEvent("Report", "Sent report for player: %s | FPS: %d", accusedPlayer.Name, currentFps)
				ValidateSuspiciousPlayer:FireServer(accusedPlayer, currentFps)
			else
				local storedFps = temporalIgnorePlayers[userId]
				if currentFps < storedFps then
					temporalIgnorePlayers[userId] = currentFps
					FPSModule.LogEvent("Report Update", "Player: %s | FPS dropped from %d to %d", accusedPlayer.Name, storedFps, currentFps)
					ValidateSuspiciousPlayer:FireServer(accusedPlayer, currentFps)
				else
					FPSModule.LogEvent("Cooldown", "Player: %s already reported. FPS not lower, skipping.", accusedPlayer.Name)
				end
			end
			table.clear(EquipmentLogs)
		end
	end

	plrChar.ChildAdded:Connect(function(Tool)
		if FPSModule.ToolHasHandle(Tool) and FPSModule.HasAccessories(plrChar) then
			RegisterEquip()
		end
	end)

	plrChar.ChildRemoved:Connect(function(Tool)
		if FPSModule.ToolHasHandle(Tool) and FPSModule.HasAccessories(plrChar) then
			RegisterEquip()
		end
	end)
end

-- // MAIN EXECUTION //
Players.PlayerAdded:Connect(function(plr)
	FPSModule.LogEvent("Player Join", "Player joined: %s", plr.Name)
	local plrChar = plr.Character or plr.CharacterAdded:Wait()
	MonitorPlayerCharacter(plrChar)

	plr.CharacterAdded:Connect(function(char)
		FPSModule.LogEvent("Respawn", "Character respawned for player: %s", plr.Name)
		MonitorPlayerCharacter(char)
		FPSModule.CleanupPlayerData(plr.UserId, locallyHiddenAccessories, macroDetection)
	end)
end)

for _, plr in Players:GetPlayers() do
	FPSModule.LogEvent("Startup", "Monitoring existing player: %s", plr.Name)
	local plrChar = plr.Character or plr.CharacterAdded:Wait()
	MonitorPlayerCharacter(plrChar)

	plr.CharacterAdded:Connect(function(char)
		FPSModule.LogEvent("Respawn", "Character respawned for player: %s", plr.Name)
		MonitorPlayerCharacter(char)
		FPSModule.CleanupPlayerData(plr.UserId, locallyHiddenAccessories, macroDetection)
	end)
end

Players.PlayerRemoving:Connect(function(plr)
	FPSModule.CleanupPlayerData(plr.UserId, locallyHiddenAccessories, macroDetection, temporalIgnorePlayers)
	FPSModule.LogEvent("Cleanup", "Cleaned up data for leaving player: %s", plr.Name)
end)

-- // MAINTENANCE TASKS //
task.spawn(function()
	while task.wait(Config.CooldownTime) do
		table.clear(temporalIgnorePlayers)
		local currentTime = FPSModule.GetCurrentTime()
		FPSModule.CleanupOldData(macroDetection, currentTime, Config.CooldownTime * 2)
	end
end)

-- Status monitoring loop for debugging
-- I know you want clear console so you can disable it in Module :)
task.spawn(function()
	if not FPSModule.InDebugMode() then return end
	while task.wait(10) do
		local currentPlayers = #Players:GetPlayers()
		local localProtectionActive = ShouldActivateLocalProtection()

		FPSModule.LogEvent("Status", "Players: %d | Local Protection: %s | Current FPS: %d", 
			currentPlayers, 
			localProtectionActive and "ACTIVE" or "INACTIVE", 
			Config.ClientFPS
		)

		local protectedCount = 0
		for userId, isHidden in pairs(locallyHiddenAccessories) do
			if isHidden then
				protectedCount = protectedCount + 1
			end
		end

		if protectedCount > 0 then
			FPSModule.LogEvent("Status", "Locally protected players: %d", protectedCount)
		end
	end
end)
