--[[
    perdi | Dragon Arena (Vegle & Data 3) — Mobile & PC  ·  v3
    Remote-first: no simulated taps needed for the world prompts
    (Pull / Buy / Place / Open) or for the UI buttons once captured.

    How it works
      1) PROMPTS  - every ProximityPrompt is cached and fired with
                    fireproximityprompt (a real client->server call, not a tap).
      2) REMOTES  - the sniffer records the RemoteEvent calls the game itself
                    makes when you tap a UI button once. After that the script
                    replays that exact call on a loop with args intact.
      3) BREED    - drives the breed bar: press "Breed!" (or replay the captured
                    breed remote) and optionally pick the two parent cards.
      4) TAPS     - optional last-resort fallback, off by default.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local globalEnv = (typeof(getgenv) == "function" and getgenv()) or _G
if globalEnv.__PERDI_DA_CLEANUP then
    pcall(globalEnv.__PERDI_DA_CLEANUP)
end

--============================================================================
-- SERVICES
--============================================================================
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local ProximityPromptService = game:GetService("ProximityPromptService")

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

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

--============================================================================
-- CONFIG / STATE
--============================================================================
local Config = {
    AutoPullEgg = false,
    AutoBuyEgg = false,
    AutoPlaceDragon = false,
    AutoOpenEgg = false,
    AutoCollect = false,

    AutoBreed = false,
    BreedMode = "Both (remote first)",
    BreedInterval = 1.2,
    AutoPickParents = false,
    AutoUpgradeNest = false,
    AutoFightWave = false,
    AutoRetreat = false,

    PromptInterval = 1.2,
    ReplayInterval = 2.0,

    Sniff = true,
    AllowTaps = false,

    AntiAFK = true,
}

local State = {
    Running = true,
    StatusText = "Idle - open the Remotes tab first",
    LastShownStatus = "",

    LastPromptFireAt = 0,
    LastReplayAt = 0,
    LastAntiAfkAt = os.clock(),
    LastSniffNoteAt = 0,
    PromptCount = 0,
    CapturedCount = 0,
}

--============================================================================
-- CACHES
--============================================================================
local Connections = {}
local CachedPrompts = {}
local FailedPrompts = {}

local function cleanText(str)
    local out = string.gsub(str or "", "<[^>]->", "")
    out = string.gsub(out, "%s+", " ")
    out = string.gsub(out, "^%s*(.-)%s*$", "%1")
    return string.lower(out)
end

local function registerPrompt(inst)
    if inst:IsA("ProximityPrompt") then
        CachedPrompts[inst] = { registeredAt = os.clock() }
        State.PromptCount = State.PromptCount + 1
    end
end

local function initPromptCache()
    table.insert(Connections, Workspace.DescendantAdded:Connect(registerPrompt))
    table.insert(Connections, Workspace.DescendantRemoving:Connect(function(inst)
        CachedPrompts[inst] = nil
        FailedPrompts[inst] = nil
    end))
    table.insert(Connections, ProximityPromptService.PromptShown:Connect(function(prompt)
        if prompt then
            CachedPrompts[prompt] = CachedPrompts[prompt] or { registeredAt = os.clock() }
        end
    end))

    task.spawn(function()
        local count = 0
        for _, inst in ipairs(Workspace:GetDescendants()) do
            if not State.Running then
                return
            end
            if inst:IsA("ProximityPrompt") then
                registerPrompt(inst)
            end
            count = count + 1
            if count % 2000 == 0 then
                task.wait()
            end
        end
    end)
end

--============================================================================
-- PROMPT ENGINE  (direct server call, no taps)
--============================================================================
local function promptLabel(prompt)
    local action = cleanText(prompt.ActionText)
    local object = cleanText(prompt.ObjectText)
    return action, object, action .. " " .. object
end

local function firePrompt(prompt)
    if not prompt or not prompt.Enabled then
        return false
    end
    if typeof(fireproximityprompt) == "function" then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then
            return true
        end
    end
    local ok = pcall(function()
        prompt:InputHoldBegin()
        local hold = prompt.HoldDuration or 0
        if hold > 0 then
            task.wait(math.min(hold, 1.5) + 0.05)
        else
            task.wait(0.05)
        end
        prompt:InputHoldEnd()
    end)
    if ok then
        return true
    end
    FailedPrompts[prompt] = true
    return false
