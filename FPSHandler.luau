-- FPS Handler Script
-- // SERVICES //
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- // MODULE IMPORT //
local FPSModule = require(ReplicatedStorage.FPSModule)

-- // CONFIGURATION //
local Config = {
	ServerAvgFPS = 0,					-- Server average FPS value
	PlayersQueue = {},					-- List to save players in queue for validation
	ValidationInterval = 6,				-- Time between validation checks
	MinFPSThreshold = 45,				-- Default minimum FPS threshold (dynamically adjusted)
	MinReportsBase = 10,				-- Base minimum reports needed
	ReportsSubtraction = 10,			-- Reports reduction based on player count
	LastSpamReportTimestamp = tick(),	-- Timestamp of last spam report for dynamic threshold
	LogWebhookAPI = "https://webhook.lewisakura.moe/api/webhooks/Webhook_Token/queue"
}

-- // REMOTE INSTANCES //
local ValidateSuspiciousPlayer = ReplicatedStorage:WaitForChild("ValidateSuspiciousPlayer") 
local UpdateAverageFPS = ReplicatedStorage:WaitForChild("UpdateAverage")

-- // LOGGING FUNCTIONS //
-- Log players with fake/altered FPS
local function LogExploiter(Player, FPS)
	FPSModule.LogWarning("Exploiter detected: %s (%d) with FPS %d", Player.Name, Player.UserId, FPS)

	local embed = FPSModule.BuildBaseEmbed(Player, "**__Fake/Altered FPS detected.__**")
	FPSModule.AddEmbedField(embed, "Reason:", ("Roblox does not allow these FPS: %d"):format(FPS))

	FPSModule.SendDiscordEmbed(Config.LogWebhookAPI, embed)
end

-- Log players causing server lag/crashes
local function LogLagSpammer(Accused, Reporters, ServerAvgFPS)
	FPSModule.LogWarning("Possible lag/crash: %s (%d) | AvgFPS: %.2f", Accused.Name, Accused.UserId, ServerAvgFPS)

	local top5Reports = FPSModule.GetTopLowFPSReports(Reporters, 5)

	local thumbUrl = FPSModule.FetchAvatarImageUrl(Accused.UserId)

	local embed = FPSModule.BuildBaseEmbed(Accused, "**__Player crashing!__**")
	FPSModule.AddEmbedField(embed, "Reason:", ("Server average FPS: %.2f"):format(ServerAvgFPS), false)
	FPSModule.AddEmbedField(embed, "Top 5 lowest FPS:", table.concat(top5Reports, "\n"), true)
	FPSModule.AddEmbedThumbnail(embed, thumbUrl)

	if not thumbUrl then
		FPSModule.LogWarning("No thumbnail URL (sending embed without thumbnail)")
	end

	FPSModule.LogInfo("Sending lag spammer embed to Discord")
	FPSModule.SendDiscordEmbed(Config.LogWebhookAPI, embed)
end

-- // REMOTE HANDLERS //
UpdateAverageFPS.OnServerInvoke = function(player) -- Just because (?)
	return true
end

ValidateSuspiciousPlayer.OnServerEvent:Connect(function(player, accused, fps)
	
	FPSModule.LogEvent("EVENT", "%s reported %s with FPS=%d", player.Name, accused and accused.Name or "nil", fps)

	Config.LastSpamReportTimestamp = tick()

	if not FPSModule.ValidatePlayer(accused) then 
		FPSModule.LogWarning("Invalid report: accused is not a Player")
		return 
	end

	if fps <= 0 or fps > 250 then
		--LogExploiter(player, fps)
		--player:Kick("Invalid data. Avoid using exploits or fflags.")
		-- Disabled because a lot of players use FFlags
		return
	end

	local processedFPS = FPSModule.ProcessFPSValue(fps, player.Name)
	if not processedFPS then
		return
	end
	fps = processedFPS

	local userId = accused.UserId

	if not Config.PlayersQueue[userId] then
		FPSModule.LogInfo("Initializing queue for %s (%d)", accused.Name, accused.UserId)
		Config.PlayersQueue[userId] = {
			Accused = accused,
			Reports = {}
		}
	end

	local reportData = Config.PlayersQueue[userId]
	local existingReport
	for _, report in ipairs(reportData.Reports) do
		if report.Reporter == player then
			existingReport = report
			break
		end
	end

	if existingReport then
		FPSModule.LogInfo("Report updated: %s -> %s with FPS=%d", player.Name, accused.Name, fps)
		existingReport.FPS = fps
	else
		FPSModule.LogInfo("New report: %s -> %s with FPS=%d", player.Name, accused.Name, fps)
		table.insert(reportData.Reports, {
			Reporter = player,
			FPS = fps
		})
	end
end)

