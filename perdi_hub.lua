--[[
    perdi | Fish & Training Automation Hub (Rayfield UI)  ·  v6
    Repository file: perdi_hub.lua (main branch, repo root)
    Features:
      - Auto Fish + Stop at Tier (1..10 / SEA KING)
      - Auto Perfect (Middle Bar) + Auto Perfect Reel (+25 Vertical Bar)
      - Auto Train (Auto-learns plot bar offset & walks character into training circle on any server)
      - Auto 2x + Auto Upgrade
      - Auto Claim Playtime Rewards + Auto Server Hop once all 9 Playtime rewards are claimed
      - Auto Save & Auto Load across Server Hops (JSON config + queue_on_teleport)
      - Shore panel layer: BAIT / FISH / AUTO detection, catch popups, reel hold (Android-safe)
      - Dual-Layer Anti-AFK
]]

-- Wait for game & LocalPlayer when auto-loaded on server hop
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local globalEnv = (typeof(getgenv) == "function" and getgenv()) or _G
if globalEnv.__PERDI_HUB_CLEANUP then
    pcall(globalEnv.__PERDI_HUB_CLEANUP)
end

--============================================================================
-- SERVICES
--============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

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
-- PERSISTENT AUTO-SAVE / AUTO-LOAD SYSTEM (perdiHub/ffsa_settings.json)
--============================================================================
local SAVE_FOLDER = "perdiHub"
local SAVE_FILE = "perdiHub/ffsa_settings.json"
local VISITED_FILE = "perdiHub/visited_servers.json"

local Config = {
    AutoFish = false,
    AutoPerfect = false,
    AutoPerfectReel = false,
    StopAtTier = 6,

    AutoTrain = false,
    Auto2x = false,
    AutoUpgrade = false,

    AutoPlaytime = false,
    ServerHopAfterPlaytime = false,

    -- Shore panel (BAIT / FISH / AUTO) behaviour
    ShoreReelMethod = "Tap FISH only",
    ShorePopups = true,
    ShoreInvert = false,
    ScriptURL = "https://raw.githubusercontent.com/triskxd-ops/Perdi/main/perdi_hub.lua",

    -- Plot-relative offset from your plot's Upgrade bar prompt to the training circle center
    BarOffsetX = nil,
    BarOffsetY = nil,
    BarOffsetZ = nil,

    AntiAFK = true,
}

local function ensureSaveFolder()
    if typeof(isfolder) == "function" and typeof(makefolder) == "function" then
        pcall(function()
            if not isfolder(SAVE_FOLDER) then
                makefolder(SAVE_FOLDER)
            end
        end)
    end
end

local function savePersistentConfig()
    if typeof(writefile) ~= "function" then
        return
    end
    ensureSaveFolder()
    pcall(function()
        local encoded = HttpService:JSONEncode(Config)
        writefile(SAVE_FILE, encoded)
    end)
end

local function loadPersistentConfig()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then
        return
    end
    pcall(function()
        if isfile(SAVE_FILE) then
            local raw = readfile(SAVE_FILE)
            local decoded = HttpService:JSONDecode(raw)
            if type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    if Config[k] ~= nil or k == "BarOffsetX" or k == "BarOffsetY" or k == "BarOffsetZ" then
                        Config[k] = v
                    end
                end
            end
        end
    end)
end

-- Load saved config immediately before building UI
loadPersistentConfig()

-- Capture PERDI_URL automatically if user launched with getgenv().PERDI_URL
if type(globalEnv.PERDI_URL) == "string" and #globalEnv.PERDI_URL > 8 then
    Config.ScriptURL = globalEnv.PERDI_URL
    savePersistentConfig()
end

-- Queue script for auto-execution in the next server on hop
local TeleportQueued = false
local function armQueueOnTeleport()
    if TeleportQueued then
        return
    end
    local url = Config.ScriptURL
    if type(url) ~= "string" or not url:find("^https?://") then
        return
    end

    local qfn = (typeof(queue_on_teleport) == "function" and queue_on_teleport)
        or (typeof(queueteleport) == "function" and queueteleport)
        or (type(syn) == "table" and typeof(syn.queue_on_teleport) == "function" and syn.queue_on_teleport)
        or (type(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" and fluxus.queue_on_teleport)

    if qfn then
        local payload = string.format(
            [[
repeat task.wait(0.5) until game:IsLoaded() and game:GetService("Players").LocalPlayer
local env = (typeof(getgenv) == "function" and getgenv()) or _G
if not env.__PERDI_BOOTING then
    env.__PERDI_BOOTING = true
    env.PERDI_URL = %q
    task.wait(2.5)
    env.__PERDI_BOOTING = nil
    loadstring(game:HttpGet(%q))()
end
]],
            url,
            url
        )
        local ok = pcall(qfn, payload)
        if ok then
            TeleportQueued = true
        end
    end
end

--============================================================================
-- RUNTIME STATE
--============================================================================
local State = {
    Running = true,
    JoinedAt = os.clock(),
    CurrentTier = 1,
    LastDecisionSignature = "",
    LastDecisionClickAt = 0,
    DecisionVisibleSince = 0,
    LastCastAt = 0,
    LastPerfectTapAt = 0,
    LastReelTapAt = 0,
    LastUpgradeAt = 0,
    Last2xAt = 0,
    LastTrainStepAt = 0,
    TrainProbeIndex = 0,
    LastPlaytimeScanAt = 0,
    LastFullPlaytimeVerifyAt = 0,
    HoppingInProgress = false,
    PlaytimeStatus = "Waiting...",
    LastShownPlaytimeStatus = "",
    LastAntiAfkPulseAt = os.clock(),
    PendingTapRelease = false,
    PrevMiddlePos = {},
    PrevReelPos = {},
}

local Connections = {}
local OriginalIdleConnections = nil

--============================================================================
-- CACHED TEXT-ELEMENT REGISTRY
-- The fishing / decision / playtime loops used to walk PlayerGui:GetDescendants()
-- many times per second. This keeps them on a plain cached list instead, which
-- is far lighter on Android (events keep it current, nothing polls the tree).
--============================================================================
local CachedTextElements = {}
local CachedTextList = {}
local CachedTextDirty = true

local function markTextCacheDirty()
    CachedTextDirty = true
end

local function eachTextElement()
    if CachedTextDirty then
        table.clear(CachedTextList)
        for d in pairs(CachedTextElements) do
            if d.Parent then
                table.insert(CachedTextList, d)
            else
                CachedTextElements[d] = nil
            end
        end
        CachedTextDirty = false
    end
    return CachedTextList
end

pcall(function()
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            CachedTextElements[d] = true
        end
    end
    CachedTextDirty = true
end)
table.insert(Connections, PlayerGui.DescendantAdded:Connect(function(inst)
    if inst:IsA("TextLabel") or inst:IsA("TextButton") then
        CachedTextElements[inst] = true
        markTextCacheDirty()
    end
end))
table.insert(Connections, PlayerGui.DescendantRemoving:Connect(function(inst)
    if CachedTextElements[inst] then
        CachedTextElements[inst] = nil
        markTextCacheDirty()
    end
end))

--============================================================================
-- LOAD RAYFIELD UI
--============================================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

--============================================================================
-- ANTI-AFK
--============================================================================
local function captureOriginalIdleConnections()
    if OriginalIdleConnections ~= nil then
        return
    end
    OriginalIdleConnections = {}
    if typeof(getconnections) == "function" then
        pcall(function()
            for _, conn in ipairs(getconnections(LocalPlayer.Idled)) do
                table.insert(OriginalIdleConnections, conn)
            end
        end)
    end
end

local function applyAntiAFKState(enabled)
    captureOriginalIdleConnections()
    for _, conn in ipairs(OriginalIdleConnections) do
        pcall(function()
            if enabled and conn.Disable then
                conn:Disable()
            elseif (not enabled) and conn.Enable then
                conn:Enable()
            end
        end)
    end
end

local function sendAntiAFKPulse()
    if VirtualUser then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
    end
    State.LastAntiAfkPulseAt = os.clock()
end

--============================================================================
-- UI & STORE-SAFETY HELPERS
--============================================================================
local CURRENCY_CHAR = utf8.char(0xE002)
local TAG_RBX = "ro" .. "bux"
local TAG_GP = "game" .. "pass"
local CLS_BORDER = "UI" .. "Str" .. "oke"
local CLS_TOUCH = "Touch" .. "Transmitter"

local function stripRichText(str)
    if type(str) ~= "string" then
        return ""
    end
    local cleaned = str:gsub("<[^>]->", "")
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned
end

local function isRayfieldInstance(inst)
    local cur = inst
    while cur and cur ~= game do
        if cur:IsA("LayerCollector") then
            local nl = cur.Name:lower()
            if nl:find("rayfield", 1, true) or nl:find("sirius", 1, true) then
                return true
            end
        end
        cur = cur.Parent
    end
    return false
end

local function getRayfieldScreenGuis()
    local roots = {}
    if typeof(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then
            table.insert(roots, hui)
        end
    end
    pcall(function()
        table.insert(roots, CoreGui)
    end)
    table.insert(roots, PlayerGui)

    local list = {}
    for _, root in ipairs(roots) do
        pcall(function()
            for _, child in ipairs(root:GetChildren()) do
                if child:IsA("ScreenGui") and child.Enabled then
                    local nl = child.Name:lower()
                    if nl:find("rayfield", 1, true) or nl:find("sirius", 1, true) then
                        table.insert(list, child)
                    end
                end
            end
        end)
    end
    return list
end

local function isPointCoveredByRayfield(vpX, vpY)
    local inset = GuiService:GetGuiInset()
    local guiX = vpX - inset.X
    local guiY = vpY - inset.Y

    for _, sg in ipairs(getRayfieldScreenGuis()) do
        for _, child in ipairs(sg:GetChildren()) do
            if child:IsA("GuiObject") and child.Visible and child.BackgroundTransparency < 0.98 then
                local p = child.AbsolutePosition
                local s = child.AbsoluteSize
                if s.X > 40 and s.Y > 40 then
                    if guiX >= p.X and guiX <= p.X + s.X and guiY >= p.Y and guiY <= p.Y + s.Y then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function isPurchasePromptOpen()
    local ok, open = pcall(function()
        local pp = CoreGui:FindFirstChild("PurchasePrompt") or CoreGui:FindFirstChild("PurchasePromptApp")
        if not pp then
            return false
        end
        for _, desc in ipairs(pp:GetDescendants()) do
            if desc:IsA("GuiButton") and desc.Visible and desc.AbsoluteSize.X > 60 and desc.AbsoluteSize.Y > 24 then
                return true
            end
        end
        return false
    end)
    return ok and open or false
end

local function isGuiChainVisible(guiObj)
    if not guiObj or not guiObj.Parent or not guiObj:IsA("GuiObject") then
        return false
    end
    if not guiObj.Visible then
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
            local nl = current.Name:lower()
            if nl:find("rayfield", 1, true) or nl:find("sirius", 1, true) then
                return false
            end
            break
        end
        current = current.Parent
    end
    return true
end

local function isVisibleTextElement(guiObj)
    if not isGuiChainVisible(guiObj) then
        return false
    end
    if guiObj.AbsoluteSize.X <= 1 or guiObj.AbsoluteSize.Y <= 1 then
        return false
    end
    if (guiObj:IsA("TextLabel") or guiObj:IsA("TextButton")) and guiObj.TextTransparency >= 0.98 then
        return false
    end
    return true
end

local UNSAFE_CONTAINER_KEYWORDS = {
    "shop", "store", TAG_RBX, TAG_GP, "passes", "monetization",
    "purchase", "codes", "index", "clan", "seabeast", "invite", "egg"
}

local function isSafeGameplayElement(guiObj)
    if isRayfieldInstance(guiObj) then
        return false
    end
    local current = guiObj
    while current and current ~= PlayerGui and current ~= game do
        local lowerName = current.Name:lower()
        for _, bad in ipairs(UNSAFE_CONTAINER_KEYWORDS) do
            if lowerName:find(bad, 1, true) then
                return false
            end
        end
        current = current.Parent
    end

    local checkRoot = guiObj
    if guiObj.Parent and guiObj.Parent:IsA("GuiObject") and guiObj.Parent.AbsoluteSize.X < 400 then
        checkRoot = guiObj.Parent
    end
    for _, desc in ipairs(checkRoot:GetDescendants()) do
        if desc:IsA("TextLabel") or desc:IsA("TextButton") then
            local t = desc.Text or ""
            local lower = t:lower()
            if t:find(CURRENCY_CHAR, 1, true) or lower:find(TAG_RBX, 1, true) or lower:find("r$", 1, true) then
                return false
            end
        end
    end
    return true
end

--============================================================================
-- UNIVERSAL MOBILE + PC INPUT HELPERS
--============================================================================
local function findClickableButton(guiObj)
    local cur = guiObj
    for _ = 1, 5 do
        if not cur or cur == PlayerGui or cur:IsA("LayerCollector") then
            break
        end
        if cur:IsA("GuiButton") and cur.Visible then
            return cur
        end
        cur = cur.Parent
    end
    if guiObj.Parent and guiObj.Parent:IsA("GuiObject") then
        for _, sibling in ipairs(guiObj.Parent:GetChildren()) do
            if sibling:IsA("GuiButton") and sibling.Visible then
                return sibling
            end
        end
    end
    for _, child in ipairs(guiObj:GetChildren()) do
        if child:IsA("GuiButton") and child.Visible then
            return child
        end
    end
    return nil
end

local function fireSingleButtonSignal(btn)
    if not btn then
        return false
    end

    if typeof(getconnections) == "function" then
        for _, sigName in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down", "TouchTap" }) do
            local ok, conns = pcall(function()
                return getconnections(btn[sigName])
            end)
            if ok and type(conns) == "table" and #conns > 0 then
                local firedAny = false
                for _, conn in ipairs(conns) do
                    pcall(function()
                        if conn.Fire then
                            conn:Fire()
                            firedAny = true
                        elseif conn.Function then
                            task.spawn(conn.Function)
                            firedAny = true
                        end
                    end)
                end
                if sigName == "MouseButton1Down" then
                    pcall(function()
                        for _, upConn in ipairs(getconnections(btn.MouseButton1Up)) do
                            if upConn.Fire then
                                upConn:Fire()
                            elseif upConn.Function then
                                task.spawn(upConn.Function)
                            end
                        end
                    end)
                end
                if firedAny then
                    return true
                end
            end
        end
    end

    if typeof(firesignal) == "function" then
        local fired = false
        pcall(function()
            firesignal(btn.MouseButton1Down)
            fired = true
        end)
        pcall(function()
            firesignal(btn.Activated)
            fired = true
        end)
        pcall(function()
            firesignal(btn.MouseButton1Click)
            fired = true
        end)
        pcall(function()
            firesignal(btn.MouseButton1Up)
        end)
        if fired then
            return true
        end
    end

    return false
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
        task.delay(0.025, function()
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

local function clickGuiElement(targetGui)
    if not targetGui or not isGuiChainVisible(targetGui) then
        return false
    end

    local btn = findClickableButton(targetGui)
    -- Guard: never click the workout "STOP" button by mistake!
    if btn and btn:IsA("TextButton") and stripRichText(btn.Text or ""):upper() == "STOP" then
        return false
    end

    local clickTarget = btn or targetGui
    local inset = GuiService:GetGuiInset()
    local vpX = clickTarget.AbsolutePosition.X + clickTarget.AbsoluteSize.X * 0.5 + inset.X
    local vpY = clickTarget.AbsolutePosition.Y + clickTarget.AbsoluteSize.Y * 0.5 + inset.Y

    if not isPointCoveredByRayfield(vpX, vpY) then
        if sendScreenTap(vpX, vpY) then
            return true
        end
    end

    if btn and fireSingleButtonSignal(btn) then
        return true
    end
    return false
end

local function fireInstantMiddleTap(minigameScreenGui, trackObj)
    if State.PendingTapRelease then
        return false
    end
    State.PendingTapRelease = true

    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)

    if minigameScreenGui then
        for _, desc in ipairs(minigameScreenGui:GetDescendants()) do
            if desc:IsA("GuiButton") and isGuiChainVisible(desc) then
                local sx, sy = desc.AbsoluteSize.X, desc.AbsoluteSize.Y
                local isFullscreenCatcher = (sx >= vs.X * 0.45 and sy >= vs.Y * 0.45)

                local combinedText = ""
                if desc:IsA("TextButton") then
                    combinedText = stripRichText(desc.Text or ""):upper()
                end
                for _, sub in ipairs(desc:GetDescendants()) do
                    if sub:IsA("TextLabel") then
                        combinedText = combinedText .. " " .. stripRichText(sub.Text or ""):upper()
                    end
                end

                local isExplicitTapPrompt = combinedText:find("TAP THE MIDDLE", 1, true)
                    or combinedText:find("TAP TO CAST", 1, true)
                    or combinedText:find("TAP TO REEL", 1, true)
                local isBlockedBtn = combinedText:find("ALWAYS PERFECT", 1, true)
                    or combinedText:find("UPGRADE SECRET", 1, true)
                    or combinedText:find(TAG_RBX:upper(), 1, true)
                    or combinedText:find("R$", 1, true)
                    or combinedText == "STOP"
                    or desc.Name:lower():find("close", 1, true)
                    or desc.Name:lower():find("cancel", 1, true)
                    or desc.Name:lower():find("pass", 1, true)

                if (isFullscreenCatcher or isExplicitTapPrompt) and (not isBlockedBtn) and isSafeGameplayElement(desc) then
                    fireSingleButtonSignal(desc)
                end
            end
        end
    end

    local candidates = {
        { vs.X * 0.18, vs.Y * 0.32 },
        { vs.X * 0.82, vs.Y * 0.32 },
        { vs.X * 0.50, vs.Y * 0.28 },
        { vs.X * 0.18, vs.Y * 0.60 },
        { vs.X * 0.82, vs.Y * 0.60 },
    }

    local vpX, vpY = candidates[1][1], candidates[1][2]
    for _, pt in ipairs(candidates) do
        if not isPointCoveredByRayfield(pt[1], pt[2]) then
            vpX, vpY = math.floor(pt[1]), math.floor(pt[2])
            break
        end
    end

    if typeof(mousemoveabs) == "function" then
        pcall(mousemoveabs, vpX, vpY)
    end
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendMouseMoveEvent(vpX, vpY, game)
        end)
        pcall(function()
            VirtualInputManager:SendTouchEvent(9, 0, vpX, vpY)
        end)
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(vpX, vpY, 0, true, game, 1)
        end)
    end
    if typeof(mouse1press) == "function" and not isPointCoveredByRayfield(vpX, vpY) then
        pcall(mouse1press)
    elseif not VirtualInputManager and VirtualUser then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:Button1Down(Vector2.new(vpX, vpY))
        end)
    end

    task.delay(0.025, function()
        if VirtualInputManager then
            pcall(function()
                VirtualInputManager:SendTouchEvent(9, 2, vpX, vpY)
            end)
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(vpX, vpY, 0, false, game, 1)
            end)
        end
        if typeof(mouse1release) == "function" then
            pcall(mouse1release)
        elseif not VirtualInputManager and VirtualUser then
            pcall(function()
                VirtualUser:Button1Up(Vector2.new(vpX, vpY))
            end)
        end
        State.PendingTapRelease = false
    end)

    return true