end

local function getRootPosition()
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    return root and root.Position or nil
end

local function promptWorldPosition(prompt)
    local parent = prompt.Parent
    if not parent then
        return nil
    end
    if parent:IsA("Attachment") then
        return parent.WorldPosition
    elseif parent:IsA("BasePart") then
        return parent.Position
    elseif parent:IsA("Model") then
        local ok, cf = pcall(function()
            return parent:GetPivot()
        end)
        if ok and cf then
            return cf.Position
        end
    end
    local part = prompt:FindFirstAncestorWhichIsA("BasePart")
    return part and part.Position or nil
end

-- Find the nearest prompt whose action/object text matches the keyword list
local function findPrompt(keywords)
    local rootPos = getRootPosition()
    if not rootPos then
        return nil
    end
    local best, bestDist = nil, math.huge
    for prompt in pairs(CachedPrompts) do
        if not prompt.Parent then
            CachedPrompts[prompt] = nil
        elseif prompt.Enabled and not FailedPrompts[prompt] then
            local _, _, combined = promptLabel(prompt)
            for _, word in ipairs(keywords) do
                if string.find(combined, word, 1, true) then
                    local pos = promptWorldPosition(prompt)
                    if pos then
                        local dist = (pos - rootPos).Magnitude
                        local maxDist = (prompt.MaxActivationDistance or 10) + 6
                        if dist <= maxDist and dist < bestDist then
                            best, bestDist = prompt, dist
                        end
                    end
                    break
                end
            end
        end
    end
    return best
end

local PROMPT_KEYWORDS = {
    pull = { "pull", "lever", "spawn egg" },
    buy = { "buy", "purchase" },
    place = { "place", "deploy", "summon", "put", "set down", "insert dragon" },
    open = { "open", "hatch", "claim egg" },
    collect = { "collect", "claim", "grab" },
    nest = { "nest", "upgrade", "evolve" },
    fight = { "fight", "attack", "battle", "start wave" },
    retreat = { "retreat", "leave", "exit arena" },
}

local function tryPromptTask(toggleOn, keywordKey)
    if not toggleOn then
        return false
    end
    local now = os.clock()
    if (now - State.LastPromptFireAt) < Config.PromptInterval then
        return false
    end
    local prompt = findPrompt(PROMPT_KEYWORDS[keywordKey])
    if not prompt then
        return false
    end
    if firePrompt(prompt) then
        State.LastPromptFireAt = now
        local action, object = promptLabel(prompt)
        State.StatusText = "Prompt: " .. string.upper(action) .. (object ~= "" and (" - " .. object) or "")
        return true
    end
    return false
end

--============================================================================
-- REMOTE SNIFFER + REPLAY  (turns one manual tap into a repeatable call)
--============================================================================
local Captured = {}          -- ordered list of { Remote = , Args = , Key = , Preview = }
local CapturedByKey = {}     -- key -> captured entry (last one wins)
local SnifferHookInstalled = false

local REMOTE_KEYS = {
    { key = "breed", words = { "breed" } },
    { key = "openegg", words = { "open", "hatch", "claimegg" } },
    { key = "buyegg", words = { "buyegg", "buynest", "buy", "purchase" } },
    { key = "place", words = { "place", "deploy", "summon", "equip" } },
    { key = "sell", words = { "sell" } },
    { key = "upgrade", words = { "upgrade", "evolve", "level" } },
    { key = "wave", words = { "wave", "fight", "attack", "battle" } },
    { key = "retreat", words = { "retreat", "leave" } },
    { key = "collect", words = { "collect", "claim", "orb" } },
    { key = "spin", words = { "spin", "roll", "power" } },
}

local function remoteKeyFor(remoteName)
    local low = string.lower(remoteName or "")
    for _, rule in ipairs(REMOTE_KEYS) do
        for _, word in ipairs(rule.words) do
            if string.find(low, word, 1, true) then
                return rule.key
            end
        end
    end
    return nil
end

