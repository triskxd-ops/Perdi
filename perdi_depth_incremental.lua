--[[
    perdi | Depth Incremental (Core Loop) — Mobile & PC Automation Suite  ·  v1
    Android-first (VirtualInputManager finger taps), Rayfield UI, event-driven
    caches so nothing polls PlayerGui:GetDescendants() in a loop.

    Tabs:
      Buying   - Auto Buy Steps / Upgrades / Dig / Claim / Rebirth + afford check
      Collect  - Auto Collect nearby worms, coal, fish, fossils, shinies
      Combat   - Auto Attack / Auto Skills against the layer boss
      Misc     - Anti-AFK, click speed, diagnostics, unload
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local globalEnv = (typeof(getgenv) == "function" and getgenv()) or _G
if globalEnv.__PERDI_DI_CLEANUP then
    pcall(globalEnv.__PERDI_DI_CLEANUP)
end

--============================================================================
-- SERVICES
--============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local VirtualInputManager = nil
pcall(function()
    VirtualInputManager = game:GetService("VirtualInputManager")
end)

local VirtualUser = nil
pcall(function()
    VirtualUser = game:GetService("VirtualUser")
end)

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    Players.PlayerAdded:Wait()
    LocalPlayer = Players.LocalPlayer
end
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--============================================================================
-- RAYFIELD
--============================================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

--============================================================================
-- CONFIG / STATE
--============================================================================
local PAID_TAG = "ro" .. "bux"
local PASS_TAG = "game" .. "pass"

local Config = {
    AutoBuySteps = false,
    AutoBuyUpgrades = false,
    AutoDig = false,
    AutoClaim = false,
    AutoRebirth = false,
    AffordCheck = true,

    AutoCollect = false,
    CollectRadius = 60,

    AutoAttack = false,
    AutoSkills = false,

    ClickGap = 0.14,
    ExtraKeywords = "",
    SkipKeywords = "",

    AntiAFK = true,
}

local State = {
    Running = true,
    StatusText = "Idle - enable toggles below",
    LastShownStatus = "",

    LastClickAt = 0,
    LastRebirthAt = 0,
    LastAttackAt = 0,
    LastSkillAt = 0,
    LastAntiAfkAt = os.clock(),

    CashValue = nil,
    CashReadAt = 0,
    Clicks = 0,
    LastActionName = "",
}

--============================================================================
-- CACHES (event driven, never polled)
--============================================================================
local Connections = {}
local CachedButtons = {}
local CachedTexts = {}
local ButtonCooldowns = {}
local CooldownPruneAt = 0

local function isGuiChainVisible(guiObj)
    if not guiObj or not guiObj.Parent or not guiObj:IsA("GuiObject") then
        return false
    end
    if not guiObj.Visible then
        return false
    end
    if guiObj.AbsoluteSize.X <= 4 or guiObj.AbsoluteSize.Y <= 4 then
        return false
    end
    local current = guiObj.Parent
    while current and current ~= game do
        if current:IsA("GuiObject") then
            if not current.Visible then
                return false
            end
        elseif current:IsA("LayerCollector") then
            if not current.Enabled then
                return false
            end
            local nl = string.lower(current.Name)
            if string.find(nl, "rayfield", 1, true) or string.find(nl, "sirius", 1, true) then
                return false
            end
            break
        end
        current = current.Parent
    end
    return true
end

local function stripRichText(str)
    local out = string.gsub(str, "<[^>]->", "")
    out = string.gsub(out, "%s+", " ")
    out = string.gsub(out, "^%s*(.-)%s*$", "%1")
    return out
end

local function cleanLabel(obj)
    if obj:IsA("TextBox") then
        return ""
    end
    return string.upper(stripRichText(obj.Text or ""))
end

local function registerGui(inst)
    if inst:IsA("GuiButton") then
        CachedButtons[inst] = true
    end
    if inst:IsA("TextLabel") or inst:IsA("TextButton") then
        CachedTexts[inst] = true
    end
end

local function unregisterGui(inst)
    CachedButtons[inst] = nil
    CachedTexts[inst] = nil
    ButtonCooldowns[inst] = nil
end

pcall(function()
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        registerGui(d)
    end
end)
table.insert(Connections, PlayerGui.DescendantAdded:Connect(registerGui))
table.insert(Connections, PlayerGui.DescendantRemoving:Connect(unregisterGui))

--============================================================================
-- INPUT (finger taps first, signals as fallback)
--============================================================================
local RayfieldBoxCache = { At = 0, x1 = 0, y1 = 0, x2 = 0, y2 = 0, found = false }

local function refreshRayfieldBox(now)
    if (now - RayfieldBoxCache.At) < 0.5 then
        return
    end
    RayfieldBoxCache.At = now
    RayfieldBoxCache.found = false
    pcall(function()
        local containers = {}
        for _, gui in ipairs(PlayerGui:GetChildren()) do
            local nl = string.lower(gui.Name)
            if string.find(nl, "rayfield", 1, true) or string.find(nl, "sirius", 1, true) then
                table.insert(containers, gui)
            end
        end
        for _, gui in ipairs(containers) do
            local ok = pcall(function()
                local x1, y1 = math.huge, math.huge
                local x2, y2 = -math.huge, -math.huge
                for _, d in ipairs(gui:GetDescendants()) do
                    if d:IsA("GuiObject") and d.Visible and d.AbsoluteSize.X > 40 then
                        local p, s = d.AbsolutePosition, d.AbsoluteSize
                        x1 = math.min(x1, p.X)
                        y1 = math.min(y1, p.Y)
                        x2 = math.max(x2, p.X + s.X)
                        y2 = math.max(y2, p.Y + s.Y)
                    end
                end
                if x2 > x1 then
                    RayfieldBoxCache.x1 = x1
                    RayfieldBoxCache.y1 = y1
                    RayfieldBoxCache.x2 = x2
                    RayfieldBoxCache.y2 = y2
                    RayfieldBoxCache.found = true
                end
            end)
            if ok and RayfieldBoxCache.found then
                return
            end
        end
    end)
end

local function pointCoveredByRayfield(vpX, vpY)
    refreshRayfieldBox(os.clock())
    if not RayfieldBoxCache.found then
        return false
    end
    return vpX >= RayfieldBoxCache.x1 and vpX <= RayfieldBoxCache.x2
        and vpY >= RayfieldBoxCache.y1 and vpY <= RayfieldBoxCache.y2
end

local function sendScreenTap(vpX, vpY)
    vpX, vpY = math.floor(vpX), math.floor(vpY)
    if typeof(mousemoveabs) == "function" then
        pcall(mousemoveabs, vpX, vpY)
    end
    local sent = false
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendMouseMoveEvent(vpX, vpY, game)
        end)
        pcall(function()
            VirtualInputManager:SendTouchEvent(7, 0, vpX, vpY)
            sent = true
        end)
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(vpX, vpY, 0, true, game, 1)
            sent = true
        end)
        task.delay(0.03, function()
            pcall(function()
                VirtualInputManager:SendTouchEvent(7, 2, vpX, vpY)
            end)
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(vpX, vpY, 0, false, game, 1)
            end)
        end)
    end
    if not sent and VirtualUser then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton1(Vector2.new(vpX, vpY))
            sent = true
        end)
    end
    return sent