-- // VALIDATION TASK //
task.spawn(function()
	while task.wait(Config.ValidationInterval) do
		local currentPlayers = #Players:GetPlayers()
		local minReports = FPSModule.CalculateMinReports(currentPlayers, Config.MinReportsBase, Config.ReportsSubtraction)

		for userId, data in pairs(Config.PlayersQueue) do
			FPSModule.LogEvent("TASK", "Validating accused: %s (%d) with %d reports", data.Accused.Name, userId, #data.Reports)

			if #data.Reports >= minReports then
				local accused = data.Accused
				local validReporters = {}

				for _, report in ipairs(data.Reports) do
					FPSModule.LogEvent("REPORT", "%s -> %s FPS=%d", report.Reporter.Name, accused.Name, report.FPS)
					table.insert(validReporters, {Reporter = report.Reporter, FPS = report.FPS})
				end

				if #validReporters > 0 then
					local avgFPS = FPSModule.CalculateAverageFPS(validReporters)
					FPSModule.LogEvent("TASK", "Average FPS for %s: %.2f with %d reports", accused.Name, avgFPS, #validReporters)

					if avgFPS < Config.MinFPSThreshold then
						FPSModule.LogWarning("%s flagged as lagger (avgFPS=%.2f)", accused.Name, avgFPS)
						LogLagSpammer(accused, validReporters, avgFPS)

						if accused and accused.Character then
							local removedCount = FPSModule.RemoveAllAccessories(accused.Character)
							if removedCount > 0 then
								FPSModule.LogEvent("ACTION", "Removed %d accessories from %s", removedCount, accused.Name)
							end
						end
					end
				end
			else
				FPSModule.LogWarning("%s (%d) skipped, not enough reports (%d/%d)", data.Accused.Name, userId, #data.Reports, minReports)
			end
			Config.PlayersQueue[userId] = nil
		end
	end
end)

-- // DYNAMIC THRESHOLD ADJUSTMENT TASK //
task.spawn(function()
	while task.wait(5) do
		local currentTime = tick()

		if currentTime - Config.LastSpamReportTimestamp >= 5 then
			local allPlayers = Players:GetPlayers()

			if #allPlayers > 0 then
				local validFPSValues = {}
				local requestStartTime = tick()
				local timeoutSeconds = 2

				FPSModule.LogEvent("FPS_UPDATE", "Requesting FPS from %d clients simultaneously...", #allPlayers)

				local clientResponses = {}
				local completedClients = 0

				for _, player in ipairs(allPlayers) do
					local playerId = player.UserId
					clientResponses[playerId] = {
						player = player,
						completed = false,
						success = false,
						fps = nil
					}

					task.spawn(function()
						local success, clientFPS = pcall(function()
							return UpdateAverageFPS:InvokeClient(player)
						end)

						if not clientResponses[playerId].completed then
							clientResponses[playerId].success = success
							clientResponses[playerId].fps = clientFPS
							clientResponses[playerId].completed = true
							completedClients = completedClients + 1
						end
					end)
				end

				local waitStartTime = tick()
				while completedClients < #allPlayers and (tick() - waitStartTime) < timeoutSeconds do
					task.wait(0.1)
				end

				for playerId, data in pairs(clientResponses) do
					if not data.completed then
						data.completed = true
						FPSModule.LogWarning("Timeout for player: %s", data.player.Name)
					end
				end

				local successfulResponses = 0
				for playerId, data in pairs(clientResponses) do
					if data.success and data.fps then
						local processedFPS = FPSModule.ProcessFPSValue(data.fps, data.player.Name)
						if processedFPS then
							table.insert(validFPSValues, processedFPS)
							successfulResponses = successfulResponses + 1
						end
					end
				end

				local requestDuration = tick() - requestStartTime
				FPSModule.LogEvent("FPS_UPDATE", "FPS collection completed in %.2f seconds. Valid responses: %d/%d", requestDuration, successfulResponses, #allPlayers)

				if #validFPSValues > 0 then
					local averageFPS = 0
					local totalFPS = 0
					for _, fps in ipairs(validFPSValues) do
						totalFPS = totalFPS + fps
					end
					averageFPS = totalFPS / #validFPSValues

					local newThreshold = FPSModule.CalculateDynamicThreshold(averageFPS, 15, 20)

					if newThreshold ~= Config.MinFPSThreshold then
						FPSModule.LogEvent("FPS_UPDATE", "Threshold updated from %d to %d (avg: %.2f)", Config.MinFPSThreshold, newThreshold, averageFPS)
						Config.MinFPSThreshold = math.max(newThreshold, 20)
					end
				else
					FPSModule.LogWarning("No valid FPS responses received, keeping current threshold")
				end
			end
		end
	end
end)