local function previewArgs(args)
    local bits = {}
    for i = 1, math.min(#args, 4) do
        local v = args[i]
        local t = typeof(v)
        if t == "Instance" then
            table.insert(bits, v.Name)
        elseif t == "string" then
            table.insert(bits, "\"" .. string.sub(v, 1, 24) .. "\"")
        elseif t == "number" or t == "boolean" then
            table.insert(bits, tostring(v))
        elseif t == "Vector3" or t == "CFrame" then
            table.insert(bits, t)
        else
            table.insert(bits, t)
        end
    end
    if #args > 4 then
        table.insert(bits, "...")
    end
    return table.concat(bits, ", ")
end

local function recordCall(remote, args)
    if not Config.Sniff then
        return
    end
    if typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") then
        return
    end
    local key = remoteKeyFor(remote.Name) or ("raw:" .. remote.Name)
    local preview = remote.Name .. "(" .. previewArgs(args) .. ")"
    local entry = {
        Remote = remote,
        Args = table.pack(table.unpack(args)),
        ArgCount = args.n or #args,
        Key = key,
        Preview = preview,
        At = os.clock(),
    }
    table.insert(Captured, entry)
    if #Captured > 60 then
        table.remove(Captured, 1)
    end
    CapturedByKey[key] = entry
    State.CapturedCount = #Captured
    State.StatusText = "Captured: " .. preview
end

local function installSniffer()
    if SnifferHookInstalled then
        return true
    end
    local hooked = false
    pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" then
                pcall(recordCall, self, table.pack(...))
            end
            return oldNamecall(self, ...)
        end)
        hooked = true
    end)
    if not hooked then
        -- fallback: hook each known remote individually
        pcall(function()
            for _, inst in ipairs(game:GetDescendants()) do
                if inst:IsA("RemoteEvent") then
                    local old
                    old = hookfunction(inst.FireServer, function(self, ...)
                        pcall(recordCall, self, table.pack(...))
                        return old(self, ...)
                    end)
                end
            end
            hooked = true
        end)
    end
    SnifferHookInstalled = hooked
    return hooked
end

local function replayEntry(entry)
    if not entry or not entry.Remote or not entry.Remote.Parent then
        return false
    end
    local ok = pcall(function()
        local n = entry.ArgCount or #entry.Args
        if n <= 0 then
            entry.Remote:FireServer()
        else
            entry.Remote:FireServer(table.unpack(entry.Args, 1, n))
        end
    end)
    return ok
end

local function replayKey(key, now)
    if (now - State.LastReplayAt) < Config.ReplayInterval then
        return false
    end
    local entry = CapturedByKey[key]
    if not entry then
        return false
    end
    if replayEntry(entry) then
        State.LastReplayAt = now
        State.StatusText = "Replayed: " .. entry.Preview
        return true
    end
    return false
end

local function capturedSummary()
    if #Captured == 0 then
        return "Nothing captured yet. Turn Sniffer ON, then tap Breed! / Open / Buy once in game."
    end
    local seen = {}
    local bits = {}
    for i = #Captured, 1, -1 do
        local entry = Captured[i]
        local id = entry.Key .. "|" .. entry.Preview
        if not seen[id] then
            seen[id] = true
            table.insert(bits, "[" .. entry.Key .. "] " .. entry.Preview)
            if #bits >= 8 then
                break
            end
        end
    end
    return table.concat(bits, "\n")
end

--============================================================================
-- OPTIONAL TAP FALLBACK (off by default)
--============================================================================
local CachedButtons = {}

local function isGuiChainVisible(guiObj)
    if not guiObj or not guiObj.Parent or not guiObj:IsA("GuiObject") then
        return false
    end
    if not guiObj.Visible or guiObj.AbsoluteSize.X <= 4 or guiObj.AbsoluteSize.Y <= 4 then
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