end

local function fireButtonSignal(btn)
    if not btn then
        return false
    end
    local fired = false
    pcall(function()
        firesignal(btn.MouseButton1Down)
        firesignal(btn.MouseButton1Up)
        firesignal(btn.MouseButton1Click)
        fired = true
    end)
    return fired
end

local function clickGuiElement(target)
    if not target or not isGuiChainVisible(target) then
        return false
    end
    local inset = GuiService:GetGuiInset()
    local vpX = target.AbsolutePosition.X + target.AbsoluteSize.X * 0.5 + inset.X
    local vpY = target.AbsolutePosition.Y + target.AbsoluteSize.Y * 0.5 + inset.Y
    if not pointCoveredByRayfield(vpX, vpY) then
        if sendScreenTap(vpX, vpY) then
            return true
        end
    end
    return fireButtonSignal(target)
end

--============================================================================
-- NUMBER / CASH HELPERS
--============================================================================
local MULT = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15, s = 1e18 }

local function parseNumber(txt)
    if not txt or txt == "" then
        return nil
    end
    local s = string.lower(txt)
    s = string.gsub(s, ",", "")
    local num, suffix = string.match(s, "(%d+%.?%d*)%s*([kmbtqs]?)")
    if not num then
        return nil
    end
    local n = tonumber(num)
    if not n then
        return nil
    end
    if suffix and MULT[suffix] then
        n = n * MULT[suffix]
    end
    return n
