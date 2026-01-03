-- FPSModule ModuleScript
-- Special thanks to claude for doing this module because i am to lazy to modularizing code
-- Also for the comments, because I am lazy for that too :)

local FPSUtilities = {}

-- // SERVICES & UTILS //
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Config = {
	Debugging = true, -- for print debugging
}

local AccessoriesTypes = {
	Enum.AccessoryType.Hat,
	Enum.AccessoryType.Face,
	Enum.AccessoryType.Hair,
	Enum.AccessoryType.Front,
	Enum.AccessoryType.Waist,
	Enum.AccessoryType.Shoulder,
	Enum.AccessoryType.Neck,
	Enum.AccessoryType.Back,
}

-- // VALIDATION UTILITIES //
function FPSUtilities.ProcessFPSValue(fps, playerName)
	if fps <= 0 or fps > 250 then
		return nil
	end

	if fps > 60 then
		fps = 60
	elseif fps < 3 then
		return nil
	end

	return fps
end

function FPSUtilities.ValidatePlayer(player)
	return player and player:IsA("Player") and player.Parent
end

function FPSUtilities.InDebugMode()
	return Config.Debugging
end

function FPSUtilities.ToolHasHandle(tool)
	return tool and tool:IsA("Tool") and tool:FindFirstChild("Handle") ~= nil
end

-- // TIME UTILITIES //
function FPSUtilities.GetCurrentTime()
	return RunService:IsRunning() and time() or os.clock()
end

function FPSUtilities.TimestampToISO(timestamp)
	timestamp = timestamp or os.time()
	return os.date("!%Y-%m-%dT%H:%M:%S.000Z", timestamp)
end

-- // ARRAY UTILITIES //
function FPSUtilities.CleanOldEntries(array, timeWindow, currentTime)
	currentTime = currentTime or FPSUtilities.GetCurrentTime()

	for i = #array, 1, -1 do
		if currentTime - array[i] > timeWindow then
			table.remove(array, i)
		end
	end

	return array
end

function FPSUtilities.SortReportsByFPS(reports)
	table.sort(reports, function(a, b)
		return a.FPS < b.FPS
	end)
	return reports
end