local function sendScreenTap(vpX, vpY)
    vpX, vpY = math.floor(vpX), math.floor(vpY)
    local sent = false
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendTouchEvent(7, 0, vpX, vpY)
            sent = true
        end)
        task.delay(0.03, function()
            pcall(function()
                VirtualInputManager:SendTouchEvent(7, 2, vpX, vpY)
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

local function tapButtonByKeywords(keywords)
    if not Config.AllowTaps then
        return false
    end
    local inset = GuiService:GetGuiInset()
    for btn in pairs(CachedButtons) do
        if not btn.Parent then
            CachedButtons[btn] = nil
        elseif btn:IsA("GuiButton") and isGuiChainVisible(btn) then
            local label = string.lower(string.gsub(btn.Text or "", "<[^>]->", ""))
            for _, word in ipairs(keywords) do
                if string.find(label, word, 1, true) then
                    local x = btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5 + inset.X
                    local y = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5 + inset.Y
                    if sendScreenTap(x, y) then
                        State.StatusText = "Tap: " .. btn.Name
                        return true
                    end
                end
            end
        end
    end
    return false
end

table.insert(Connections, PlayerGui.DescendantAdded:Connect(function(inst)
    if inst:IsA("GuiButton") then
        CachedButtons[inst] = true
    end
end))
table.insert(Connections, PlayerGui.DescendantRemoving:Connect(function(inst)
    CachedButtons[inst] = nil
end))

--============================================================================
-- AUTO BREED  (Breed bar: two parent cards + preview + "Breed!" button)
-- The wiki flow: heart button -> pick two dragons -> preview -> Breed!
-- Two ways to drive it:
--   * remote replay - if the sniffer captured the breed call, fire it directly
--   * button press  - tap "Breed!" (position matched, works even with no text)
--============================================================================
local Breed = {
    Button = nil,
    ScanAt = 0,
    LastTapAt = 0,
    LastParentAt = 0,
    FoundOnce = false,
}

local function viewportOf()
    local cam = Workspace.CurrentCamera
    return (cam and cam.ViewportSize) or Vector2.new(1280, 720)
end

local function labelLooksLikeBreed(text)
    local low = string.lower(string.gsub(text or "", "<[^>]->", ""))
    if string.find(low, "breed egg", 1, true) then
        return false
    end
    if string.find(low, "breeding", 1, true) and not string.find(low, "breed!", 1, true) then
        return false
    end
    return string.find(low, "breed", 1, true) ~= nil
end

-- Finds the pink "Breed!" button by text, or by its slot on the bottom bar.
local function refreshBreedButton(now)
    if (now - Breed.ScanAt) < 0.5 then
        return Breed.Button
    end
    Breed.ScanAt = now
    local vp = viewportOf()
    local best = nil
    local bestScore = -math.huge
    for btn in pairs(CachedButtons) do
        if not btn.Parent then
            CachedButtons[btn] = nil
        elseif btn:IsA("GuiButton") and isGuiChainVisible(btn) then
            local textHit = btn:IsA("TextButton") and labelLooksLikeBreed(btn.Text)
            local cx = (btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5) / vp.X
            local cy = (btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5) / vp.Y
            local slotHit = cx >= 0.57 and cx <= 0.78 and cy >= 0.83 and cy <= 0.995
                and btn.AbsoluteSize.X >= vp.X * 0.035
                and btn.AbsoluteSize.Y >= vp.Y * 0.04
            if textHit or slotHit then
                local score = (textHit and 100 or 0) + btn.AbsoluteSize.X
                if score > bestScore then
                    bestScore = score
                    best = btn
                end
            end
        end
    end
    Breed.Button = best
    if best then
        Breed.FoundOnce = true
    end
    return best
end

local function tapPoint(x, y)
    local vp = viewportOf()
    if x < 0 or y < 0 or x > vp.X or y > vp.Y then
        return false
    end
    return sendScreenTap(x, y)
end

local function pressBreedButton(btn, now)
    if not btn then
        return false
    end
    local inset = GuiService:GetGuiInset()
    local x = btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5 + inset.X
    local y = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5 + inset.Y
    if tapPoint(x, y) then
        Breed.LastTapAt = now
        State.StatusText = "Breed: pressed Breed!"
        return true
    end
    return false
end

-- Parent cards sit to the left of Breed! on the same bar; offsets are in
-- viewport heights so they hold up across phone resolutions.
local PARENT_OFFSETS = { -0.81, -0.65 }

local function pressParentSlot(index, now)
    local btn = Breed.Button
    if not btn then
        return false
    end
    local vp = viewportOf()
    local inset = GuiService:GetGuiInset()
    local bx = btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5 + inset.X
    local by = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5 + inset.Y
    local x = bx + PARENT_OFFSETS[index] * vp.Y
    Breed.LastParentAt = now
    if tapPoint(x, by) then
        State.StatusText = "Breed: picked parent " .. tostring(index)
        return true
    end
    return false
end

local function stepAutoBreed(now)
    if not Config.AutoBreed then
        return false
    end

    local mode = Config.BreedMode
    if mode ~= "Tap Breed! button only" then
        if replayKey("breed", now) then
            State.StatusText = "Breed: remote replay"
            return true
        end
        if mode == "Remote replay only" then
            return false
        end
    end

    local btn = refreshBreedButton(now)
    if not btn then
        return false
    end

    if Config.AutoPickParents and (now - Breed.LastParentAt) >= 3.0 then
        pressParentSlot(1, now)
        task.wait(0.30)
        pressParentSlot(2, now)
        task.wait(0.30)
    end

    if (now - Breed.LastTapAt) < Config.BreedInterval then
        return false
    end
    return pressBreedButton(btn, now)
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
end

--============================================================================
-- UI
--============================================================================
local Window = Rayfield:CreateWindow({
    Name = "perdi",
    Icon = 0,
    LoadingTitle = "perdi",
    LoadingSubtitle = "Dragon Arena (Mobile + PC)",
    Theme = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = true,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "perdiHub",
        FileName = "DragonArena",
    },
    Discord = {
        Enabled = false,
        Invite = "",
        RememberJoins = false,
    },
    KeySystem = false,
})

local MainTab = Window:CreateTab("Main", 4483362458)

local StatusPara = MainTab:CreateParagraph({
    Title = "perdi Status",
    Content = State.StatusText,
})

MainTab:CreateSection("World Prompts (server calls, no taps)")

MainTab:CreateToggle({
    Name = "Auto Pull Egg",
    CurrentValue = Config.AutoPullEgg,
    Flag = "PerdiDAPull",
    Callback = function(v)
        Config.AutoPullEgg = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Buy Egg",
    CurrentValue = Config.AutoBuyEgg,
    Flag = "PerdiDABuyEgg",
    Callback = function(v)
        Config.AutoBuyEgg = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Place Dragon",
    CurrentValue = Config.AutoPlaceDragon,
    Flag = "PerdiDAPlace",
    Callback = function(v)
        Config.AutoPlaceDragon = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Open / Hatch Egg",
    CurrentValue = Config.AutoOpenEgg,
    Flag = "PerdiDAOpen",
    Callback = function(v)
        Config.AutoOpenEgg = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Collect Orbs / Claims",
    CurrentValue = Config.AutoCollect,
    Flag = "PerdiDACollect",
    Callback = function(v)
        Config.AutoCollect = v
    end,
})

MainTab:CreateSection("UI Buttons (replayed remotes)")

MainTab:CreateToggle({
    Name = "Auto Breed",
    CurrentValue = Config.AutoBreed,
    Flag = "PerdiDABreed",
    Callback = function(v)
        Config.AutoBreed = v
        Breed.ScanAt = 0
    end,
})

MainTab:CreateDropdown({
    Name = "Breed Mode",
    Options = { "Both (remote first)", "Remote replay only", "Tap Breed! button only" },
    CurrentOption = { Config.BreedMode },
    MultipleOptions = false,
    Flag = "PerdiDABreedMode",
    Callback = function(Options)
        local pick = type(Options) == "table" and Options[1] or Options
        if pick then
            Config.BreedMode = pick
        end
    end,
})

MainTab:CreateSlider({
    Name = "Breed Interval",
    Range = { 0.6, 10 },
    Increment = 0.1,
    Suffix = " s",
    CurrentValue = Config.BreedInterval,
    Flag = "PerdiDABreedGap",
    Callback = function(v)
        Config.BreedInterval = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Pick Parents (experimental)",
    CurrentValue = Config.AutoPickParents,
    Flag = "PerdiDAParents",
    Callback = function(v)
        Config.AutoPickParents = v
    end,
})

MainTab:CreateButton({
    Name = "Find Breed Button (Test)",
    Callback = function()
        Breed.ScanAt = 0
        local btn = refreshBreedButton(os.clock())
        if btn then
            local vp = viewportOf()
            local cx = (btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5) / vp.X
            local cy = (btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5) / vp.Y
            local msg = string.format("Found: %s at %.2f, %.2f", btn.Name, cx, cy)
            State.StatusText = msg
            if pressBreedButton(btn, os.clock()) then
                State.StatusText = msg .. " (pressed)"
            end
        else
            State.StatusText = "Breed! button not found - open the breed bar first"
        end
    end,
})

MainTab:CreateToggle({
    Name = "Auto Upgrade / Evolve",
    CurrentValue = Config.AutoUpgradeNest,
    Flag = "PerdiDAUpgrade",
    Callback = function(v)
        Config.AutoUpgradeNest = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Fight Waves",
    CurrentValue = Config.AutoFightWave,
    Flag = "PerdiDAFight",
    Callback = function(v)
        Config.AutoFightWave = v
    end,
})

MainTab:CreateToggle({
    Name = "Auto Retreat",
    CurrentValue = Config.AutoRetreat,
    Flag = "PerdiDARetreat",
    Callback = function(v)
        Config.AutoRetreat = v
    end,
})

MainTab:CreateSlider({
    Name = "Prompt Interval",
    Range = { 0.4, 5 },
    Increment = 0.1,
    Suffix = " s",
    CurrentValue = Config.PromptInterval,
    Flag = "PerdiDAPromptGap",
    Callback = function(v)
        Config.PromptInterval = v
    end,
})

MainTab:CreateSlider({
    Name = "Replay Interval",
    Range = { 0.5, 15 },
    Increment = 0.1,
    Suffix = " s",
    CurrentValue = Config.ReplayInterval,
    Flag = "PerdiDAReplayGap",
    Callback = function(v)
        Config.ReplayInterval = v
    end,
})

local RemoteTab = Window:CreateTab("Remotes", 4483362458)

RemoteTab:CreateSection("Sniffer")

RemoteTab:CreateParagraph({
    Title = "How to make it tap-less",
    Content = "1) Keep Sniffer ON. 2) Tap Breed!, Open, Buy or Place ONCE by hand in game. 3) The script records the exact RemoteEvent + arguments. 4) Turn on the matching Auto toggle - from then on it fires that call directly, with no tapping at all.",
})

RemoteTab:CreateToggle({
    Name = "Sniffer (record remote calls)",
    CurrentValue = Config.Sniff,
    Flag = "PerdiDASniff",
    Callback = function(v)
        Config.Sniff = v
        if v then
            installSniffer()
        end
    end,
})

RemoteTab:CreateButton({
    Name = "Show Captured Calls",
    Callback = function()
        local text = capturedSummary()
        State.StatusText = text
        pcall(function()
            Rayfield:Notify({
                Title = "Captured Calls",
                Content = text,
                Duration = 10,
            })
        end)
    end,
})

RemoteTab:CreateButton({
    Name = "Clear Captured Calls",
    Callback = function()
        table.clear(Captured)
        table.clear(CapturedByKey)
        State.CapturedCount = 0
        State.StatusText = "Captured list cleared"
    end,
})

RemoteTab:CreateButton({
    Name = "Replay Last Captured",
    Callback = function()
        local entry = Captured[#Captured]
        if entry and replayEntry(entry) then
            State.StatusText = "Replayed " .. entry.Preview
        else
            State.StatusText = "Nothing to replay yet"
        end
    end,
})

RemoteTab:CreateSection("Diagnostics")

RemoteTab:CreateParagraph({
    Title = "Diagnostics",
    Content = "Prompts cache + captured call list. Use the buttons below if something is not firing.",
})

RemoteTab:CreateButton({
    Name = "List Nearby Prompts",
    Callback = function()
        local rootPos = getRootPosition()
        local bits = {}
        if rootPos then
            for prompt in pairs(CachedPrompts) do
                if prompt.Parent and prompt.Enabled then
                    local action, object = promptLabel(prompt)
                    local pos = promptWorldPosition(prompt)
                    if pos and (pos - rootPos).Magnitude <= (prompt.MaxActivationDistance or 10) + 8 then
                        table.insert(bits, action .. " | " .. object)
                        if #bits >= 8 then
                            break
                        end
                    end
                end
            end
        end
        local text = #bits > 0 and table.concat(bits, "  •  ") or "No prompts in range"
        State.StatusText = text
        pcall(function()
            Rayfield:Notify({
                Title = "Nearby Prompts",
                Content = text,
                Duration = 10,
            })
        end)
    end,
})

RemoteTab:CreateButton({
    Name = "Show Prompt Stats",
    Callback = function()
        local live = 0
        for prompt in pairs(CachedPrompts) do
            if prompt.Parent and prompt.Enabled then
                live = live + 1
            end
        end
        local text = string.format("%d prompts cached, %d live, %d captured calls", State.PromptCount, live, #Captured)
        State.StatusText = text
        pcall(function()
            Rayfield:Notify({
                Title = "Diagnostics",
                Content = text,
                Duration = 6,
            })
        end)
    end,
})

local MiscTab = Window:CreateTab("Misc", 4483362458)

MiscTab:CreateSection("Fallback")

MiscTab:CreateToggle({
    Name = "Allow Tap Fallback (uses screen taps)",
    CurrentValue = Config.AllowTaps,
    Flag = "PerdiDATaps",
    Callback = function(v)
        Config.AllowTaps = v
    end,
})

MiscTab:CreateSection("Session")

MiscTab:CreateToggle({
    Name = "Anti-AFK",
    CurrentValue = Config.AntiAFK,
    Flag = "PerdiDAAntiAfk",
    Callback = function(v)
        Config.AntiAFK = v
    end,
})

MiscTab:CreateButton({
    Name = "Unload perdi",
    Callback = function()
        if globalEnv.__PERDI_DA_CLEANUP then
            globalEnv.__PERDI_DA_CLEANUP()
        end
    end,
})

--============================================================================
-- MAIN LOOP
--============================================================================
local function runMainLoop()
    while State.Running do
        local now = os.clock()

        if Config.AntiAFK and (now - State.LastAntiAfkAt) >= 60 then
            State.LastAntiAfkAt = now
            sendAntiAfkPulse()
        end

        -- 1) world prompts first (cheapest, truly server-side)
        local handled = false
        handled = tryPromptTask(Config.AutoOpenEgg, "open") or handled
        handled = tryPromptTask(Config.AutoBuyEgg, "buy") or handled
        handled = tryPromptTask(Config.AutoPullEgg, "pull") or handled
        if Config.AutoPlaceDragon then
            if tryPromptTask(true, "place") then
                handled = true
            elseif (now - State.LastPromptFireAt) >= Config.PromptInterval then
                -- no Place prompt nearby: fall back to a "Place" button if one exists
                handled = tapButtonByKeywords({ "place", "deploy" }) or handled
            end
        end
        handled = tryPromptTask(Config.AutoCollect, "collect") or handled
        handled = tryPromptTask(Config.AutoUpgradeNest, "nest") or handled
        handled = tryPromptTask(Config.AutoFightWave, "fight") or handled
        handled = tryPromptTask(Config.AutoRetreat, "retreat") or handled

        -- 2) replayed remotes for plain UI buttons
        if not handled then
            if Config.AutoOpenEgg then
                handled = replayKey("openegg", now)
            end
            if not handled and Config.AutoBreed then
                handled = stepAutoBreed(now)
            end
            if not handled and Config.AutoUpgradeNest then
                handled = replayKey("upgrade", now)
            end
            if not handled and Config.AutoFightWave then
                handled = replayKey("wave", now)
            end
            if not handled and Config.AutoBuyEgg then
                handled = replayKey("buyegg", now)
            end
            if not handled and Config.AutoPlaceDragon then
                handled = replayKey("place", now)
            end
            if not handled and Config.AutoCollect then
                handled = replayKey("collect", now)
            end
        end

        -- 3) optional tap fallback
        if not handled and Config.AllowTaps then
            if Config.AutoBreed then
                handled = tapButtonByKeywords({ "breed" })
            end
            if not handled and Config.AutoOpenEgg then
                handled = tapButtonByKeywords({ "open", "hatch" })
            end
        end

        if State.StatusText ~= State.LastShownStatus then
            State.LastShownStatus = State.StatusText
            pcall(function()
                StatusPara:Set({
                    Title = "perdi Status",
                    Content = State.StatusText,
                })
            end)
        end

        task.wait(0.12)
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
    globalEnv.__PERDI_DA_CLEANUP = nil
end

globalEnv.__PERDI_DA_CLEANUP = cleanup

initPromptCache()

if Config.Sniff then
    task.delay(1, function()
        installSniffer()
    end)
end

table.insert(Connections, LocalPlayer.Idled:Connect(function()
    if Config.AntiAFK then
        sendAntiAfkPulse()
    end
end))

task.spawn(runMainLoop)

pcall(function()
    Rayfield:LoadConfiguration()
end)

Rayfield:Notify({
    Title = "perdi  ·  v3",
    Content = "Dragon Arena v3 - Auto Place / Open / Breed on prompts + remotes.",
    Duration = 6,
})