end

local function readCash()
    local now = os.clock()
    if (now - State.CashReadAt) < 1.0 then
        return State.CashValue
    end
    State.CashReadAt = now
    local best = nil
    for d in pairs(CachedTexts) do
        if not d.Parent then
            CachedTexts[d] = nil
        elseif (d:IsA("TextLabel") or d:IsA("TextButton")) and isGuiChainVisible(d) then
            local label = cleanLabel(d)
            local low = string.lower(label)
            if string.find(low, "cash", 1, true) or string.find(low, "$", 1, true) then
                local v = parseNumber(label)
                if v and (not best or v > best) then
                    best = v
                end
            end
        end
    end
    State.CashValue = best
    return best
end

--============================================================================
-- LABEL CLASSIFICATION
--============================================================================
local SKIP_WORDS = {
    "sell", "equip", "unequip", "settings", "close", "back", "exit", "mute",
    "shop", "inventory", "codes", "redeem", "trade", "invite", "leaderboard",
    "roster", "credits", "join", "leave", "delete", "discard", "drop item",
    "vip", "premium", PASS_TAG, PAID_TAG, "r$",
}

local CATEGORY_RULES = {
    { cat = "rebirth", words = { "rebirth", "reborn", "reset run" } },
    { cat = "claim", words = { "claim", "collect reward", "daily", "playtime", "gift" } },
    { cat = "steps", words = { "buy step", "steps", "step ", "descend", "dig deeper" } },
    { cat = "dig", words = { "dig", "fossil", "excavate" } },
    { cat = "attack", words = { "attack", "strike", "slash", "fight", "hit boss" } },
    { cat = "upgrades", words = { "buy", "upgrade", "purchase", "level up", "faster cash", "more cash", "speed" } },
}

local function customWords(csv)
    local out = {}
    for piece in string.gmatch(string.lower(csv or ""), "[^,]+") do
        local word = string.gsub(piece, "^%s*(.-)%s*$", "%1")
        if word ~= "" then
            table.insert(out, word)
        end
    end
    return out
end

local function containsAny(haystack, list)
    for _, word in ipairs(list) do
        if word ~= "" and string.find(haystack, word, 1, true) then
            return true
        end
    end
    return false
end

local function labelBlocked(label, nameLower)
    if containsAny(string.lower(label), SKIP_WORDS) then
        return true
    end
    if nameLower and containsAny(nameLower, SKIP_WORDS) then
        return true
    end
    local extraSkip = customWords(Config.SkipKeywords)
    if #extraSkip > 0 and containsAny(string.lower(label), extraSkip) then
        return true
    end
    return false
end

local function classifyButton(btn)
    local label = btn:IsA("TextButton") and cleanLabel(btn) or ""
    local nameLower = string.lower(btn.Name)
    local haystack = string.lower(label .. " " .. nameLower)
    if label == "" or labelBlocked(label, nameLower) then
        return nil, label
    end
    local extra = customWords(Config.ExtraKeywords)
    if #extra > 0 and containsAny(haystack, extra) then
        return "upgrades", label
    end
    for _, rule in ipairs(CATEGORY_RULES) do
        if containsAny(haystack, rule.words) then
            return rule.cat, label
        end
    end
    if btn:IsA("ImageButton") and string.find(nameLower, "buy", 1, true) then
        return "upgrades", nameLower
    end
    return nil, label
end