function FPSUtilities.GetTopLowFPSReports(reports, count)
	count = count or 5
	local sortedReports = FPSUtilities.SortReportsByFPS(reports)
	local result = {}

	for i = 1, math.min(count, #sortedReports) do
		local r = sortedReports[i]
		table.insert(result, ("-# %s (%d) | %d"):format(
			r.Reporter.Name, 
			r.Reporter.UserId, 
			r.FPS
			))
	end

	return result
end

function FPSUtilities.CalculateAverageFPS(reports)
	if #reports == 0 then return 0 end

	local totalFPS = 0
	for _, report in ipairs(reports) do
		totalFPS = totalFPS + report.FPS
	end

	return totalFPS / #reports
end

-- // HTTP UTILITIES //
function FPSUtilities.BuildAvatarURL(userId, size)
	size = size or "420x420"
	return ("https://thumbnails.roproxy.com/v1/users/avatar?userIds=%d&size=%s&format=Png"):format(userId, size)
end

function FPSUtilities.FetchAvatarImageUrl(userId)
	local url = FPSUtilities.BuildAvatarURL(userId)

	local ok, body = pcall(function()
		return HttpService:GetAsync(url)
	end)

	if not ok then
		if Config.Debugging then
			warn(("[AVATAR_FETCH] Failed to fetch avatar thumbnail for %d: %s"):format(userId, tostring(body)))
		end
		return nil
	end

	local success, decoded = pcall(HttpService.JSONDecode, HttpService, body)
	if not success then
		if Config.Debugging then
			warn("[AVATAR_FETCH] Failed to decode JSON from thumbnail response")
		end
		return nil
	end

	local entry = decoded and decoded.data and decoded.data[1]
	if entry and entry.state == "Completed" and entry.imageUrl then
		return entry.imageUrl
	end
	
	if Config.Debugging then
		warn(("[AVATAR_FETCH] Thumbnail not ready for userId=%d"):format(userId))
	end
	return nil
end

function FPSUtilities.SendDiscordEmbed(webhookURL, embed)
	local success, result = pcall(function()
		return HttpService:PostAsync(webhookURL, HttpService:JSONEncode(embed))
	end)

	if not success then
		if Config.Debugging then
			warn("[DISCORD_WEBHOOK] Failed to send embed:", result)
		end
		
		return false
	end
	
	if Config.Debugging then
		print("[DISCORD_WEBHOOK] Embed sent successfully")
	end
	
	return true
end

-- // DISCORD EMBED BUILDERS //
function FPSUtilities.BuildBaseEmbed(player, title, color)
	return {
		embeds = {
			{
				author = {
					name = "Click me for view profile!",
					url = ("https://www.roblox.com/users/%d/profile"):format(player.UserId)
				},
				title = title,
				color = color or 15105570,
				fields = {
					{
						name = "Player Profile:",
						value = ("Username: %s (%d)\nAccount Age: %d days"):format(
							player.Name, 
							player.UserId, 
							player.AccountAge
						)
					},
					{
						name = "Server JobId:",
						value = game.JobId,
						inline = true
					},
					{
						name = "Server ID",
						value = game.JobId:split("-")[2],
						inline = true
					}
				},
				footer = { text = "Developed by System_Calix" },
				timestamp = FPSUtilities.TimestampToISO()
			}
		}
	}
end

function FPSUtilities.AddEmbedField(embed, name, value, inline)
	inline = inline or false
	table.insert(embed.embeds[1].fields, {
		name = name,
		value = value,
		inline = inline
	})
	return embed
end

function FPSUtilities.AddEmbedThumbnail(embed, thumbnailUrl)
	if thumbnailUrl then
		embed.embeds[1].thumbnail = { url = thumbnailUrl }
	end
	return embed
end

-- // PLAYER UTILITIES //
function FPSUtilities.GetPlayerFromCharacter(character)
	if not character or not character.Parent then return nil end
	return game.Players:GetPlayerFromCharacter(character)
end

function FPSUtilities.CountAccessories(character)
	if not character then return 0 end

	local count = 0
	for _, child in pairs(character:GetChildren()) do
		if child:IsA("Accessory") and not table.find(AccessoriesTypes, child.AccessoryType) then
			count = count + 1
		end
	end
	return count
end

function FPSUtilities.RemoveAllAccessories(character)
	if not character then return 0 end

	local removedCount = 0
	for _, accessory in pairs(character:GetChildren()) do
		if accessory:IsA("Accessory") and not table.find(AccessoriesTypes, accessory.AccessoryType) then
			accessory:Destroy()
			removedCount = removedCount + 1
		end
	end
	return removedCount
end

function FPSUtilities.HasAccessories(character)
	if not character then return false end

	for _, child in pairs(character:GetChildren()) do
		if child:IsA("Accessory") then
			return true
		end
	end
	return false
end

-- // CALCULATION UTILITIES //
function FPSUtilities.CalculateMinReports(playerCount, baseMin, subtraction)
	baseMin = baseMin or 5
	subtraction = subtraction or 5

	return (playerCount >= subtraction * 2) and (playerCount - subtraction) or baseMin
end

function FPSUtilities.CalculateDynamicThreshold(averageFPS, reduction, minimumThreshold)
	reduction = reduction or 15
	minimumThreshold = minimumThreshold or 20

	return math.max(minimumThreshold, math.floor(averageFPS - reduction))
end

function FPSUtilities.DetectMacroTiming(timeDifference, threshold)
	threshold = threshold or 0.01
	return timeDifference <= threshold and timeDifference > 0
end

-- // LOGGING UTILITIES //
function FPSUtilities.LogEvent(eventType, message, ...)
	if Config.Debugging then
		local prefix = ("[%s]"):format(eventType:upper())
		if Config.Debugging then
			print(prefix, message:format(...))
		end
	end
end

function FPSUtilities.LogWarning(message, ...)
	if Config.Debugging then
		warn(("[WARNING] %s"):format(message:format(...)))
	end
end

function FPSUtilities.LogInfo(message, ...)
	if Config.Debugging then
		print(("[INFO] %s"):format(message:format(...)))
	end
end

-- // DATA CLEANUP UTILITIES //
function FPSUtilities.CleanupPlayerData(userId, ...)
	local dataTables = {...}
	for _, dataTable in ipairs(dataTables) do
		if type(dataTable) == "table" and dataTable[userId] then
			dataTable[userId] = nil
		end
	end
end

function FPSUtilities.CleanupOldData(dataTable, currentTime, maxAge)
	for key, data in pairs(dataTable) do
		if type(data) == "table" and data.lastActivity then
			if currentTime - data.lastActivity > maxAge then
				dataTable[key] = nil
			end
		end
	end
end

return FPSUtilities