end

--============================================================================
-- CHARACTER & PROXIMITY PROMPT HELPERS
--============================================================================
local function getCharacterAndRoot()
    local char = LocalPlayer.Character
    if not char then
        return nil, nil, nil
    end
    local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    local hum = char:FindFirstChildOfClass("Humanoid")
    return char, root, hum
end

local function getPromptBasePart(prompt)
    local parent = prompt.Parent
    if not parent then
        return nil
    end
    if parent:IsA("BasePart") then
        return parent
    elseif parent:IsA("Attachment") and parent.Parent and parent.Parent:IsA("BasePart") then
        return parent.Parent
    elseif parent:IsA("Model") and parent.PrimaryPart then
        return parent.PrimaryPart
    end
    return prompt:FindFirstAncestorWhichIsA("BasePart")
end

local function getPromptWorldPosition(prompt)
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
    local partAncestor = prompt:FindFirstAncestorWhichIsA("BasePart")
    return partAncestor and partAncestor.Position or nil
end

local function findNearestPromptMatching(predicate, customMaxRadius)
    local _, root = getCharacterAndRoot()
    if not root then
        return nil
    end
    local rootPos = root.Position
    local bestPrompt = nil
    local bestDist = math.huge

    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc:IsA("ProximityPrompt") and desc.Enabled then
            local actionText = stripRichText(desc.ActionText or ""):lower()
            local objectText = stripRichText(desc.ObjectText or ""):lower()
            if predicate(actionText, objectText, desc) then
                local promptPos = getPromptWorldPosition(desc)
                if promptPos then
                    local dist = (promptPos - rootPos).Magnitude
                    local maxDist = customMaxRadius or ((desc.MaxActivationDistance or 10) + 3)
                    if dist <= maxDist and dist < bestDist then
                        bestDist = dist
                        bestPrompt = desc
                    end
                end
            end
        end
    end
    return bestPrompt
end

local function triggerPrompt(prompt)
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
        if prompt.HoldDuration and prompt.HoldDuration > 0 then
            task.wait(prompt.HoldDuration + 0.05)
        else
            task.wait(0.05)
        end
        prompt:InputHoldEnd()
    end)
    return ok
end