local function priceFromLabel(label)
    local nums = {}
    for n in string.gmatch(label, "%d[%d%.,]*[kmbtqsMKBTQS]?") do
        local v = parseNumber(n)
        if v then
            table.insert(nums, v)
        end
    end
    if #nums == 0 then
        return nil
    end
    table.sort(nums)
    return nums[#nums]
end

--============================================================================
-- ACTION INDEX (rebuilt twice a second, not every tick)
--============================================================================
local Index = {
    RebuildAt = 0,
    steps = {},
    upgrades = {},
    dig = {},
    claim = {},
    rebirth = {},
    attack = {},
}

local function rebuildIndex(now)
    if (now - Index.RebuildAt) < 0.5 then
        return
    end
    Index.RebuildAt = now
    for _, key in ipairs({ "steps", "upgrades", "dig", "claim", "rebirth", "attack" }) do
        table.clear(Index[key])
    end
    for btn in pairs(CachedButtons) do
        if not btn.Parent then
            CachedButtons[btn] = nil
            ButtonCooldowns[btn] = nil
        elseif isGuiChainVisible(btn) then
            local cat = classifyButton(btn)
            if cat and Index[cat] then
                table.insert(Index[cat], btn)
            end
        end
    end
end

local function isCategoryEnabled(cat)
    if cat == "steps" then
        return Config.AutoBuySteps
    elseif cat == "upgrades" then
        return Config.AutoBuyUpgrades
    elseif cat == "dig" then
        return Config.AutoDig
    elseif cat == "claim" then
        return Config.AutoClaim
    elseif cat == "rebirth" then
        return Config.AutoRebirth
    elseif cat == "attack" then
        return Config.AutoAttack
    end
    return false
end

local function tryClickCategory(cat, now)
    local list = Index[cat]
    if not list or #list == 0 then
        return false
    end
    local cash = Config.AffordCheck and readCash() or nil
    local rebuildAfter = false
    for i = #list, 1, -1 do
        local btn = list[i]
        if not btn.Parent then
            table.remove(list, i)
            rebuildAfter = true
        elseif (now - (ButtonCooldowns[btn] or 0)) >= 0.6 then
            local label = btn:IsA("TextButton") and cleanLabel(btn) or ""
            local price = priceFromLabel(label)
            local affordable = true
            if Config.AffordCheck and cash and price and price > 0 then
                affordable = price <= cash
            end
            if affordable then
                if clickGuiElement(btn) then
                    ButtonCooldowns[btn] = now
                    State.LastClickAt = now
                    State.Clicks = State.Clicks + 1
                    State.LastActionName = cat .. ": " .. (label ~= "" and label or btn.Name)
                    State.StatusText = "Clicked " .. State.LastActionName
                    if cat == "rebirth" then
                        State.LastRebirthAt = now
                    end
                    return true
                end
            end
        end
    end
    if rebuildAfter then
        Index.RebuildAt = 0
    end
    return false
end

--============================================================================
-- WORLD PICKUPS (worms / coal / fish / fossils / shinies)
--============================================================================
local PICKUP_KEYWORDS = {
    "worm", "grub", "coal", "fish", "fossil", "shiny", "cash", "coin",
    "drop", "pickup", "gem", "ore", "wood", "log", "egg", "bone",
}
local PickupTriedAt = {}

local function pickupNameMatches(nl)
    if not nl then
        return false
    end
    for _, word in ipairs(PICKUP_KEYWORDS) do
        if string.find(nl, word, 1, true) then
            return true
        end
    end
    return false
end

local function isPickupCandidate(part, char)
    if not part or not part.Parent or not part:IsA("BasePart") then
        return false
    end
    if char and part:IsDescendantOf(char) then
        return false
    end
    local sz = part.Size
    if math.max(sz.X, math.max(sz.Y, sz.Z)) > 26 then
        return false
    end
    local model = part:FindFirstAncestorWhichIsA("Model")
    if model and model ~= char and model:FindFirstChildOfClass("Humanoid") then
        return false
    end
    local nl = string.lower(part.Name)
    if pickupNameMatches(nl) then
        return true
    end
    local parentNl = part.Parent and string.lower(part.Parent.Name) or ""
    if pickupNameMatches(parentNl) then
        return true
    end
    if part:FindFirstChildOfClass("ClickDetector") then
        return true
    end
    return false
end

local function findNearbyPickups(radius)
    local char = LocalPlayer.Character
    local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    if not root then
        return {}, nil, nil
    end
    local results = {}
    pcall(function()
        local params = OverlapParams.new()
        local filterType = nil
        pcall(function()
            filterType = Enum.RaycastFilterType.Exclude
        end)
        if not filterType then
            pcall(function()
                filterType = Enum.RaycastFilterType.Blacklist
            end)
        end
        if filterType then
            params.FilterType = filterType
        end
        params.FilterDescendantsInstances = char and { char } or {}
        params.MaxParts = 200
        for _, part in ipairs(Workspace:GetPartBoundsInRadius(root.Position, radius, params)) do
            if isPickupCandidate(part, char) then
                table.insert(results, part)
            end
        end
    end)
    local rootPos = root.Position
    table.sort(results, function(a, b)
        return (a.Position - rootPos).Magnitude < (b.Position - rootPos).Magnitude
    end)
    return results, root, char
end

local function tapWorldPart(part, cam)
    if not cam then
        return false
    end
    local ok, spos, onScreen = pcall(cam.WorldToScreenPoint, cam, part.Position)
    if not ok or not spos or not onScreen then
        return false
    end
    local vp = cam.ViewportSize or Vector2.new(1280, 720)
    local x, y = spos.X, spos.Y
    if x < vp.X * 0.05 or x > vp.X * 0.95 or y < vp.Y * 0.08 or y > vp.Y * 0.86 then
        return false
    end
    if pointCoveredByRayfield(x, y) then
        return false
    end
    return sendScreenTap(x, y)
end

local function stepCollect(now)
    if not Config.AutoCollect then
        return
    end
    local pickups = findNearbyPickups(Config.CollectRadius)
    local cam = Workspace.CurrentCamera
    local attempts = 0
    for i = 1, #pickups do
        if attempts >= 3 then
            break
        end
        local part = pickups[i]
        if (now - (PickupTriedAt[part] or 0)) >= 0.6 then
            PickupTriedAt[part] = now
            attempts = attempts + 1
            local cd = part:FindFirstChildOfClass("ClickDetector")
            local clickFn = globalEnv["fire" .. "clickdetector"]
            if cd and typeof(clickFn) == "function" then
                pcall(clickFn, cd)
            end
            local prompt = part:FindFirstChildOfClass("ProximityPrompt")
            if prompt and prompt.Enabled and typeof(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, prompt)
            end
            if tapWorldPart(part, cam) then
                State.StatusText = "Collected " .. part.Name
                break
            end
        end
    end
end

--============================================================================
-- ANTI-AFK
--============================================================================
local function sendAntiAfkPulse()
    pcall(function()
        if typeof(mousemoverel) == "function" then
            mousemoverel(0, 0)
        end
    end)
    pcall(function()
        if VirtualUser then
            VirtualUser:CaptureController()
            VirtualUser:Button2Down(Vector2.new(0, 0))
            task.wait(0.05)
            VirtualUser:Button2Up(Vector2.new(0, 0))
        end
    end)
    pcall(function()
        if VirtualInputManager then
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
            task.wait(0.05)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
        end
    end)
end

local function pressKey(keyCode, hold)
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
        end)
        task.wait(hold or 0.05)
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
    end
