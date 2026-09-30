-- Connected Discord-GitHub tonytonychopper41
-- Spawns the litter that covers the map.
-- many clicks it takes scales with how big it is: a crisp packet is one tap, a
-- dumped sofa is a proper click-spam fight. Progress is shown on the item and
-- decays if you wander off, so you cannot chip away at a sofa from three
-- streets over.
local Workspace = game.Workspace
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GameConfig = require(game.ReplicatedStorage.Modules.GameConfig)
local PlayerData = require(game.ServerScriptService.PlayerData)
local GamePassService = require(game.ServerScriptService.GamePassService)
local Remotes = game.ReplicatedStorage:WaitForChild("Remotes")

local ServerStorage = game:GetService("ServerStorage")

local GarbageFolder = Workspace:WaitForChild("GarbageFolder")
local TemplatesFolder = Workspace:FindFirstChild("Templates")
local BagTemplate = TemplatesFolder and TemplatesFolder:FindFirstChild("Tmpl_TrashBag")

local LIB = ServerStorage:WaitForChild("GarbageModels")
local POOLS = {
	Common    = LIB.Small,
	Uncommon  = LIB.Small,
	Rare      = LIB.Medium,
	Epic      = LIB.Big,
	Legendary = LIB.Big,
}

local SIZE_FOR_RARITY = {
	Common = "Small", Uncommon = "Small", Rare = "Medium", Epic = "Big", Legendary = "Big",
}