--============================================================================
-- AUTO TRAIN (Walks onto Your Plot's Training Circle & Auto-Learns Offset)
--============================================================================
local function isCurrentlyTraining()
    -- While training on the bar, the red "STOP" button is visible at bottom-center
    for _, d in ipairs(eachTextElement()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            if stripRichText(d.Text or ""):upper() == "STOP" then
                return true
            end
        end
    end
    return false
end

local function findOwnedPlotAnchorPos()
    -- Look for the "YOURS" plot sign in Workspace (BillboardGui / SurfaceGui)
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("TextLabel") and stripRichText(d.Text or ""):upper() == "YOURS" then
            local gui = d:FindFirstAncestorWhichIsA("BillboardGui") or d:FindFirstAncestorWhichIsA("SurfaceGui")
            if gui and gui.Adornee and gui.Adornee:IsA("BasePart") then
                return gui.Adornee.Position
            end
            local part = d:FindFirstAncestorWhichIsA("BasePart")
            if part then
                return part.Position
            end
        end
    end
    return nil
end

local function findMyBarUpgradePrompt()
    local _, root = getCharacterAndRoot()
    if not root then
        return nil
    end

    local yoursPos = findOwnedPlotAnchorPos()
    local refPos = yoursPos or root.Position
    local bestPrompt = nil
    local bestDist = math.huge

    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc:IsA("ProximityPrompt") and desc.Enabled then
            local act = stripRichText(desc.ActionText or ""):lower()
            if act:find("upgrade", 1, true) ~= nil then
                local pPos = getPromptWorldPosition(desc)
                if pPos then
                    local d = (pPos - refPos).Magnitude
                    if d <= 260 and d < bestDist then
                        bestDist = d
                        bestPrompt = desc
                    end
                end
            end
        end
    end
    return bestPrompt
end

local function findTrainingPadPosition(upgradePrompt)
    local _, root = getCharacterAndRoot()
    if not root or not upgradePrompt then
        return nil
    end

    local upgradePart = getPromptBasePart(upgradePrompt)
    local promptPos = getPromptWorldPosition(upgradePrompt)
    if not promptPos then
        return nil
    end

    -- 1) If we learned/saved the exact plot-relative offset from the Upgrade bar, map it to world space!
    if upgradePart and Config.BarOffsetX and Config.BarOffsetY and Config.BarOffsetZ then
        local localOffset = Vector3.new(Config.BarOffsetX, Config.BarOffsetY, Config.BarOffsetZ)
        if localOffset.Magnitude <= 35 then
            return upgradePart.CFrame:PointToWorldSpace(localOffset)
        end
    end

    -- 2) Scan within 28 studs of your Upgrade prompt for the TouchTransmitter training circle/pad
    local bestTouchPart = nil
    local bestTouchDist = math.huge
    local bestNamedPart = nil
    local bestNamedDist = math.huge

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and math.abs(obj.Position.Y - root.Position.Y) <= 14 then
            local dist = (obj.Position - promptPos).Magnitude
            if dist <= 28 then
                if obj:FindFirstChildOfClass(CLS_TOUCH) then
                    if dist < bestTouchDist then
                        bestTouchDist = dist
                        bestTouchPart = obj
                    end
                end
                local nl = obj.Name:lower()
                local parentNl = obj.Parent and obj.Parent.Name:lower() or ""
                if nl:find("circle", 1, true) or nl:find("ring", 1, true) or nl:find("train", 1, true)
                    or nl:find("pad", 1, true) or nl:find("zone", 1, true) or parentNl:find("bar", 1, true)
                then
                    if dist < bestNamedDist then
                        bestNamedDist = dist
                        bestNamedPart = obj
                    end
                end
            end
        end
    end

    if bestTouchPart then
        return bestTouchPart.Position
    end
    if bestNamedPart then
        return bestNamedPart.Position
    end

    -- 3) Fallback: probe right around the Upgrade prompt until "STOP" triggers, then auto-save!
    local probeOffsets = {
        Vector3.new(0, 0, 0),
        Vector3.new(5, 0, 0),
        Vector3.new(-5, 0, 0),
        Vector3.new(0, 0, 5),
        Vector3.new(0, 0, -5),
        Vector3.new(7, 0, 5),
        Vector3.new(-7, 0, 5),
    }
    State.TrainProbeIndex = (State.TrainProbeIndex % #probeOffsets) + 1
    return promptPos + probeOffsets[State.TrainProbeIndex]
end

local function stepAutoTrain()
    local now = os.clock()
    local _, root, hum = getCharacterAndRoot()
    if not root or not hum or hum.Health <= 0 then
        return
    end

    if isCurrentlyTraining() then
        -- Automatically learn & save the exact plot-relative training circle offset!
        if Config.BarOffsetX == nil then
            local upPrompt = findMyBarUpgradePrompt()
            local upPart = upPrompt and getPromptBasePart(upPrompt) or nil
            if upPart and (upPart.Position - root.Position).Magnitude <= 32 then
                local rel = upPart.CFrame:PointToObjectSpace(root.Position)
                Config.BarOffsetX = math.floor(rel.X * 100) / 100
                Config.BarOffsetY = math.floor(rel.Y * 100) / 100
                Config.BarOffsetZ = math.floor(rel.Z * 100) / 100
                savePersistentConfig()
            end
        end
        return
    end

    if (now - State.LastTrainStepAt) < 1.8 then
        return
    end
    State.LastTrainStepAt = now

    local upPrompt = findMyBarUpgradePrompt()
    if not upPrompt then
        return
    end

    local targetPos = findTrainingPadPosition(upPrompt)
    if not targetPos then
        return
    end

    local flatDist = Vector3.new(targetPos.X - root.Position.X, 0, targetPos.Z - root.Position.Z).Magnitude
    if flatDist > 90 then
        -- Smoothly place character near plot bar if spawned far away, then walk into the circle
        root.CFrame = CFrame.new(targetPos + Vector3.new(0, 3.5, 4))
        task.wait(0.15)
    end
    hum:MoveTo(Vector3.new(targetPos.X, root.Position.Y, targetPos.Z))
end

--============================================================================
-- PLAYTIME REWARDS + SERVER HOP WHEN ALL 9 ARE CLAIMED
--============================================================================
local function loadVisitedServers()
    local visited = {}
    if typeof(isfile) == "function" and typeof(readfile) == "function" then
        pcall(function()
            if isfile(VISITED_FILE) then
                local decoded = HttpService:JSONDecode(readfile(VISITED_FILE))
                if type(decoded) == "table" then
                    visited = decoded
                end
            end
        end)
    end
    return visited
end

local function recordCurrentServerVisited()
    if typeof(writefile) ~= "function" or game.JobId == "" then
        return
    end
    ensureSaveFolder()
    local visited = loadVisitedServers()
    local filtered = { game.JobId }
    for _, id in ipairs(visited) do
        if id ~= game.JobId and #filtered < 18 then
            table.insert(filtered, id)
        end
    end
    pcall(function()
        writefile(VISITED_FILE, HttpService:JSONEncode(filtered))
    end)
end

local function serverHopToFreshServer()
    if State.HoppingInProgress then
        return
    end
    State.HoppingInProgress = true
    State.PlaytimeStatus = "All Playtime rewards claimed! Server hopping..."

    savePersistentConfig()
    recordCurrentServerVisited()
    armQueueOnTeleport()

    local visitedMap = {}
    for _, id in ipairs(loadVisitedServers()) do
        visitedMap[id] = true
    end
    visitedMap[game.JobId] = true

    task.spawn(function()
        local cursor = ""
        for _ = 1, 4 do
            local apiUrl = string.format(
                "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s",
                game.PlaceId,
                cursor ~= "" and ("&cursor=" .. HttpService:UrlEncode(cursor)) or ""
            )

            local ok, body = pcall(function()
                return game:HttpGet(apiUrl)
            end)

            if ok and type(body) == "string" then
                local okJson, data = pcall(function()
                    return HttpService:JSONDecode(body)
                end)
                if okJson and type(data) == "table" and type(data.data) == "table" then
                    local candidates = {}
                    for _, srv in ipairs(data.data) do
                        local id = srv.id
                        local playing = tonumber(srv.playing) or 0
                        local maxP = tonumber(srv.maxPlayers) or 0
                        if type(id) == "string" and not visitedMap[id] and playing >= 1 and playing < (maxP - 1) then
                            table.insert(candidates, id)
                        end
                    end

                    if #candidates > 0 then
                        local pick = candidates[math.random(1, #candidates)]
                        State.PlaytimeStatus = "Teleporting to fresh server..."
                        pcall(function()
                            TeleportService:TeleportToPlaceInstance(game.PlaceId, pick, LocalPlayer)
                        end)
                        task.wait(5)
                    end

                    if type(data.nextPageCursor) == "string" and data.nextPageCursor ~= "" then
                        cursor = data.nextPageCursor
                    else
                        break
                    end
                else
                    break
                end
            else
                break
            end
        end

        -- Fallback generic Teleport if server list API was rate-limited
        State.PlaytimeStatus = "Fallback teleporting to another server..."
        pcall(function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
        task.wait(6)
        State.HoppingInProgress = false
    end)
end

local function findRewardsHudOpenButton()
    -- Look for the top HUD Gift button that shows "in MM:SS" (e.g., "in 8:28") or named Rewards/Playtime
    for _, d in ipairs(eachTextElement()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            local clean = stripRichText(d.Text or ""):lower()
            if clean:match("^in%s+%d+:%d+$") then
                local btn = findClickableButton(d)
                if btn then
                    return btn
                end
                if d.Parent and d.Parent:IsA("GuiObject") then
                    return d.Parent
                end
            end
        end
    end
    for _, d in ipairs(eachTextElement()) do
        if d:IsA("GuiButton") and isGuiChainVisible(d) and d.AbsolutePosition.Y < 160 then
            local nl = d.Name:lower()
            if nl:find("reward", 1, true) or nl:find("playtime", 1, true) or nl:find("gift", 1, true) then
                return d
            end
        end
    end
    return nil
end

local function hasHiddenOrVisibleReadyPlaytime()
    -- Check if any Playtime slot in PlayerGui already says "READY!" or HUD Gift badge >= 1
    for _, d in ipairs(eachTextElement()) do
        if d:IsA("TextLabel") or d:IsA("TextLabel") or d:IsA("TextButton") then
            local clean = stripRichText(d.Text or ""):upper()
            if clean == "READY!" then
                return true
            end
        end
    end
    local hudBtn = findRewardsHudOpenButton()
    if hudBtn then
        for _, sub in ipairs(hudBtn:GetDescendants()) do
            if sub:IsA("TextLabel") and isVisibleTextElement(sub) then
                local n = tonumber(stripRichText(sub.Text or ""))
                if n and n >= 1 then
                    return true
                end
            end
        end
    end
    return false
end

local function findOpenRewardsModal()
    -- Find the visible "PLAYTIME" tab button inside the "Rewards" window
    local playtimeTabBtn = nil
    local rewardsTitle = nil

    for _, d in ipairs(eachTextElement()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            local up = stripRichText(d.Text or ""):upper()
            if up == "PLAYTIME" then
                playtimeTabBtn = d
            elseif up == "REWARDS" then
                rewardsTitle = d
            end
        end
    end

    if not playtimeTabBtn then
        return nil
    end

    -- Walk up from PLAYTIME tab button to find the main Rewards modal Frame
    local modal = playtimeTabBtn.Parent
    while modal and modal.Parent and modal:IsA("GuiObject") do
        if modal.AbsoluteSize.X >= 260 and modal.AbsoluteSize.Y >= 220 then
            break
        end
        modal = modal.Parent
    end
    if not modal or not modal:IsA("GuiObject") then
        return nil
    end

    -- Locate the red "X" close button inside the Rewards modal header
    local closeBtn = nil
    for _, d in ipairs(modal:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            local up = stripRichText(d.Text or ""):upper()
            if up == "X" and d.AbsolutePosition.Y <= (modal.AbsolutePosition.Y + modal.AbsoluteSize.Y * 0.25) then
                closeBtn = d
                break
            end
        end
    end

    return {
        Modal = modal,
        PlaytimeTabBtn = playtimeTabBtn,
        RewardsTitle = rewardsTitle,
        CloseBtn = closeBtn,
    }
end

local function inspectPlaytimeGrid(modal)
    local readyLabels = {}
    local timerCount = 0
    local subtitleSeen = false
    local itemSlotCount = 0

    for _, d in ipairs(modal:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            local clean = stripRichText(d.Text or "")
            local up = clean:upper()

            if up:find("REWARDS FOR PLAYING", 1, true) then
                subtitleSeen = true
            elseif up == "READY!" then
                table.insert(readyLabels, d)
                itemSlotCount = itemSlotCount + 1
            elseif clean:match("^%d+:%d+$") then
                timerCount = timerCount + 1
                itemSlotCount = itemSlotCount + 1
            elseif up:find("CLAIMED", 1, true) or up:find("CRICKET", 1, true) or up:find("SHRIMP", 1, true)
                or up:find("SQUID", 1, true) or up:find("WORM", 1, true) or up:find("LURE", 1, true)
                or up:find("JACKPOT", 1, true)
            then
                itemSlotCount = itemSlotCount + 1
            end
        end
    end

    return {
        ReadyLabels = readyLabels,
        TimerCount = timerCount,
        SubtitleSeen = subtitleSeen,
        ItemSlotCount = itemSlotCount,
    }
end

local function stepAutoPlaytimeAndHop()
    if State.HoppingInProgress or isPurchasePromptOpen() then
        return
    end

    local now = os.clock()
    -- Wait 5s after joining a server so PlayerGui & rewards initialize
    if (now - State.JoinedAt) < 5.0 then
        return
    end
    if (now - State.LastPlaytimeScanAt) < 5.0 then
        return
    end
    State.LastPlaytimeScanAt = now

    local openInfo = findOpenRewardsModal()
    local hasReadySignal = hasHiddenOrVisibleReadyPlaytime()
    local duePeriodicVerify = (now - State.LastFullPlaytimeVerifyAt) >= 40.0

    if not openInfo and not hasReadySignal and not duePeriodicVerify then
        return
    end

    -- Open Rewards modal if it isn't open yet
    local openedByScript = false
    if not openInfo then
        local hudBtn = findRewardsHudOpenButton()
        if not hudBtn then
            return
        end
        clickGuiElement(hudBtn)
        openedByScript = true
        task.wait(0.35)
        openInfo = findOpenRewardsModal()
        if not openInfo then
            return
        end
    end

    State.LastFullPlaytimeVerifyAt = now

    -- Switch to PLAYTIME tab if subtitle isn't showing yet
    local grid = inspectPlaytimeGrid(openInfo.Modal)
    if not grid.SubtitleSeen and openInfo.PlaytimeTabBtn then
        clickGuiElement(openInfo.PlaytimeTabBtn)
        task.wait(0.30)
        grid = inspectPlaytimeGrid(openInfo.Modal)
    end

    -- Claim all "READY!" slots
    if #grid.ReadyLabels > 0 then
        State.PlaytimeStatus = string.format("Claiming %d READY Playtime reward(s)...", #grid.ReadyLabels)
        for _, rLbl in ipairs(grid.ReadyLabels) do
            if not State.Running then
                return
            end
            clickGuiElement(rLbl)
            task.wait(0.22)
        end
        task.wait(0.45)
        grid = inspectPlaytimeGrid(openInfo.Modal)
    end

    State.PlaytimeStatus = string.format(
        "Playtime: %d Ready | %d Timers left",
        #grid.ReadyLabels,
        grid.TimerCount
    )

    -- Check if ALL 9 Playtime rewards have been claimed (0 READY + 0 MM:SS timers while grid is loaded)
    if grid.SubtitleSeen and grid.ItemSlotCount >= 4 and #grid.ReadyLabels == 0 and grid.TimerCount == 0 then
        task.wait(1.0)
        local confirmGrid = inspectPlaytimeGrid(openInfo.Modal)
        if confirmGrid.SubtitleSeen and #confirmGrid.ReadyLabels == 0 and confirmGrid.TimerCount == 0 then
            if Config.ServerHopAfterPlaytime then
                serverHopToFreshServer()
                return
            else
                State.PlaytimeStatus = "All 9 Playtime rewards claimed!"
            end
        end
    end

    -- Close the Rewards modal cleanly if we opened it (so screen stays clear)
    if openedByScript and openInfo.CloseBtn then
        clickGuiElement(openInfo.CloseBtn)
    end
end

--============================================================================
-- RESOLUTION-INDEPENDENT MOTION-FIRST AUTO MIDDLE (RenderStepped)
--============================================================================
local CachedBar = {
    Header = nil,
    ScreenGui = nil,
    Cursor = nil,
    Track = nil,
    LastIdleScanAt = 0,
}

local function findTrackForCursor(cursor, searchRoot, screenW)
    local curSize = cursor.AbsoluteSize
    local curCy = cursor.AbsolutePosition.Y + curSize.Y * 0.5

    local anc = cursor.Parent
    while anc and anc ~= searchRoot and anc:IsA("GuiObject") do
        local sx, sy = anc.AbsoluteSize.X, anc.AbsoluteSize.Y
        if sx > curSize.X * 5 and sx >= screenW * 0.15 and sx <= screenW * 0.92 and sx > sy * 2.2 then
            return anc
        end
        anc = anc.Parent
    end

    local bestTrack = nil
    local bestDistY = math.huge
    for _, obj in ipairs(searchRoot:GetDescendants()) do
        if obj ~= cursor and obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
            local isOpaque = (obj.BackgroundTransparency < 0.95)
                or ((obj:IsA("ImageLabel") or obj:IsA("ImageButton")) and obj.ImageTransparency < 0.95)
            local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
            if isOpaque and sx > curSize.X * 5 and sx >= screenW * 0.15 and sx <= screenW * 0.92 and sx > sy * 2.2 then
                local cy = obj.AbsolutePosition.Y + sy * 0.5
                local distY = math.abs(cy - curCy)
                if distY <= curSize.Y * 1.2 and distY < bestDistY then
                    bestDistY = distY
                    bestTrack = obj
                end
            end
        end
    end
    return bestTrack
end

local function getActiveMinigameData()
    local now = os.clock()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    if CachedBar.Header and isVisibleTextElement(CachedBar.Header)
        and CachedBar.Cursor and isGuiChainVisible(CachedBar.Cursor)
    then
        local cursor = CachedBar.Cursor
        local cx = cursor.AbsolutePosition.X + cursor.AbsoluteSize.X * 0.5
        local cy = cursor.AbsolutePosition.Y + cursor.AbsoluteSize.Y * 0.5
        local prev = State.PrevMiddlePos[cursor]
        local vx = prev and (cx - prev.x) or 0
        State.PrevMiddlePos[cursor] = { x = cx, y = cy }

        local track = (CachedBar.Track and isGuiChainVisible(CachedBar.Track)) and CachedBar.Track or nil
        local middleX = track and (track.AbsolutePosition.X + track.AbsoluteSize.X * 0.5) or (screenW * 0.5)
        local yellowHalfW = track and (track.AbsoluteSize.X * 0.042) or (screenW * 0.018)

        return {
            ScreenGui = CachedBar.ScreenGui,
            Track = track,
            CurX = cx,
            Vx = vx,
            MiddleX = middleX,
            YellowHalfWidth = yellowHalfW,
        }
    end

    if not CachedBar.Header or not isVisibleTextElement(CachedBar.Header) then
        if (now - CachedBar.LastIdleScanAt) < 0.08 then
            return nil
        end
        CachedBar.LastIdleScanAt = now
        CachedBar.Header = nil
        CachedBar.Cursor = nil
        CachedBar.Track = nil

        for _, desc in ipairs(eachTextElement()) do
            if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
                local upper = stripRichText(desc.Text or ""):upper()
                if upper:find("STRENGTHEN", 1, true) or upper:find("TAP THE MIDDLE", 1, true) then
                    CachedBar.Header = desc
                    CachedBar.ScreenGui = desc:FindFirstAncestorWhichIsA("LayerCollector") or desc.Parent
                    break
                end
            end
        end

        if not CachedBar.Header then
            return nil
        end
    end

    local searchRoot = CachedBar.ScreenGui or PlayerGui
    local bestCursor = nil
    local bestSpeed = 0
    local bestVx = 0

    for _, obj in ipairs(searchRoot:GetDescendants()) do
        if obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
            local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
            if sx >= 2 and sx <= screenW * 0.12 and sy >= 8 and sy <= screenH * 0.35 and sx <= sy * 1.5 then
                local cx = obj.AbsolutePosition.X + sx * 0.5
                local cy = obj.AbsolutePosition.Y + sy * 0.5
                local prev = State.PrevMiddlePos[obj]
                State.PrevMiddlePos[obj] = { x = cx, y = cy }

                if prev then
                    local dx = cx - prev.x
                    local dy = cy - prev.y
                    if math.abs(dx) > 0.3 and math.abs(dy) < 1.5 then
                        if math.abs(dx) > bestSpeed then
                            bestSpeed = math.abs(dx)
                            bestVx = dx
                            bestCursor = obj
                        end
                    end
                end
            end
        end
    end

    if not bestCursor then
        return {
            ScreenGui = CachedBar.ScreenGui,
            WaitingForMotion = true,
        }
    end

    CachedBar.Cursor = bestCursor
    CachedBar.Track = findTrackForCursor(bestCursor, searchRoot, screenW)

    local cx = bestCursor.AbsolutePosition.X + bestCursor.AbsoluteSize.X * 0.5
    local track = CachedBar.Track
    local middleX = track and (track.AbsolutePosition.X + track.AbsoluteSize.X * 0.5) or (screenW * 0.5)
    local yellowHalfW = track and (track.AbsoluteSize.X * 0.042) or (screenW * 0.018)

    return {
        ScreenGui = CachedBar.ScreenGui,
        Track = track,
        CurX = cx,
        Vx = bestVx,
        MiddleX = middleX,
        YellowHalfWidth = yellowHalfW,
    }
end

local function stepAutoMiddle()
    if not State.Running or not Config.AutoPerfect then
        return
    end

    local data = getActiveMinigameData()
    if not data or data.WaitingForMotion then
        return
    end

    local now = os.clock()
    if (now - State.LastPerfectTapAt) < 0.30 then
        return
    end

    local curX = data.CurX
    local vx = data.Vx
    local prevX = curX - vx
    local predictedX = curX + vx * 0.85
    local middleX = data.MiddleX
    local tolerance = math.max(data.YellowHalfWidth * 0.65, 4)

    local prevDelta = prevX - middleX
    local predDelta = predictedX - middleX

    local insideYellow = math.abs(predDelta) <= tolerance
    local crossedMiddle = (math.abs(vx) > 0.3)
        and ((prevDelta <= 0 and predDelta >= 0) or (prevDelta >= 0 and predDelta <= 0))

    if insideYellow or crossedMiddle then
        if fireInstantMiddleTap(data.ScreenGui, data.Track) then
            State.LastPerfectTapAt = now
        end
    end
end

--============================================================================
-- VERTICAL BAR DETECTOR: AUTO PERFECT REEL ("TAP TO CAST!" / "+25")
--============================================================================
local CachedReelBar = {
    Header = nil,
    ScreenGui = nil,
    Cursor = nil,
    Track = nil,
    FallbackTopY = nil,
    LastIdleScanAt = 0,
}

local function findVerticalTrackForCursor(cursor, searchRoot, screenH)
    local curSize = cursor.AbsoluteSize
    local curCx = cursor.AbsolutePosition.X + curSize.X * 0.5

    local anc = cursor.Parent
    while anc and anc ~= searchRoot and anc:IsA("GuiObject") do
        local sx, sy = anc.AbsoluteSize.X, anc.AbsoluteSize.Y
        if sy > curSize.Y * 4 and sy >= screenH * 0.18 and sy <= screenH * 0.92 and sy > sx * 2.0 then
            return anc
        end
        anc = anc.Parent
    end

    local bestTrack = nil
    local bestDistX = math.huge
    for _, obj in ipairs(searchRoot:GetDescendants()) do
        if obj ~= cursor and obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
            local isOpaque = (obj.BackgroundTransparency < 0.95)
                or ((obj:IsA("ImageLabel") or obj:IsA("ImageButton")) and obj.ImageTransparency < 0.95)
            local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
            if isOpaque and sy > curSize.Y * 4 and sy >= screenH * 0.18 and sy <= screenH * 0.92 and sy > sx * 2.0 then
                local cx = obj.AbsolutePosition.X + sx * 0.5
                local distX = math.abs(cx - curCx)
                if distX <= math.max(curSize.X * 1.2, 60) and distX < bestDistX then
                    bestDistX = distX
                    bestTrack = obj
                end
            end
        end
    end
    return bestTrack
end

local function findTopPerfectAnchorY(searchRoot)
    for _, desc in ipairs(searchRoot:GetDescendants()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
            local upper = stripRichText(desc.Text or ""):upper()
            if upper:find("^%+25") or upper:find("ALWAYS PERFECT", 1, true) then
                return desc.AbsolutePosition.Y + desc.AbsoluteSize.Y * 0.5
            end
        end
    end
    return nil
end

local function getActiveReelBarData()
    local now = os.clock()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    if CachedReelBar.Header and isVisibleTextElement(CachedReelBar.Header)
        and CachedReelBar.Cursor and isGuiChainVisible(CachedReelBar.Cursor)
    then
        local cursor = CachedReelBar.Cursor
        local cx = cursor.AbsolutePosition.X + cursor.AbsoluteSize.X * 0.5
        local cy = cursor.AbsolutePosition.Y + cursor.AbsoluteSize.Y * 0.5
        local prev = State.PrevReelPos[cursor]
        local vy = prev and (cy - prev.y) or 0
        State.PrevReelPos[cursor] = { x = cx, y = cy }

        local track = (CachedReelBar.Track and isGuiChainVisible(CachedReelBar.Track)) and CachedReelBar.Track or nil
        local topY = track and track.AbsolutePosition.Y or CachedReelBar.FallbackTopY or (screenH * 0.21)
        local barH = track and track.AbsoluteSize.Y or (screenH * 0.52)

        return {
            ScreenGui = CachedReelBar.ScreenGui,
            Track = track,
            CurY = cy,
            Vy = vy,
            TopY = topY,
            BarHeight = barH,
        }
    end

    if not CachedReelBar.Header or not isVisibleTextElement(CachedReelBar.Header) then
        if (now - CachedReelBar.LastIdleScanAt) < 0.08 then
            return nil
        end
        CachedReelBar.LastIdleScanAt = now
        CachedReelBar.Header = nil
        CachedReelBar.Cursor = nil
        CachedReelBar.Track = nil
        CachedReelBar.FallbackTopY = nil

        for _, desc in ipairs(eachTextElement()) do
            if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
                local upper = stripRichText(desc.Text or ""):upper()
                if upper:find("TAP TO CAST", 1, true)
                    or upper:find("TAP TO REEL", 1, true)
                    or upper:find("ALWAYS PERFECT", 1, true)
                then
                    CachedReelBar.Header = desc
                    CachedReelBar.ScreenGui = desc:FindFirstAncestorWhichIsA("LayerCollector") or desc.Parent
                    break
                end
            end
        end

        if not CachedReelBar.Header then
            return nil
        end
    end

    local searchRoot = CachedReelBar.ScreenGui or PlayerGui
    local bestCursor = nil
    local bestSpeed = 0
    local bestVy = 0

    for _, obj in ipairs(searchRoot:GetDescendants()) do
        if obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
            local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
            if sy >= 2 and sy <= screenH * 0.12 and sx >= 12 and sx <= screenW * 0.35 and sy <= sx * 1.3 then
                local cx = obj.AbsolutePosition.X + sx * 0.5
                local cy = obj.AbsolutePosition.Y + sy * 0.5
                local prev = State.PrevReelPos[obj]
                State.PrevReelPos[obj] = { x = cx, y = cy }

                if prev then
                    local dx = cx - prev.x
                    local dy = cy - prev.y
                    if math.abs(dy) > 0.3 and math.abs(dx) < 1.5 then
                        if math.abs(dy) > bestSpeed then
                            bestSpeed = math.abs(dy)
                            bestVy = dy
                            bestCursor = obj
                        end
                    end
                end
            end
        end
    end

    if not bestCursor then
        return {
            ScreenGui = CachedReelBar.ScreenGui,
            WaitingForMotion = true,
        }
    end

    CachedReelBar.Cursor = bestCursor
    CachedReelBar.Track = findVerticalTrackForCursor(bestCursor, searchRoot, screenH)
    CachedReelBar.FallbackTopY = findTopPerfectAnchorY(searchRoot)

    local cy = bestCursor.AbsolutePosition.Y + bestCursor.AbsoluteSize.Y * 0.5
    local track = CachedReelBar.Track
    local topY = track and track.AbsolutePosition.Y or CachedReelBar.FallbackTopY or (screenH * 0.21)
    local barH = track and track.AbsoluteSize.Y or (screenH * 0.52)

    return {
        ScreenGui = CachedReelBar.ScreenGui,
        Track = track,
        CurY = cy,
        Vy = bestVy,
        TopY = topY,
        BarHeight = barH,
    }
end

local function stepAutoPerfectReel()
    if not State.Running or not Config.AutoPerfectReel then
        return
    end

    local data = getActiveReelBarData()
    if not data or data.WaitingForMotion then
        return
    end

    local now = os.clock()
    if (now - State.LastReelTapAt) < 0.35 then
        return
    end

    local curY = data.CurY
    local vy = data.Vy
    local predictedY = curY + vy * 0.85
    local topY = data.TopY
    local perfectZoneBottom = topY + math.max(data.BarHeight * 0.042, 6)
    local perfectZoneTop = topY - math.max(data.BarHeight * 0.06, 12)

    if predictedY <= perfectZoneBottom and curY >= perfectZoneTop and vy <= 1.0 then
        if fireInstantMiddleTap(data.ScreenGui, data.Track) then
            State.LastReelTapAt = now
        end
    end
end

--============================================================================
-- TIER LADDER DETECTOR + REEL IN / GO DEEPER
--============================================================================
local function detectTierFromLadder(searchRoot)
    local seaKingLabel = nil
    for _, desc in ipairs(searchRoot:GetDescendants()) do
        if desc:IsA("TextLabel") and isVisibleTextElement(desc) then
            if stripRichText(desc.Text or ""):upper() == "SEA KING" then
                seaKingLabel = desc
                break
            end
        end
    end
    if not seaKingLabel then
        return nil
    end

    local cur = seaKingLabel.Parent
    local ladderContainer = nil
    for _ = 1, 3 do
        if not cur or cur == searchRoot then
            break
        end
        local boxCount = 0
        for _, child in ipairs(cur:GetChildren()) do
            if child:IsA("GuiObject") and child.Visible and child.AbsoluteSize.Y > 8 then
                boxCount = boxCount + 1
            end
        end
        if boxCount >= 8 and boxCount <= 12 then
            ladderContainer = cur
            break
        end
        cur = cur.Parent
    end

    if not ladderContainer then
        return nil
    end

    local boxes = {}
    for _, child in ipairs(ladderContainer:GetChildren()) do
        if child:IsA("GuiObject") and child.Visible and child.AbsoluteSize.Y > 8 then
            table.insert(boxes, child)
        end
    end
    table.sort(boxes, function(a, b)
        return a.AbsolutePosition.Y < b.AbsolutePosition.Y
    end)

    for idx, box in ipairs(boxes) do
        for _, d in ipairs(box:GetDescendants()) do
            if d:IsA(CLS_BORDER) and d.Enabled and d.Thickness > 0.5 then
                local parentIsText = d.Parent and (d.Parent:IsA("TextLabel") or d.Parent:IsA("TextButton"))
                if not parentIsText and d.Color.R > 0.78 and d.Color.G > 0.78 and d.Color.B > 0.78 then
                    return math.clamp(idx, 1, 10)
                end
            end
        end
        local directBorder = box:FindFirstChildOfClass(CLS_BORDER)
        if directBorder and directBorder.Enabled and directBorder.Color.R > 0.78 and directBorder.Color.G > 0.78 and directBorder.Color.B > 0.78 then
            return math.clamp(idx, 1, 10)
        end
    end

    local widths = {}
    for i = 1, math.min(9, #boxes) do
        table.insert(widths, boxes[i].AbsoluteSize.X)
    end
    table.sort(widths)
    local medianW = widths[math.ceil(#widths * 0.5)] or 0
    if medianW > 0 then
        for i = 1, math.min(9, #boxes) do
            if boxes[i].AbsoluteSize.X > medianW * 1.12 then
                return i
            end
        end
    end

    return nil
end

local function findDecisionContext()
    local reelLabel = nil
    local deeperLabel = nil

    for _, desc in ipairs(eachTextElement()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
            local upper = stripRichText(desc.Text or ""):upper()
            if upper == "REEL IN" or upper:find("^REEL IN") then
                reelLabel = desc
            elseif upper == "GO DEEPER" or upper:find("^GO DEEPER") then
                deeperLabel = desc
            end
        end
    end

    if not reelLabel and not deeperLabel then
        return nil
    end

    local searchRoot = (reelLabel or deeperLabel):FindFirstAncestorWhichIsA("LayerCollector") or PlayerGui
    local doubloonsText = ""
    local isFirstTierUncommonNext = false

    for _, desc in ipairs(searchRoot:GetDescendants()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
            local clean = stripRichText(desc.Text or "")
            local upper = clean:upper()
            if upper:find("DOUBLOON", 1, true) then
                doubloonsText = clean
            end
            if upper:find("UNCOMMON", 1, true) and upper:find("SNAP", 1, true) then
                isFirstTierUncommonNext = true
            end
        end
    end

    local ladderTier = detectTierFromLadder(searchRoot)
    if isFirstTierUncommonNext then
        ladderTier = 1
    end

    return {
        ReelLabel = reelLabel,
        DeeperLabel = deeperLabel,
        LadderTier = ladderTier,
        Signature = string.format("%s|%s", doubloonsText, tostring(ladderTier or "?")),
    }
end

--============================================================================
-- FISH AGAIN, AUTO 2X & AUTO UPGRADE
--============================================================================
local function tryClickFishAgain()
    for _, desc in ipairs(eachTextElement()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
            if stripRichText(desc.Text or ""):upper() == "FISH AGAIN" then
                if clickGuiElement(desc) then
                    return true
                end
            end
        end
    end
    return false
end

local function tryClick2x()
    if isPurchasePromptOpen() then
        return false
    end
    for _, desc in ipairs(eachTextElement()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isVisibleTextElement(desc) then
            if stripRichText(desc.Text or ""):lower() == "2x" and desc.AbsolutePosition.Y > 90 and isSafeGameplayElement(desc) then
                if clickGuiElement(desc) then
                    return true
                end
            end
        end
    end
    return false
end

local function tryUpgradePrompt()
    if isPurchasePromptOpen() then
        return false
    end
    local prompt = findNearestPromptMatching(function(actionText)
        return actionText:find("upgrade", 1, true) ~= nil
    end)
    if prompt then
        return triggerPrompt(prompt)
    end
    return false
end

--============================================================================
-- SHORE PANEL FISHING (BAIT / FISH / AUTO / BACK TO SHORE)
-- Handles the on-shore fishing panel: casts with FISH, toggles the in-game
-- AUTO button once per session, clears catch popups, and (optionally) reels
-- by holding/releasing the screen to keep the fish marker inside the catch
-- window. One cached ScreenGui registry - no per-frame descendant scans.
--============================================================================
local Shore = {
    LastScanAt = 0,
    ScanIndex = 0,
    Root = nil,
    Items = {},
    Conns = {},
    FishBtn = nil,
    AutoBtn = nil,
    BackBtn = nil,
    Marker = nil,
    Zone = nil,
    PrevX = {},
    Holding = false,
    HoldPoint = nil,
    LastHoldChangeAt = 0,
    LastCastAt = 0,
    LastPopupAt = 0,
    LastEnterAt = 0,
    LastAUTOAt = 0,
    AutoTapCount = 0,
    LastReelAt = 0,
    LastRescueAt = 0,
    LastDiscoverAt = 0,
    ForceRescan = false,
    Active = false,
    Status = "",
    LastAction = nil,
}

local SHORE_POPUP_WORDS = {
    ["COLLECT"] = true,
    ["COLLECT ALL"] = true,
    ["CLAIM"] = true,
    ["CONTINUE"] = true,
    ["TAP TO CONTINUE"] = true,
    ["OK"] = true,
    ["NICE"] = true,
    ["GREAT"] = true,
}

local SHORE_MARKER_HINTS = { "indicator", "pointer", "hook", "marker", "bobber", "sprite", "fishicon", "needle", "handle", "cursor" }
local SHORE_ZONE_HINTS = { "zone", "window", "slider", "catch", "sweet", "perfect", "rail", "track", "bar", "range" }
local SHORE_REEL_SCAN_FOUND = 0.5
local SHORE_REEL_SCAN_IDLE = 0.3

local function shoreLabel(obj)
    if obj:IsA("TextBox") then
        return ""
    end
    local txt = stripRichText(obj.Text or "")
    txt = string.gsub(txt, "%s+", " ")
    txt = string.gsub(txt, "^%s*(.-)%s*$", "%1")
    return string.upper(txt)
end

local function shoreViewport()
    local cam = Workspace.CurrentCamera
    return (cam and cam.ViewportSize) or Vector2.new(1280, 720)
end

--------------------------------------------------------------------------
-- Cached registry
--------------------------------------------------------------------------
local function shoreForget(inst)
    for i = #Shore.Items, 1, -1 do
        local item = Shore.Items[i]
        if item == inst or not item.Parent or inst:IsDescendantOf(item) then
            table.remove(Shore.Items, i)
            Shore.PrevX[item] = nil
        end
    end
end

local function shoreDetach()
    for _, c in ipairs(Shore.Conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(Shore.Conns)
    table.clear(Shore.Items)
    table.clear(Shore.PrevX)
    Shore.Root = nil
    Shore.FishBtn = nil
    Shore.AutoBtn = nil
    Shore.BackBtn = nil
    Shore.Marker = nil
    Shore.Zone = nil
    Shore.Active = false
    Shore.AutoTapCount = 0
    Shore.LastReelAt = os.clock()
    Shore.LastRescueAt = 0
end

local function shoreAttach(root)
    shoreDetach()
    Shore.Root = root
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("GuiObject") and #Shore.Items < 2000 then
            table.insert(Shore.Items, d)
        end
    end
    table.insert(Shore.Conns, root.DescendantAdded:Connect(function(inst)
        if inst:IsA("GuiObject") and #Shore.Items < 2000 then
            table.insert(Shore.Items, inst)
        end
    end))
    table.insert(Shore.Conns, root.DescendantRemoving:Connect(shoreForget))
    table.insert(Shore.Conns, root.AncestryChanged:Connect(function(_, parent)
        if not parent then
            shoreDetach()
        end
    end))
end

-- The panel is drawn as three wide bars in a fixed row at the bottom of the
-- screen, so we can find them by position even when the labels are images.
local SHORE_SLOT_ZONES = {
    BackBtn = { 0.27, 0.49, 0.80, 0.98 },
    FishBtn = { 0.49, 0.70, 0.80, 0.98 },
    AutoBtn = { 0.70, 0.88, 0.80, 0.98 },
}

local function shoreSlotButtonCount(gui)
    local vp = shoreViewport()
    local hits = 0
    for _, d in ipairs(gui:GetDescendants()) do
        if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
            local sx, sy = d.AbsoluteSize.X, d.AbsoluteSize.Y
            if sx >= vp.X * 0.07 and sy >= vp.Y * 0.045 then
                local cx = (d.AbsolutePosition.X + sx * 0.5) / vp.X
                local cy = (d.AbsolutePosition.Y + sy * 0.5) / vp.Y
                if cx >= 0.27 and cx <= 0.88 and cy >= 0.80 and cy <= 0.98 then
                    hits = hits + 1
                end
            end
        end
    end
    return hits
end

local function shoreSlotCandidates()
    local vp = shoreViewport()
    local found = { FishBtn = nil, AutoBtn = nil, BackBtn = nil }
    local bestArea = { FishBtn = 0, AutoBtn = 0, BackBtn = 0 }
    for i = #Shore.Items, 1, -1 do
        local d = Shore.Items[i]
        if not d.Parent then
            table.remove(Shore.Items, i)
        elseif (d:IsA("TextButton") or d:IsA("ImageButton")) and isGuiChainVisible(d) then
            local sx, sy = d.AbsoluteSize.X, d.AbsoluteSize.Y
            if sx >= vp.X * 0.07 and sy >= vp.Y * 0.045 then
                local cx = (d.AbsolutePosition.X + sx * 0.5) / vp.X
                local cy = (d.AbsolutePosition.Y + sy * 0.5) / vp.Y
                for key, z in pairs(SHORE_SLOT_ZONES) do
                    if cx >= z[1] and cx <= z[2] and cy >= z[3] and cy <= z[4] then
                        local area = sx * sy
                        if area > bestArea[key] then
                            bestArea[key] = area
                            found[key] = d
                        end
                    end
                end
            end
        end
    end
    return found
end

local function looksLikeShorePanel(gui)
    if not gui:IsA("ScreenGui") or not gui.Enabled then
        return false
    end
    local hasFishBtn = false
    local hasCompanion = false
    local scanned = 0
    for _, d in ipairs(gui:GetDescendants()) do
        scanned = scanned + 1
        if scanned > 1400 then
            break
        end
        if (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Visible then
            local label = shoreLabel(d)
            if label == "FISH" or label == "CAST" or label == "CAST LINE" then
                hasFishBtn = true
            elseif label == "BACK TO SHORE" or label == "AUTO" or label == "BAIT" then
                hasCompanion = true
            end
        end
    end
    if hasFishBtn and hasCompanion then
        return true
    end
    return shoreSlotButtonCount(gui) >= 2
end

local function shoreFindRoot()
    local kids = PlayerGui:GetChildren()
    if #kids == 0 then
        return nil
    end
    Shore.ScanIndex = (Shore.ScanIndex % #kids) + 1
    local candidate = kids[Shore.ScanIndex]
    if candidate and candidate:IsA("ScreenGui") and candidate.Enabled and looksLikeShorePanel(candidate) then
        return candidate
    end
    return nil
end

local function shoreRefreshRoot()
    local now = os.clock()
    if (now - Shore.LastScanAt) < 0.35 and not Shore.ForceRescan then
        return
    end
    Shore.LastScanAt = now
    Shore.ForceRescan = false
    if Shore.Root and Shore.Root.Parent and Shore.Root.Enabled then
        return
    end
    local found = shoreFindRoot()
    if found then
        shoreAttach(found)
    elseif Shore.Root then
        shoreDetach()
    end
end

local function shoreRefreshButtons()
    Shore.FishBtn = nil
    Shore.AutoBtn = nil
    Shore.BackBtn = nil
    if not Shore.Root then
        return
    end
    local lowerScreenGui = 0
    -- pass 1: text / name match
    for i = #Shore.Items, 1, -1 do
        local d = Shore.Items[i]
        if not d.Parent then
            table.remove(Shore.Items, i)
        elseif (d:IsA("TextButton") or d:IsA("ImageButton")) and isGuiChainVisible(d) then
            local label = d:IsA("TextButton") and shoreLabel(d) or ""
            local nl = string.lower(d.Name)
            local nameIsFish = string.find(nl, "fish", 1, true) ~= nil
                and string.find(nl, "again", 1, true) == nil
            if not Shore.FishBtn and (label == "FISH" or label == "CAST" or label == "CAST LINE" or nameIsFish) then
                Shore.FishBtn = d
            elseif not Shore.AutoBtn and label == "AUTO" then
                Shore.AutoBtn = d
            elseif not Shore.BackBtn and label == "BACK TO SHORE" then
                Shore.BackBtn = d
            end
        end
    end
    -- pass 2: fixed bottom-row slots (labels may be images with no text at all)
    if not (Shore.FishBtn and Shore.AutoBtn) then
        local found = shoreSlotCandidates()
        Shore.FishBtn = Shore.FishBtn or found.FishBtn
        Shore.AutoBtn = Shore.AutoBtn or found.AutoBtn
        Shore.BackBtn = Shore.BackBtn or found.BackBtn
    end
end

--------------------------------------------------------------------------
-- Held screen input (reel control)
--------------------------------------------------------------------------
local SHORE_HOLD_POINTS = {
    { 0.50, 0.46 },
    { 0.44, 0.52 },
    { 0.56, 0.40 },
    { 0.50, 0.58 },
    { 0.38, 0.44 },
    { 0.62, 0.44 },
}

local function shorePointOnButton(vpX, vpY)
    for i = 1, #Shore.Items do
        local d = Shore.Items[i]
        if d.Parent and (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
            local p, s = d.AbsolutePosition, d.AbsoluteSize
            if vpX >= p.X and vpX <= p.X + s.X and vpY >= p.Y and vpY <= p.Y + s.Y then
                return true
            end
        end
    end
    return false
end

local function shorePickHoldPoint()
    local vp = shoreViewport()
    for _, pt in ipairs(SHORE_HOLD_POINTS) do
        local x, y = vp.X * pt[1], vp.Y * pt[2]
        if not isPointCoveredByRayfield(x, y) and not shorePointOnButton(x, y) then
            return math.floor(x), math.floor(y)
        end
    end
    return math.floor(vp.X * 0.5), math.floor(vp.Y * 0.46)
end

local function shoreSetHold(on)
    if on == Shore.Holding then
        return
    end
    if (os.clock() - Shore.LastHoldChangeAt) < 0.05 then
        return
    end
    Shore.LastHoldChangeAt = os.clock()
    Shore.Holding = on

    if on then
        local vpX, vpY = shorePickHoldPoint()
        Shore.HoldPoint = Vector2.new(vpX, vpY)
        pcall(function()
            if typeof(mouse1press) == "function" then
                mouse1press()
            end
        end)
        if VirtualInputManager then
            pcall(function()
                VirtualInputManager:SendTouchEvent(7, 1, vpX, vpY)
            end)
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(vpX, vpY, 0, true, game, 1)
            end)
        elseif VirtualUser then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:Button1Down(Vector2.new(vpX, vpY))
            end)
        end
    else
        local p = Shore.HoldPoint or Vector2.new(shoreViewport().X * 0.5, shoreViewport().Y * 0.46)
        pcall(function()
            if typeof(mouse1release) == "function" then
                mouse1release()
            end
        end)
        if VirtualInputManager then
            pcall(function()
                VirtualInputManager:SendTouchEvent(7, 2, p.X, p.Y)
            end)
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
            end)
        elseif VirtualUser then
            pcall(function()
                VirtualUser:Button1Up(Vector2.new(p.X, p.Y))
            end)
        end
    end
end

--------------------------------------------------------------------------
-- Reel detection: moving square fish marker + wide catch window
--------------------------------------------------------------------------
local function shoreDiscoverReel(now)
    local gap = (Shore.Marker and Shore.Zone) and SHORE_REEL_SCAN_FOUND or SHORE_REEL_SCAN_IDLE
    if (now - Shore.LastDiscoverAt) < gap then
        return
    end
    Shore.LastDiscoverAt = now
    Shore.Marker = nil
    Shore.Zone = nil
    if not Shore.Root then
        return
    end

    local vp = shoreViewport()
    local bandMinY, bandMaxY = vp.Y * 0.30, vp.Y * 0.99
    local markerBest, zoneBest = nil, nil

    for i = #Shore.Items, 1, -1 do
        local d = Shore.Items[i]
        if not d.Parent then
            table.remove(Shore.Items, i)
        elseif (d:IsA("Frame") or d:IsA("ImageLabel") or d:IsA("ImageButton"))
            and d.Visible and isGuiChainVisible(d) then
            local sz = d.AbsoluteSize
            local ap = d.AbsolutePosition
            local cy = ap.Y + sz.Y * 0.5
            if sz.X >= 6 and sz.Y >= 6 and cy >= bandMinY and cy <= bandMaxY and sz.X <= vp.X * 0.9 then
                local cx = ap.X + sz.X * 0.5
                local prev = Shore.PrevX[d]
                Shore.PrevX[d] = cx
                local moved = prev ~= nil and math.abs(cx - prev) >= 0.8
                local nl = string.lower(d.Name)
                local nameMarker, nameZone = false, false
                for _, hint in ipairs(SHORE_MARKER_HINTS) do
                    if string.find(nl, hint, 1, true) then
                        nameMarker = true
                        break
                    end
                end
                for _, hint in ipairs(SHORE_ZONE_HINTS) do
                    if string.find(nl, hint, 1, true) then
                        nameZone = true
                        break
                    end
                end
                local nearSquare = math.abs(sz.X - sz.Y) <= math.max(sz.X, sz.Y) * 0.55
                local smallish = sz.X <= vp.X * 0.18 and sz.Y <= vp.Y * 0.18
                local wideBar = sz.X >= vp.X * 0.08 and sz.X >= sz.Y * 2.2

                if (nameMarker or (nearSquare and smallish)) and (moved or nameMarker) then
                    local score = (nameMarker and 100 or 0) + (moved and 20 or 0) + math.max(0, 40 - sz.X * 0.05)
                    if not markerBest or score > markerBest.score then
                        markerBest = { obj = d, score = score, cx = cx, cy = cy }
                    end
                end
                if nameZone or wideBar then
                    local score = (nameZone and 100 or 0) + sz.X * 0.1
                    if not zoneBest or score > zoneBest.score then
                        zoneBest = { obj = d, score = score, cx = cx, cy = cy, w = sz.X }
                    end
                end
            end
        end
    end

    if markerBest and zoneBest then
        if math.abs(markerBest.cy - zoneBest.cy) <= vp.Y * 0.22 then
            Shore.Marker = markerBest
            Shore.Zone = zoneBest
        else
            Shore.Marker = markerBest
        end
    end
end

local function shoreUpdateReel()
    local m, z = Shore.Marker, Shore.Zone
    if not m or not z then
        return false
    end
    if not m.obj.Parent or not z.obj.Parent then
        Shore.Marker = nil
        Shore.Zone = nil
        return false
    end
    if not isGuiChainVisible(m.obj) or not isGuiChainVisible(z.obj) then
        return false
    end
    local inset = GuiService:GetGuiInset()
    m.cx = m.obj.AbsolutePosition.X + m.obj.AbsoluteSize.X * 0.5 + inset.X
    z.cx = z.obj.AbsolutePosition.X + z.obj.AbsoluteSize.X * 0.5 + inset.X
    z.w = z.obj.AbsoluteSize.X
    return true
end

local function shoreDriveReel(now)
    if not Shore.Marker or not Shore.Zone then
        shoreSetHold(false)
        return false
    end
    local tol = math.max(6, (Shore.Zone.w or 40) * 0.22)
    local err = Shore.Marker.cx - Shore.Zone.cx
    local wantHold
    if Config.ShoreInvert then
        wantHold = err < -tol
    else
        wantHold = err > tol
    end
    shoreSetHold(wantHold)
    return true
end

--------------------------------------------------------------------------
-- Popups, AUTO, cast, enter
--------------------------------------------------------------------------
local function shoreTapPopups(now)
    if not Config.ShorePopups then
        return
    end
    if (now - Shore.LastPopupAt) < 0.9 then
        return
    end
    Shore.LastPopupAt = now
    for i = #Shore.Items, 1, -1 do
        local d = Shore.Items[i]
        if not d.Parent then
            table.remove(Shore.Items, i)
        elseif (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Visible and isGuiChainVisible(d) then
            local label = d:IsA("TextButton") and shoreLabel(d) or ""
            if SHORE_POPUP_WORDS[label] == true then
                local btn = d:IsA("TextButton") and d or d:FindFirstAncestorWhichIsA("TextButton")
                if btn and clickGuiElement(btn) then
                    return
                end
            end
        end
    end
end

local function shoreTapGameAuto(now)
    if Config.ShoreReelMethod ~= "Game AUTO button" then
        return
    end
    if not Shore.AutoBtn or not isGuiChainVisible(Shore.AutoBtn) then
        return
    end
    if (now - Shore.LastAUTOAt) < (Shore.AutoTapCount > 0 and 45.0 or 0.4) then
        return
    end
    Shore.LastAUTOAt = now
    Shore.AutoTapCount = Shore.AutoTapCount + 1
    clickGuiElement(Shore.AutoBtn)
end

local function shoreTryEnter(now)
    if Shore.Active then
        return
    end
    if (now - Shore.LastEnterAt) < 4.0 then
        return
    end
    Shore.LastEnterAt = now
    local prompt = findNearestPromptMatching(function(actionText, objectText)
        return actionText:find("fish", 1, true) ~= nil
            or objectText:find("fish", 1, true) ~= nil
            or objectText:find("shore", 1, true) ~= nil
            or actionText:find("cast", 1, true) ~= nil
    end)
    if prompt then
        triggerPrompt(prompt)
    end
end

--------------------------------------------------------------------------
-- Public step
--------------------------------------------------------------------------
local ShoreStatusPara = nil

local function shoreSetStatus(txt)
    if Shore.Status == txt then
        return
    end
    Shore.Status = txt
    if ShoreStatusPara then
        pcall(function()
            ShoreStatusPara:Set({
                Title = "Shore Panel",
                Content = txt,
            })
        end)
    end
end

local function stepShorePanel(now, blocked)
    if not Config.AutoFish then
        if Shore.Holding then
            shoreSetHold(false)
        end
        Shore.Active = false
        return false
    end

    shoreRefreshRoot()
    local rootVisible = Shore.Root and Shore.Root.Parent
        and (not Shore.Root:IsA("LayerCollector") or Shore.Root.Enabled)
    if not rootVisible then
        Shore.Active = false
        if Shore.Holding then
            shoreSetHold(false)
        end
        shoreSetStatus("Waiting for the shore panel (BAIT / FISH / AUTO)...")
        shoreTryEnter(now)
        return false
    end

    Shore.Active = true
    shoreRefreshButtons()
    local fishBtnVisible = Shore.FishBtn ~= nil and isGuiChainVisible(Shore.FishBtn)
    local autoBtnVisible = Shore.AutoBtn ~= nil and isGuiChainVisible(Shore.AutoBtn)
    local backBtnVisible = Shore.BackBtn ~= nil and isGuiChainVisible(Shore.BackBtn)
    shoreSetStatus(string.format("FISH: %s | AUTO: %s | BACK: %s%s",
        fishBtnVisible and "ready" or "NOT SEEN",
        autoBtnVisible and "ready" or "NOT SEEN",
        backBtnVisible and "ready" or "NOT SEEN",
        Shore.LastAction and ("  —  " .. Shore.LastAction) or ""))

    shoreDiscoverReel(now)

    -- 1) Reeling: only take over when the hub's own reel controller is off
    if shoreUpdateReel() then
        Shore.LastReelAt = now
        if Config.ShoreReelMethod == "Script reel" and not Config.AutoPerfectReel then
            shoreDriveReel(now)
        else
            shoreSetHold(false)
        end
        return true
    end

    shoreSetHold(false)

    -- 2) Panel not actually on screen -> hand control back to the normal
    --    fishing flow (FISH AGAIN button / fishing prompts) instead of holding it.
    if not fishBtnVisible then
        shoreSetStatus("Shore panel not on screen")
        return false
    end

    shoreTapPopups(now)

    -- 3) Never cast while the hub is mid-minigame or picking a tier
    if blocked then
        return true
    end

    local mode = Config.ShoreReelMethod

    -- Press the in-game AUTO once if that mode is selected (optional extra)
    if mode == "Game AUTO button" then
        shoreTapGameAuto(now)
    end

    -- Every mode taps the green FISH bar; only the gap differs.
    local castGap = 1.6
    if mode == "Script reel" then
        castGap = 2.8
    elseif mode == "Game AUTO button" then
        castGap = 1.8
    end

    if (now - Shore.LastCastAt) >= castGap then
        Shore.LastCastAt = now
        if clickGuiElement(Shore.FishBtn) then
            State.LastCastAt = now
            Shore.LastAction = "FISH tap"
        end
    end
    return true
end

local function stopShorePanel()
    shoreSetHold(false)
    pcall(shoreDetach)
    Shore.Active = false
end

--============================================================================
-- BUILD RAYFIELD UI ("perdi")
--============================================================================
local Window = Rayfield:CreateWindow({
    Name = "perdi",
    Icon = 0,
    LoadingTitle = "perdi",
    LoadingSubtitle = "Auto Fish, Train & Playtime Hop",
    Theme = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = true,
    ConfigurationSaving = {
        Enabled = false,
        FolderName = "perdiHub",
        FileName = "perdiConfig",
    },
    Discord = {
        Enabled = false,
        Invite = "",
        RememberJoins = false,
    },
    KeySystem = false,
})

-- TAB 1: MAIN (Fishing & Training)
local MainTab = Window:CreateTab("Main", 4483362458)

MainTab:CreateSection("Fishing")

local AutoPerfectToggle = nil

MainTab:CreateToggle({
    Name = "Auto Fish",
    CurrentValue = Config.AutoFish,
    Callback = function(Value)
        Config.AutoFish = Value
        if Value and not Config.AutoPerfect then
            Config.AutoPerfect = true
            if AutoPerfectToggle then
                pcall(function()
                    AutoPerfectToggle:Set(true)
                end)
            end
        end
        savePersistentConfig()
    end,
})

AutoPerfectToggle = MainTab:CreateToggle({
    Name = "Auto Perfect (Middle Bar)",
    CurrentValue = Config.AutoPerfect,
    Callback = function(Value)
        Config.AutoPerfect = Value
        savePersistentConfig()
    end,
})

MainTab:CreateToggle({
    Name = "Auto Perfect Reel",
    CurrentValue = Config.AutoPerfectReel,
    Callback = function(Value)
        Config.AutoPerfectReel = Value
        savePersistentConfig()
    end,
})

MainTab:CreateSlider({
    Name = "Stop at Tier (10 = SEA KING)",
    Range = { 1, 10 },
    Increment = 1,
    Suffix = " Tier",
    CurrentValue = Config.StopAtTier,
    Callback = function(Value)
        Config.StopAtTier = Value
        savePersistentConfig()
    end,
})

MainTab:CreateSection("Shore Panel (BAIT / FISH / AUTO)")

MainTab:CreateDropdown({
    Name = "Shore Cast Mode",
    Options = { "Tap FISH only", "Game AUTO button", "Script reel" },
    CurrentOption = { Config.ShoreReelMethod },
    MultipleOptions = false,
    Callback = function(Options)
        local pick = type(Options) == "table" and Options[1] or Options
        if pick then
            Config.ShoreReelMethod = pick
            shoreSetHold(false)
            savePersistentConfig()
        end
    end,
})

ShoreStatusPara = MainTab:CreateParagraph({
    Title = "Shore Panel",
    Content = "Enable Auto Fish and stand at the shore",
})

MainTab:CreateButton({
    Name = "Tap FISH Now (Test)",
    Callback = function()
        Shore.ForceRescan = true
        shoreRefreshRoot()
        shoreRefreshButtons()
        if Shore.FishBtn and clickGuiElement(Shore.FishBtn) then
            Shore.LastAction = "manual tap"
            shoreSetStatus("Manual FISH tap sent")
        else
            shoreSetStatus("FISH button not found - open the shore panel first")
        end
    end,
})

MainTab:CreateToggle({
    Name = "Auto Collect Catch Popups",
    CurrentValue = Config.ShorePopups,
    Callback = function(Value)
        Config.ShorePopups = Value
        savePersistentConfig()
    end,
})

MainTab:CreateToggle({
    Name = "Invert Reel Direction",
    CurrentValue = Config.ShoreInvert,
    Callback = function(Value)
        Config.ShoreInvert = Value
        shoreSetHold(false)
        savePersistentConfig()
    end,
})

MainTab:CreateButton({
    Name = "Re-scan Shore Panel",
    Callback = function()
        Shore.ForceRescan = true
        shoreRefreshRoot()
        shoreRefreshButtons()
    end,
})

MainTab:CreateSection("Training")

MainTab:CreateToggle({
    Name = "Auto Train (Walk to Training Area)",
    CurrentValue = Config.AutoTrain,
    Callback = function(Value)
        Config.AutoTrain = Value
        State.LastTrainStepAt = 0
        savePersistentConfig()
    end,
})

MainTab:CreateToggle({
    Name = "Auto 2x",
    CurrentValue = Config.Auto2x,
    Callback = function(Value)
        Config.Auto2x = Value
        savePersistentConfig()
    end,
})

MainTab:CreateToggle({
    Name = "Auto Upgrade",
    CurrentValue = Config.AutoUpgrade,
    Callback = function(Value)
        Config.AutoUpgrade = Value
        savePersistentConfig()
    end,
})

MainTab:CreateButton({
    Name = "Save Current Pos as Training Spot",
    Callback = function()
        local _, root = getCharacterAndRoot()
        local upPrompt = findMyBarUpgradePrompt()
        local upPart = upPrompt and getPromptBasePart(upPrompt) or nil
        if root and upPart then
            local rel = upPart.CFrame:PointToObjectSpace(root.Position)
            Config.BarOffsetX = math.floor(rel.X * 100) / 100
            Config.BarOffsetY = math.floor(rel.Y * 100) / 100
            Config.BarOffsetZ = math.floor(rel.Z * 100) / 100
            savePersistentConfig()
            Rayfield:Notify({
                Title = "perdi",
                Content = "Saved plot-relative Training Spot!",
                Duration = 3,
            })
        else
            Rayfield:Notify({
                Title = "perdi",
                Content = "Stand on your plot near your Bar first!",
                Duration = 3,
            })
        end
    end,
})

-- TAB 2: PLAYTIME & SERVER HOP
local HopTab = Window:CreateTab("Playtime & Hop", 4483362458)

local PlaytimeStatusPara = HopTab:CreateParagraph({
    Title = "Playtime & Hop Status",
    Content = State.PlaytimeStatus,
})

HopTab:CreateSection("Playtime Rewards")

HopTab:CreateToggle({
    Name = "Auto Claim Playtime",
    CurrentValue = Config.AutoPlaytime,
    Callback = function(Value)
        Config.AutoPlaytime = Value
        State.LastPlaytimeScanAt = 0
        State.LastFullPlaytimeVerifyAt = 0
        savePersistentConfig()
    end,
})

HopTab:CreateToggle({
    Name = "Server Hop After All Playtime Claimed",
    CurrentValue = Config.ServerHopAfterPlaytime,
    Callback = function(Value)
        Config.ServerHopAfterPlaytime = Value
        savePersistentConfig()
        if Value then
            armQueueOnTeleport()
        end
    end,
})

HopTab:CreateSection("Auto-Save & Auto-Load on Hop")

HopTab:CreateInput({
    Name = "Script Raw URL (Auto-Loads on Hop)",
    CurrentValue = Config.ScriptURL or "",
    PlaceholderText = "https://raw.githubusercontent.com/triskxd-ops/Perdi/main/perdi_hub.lua",
    RemoveTextAfterFocusLost = false,
    Callback = function(Text)
        if type(Text) == "string" and #Text > 8 then
            Config.ScriptURL = stripRichText(Text)
            TeleportQueued = false
            savePersistentConfig()
            armQueueOnTeleport()
            Rayfield:Notify({
                Title = "perdi",
                Content = "Saved Raw URL! Script will auto-load on server hop.",
                Duration = 3,
            })
        end
    end,
})

HopTab:CreateButton({
    Name = "Server Hop Now (Test)",
    Callback = function()
        serverHopToFreshServer()
    end,
})

HopTab:CreateSection("Session")

HopTab:CreateToggle({
    Name = "Anti-AFK",
    CurrentValue = Config.AntiAFK,
    Callback = function(Value)
        Config.AntiAFK = Value
        applyAntiAFKState(Value)
        savePersistentConfig()
    end,
})

--============================================================================
-- MAIN AUTOMATION LOOP
--============================================================================
local lastFishingScreenSeenAt = os.clock()

local function runMainLoop()
    while State.Running do
        local now = os.clock()

        -- 1) Periodic Anti-AFK backup every 10 minutes
        if Config.AntiAFK and (now - State.LastAntiAfkPulseAt) >= 600 then
            sendAntiAFKPulse()
        end

        local barActive = (CachedBar.Header and isVisibleTextElement(CachedBar.Header))
            or (CachedReelBar.Header and isVisibleTextElement(CachedReelBar.Header))

        -- 2) Auto Claim Playtime & Server Hop (runs when not mid-fishing bar)
        if Config.AutoPlaytime and not barActive then
            stepAutoPlaytimeAndHop()
        end

        -- 3) Auto Train (walks onto plot training area if not currently fishing or already training)
        if Config.AutoTrain and not Config.AutoFish and not barActive and not State.HoppingInProgress then
            stepAutoTrain()
        end

        -- 4) Auto Fish (Cast + Stop at Tier)
        if Config.AutoFish and not State.HoppingInProgress then
            local middleBarActive = CachedBar.Header and isVisibleTextElement(CachedBar.Header)
            local reelBarActive = CachedReelBar.Header and isVisibleTextElement(CachedReelBar.Header)
            local decisionCtx = (not middleBarActive) and findDecisionContext() or nil

            -- Shore panel layer: owns the BAIT / FISH / AUTO panel, in-game AUTO
            -- button, catch popups and (optionally) the reel hold.
            local shoreActive = stepShorePanel(now, middleBarActive or reelBarActive or (decisionCtx ~= nil))

            if middleBarActive then
                lastFishingScreenSeenAt = now
                State.DecisionVisibleSince = 0
            elseif decisionCtx then
                lastFishingScreenSeenAt = now
                if State.DecisionVisibleSince == 0 then
                    State.DecisionVisibleSince = now
                end

                if decisionCtx.LadderTier then
                    State.CurrentTier = decisionCtx.LadderTier
                end

                local settled = (now - State.DecisionVisibleSince) >= 0.25
                local cooldownReady = (now - State.LastDecisionClickAt) >= 0.55
                local signatureChanged = (decisionCtx.Signature ~= State.LastDecisionSignature)
                    or ((now - State.LastDecisionClickAt) >= 1.3)

                if settled and cooldownReady and signatureChanged then
                    local tier = State.CurrentTier
                    local shouldGoDeeper = (decisionCtx.DeeperLabel ~= nil) and (tier < Config.StopAtTier)

                    if shouldGoDeeper then
                        if clickGuiElement(decisionCtx.DeeperLabel) then
                            State.LastDecisionSignature = decisionCtx.Signature
                            State.LastDecisionClickAt = now
                            State.CurrentTier = math.min(10, State.CurrentTier + 1)
                        end
                    elseif decisionCtx.ReelLabel then
                        if clickGuiElement(decisionCtx.ReelLabel) then
                            State.LastDecisionSignature = ""
                            State.LastDecisionClickAt = now
                            State.CurrentTier = 1
                            State.LastCastAt = now
                        end
                    end
                end
            else
                State.DecisionVisibleSince = 0
                if (now - lastFishingScreenSeenAt) > 1.2 then
                    State.CurrentTier = 1
                    State.LastDecisionSignature = ""
                end

                -- The shore panel layer already casts (FISH / AUTO), so only fall
                -- back to prompt casting when that panel is not on screen.
                if not shoreActive and (now - State.LastCastAt) >= 1.3 and not isPurchasePromptOpen() then
                    local startedCast = false
                    if tryClickFishAgain() then
                        startedCast = true
                    else
                        local fishPrompt = findNearestPromptMatching(function(actionText, objectText)
                            return actionText == "fish"
                                or actionText:find("fish", 1, true) ~= nil
                                or objectText:find("abyss hole", 1, true) ~= nil
                        end)
                        if fishPrompt and triggerPrompt(fishPrompt) then
                            startedCast = true
                        end
                    end
                    if startedCast then
                        State.CurrentTier = 1
                        State.LastDecisionSignature = ""
                        State.LastCastAt = now
                    end
                end
            end
        end

        -- 5) Auto 2x
        if Config.Auto2x and (now - State.Last2xAt) >= 0.6 then
            if tryClick2x() then
                State.Last2xAt = now
            end
        end

        -- 6) Auto Upgrade
        if Config.AutoUpgrade and (now - State.LastUpgradeAt) >= 2.5 then
            State.LastUpgradeAt = now
            tryUpgradePrompt()
        end

        -- Update Playtime Status Paragraph when changed
        if State.PlaytimeStatus ~= State.LastShownPlaytimeStatus then
            State.LastShownPlaytimeStatus = State.PlaytimeStatus
            pcall(function()
                PlaytimeStatusPara:Set({
                    Title = "Playtime & Hop Status",
                    Content = State.PlaytimeStatus,
                })
            end)
        end

        task.wait(0.15)
    end
end

--============================================================================
-- LIFECYCLE & STARTUP
--============================================================================
local function cleanup()
    State.Running = false
    pcall(stopShorePanel)
    applyAntiAFKState(false)
    for _, conn in ipairs(Connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    table.clear(Connections)
    pcall(function()
        Rayfield:Destroy()
    end)
    globalEnv.__PERDI_HUB_CLEANUP = nil
end

globalEnv.__PERDI_HUB_CLEANUP = cleanup

applyAntiAFKState(Config.AntiAFK)
recordCurrentServerVisited()
armQueueOnTeleport()

-- Ensure queue_on_teleport also arms on any manual or server-initiated teleport
table.insert(Connections, LocalPlayer.OnTeleport:Connect(function()
    savePersistentConfig()
    armQueueOnTeleport()
end))

-- Retry another server automatically if chosen server filled up mid-teleport
table.insert(Connections, TeleportService.TeleportInitFailed:Connect(function()
    if State.HoppingInProgress then
        State.HoppingInProgress = false
        task.delay(2, function()
            if State.Running and Config.ServerHopAfterPlaytime then
                serverHopToFreshServer()
            end
        end)
    end
end))

table.insert(Connections, LocalPlayer.Idled:Connect(function()
    if Config.AntiAFK then
        sendAntiAFKPulse()
    end
end))

table.insert(Connections, LocalPlayer.CharacterAdded:Connect(function()
    State.LastTrainStepAt = 0
    if Config.AntiAFK then
        task.delay(1, function()
            if State.Running and Config.AntiAFK then
                applyAntiAFKState(true)
            end
        end)
    end
end))

table.insert(Connections, RunService.RenderStepped:Connect(stepAutoMiddle))
table.insert(Connections, RunService.RenderStepped:Connect(stepAutoPerfectReel))
task.spawn(runMainLoop)

Rayfield:Notify({
    Title = "perdi  ·  v6",
    Content = "Shore Auto Fish: taps FISH on the BAIT / FISH / AUTO panel.",
    Duration = 5,
})