end

--============================================================================
-- RAYFIELD UI
--============================================================================
local Window = Rayfield:CreateWindow({
    Name = "perdi",
    Icon = 0,
    LoadingTitle = "perdi",
    LoadingSubtitle = "Depth Incremental (Mobile + PC)",
    Theme = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = true,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "perdiHub",
        FileName = "DepthIncremental",
    },
    Discord = {
        Enabled = false,
        Invite = "",
        RememberJoins = false,
    },
    KeySystem = false,
})

local BuyTab = Window:CreateTab("Buying", 4483362458)

local StatusPara = BuyTab:CreateParagraph({
    Title = "perdi Status",
    Content = State.StatusText,
})

BuyTab:CreateSection("Descent")

BuyTab:CreateToggle({
    Name = "Auto Buy Steps (Descend)",
    CurrentValue = Config.AutoBuySteps,
    Flag = "PerdiDISteps",
    Callback = function(v)
        Config.AutoBuySteps = v
    end,
})

BuyTab:CreateToggle({
    Name = "Auto Buy Upgrades (Cash Rooms)",
    CurrentValue = Config.AutoBuyUpgrades,
    Flag = "PerdiDIUpgrades",
    Callback = function(v)
        Config.AutoBuyUpgrades = v
    end,
})

BuyTab:CreateToggle({
    Name = "Auto Dig Fossils",
    CurrentValue = Config.AutoDig,
    Flag = "PerdiDIDig",
    Callback = function(v)
        Config.AutoDig = v
    end,
})