local function pickProp(rarityKey, zoneKey)
	local folder = POOLS[rarityKey] or LIB.Small
	-- each zone drops its own kinds of junk
	local zoneList = GameConfig.ZoneProps[zoneKey]
	local sizeKey = SIZE_FOR_RARITY[rarityKey] or "Small"
	if zoneList and zoneList[sizeKey] then
		local allowed = {}
		for _, name in ipairs(zoneList[sizeKey]) do
			local m = folder:FindFirstChild(name)
			if m then table.insert(allowed, m) end
		end
		if #allowed > 0 then return allowed[math.random(1, #allowed)] end
	end
	local options = folder:GetChildren()
	if #options == 0 then return nil end
	return options[math.random(1, #options)]
end

-- a light zone wash so litter matches its surroundings
local function tintModel(model, zoneKey)
	local t = GameConfig.ZoneLitterTint[zoneKey]
	if not t then return end
	local c, k = t.color, t.strength or 0.2
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.9 then
			d.Color = d.Color:Lerp(c, k)
		end
	end
end

-- the biggest visible part, so click detectors land on something you can hit
local function biggestPart(model)
	local best, bestVol = nil, -1
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.9 then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then best, bestVol = d, v end
		end
	end
	return best or model.PrimaryPart
end

local ActiveFolder = Workspace:FindFirstChild("ActiveGarbage")
if not ActiveFolder then
	ActiveFolder = Instance.new("Folder")
	ActiveFolder.Name = "ActiveGarbage"
	ActiveFolder.Parent = Workspace
end

local RARITY_SCALE = {
	Common = 0.9, Uncommon = 1.05, Rare = 1.15, Epic = 1.0, Legendary = 1.25,
}

local function isBigRarity(rarity)
	return rarity.Key == "Epic" or rarity.Key == "Legendary"
end

-- Centralised bob animation: ONE Heartbeat connection drives every active item,
-- split into round-robin buckets so only a third of them move per frame.
local animated = {}
local frameCounter = 0
local BUCKETS = 3

local ANIM_DIST = GameConfig.AnimateDistance or 220
local ANIM_DIST_SQ = ANIM_DIST * ANIM_DIST
local playerPositions = {}

task.spawn(function()
	while true do
		local list = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then table.insert(list, hrp.Position) end
		end
		playerPositions = list
		task.wait(0.4)
	end
end)

local function nearAnyone(pos)
	for _, p in ipairs(playerPositions) do
		local dx, dz = pos.X - p.X, pos.Z - p.Z
		if dx * dx + dz * dz <= ANIM_DIST_SQ then return true end
	end
	return false
end

RunService.Heartbeat:Connect(function()
	frameCounter = (frameCounter + 1) % BUCKETS
	local now = os.clock()
	for model, info in pairs(animated) do
		if model.Parent then
			if info.bucket == frameCounter and nearAnyone(info.basePos) then
				local t = now + info.phase
				-- no vertical bob: litter stays flat on the ground, it only turns
				model:PivotTo(CFrame.new(info.basePos) * CFrame.Angles(0, t * 0.35, 0))
			end
		else
			animated[model] = nil
		end
	end
end)

local function pickRarity(zoneKey)
	local mods = GameConfig.ZoneRarityWeights[zoneKey]
	local total = 0
	for _, r in ipairs(GameConfig.Rarities) do
		total += r.Weight * ((mods and mods[r.Key]) or 1)
	end
	local roll = math.random() * total
	local cum = 0
	for _, r in ipairs(GameConfig.Rarities) do
		cum += r.Weight * ((mods and mods[r.Key]) or 1)
		if roll <= cum then return r end
	end
	return GameConfig.Rarities[1]
end

-- everything a garbage prop must NOT land on top of
local GROUND_IGNORE = {}
task.spawn(function()
	while true do
		local list = {}
		for _, n in ipairs({"ActiveGarbage", "GarbageFolder", "Workers", "QuestNPCs", "QuestSkins", "LiveEvents"}) do
			local inst = workspace:FindFirstChild(n)
			if inst then table.insert(list, inst) end
		end
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character then table.insert(list, plr.Character) end
		end
		GROUND_IGNORE = list
		task.wait(3)
	end
end)

local function prepModel(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = true
			d.CastShadow = false
			-- MUST be true or the mouse ray goes straight through the prop and
			-- the ClickDetector never fires.
			d.CanQuery = true
		end
	end
end
-- collecting
local CollectedEvent = game.ServerScriptService:WaitForChild("GarbageCollected")

local function giveToPlayer(player, model, rarity, value, xp, payMultiplier)
	local data = player:FindFirstChild("Data")
	if not data then return false end
	if data.Carried.Value >= PlayerData.GetCapacity(player) then
		Remotes.Popup:FireClient(player, {kind = "error", text = "Backpack full - go sell!"})
		return false
	end
	model:SetAttribute("Claimed", true)
	local payout = math.max(1, math.floor(value * (payMultiplier or 1)))
	data.Carried.Value += 1
	data.CarriedValue.Value += payout
	local cw = data:FindFirstChild("CarriedWeight")
	if cw then
		cw.Value += model:GetAttribute("Weight") or 1
		PlayerData.RecomputeWalkSpeed(player)
	end
	PlayerData.AddXP(player, xp)
	Remotes.PlaySfx:FireClient(player, "pickup")
	local zoneKey = model:GetAttribute("ZoneKey")
	local pos = model:GetPivot().Position
	local wasBig = model:GetAttribute("Big") and true or false
	animated[model] = nil
	model:Destroy()
	-- rarity and size ride along so quest givers can ask for specific finds
	CollectedEvent:Fire(player, zoneKey, pos, rarity.Key, wasBig, payout)
	-- a popup for every single wrapper would bury the screen; only real finds
	if rarity.Key == "Epic" or rarity.Key == "Legendary" then
		Remotes.Popup:FireClient(player, {
			kind = "bigpickup",
			text = rarity.Name .. " +$" .. payout,
			color = {rarity.Color.R, rarity.Color.G, rarity.Color.B},
		})
	end
	return true
end

-- exposed so the AutoCollect / AutoClicker passes can reuse the same path
local Collect = {}
Collect.Give = giveToPlayer
_G.GarbageCollect = Collect

local function spawnGarbageAt(spawnPoint, zoneKey)
	local rarity = pickRarity(zoneKey)
	local zoneMult = GameConfig.ZoneValueMultiplier[zoneKey] or 1
	local xpMult = GameConfig.ZoneXPMultiplier[zoneKey] or 1
	local value = math.max(1, math.floor(rarity.Value * zoneMult))
	local xp = math.max(1, math.floor(rarity.XP * xpMult))

	local prop = pickProp(rarity.Key, zoneKey)
	local model = prop and prop:Clone() or BagTemplate:Clone()
	model.Name = "Garbage_"..rarity.Key
	model.Parent = ActiveFolder

	prepModel(model)
	tintModel(model, zoneKey)
	local scale = RARITY_SCALE[rarity.Key] or 1
	pcall(function() model:ScaleTo(scale) end)

	local big = isBigRarity(rarity)
	-- Sit it FLAT on whatever is underneath. Measure the prop, find the real
	-- surface with a downward ray, then drop the model so its own underside
	-- touches that surface - no hovering and no half-buried props, whatever
	-- the prop's size or the ground's height.
	local yaw = CFrame.Angles(0, math.random() * 6.28, 0)
	model:PivotTo(CFrame.new(spawnPoint.Position) * yaw)
	local bcf0, bsz0 = model:GetBoundingBox()
	local pivotY = model:GetPivot().Position.Y
	local bottomOffset = pivotY - (bcf0.Y - bsz0.Y / 2)   -- pivot height above the prop's base

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = GROUND_IGNORE
	rp.IgnoreWater = true
	local from = Vector3.new(spawnPoint.Position.X, spawnPoint.Position.Y + 12, spawnPoint.Position.Z)
	local hit = workspace:Raycast(from, Vector3.new(0, -60, 0), rp)
	local surfaceY = hit and hit.Position.Y or (spawnPoint.Position.Y - 1.2)

	local basePos = Vector3.new(spawnPoint.Position.X, surfaceY + bottomOffset, spawnPoint.Position.Z)
	model:PivotTo(CFrame.new(basePos) * yaw)

	local sizeClass = big and "Big" or (rarity.Key == "Rare" and "Medium" or "Small")
	local needed = GameConfig.ClicksToCollect[sizeClass] or 1
	local payMult = big and GameConfig.BigGarbageBonus or 1

	model:SetAttribute("Rarity", rarity.Key)
	model:SetAttribute("RarityName", rarity.Name)
	model:SetAttribute("Value", value)
	model:SetAttribute("XP", xp)
	model:SetAttribute("ZoneKey", zoneKey)
	model:SetAttribute("SizeClass", sizeClass)
	model:SetAttribute("Weight", GameConfig.ItemWeight[sizeClass] or 1)
	model:SetAttribute("ClicksNeeded", needed)
	model:SetAttribute("Clicks", 0)
	model:SetAttribute("PayMultiplier", payMult)
	if big then model:SetAttribute("Big", true) end

	----------------------------------------------------------------
	-- click to collect
	----------------------------------------------------------------
	local anchor = biggestPart(model)
	if anchor then
		local bcf, bsz = model:GetBoundingBox()
		local hit = Instance.new("Part")
		hit.Name = "Hitbox"
		hit.Size = Vector3.new(math.max(bsz.X, 6), math.max(bsz.Y, 6), math.max(bsz.Z, 6))
		hit.CFrame = bcf
		hit.Transparency = 1
		hit.Anchored = true
		hit.CanCollide = false
		hit.CanTouch = false
		hit.CanQuery = true
		hit.CastShadow = false
		hit.Parent = model
		anchor = hit

		local click = Instance.new("ClickDetector")
		click.Name = "Pickup"
		click.MaxActivationDistance = GameConfig.ClickRange
		click.CursorIcon = "rbxasset://textures/GunCursor.png"
		click.Parent = anchor

		local lbl
		if needed > 1 then
			local tag = Instance.new("BillboardGui")
			tag.Name = "Tag"
			tag.Size = UDim2.new(0, 130, 0, 34)
			tag.StudsOffset = Vector3.new(0, big and 5 or 3, 0)
			tag.MaxDistance = GameConfig.ClickRange + 12
			tag.AlwaysOnTop = true
			tag.Parent = anchor

			lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(1, 0, 1, 0)
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.GothamBlack
			lbl.TextScaled = true
			lbl.TextStrokeTransparency = 0.15
			lbl.TextColor3 = rarity.Color
			lbl.Text = "CLICK 0/" .. needed
			lbl.Parent = tag
		end

		local lastClick = 0

		click.MouseClick:Connect(function(player)
			if not model.Parent then return end
			if model:GetAttribute("Claimed") then return end
			if not PlayerData.IsReady(player) then return end

			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local data = player:FindFirstChild("Data")
			if not hrp or not data then return end

			if (model:GetPivot().Position - hrp.Position).Magnitude > GameConfig.ClickRange + 6 then
				Remotes.Popup:FireClient(player, {kind = "error", text = "Too far - get closer!"})
				return
			end
			if data.Carried.Value >= PlayerData.GetCapacity(player) then
				Remotes.Popup:FireClient(player, {kind = "error", text = "Backpack full - go sell!"})
				return
			end

			local now = os.clock()
			local progress = model:GetAttribute("Clicks") or 0
			-- stop chipping away at something you walked away from
			if now - lastClick > GameConfig.ClickDecayTime then progress = 0 end
			lastClick = now

			progress += PlayerData.GetClickPower(player)
			model:SetAttribute("Clicks", progress)

			if progress >= needed then
				giveToPlayer(player, model, rarity, value, xp, payMult)
			else
				if lbl then lbl.Text = "CLICK " .. progress .. "/" .. needed end
				-- a little shake so the click feels like it landed
				local pivot = model:GetPivot()
				model:PivotTo(pivot * CFrame.Angles(0, math.rad(12), 0))
			end
		end)
	end

	if rarity.Announce then
		local a = biggestPart(model)
		if a then
			if rarity.Key == "Legendary" then
				local light = Instance.new("PointLight")
				light.Color = rarity.Color
				light.Range = 11
				light.Brightness = 1.1
				light.Shadows = false
				light.Parent = a
			end
			local sparkle = Instance.new("Sparkles")
			sparkle.SparkleColor = rarity.Color
			sparkle.Parent = a
		end
		local zoneCfg = GameConfig.Zones[zoneKey]
		PlayerData.AnnounceAll({
			kind = "raregarbage",
			rarity = rarity.Name,
			zone = zoneCfg and zoneCfg.DisplayName or zoneKey,
			value = value,
			color = {rarity.Color.R, rarity.Color.G, rarity.Color.B},
		})
	end

	-- nothing bobs any more: litter lies where it was dropped

	return model
end

local MAX_ACTIVE_GARBAGE = GameConfig.MaxActiveGarbage or 900
local activeCount = 0

local function spawnLoop(spawnPoint, zoneKey)
	task.wait(math.random() * 4)
	while true do
		while activeCount >= MAX_ACTIVE_GARBAGE do
			task.wait(0.5 + math.random() * 0.5)
		end
		local model = spawnGarbageAt(spawnPoint, zoneKey)
		activeCount += 1
		while model and model.Parent do
			task.wait(0.5)
		end
		activeCount -= 1
		animated[model] = nil
		local baseDelay = GameConfig.GarbageRespawnDelay[zoneKey] or 20
		local jitter = GameConfig.GarbageRespawnJitter or 0
		local waitTime = baseDelay * (1 + (math.random() * 2 - 1) * jitter)
		task.wait(math.max(0.1, waitTime))
	end
end

local startedPoints = {}
local function trySpawnLoopFor(sp)
	if startedPoints[sp] then return end
	if not sp:IsA("BasePart") then return end
	local zoneKey = sp:GetAttribute("ZoneKey")
	if zoneKey and GameConfig.Zones[zoneKey] then
		startedPoints[sp] = true
		task.spawn(spawnLoop, sp, zoneKey)
	end
end

for _, sp in ipairs(GarbageFolder:GetChildren()) do
	trySpawnLoopFor(sp)
end
GarbageFolder.ChildAdded:Connect(trySpawnLoopFor)

print("[GarbageSpawner] click-to-collect active, spawn points: "..#GarbageFolder:GetChildren())