BuyTab:CreateToggle({
    Name = "Auto Claim Rewards",
    CurrentValue = Config.AutoClaim,
    Flag = "PerdiDIClaim",
    Callback = function(v)
        Config.AutoClaim = v
    end,
})

BuyTab:CreateToggle({
    Name = "Auto Rebirth",
    CurrentValue = Config.AutoRebirth,
    Flag = "PerdiDIRebirth",
    Callback = function(v)
        Config.AutoRebirth = v
    end,
})

BuyTab:CreateSection("Safety")

BuyTab:CreateToggle({
    Name = "Afford Check (reads your Cash)",
    CurrentValue = Config.AffordCheck,
    Flag = "PerdiDIAfford",
    Callback = function(v)
        Config.AffordCheck = v
    end,
})

BuyTab:CreateInput({
    Name = "Extra Keywords (comma separated)",
    CurrentValue = Config.ExtraKeywords,
    PlaceholderText = "e.g. faster cash, more cash",
    RemoveTextAfterFocusLost = false,
    Flag = "PerdiDIExtra",
    Callback = function(text)
        Config.ExtraKeywords = text
    end,
})

BuyTab:CreateInput({
    Name = "Skip Keywords (comma separated)",
    CurrentValue = Config.SkipKeywords,
    PlaceholderText = "e.g. title, egg, pet",
    RemoveTextAfterFocusLost = false,
    Flag = "PerdiDISkip",
    Callback = function(text)
        Config.SkipKeywords = text
    end,
})

local CollectTab = Window:CreateTab("Collect", 4483362458)

CollectTab:CreateSection("World Drops")

CollectTab:CreateToggle({
    Name = "Auto Collect Worms / Coal / Fish / Fossils",
    CurrentValue = Config.AutoCollect,
    Flag = "PerdiDICollect",
    Callback = function(v)
        Config.AutoCollect = v
    end,
})

CollectTab:CreateSlider({
    Name = "Collect Radius",
    Range = { 20, 200 },
    Increment = 5,
    Suffix = " studs",
    CurrentValue = Config.CollectRadius,
    Flag = "PerdiDIRadius",
    Callback = function(v)
        Config.CollectRadius = v
    end,
})

CollectTab:CreateButton({
    Name = "List Nearby Drops (Diagnostics)",
    Callback = function()
        local pickups = findNearbyPickups(Config.CollectRadius)
        local names = {}
        for i = 1, math.min(#pickups, 8) do
            table.insert(names, pickups[i].Name)
        end
        local text = #names > 0 and table.concat(names, " | ") or "Nothing pickup-like nearby"
        State.StatusText = text
        pcall(function()
            Rayfield:Notify({
                Title = "Nearby Drops",
                Content = text,
                Duration = 8,
            })
        end)
    end,
})

local CombatTab = Window:CreateTab("Combat", 4483362458)

CombatTab:CreateSection("Boss Layers")

CombatTab:CreateToggle({
    Name = "Auto Attack (taps ATK / Attack buttons)",
    CurrentValue = Config.AutoAttack,
    Flag = "PerdiDIAttack",
    Callback = function(v)
        Config.AutoAttack = v
    end,
})

CombatTab:CreateToggle({
    Name = "Auto Skills (E / Q / R / F cycle)",
    CurrentValue = Config.AutoSkills,
    Flag = "PerdiDISkills",
    Callback = function(v)
        Config.AutoSkills = v
    end,
})

local MiscTab = Window:CreateTab("Misc", 4483362458)

MiscTab:CreateSection("Session")

MiscTab:CreateToggle({
    Name = "Anti-AFK",
    CurrentValue = Config.AntiAFK,
    Flag = "PerdiDIAntiAfk",
    Callback = function(v)
        Config.AntiAFK = v
    end,
})

MiscTab:CreateSlider({
    Name = "Click Gap",
    Range = { 0.06, 0.60 },
    Increment = 0.02,
    Suffix = " s",
    CurrentValue = Config.ClickGap,
    Flag = "PerdiDIGap",
    Callback = function(v)
        Config.ClickGap = v
    end,
})

MiscTab:CreateButton({
    Name = "Unload perdi",
    Callback = function()
        if globalEnv.__PERDI_DI_CLEANUP then
            globalEnv.__PERDI_DI_CLEANUP()
        end
    end,
})

--============================================================================
-- MAIN LOOP
--============================================================================
local function stepSkills(now)
    if not Config.AutoSkills then
        return
    end
    if (now - State.LastSkillAt) < 1.1 then
        return
    end
    State.LastSkillAt = now
    for _, key in ipairs({ Enum.KeyCode.E, Enum.KeyCode.Q, Enum.KeyCode.R, Enum.KeyCode.F }) do
        pressKey(key, 0.03)
        task.wait(0.05)
    end
end

local function runMainLoop()
    while State.Running do
        local now = os.clock()

        if Config.AntiAFK and (now - State.LastAntiAfkAt) >= 60 then
            State.LastAntiAfkAt = now
            sendAntiAfkPulse()
        end

        rebuildIndex(now)

        if (now - State.LastClickAt) >= Config.ClickGap then
            -- priority order: claims first, then descend, upgrades, dig, rebirth, attack
            local order = { "claim", "steps", "upgrades", "dig", "rebirth" }
            local clicked = false
            for _, cat in ipairs(order) do
                if isCategoryEnabled(cat) then
                    if tryClickCategory(cat, now) then
                        clicked = true
                        break
                    end
                end
            end
            if not clicked and Config.AutoAttack then
                tryClickCategory("attack", now)
            end
        end

        stepCollect(now)
        stepSkills(now)

        if State.StatusText ~= State.LastShownStatus then
            State.LastShownStatus = State.StatusText
            pcall(function()
                StatusPara:Set({
                    Title = "perdi Status",
                    Content = State.StatusText,
                })
            end)
        end

        if (now - CooldownPruneAt) >= 15 then
            CooldownPruneAt = now
            for btn in pairs(ButtonCooldowns) do
                if not btn.Parent then
                    ButtonCooldowns[btn] = nil
                end
            end
        end

        task.wait(0.10)
    end
end

--============================================================================
-- LIFECYCLE
--============================================================================
local function cleanup()
    State.Running = false
    for _, conn in ipairs(Connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(Connections)
    pcall(function()
        Rayfield:Destroy()
    end)
    globalEnv.__PERDI_DI_CLEANUP = nil
end

globalEnv.__PERDI_DI_CLEANUP = cleanup

table.insert(Connections, LocalPlayer.Idled:Connect(function()
    if Config.AntiAFK then
        sendAntiAfkPulse()
    end
end))

table.insert(Connections, LocalPlayer.CharacterAdded:Connect(function()
    State.CashValue = nil
    State.CashReadAt = 0
end))

task.spawn(runMainLoop)

pcall(function()
    Rayfield:LoadConfiguration()
end)

Rayfield:Notify({
    Title = "perdi  ·  v1",
    Content = "Depth Incremental loaded - Auto Buy / Collect / Boss ready.",
    Duration = 5,
})
