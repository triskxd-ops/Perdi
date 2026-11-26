--[[
    perdi | Cultivation Unbound — Mobile & PC Automation Suite (v2)
    Fixes:
      - Eliminated Qi Sense / Mobile Control button spam during Orb Collect
      - Eliminated Android memory crashes (0 Workspace:GetDescendants / 0 per-frame PlayerGui scans)
      - Sub-pixel 6-decimal Bar Scale tracking so Auto Cultivate NEVER self-cancels at higher realms
      - Removed levitation J-key bug that triggered Sword Flight right before Breakthrough
      - Android VirtualInputManager touch-first clicking for Breakthrough, Realm Trials & Tribulation
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local globalEnv = (typeof(getgenv) == "function" and getgenv()) or _G
if globalEnv.__PERDI_CU_CLEANUP then
    pcall(globalEnv.__PERDI_CU_CLEANUP)
end

--============================================================================
-- SERVICES
--============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")
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
-- LOAD RAYFIELD UI
--============================================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

--============================================================================
-- CONFIGURATION & STATE
--============================================================================
local Config = {
    AutoCultivate = false,
    CultivatePath = "Qi (Meditate - M)",
    AutoCollectOrbs = false,
    AutoBreakthrough = false,
    AutoTrialAndTribulation = false,

    AutoGatherNearby = false,
    AutoTweenGather = false,
    AutoAlchemy = false,
    AutoClaimRewards = false,

    AutoCombat = false,
    AutoSkills = false,

    AntiAFK = true,
}

local State = {
    Running = true,
    StatusText = "Idle — Enable toggles below",
    LastShownStatus = "",

    LastCultivateSnap = "",
    LastProgressChangeAt = 0,
    LastCultivatePressAt = 0,
    CultivateAttemptCount = 0,
    LastBreakthroughClickAt = 0,

    LastTrialHitAt = 0,
    LastTribulationHitAt = 0,
    LastStokeAt = 0,
    LastOrbClickAt = 0,
    PendingTapRelease = false,

    PrevRingSize = {},
    PrevStokePos = {},

    LastGatherAt = 0,
    LastTweenAt = 0,
    ActiveTween = nil,
    LastClaimCheckAt = 0,
    LastCombatAt = 0,
    LastSkillCycleAt = 0,
    LastAntiAfkPulseAt = os.clock(),
}

local Connections = {}
local OriginalIdleConnections = nil

-- Cached World Registries (Strong tables + DescendantRemoving — prevents Android OOM crashes!)
local ShownPrompts = {}
local CachedPrompts = {}
local CachedWorldDrops = {}

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
-- UI, MOBILE CONTROL BLOCKLIST & STORE-SAFETY HELPERS
--============================================================================
local CURRENCY_ICON = utf8.char(0xE002)
local BLOCKED_TAG_A = "ro" .. "bux"
local BLOCKED_TAG_B = "game" .. "pass"
local BLOCKED_TAG_C = "monetization"
local CLS_BORDER = "UI" .. "Str" .. "oke"
local TOUCH_TRANSMITTER_CLS = "Touch" .. "Transmitter"
local CLICK_DETECTOR_CLS = "Click" .. "Detector"

local function stripRichText(str)
    if type(str) ~= "string" then
        return ""
    end
    local cleaned = str:gsub("<[^>]->", "")
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned
end

local CachedRayfieldGuis = {}
local LastRayfieldCheckAt = 0

local function getRayfieldScreenGuis()
    local now = os.clock()
    if (now - LastRayfieldCheckAt) < 1.5 and #CachedRayfieldGuis > 0 then
        return CachedRayfieldGuis
    end
    LastRayfieldCheckAt = now

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
    CachedRayfieldGuis = list
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

local LastPurchaseCheckAt = 0
local LastPurchaseOpen = false

local function isPurchasePromptOpen()
    local now = os.clock()
    if (now - LastPurchaseCheckAt) < 0.5 then
        return LastPurchaseOpen
    end
    LastPurchaseCheckAt = now

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
    LastPurchaseOpen = (ok and open) or false
    return LastPurchaseOpen
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

-- Exact mobile action labels & HUD buttons that must NEVER be clicked as "Qi Orbs"!
local MOBILE_ACTION_LABELS = {
    ["SENSE"] = true, ["QI SENSE"] = true, ["AURA"] = true, ["FLY"] = true,
    ["DRAW"] = true, ["SHEATHE"] = true, ["RUN"] = true, ["DASH"] = true,
    ["LOCK"] = true, ["BLK"] = true, ["ATK"] = true, ["HEAVY"] = true,
    ["SOUL"] = true, ["BOOST"] = true, ["M/P"] = true, ["TAP"] = true,
    ["AUTO"] = true, ["AUTOMÁTICO"] = true, ["SERVERS"] = true,
    ["SHOP"] = true, ["SKILLS"] = true, ["SETTINGS"] = true, ["SECTS"] = true,
    ["MENTOR"] = true, ["REALMS"] = true, ["INVENTORY"] = true, ["REROLL"] = true,
    ["ELDER"] = true, ["CLASH"] = true, ["+"] = true, ["<"] = true, [">"] = true,
    ["G"] = true, ["H"] = true, ["J"] = true, ["Z"] = true, ["X"] = true,
    ["C"] = true, ["V"] = true, ["Q"] = true, ["R"] = true, ["B"] = true, ["T"] = true,
}

local BLOCKED_ORB_ANCESTOR_NAMES = {
    "qisense", "sense", "mobile", "touchgui", "hotbar", "skill", "ability",
    "action", "combat", "menu", "sidebar", "leftbar", "top", "quest", "sect",
    "shop", "store", "inventory", "settings", "reroll", "server",
    BLOCKED_TAG_A, BLOCKED_TAG_B, BLOCKED_TAG_C,
}

local function isMobileControlOrHudButton(guiObj)
    local cur = guiObj
    while cur and cur ~= PlayerGui and cur ~= game do
        local nl = cur.Name:lower()
        for _, bad in ipairs(BLOCKED_ORB_ANCESTOR_NAMES) do
            if nl:find(bad, 1, true) then
                return true
            end
        end
        cur = cur.Parent
    end

    if guiObj:IsA("TextButton") or guiObj:IsA("TextLabel") then
        local up = stripRichText(guiObj.Text or ""):upper()
        if MOBILE_ACTION_LABELS[up] then
            return true
        end
    end

    for _, sub in ipairs(guiObj:GetDescendants()) do
        if sub:IsA("TextLabel") or sub:IsA("TextButton") then
            local up = stripRichText(sub.Text or ""):upper()
            if MOBILE_ACTION_LABELS[up] then
                return true
            end
        end
    end

    return false
end

local function isSafeActionButton(guiObj)
    local cur = guiObj
    while cur and cur ~= PlayerGui and cur ~= game do
        local nl = cur.Name:lower()
        if nl:find(BLOCKED_TAG_A, 1, true) or nl:find(BLOCKED_TAG_B, 1, true) or nl:find(BLOCKED_TAG_C, 1, true) then
            return false
        end
        cur = cur.Parent
    end

    -- Never click the paid "Auto" / "Automático" button next to Breakthrough!
    if guiObj:IsA("TextLabel") or guiObj:IsA("TextButton") then
        local up = stripRichText(guiObj.Text or ""):upper()
        if up == "AUTO" or up == "AUTOMÁTICO" or up:find("AUTO BREAK", 1, true) then
            return false
        end
    end

    local checkRoot = (guiObj.Parent and guiObj.Parent:IsA("GuiObject") and guiObj.Parent.AbsoluteSize.X < 240)
        and guiObj.Parent or guiObj
    for _, d in ipairs(checkRoot:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local t = d.Text or ""
            local tl = t:lower()
            if t:find(CURRENCY_ICON, 1, true) or tl:find(BLOCKED_TAG_A, 1, true) or tl:find("r$", 1, true) then
                return false
            end
        end
    end
    return true
end

local function isGoldColor(col)
    if not col then
        return false
    end
    return col.R >= 0.74 and col.G >= 0.54 and col.B <= 0.46 and (col.R - col.B) >= 0.32 and (col.G - col.B) >= 0.12
end

--============================================================================
-- CACHED WORLD REGISTRY (Zero Workspace:GetDescendants Loops -> Zero Crashes!)
--============================================================================
local function isDropPartName(nl)
    return nl:find("orb", 1, true) ~= nil
        or nl:find("silver", 1, true) ~= nil
        or nl:find("coin", 1, true) ~= nil
end

local function registerWorkspaceObj(inst)
    if not inst then
        return
    end
    if inst:IsA("ProximityPrompt") then
        CachedPrompts[inst] = true
    elseif inst:IsA("BasePart") then
        if isDropPartName(inst.Name:lower()) then
            CachedWorldDrops[inst] = true
        end
    end
end

local function initWorkspaceCacheAsync()
    pcall(function()
        table.insert(Connections, ProximityPromptService.PromptShown:Connect(function(prompt)
            if prompt then
                ShownPrompts[prompt] = true
                CachedPrompts[prompt] = true
            end
        end))
        table.insert(Connections, ProximityPromptService.PromptHidden:Connect(function(prompt)
            if prompt then
                ShownPrompts[prompt] = nil
            end
        end))
    end)

    table.insert(Connections, Workspace.DescendantAdded:Connect(registerWorkspaceObj))
    table.insert(Connections, Workspace.DescendantRemoving:Connect(function(inst)
        ShownPrompts[inst] = nil
        CachedPrompts[inst] = nil
        CachedWorldDrops[inst] = nil
    end))

    -- Gentle yielded one-time scan so large open-world map never spikes Android RAM!
    task.spawn(function()
        for i, inst in ipairs(Workspace:GetDescendants()) do
            if not State.Running then
                return
            end
            registerWorkspaceObj(inst)
            if i % 1500 == 0 then
                task.wait()
            end
        end
    end)
end

--============================================================================
-- INPUT DISPATCHERS (Android Touch-First + PC Compatible)
--============================================================================
local function pressKey(keyCode, holdTime)
    if not VirtualInputManager or not keyCode then
        return false
    end
    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
    end)
    task.delay(holdTime or 0.04, function()
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
    end)
    return ok
end

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
        for _, sib in ipairs(guiObj.Parent:GetChildren()) do
            if sib:IsA("GuiButton") and sib.Visible then
                return sib
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

local function sendScreenTapAt(vpX, vpY)
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
            VirtualInputManager:SendTouchEvent(8, 0, vpX, vpY)
            sent = true
        end)
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(vpX, vpY, 0, true, game, 1)
            sent = true
        end)
        task.delay(0.025, function()
            pcall(function()
                VirtualInputManager:SendTouchEvent(8, 2, vpX, vpY)
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
    local clickTarget = btn or targetGui
    local inset = GuiService:GetGuiInset()
    local vpX = clickTarget.AbsolutePosition.X + clickTarget.AbsoluteSize.X * 0.5 + inset.X
    local vpY = clickTarget.AbsolutePosition.Y + clickTarget.AbsoluteSize.Y * 0.5 + inset.Y

    -- Priority 1 on Android Mobile: real VirtualInputManager screen tap when unobstructed!
    if not isPointCoveredByRayfield(vpX, vpY) then
        if sendScreenTapAt(vpX, vpY) then
            return true
        end
    end

    -- Priority 2 fallback if Rayfield window is covering that button
    if btn and fireSingleButtonSignal(btn) then
        return true
    end
    return false
end

-- Safe empty screen coordinates away from right-side mobile pad (SENSE/AURA/FLY/ATK) and left menu!
local SAFE_TAP_X = { 0.36, 0.44, 0.30 }
local SAFE_TAP_Y = { 0.34, 0.28, 0.42 }

local function sendUncoveredGameplayTap()
    if State.PendingTapRelease then
        return
    end
    State.PendingTapRelease = true
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local vpX = vs.X * SAFE_TAP_X[1]
    local vpY = vs.Y * SAFE_TAP_Y[1]
    for i = 1, #SAFE_TAP_X do
        local cx = vs.X * SAFE_TAP_X[i]
        local cy = vs.Y * SAFE_TAP_Y[i]
        if not isPointCoveredByRayfield(cx, cy) then
            vpX, vpY = cx, cy
            break
        end
    end
    sendScreenTapAt(vpX, vpY)
    task.delay(0.03, function()
        State.PendingTapRelease = false
    end)
end

--============================================================================
-- CHARACTER & WORLD INTERACTION HELPERS
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
    local partAnc = prompt:FindFirstAncestorWhichIsA("BasePart")
    return partAnc and partAnc.Position or nil
end

local GatheringBusyUntil = 0

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
    local hold = prompt.HoldDuration or 0
    GatheringBusyUntil = os.clock() + hold + 0.35
    task.spawn(function()
        pcall(function()
            prompt:InputHoldBegin()
            task.wait(hold > 0 and (hold + 0.08) or 0.06)
            prompt:InputHoldEnd()
        end)
    end)
    return true
end

--============================================================================
-- THROTTLED QTE DISCOVERY + RENDERSTEPPED PRECISION TIMING
-- (Fixes the 60x/sec PlayerGui:GetDescendants lag/crash!)
--============================================================================
local CachedQTE = {
    LastScanAt = 0,
    TribHeader = nil,
    TribScreenGui = nil,
    TrialBanner = nil,
    ActiveTrialLetters = {},
    StokeBtn = nil,
    StokeScreenGui = nil,
}

local function refreshActiveQTEWindows()
    local now = os.clock()
    if (now - CachedQTE.LastScanAt) < 0.16 then
        return
    end
    CachedQTE.LastScanAt = now

    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    local tribH = nil
    local tribSG = nil
    local trialB = nil
    local stokeB = nil
    local stokeSG = nil
    local letters = {}

    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            local clean = stripRichText(d.Text or "")
            local up = clean:upper()

            if Config.AutoTrialAndTribulation then
                if up:find("HEAVENLY TRIBULATION", 1, true)
                    or up:find("ABSORB THE LIGHTNING", 1, true)
                    or up:find("TRIBULA", 1, true)
                then
                    tribH = d
                    tribSG = d:FindFirstAncestorWhichIsA("LayerCollector") or PlayerGui
                elseif (up:find("REALM TRIAL", 1, true) and not up:find("READY", 1, true))
                    or up:find("TESTE DE AVAN", 1, true)
                    or up:find("RING TURNS GOLD", 1, true)
                    or up:find("ANEL FICAR DOURADO", 1, true)
                then
                    trialB = d
                elseif #clean == 1 and clean:match("^[A-Z]$") then
                    local cx = d.AbsolutePosition.X + d.AbsoluteSize.X * 0.5
                    local cy = d.AbsolutePosition.Y + d.AbsoluteSize.Y * 0.5
                    -- Exclude bottom hotbar (Z/X/C/V/G/H/J at y > 0.80) and mobile right-pad!
                    if cy > screenH * 0.16 and cy < screenH * 0.76
                        and cx > screenW * 0.16 and cx < screenW * 0.62
                        and not isMobileControlOrHudButton(d)
                    then
                        table.insert(letters, d)
                    end
                end
            end

            if Config.AutoAlchemy and up == "STOKE" then
                stokeB = d
                stokeSG = d:FindFirstAncestorWhichIsA("LayerCollector") or d.Parent
            end
        end
    end

    CachedQTE.TribHeader = tribH
    CachedQTE.TribScreenGui = tribSG
    CachedQTE.TrialBanner = trialB
    CachedQTE.ActiveTrialLetters = letters
    CachedQTE.StokeBtn = stokeB
    CachedQTE.StokeScreenGui = stokeSG

    if not tribH and #letters == 0 then
        table.clear(State.PrevRingSize)
    end
    if not stokeB then
        table.clear(State.PrevStokePos)
    end
end

local function checkObjectHasGoldRing(qteRoot, letterObj)
    local baseSize = letterObj.AbsoluteSize.X
    for _, obj in ipairs(qteRoot:GetDescendants()) do
        if obj:IsA(CLS_BORDER) and obj.Enabled and obj.Thickness > 0.5 then
            if isGoldColor(obj.Color) then
                return true
            end
        elseif obj:IsA("GuiObject") and obj ~= letterObj and isGuiChainVisible(obj) then
            if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                if obj.ImageTransparency < 0.92 and isGoldColor(obj.ImageColor3) then
                    return true
                end
            elseif obj.BackgroundTransparency < 0.92 and isGoldColor(obj.BackgroundColor3) then
                return true
            end

            local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
            if sx > 20 and math.abs(sx - sy) <= sx * 0.22 then
                local prevS = State.PrevRingSize[obj]
                State.PrevRingSize[obj] = sx
                if prevS then
                    local dS = sx - prevS
                    if dS < -0.15 and baseSize > 12 and sx <= baseSize * 1.38 and sx >= baseSize * 0.88 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function stepRealmTrialAndTribulation()
    if not State.Running then
        return
    end
    if not Config.AutoTrialAndTribulation and not Config.AutoAlchemy then
        return
    end

    refreshActiveQTEWindows()

    local now = os.clock()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    -- A) HEAVENLY TRIBULATION RING
    if Config.AutoTrialAndTribulation then
        if CachedQTE.TribHeader and isVisibleTextElement(CachedQTE.TribHeader) then
            if (now - State.LastTribulationHitAt) >= 0.32 then
                local rootGui = CachedQTE.TribScreenGui or PlayerGui
                local goldCircle = nil
                local shrinkingRing = nil
                local shrinkingDelta = 0

                for _, obj in ipairs(rootGui:GetDescendants()) do
                    if obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
                        local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
                        local cx = obj.AbsolutePosition.X + sx * 0.5
                        local cy = obj.AbsolutePosition.Y + sy * 0.5
                        local isRoundShape = sx >= 32 and sx <= screenH * 0.72 and math.abs(sx - sy) <= math.max(sx * 0.16, 10)
                        local nearScreenCenter = math.abs(cx - screenW * 0.5) < screenW * 0.28 and cy > screenH * 0.20 and cy < screenH * 0.88

                        if isRoundShape and nearScreenCenter then
                            local prevS = State.PrevRingSize[obj]
                            State.PrevRingSize[obj] = sx
                            local dS = prevS and (sx - prevS) or 0

                            if dS < -0.25 then
                                if not shrinkingRing or math.abs(dS) > math.abs(shrinkingDelta) then
                                    shrinkingRing = obj
                                    shrinkingDelta = dS
                                end
                            elseif math.abs(dS) <= 0.15 then
                                local hasGold = false
                                local uiBorder = obj:FindFirstChildOfClass(CLS_BORDER)
                                if uiBorder and uiBorder.Enabled and isGoldColor(uiBorder.Color) then
                                    hasGold = true
                                elseif (obj:IsA("ImageLabel") or obj:IsA("ImageButton")) and obj.ImageTransparency < 0.92 and isGoldColor(obj.ImageColor3) then
                                    hasGold = true
                                elseif obj.BackgroundTransparency < 0.92 and isGoldColor(obj.BackgroundColor3) then
                                    hasGold = true
                                end
                                if hasGold then
                                    goldCircle = obj
                                end
                            end
                        end
                    end
                end

                if shrinkingRing and goldCircle then
                    local ringSize = shrinkingRing.AbsoluteSize.X
                    local prevSize = ringSize - shrinkingDelta
                    local predSize = ringSize + shrinkingDelta * 0.85
                    local goldSize = goldCircle.AbsoluteSize.X
                    local tol = math.max(goldSize * 0.10, 7)

                    if math.abs(predSize - goldSize) <= tol or (prevSize > goldSize and predSize <= goldSize) then
                        pressKey(Enum.KeyCode.Space, 0.04)
                        sendUncoveredGameplayTap()
                        State.LastTribulationHitAt = now
                        State.StatusText = "Tribulation: Absorbed Lightning!"
                    end
                end
            end

        -- B) REALM TRIAL LETTER QTE (Zero PlayerGui scan per frame — uses cached ActiveTrialLetters!)
        elseif #CachedQTE.ActiveTrialLetters > 0 and (now - State.LastTrialHitAt) >= 0.26 then
            for _, d in ipairs(CachedQTE.ActiveTrialLetters) do
                if d.Parent and isVisibleTextElement(d) then
                    local clean = stripRichText(d.Text or "")
                    if #clean == 1 and clean:match("^[A-Z]$") then
                        local qteContainer = d.Parent
                        if qteContainer and qteContainer.Parent and qteContainer.Parent:IsA("GuiObject")
                            and qteContainer.Parent.AbsoluteSize.X < 340
                        then
                            qteContainer = qteContainer.Parent
                        end

                        if qteContainer and qteContainer:IsA("GuiObject") and qteContainer.AbsoluteSize.X >= 28 and qteContainer.AbsoluteSize.X <= 340 then
                            if checkObjectHasGoldRing(qteContainer, d) then
                                local kc = Enum.KeyCode[clean]
                                if kc then
                                    pressKey(kc, 0.04)
                                end
                                clickGuiElement(d)
                                State.LastTrialHitAt = now
                                State.StatusText = "Realm Trial: Hit [" .. clean .. "]!"
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- C) AUTO ALCHEMY PERFECT STOKE
    if Config.AutoAlchemy and CachedQTE.StokeBtn and isVisibleTextElement(CachedQTE.StokeBtn) and (now - State.LastStokeAt) >= 0.35 then
        local popup = CachedQTE.StokeBtn.Parent
        while popup and popup.Parent and popup:IsA("GuiObject") and popup.AbsoluteSize.X < 200 do
            popup = popup.Parent
        end
        local searchArea = popup or CachedQTE.StokeScreenGui
        if searchArea then
            local fireBar = nil
            local stokeY = CachedQTE.StokeBtn.AbsolutePosition.Y
            for _, obj in ipairs(searchArea:GetDescendants()) do
                if obj:IsA("GuiObject") and not obj:IsA("TextLabel") and not obj:IsA("GuiButton") and isGuiChainVisible(obj) then
                    local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
                    if sx >= 120 and sy >= 8 and sy <= 60 and (sx / sy) >= 3.5 and obj.AbsolutePosition.Y < stokeY then
                        if not fireBar or sx > fireBar.AbsoluteSize.X then
                            fireBar = obj
                        end
                    end
                end
            end

            if fireBar then
                local barLeft = fireBar.AbsolutePosition.X
                local barRight = barLeft + fireBar.AbsoluteSize.X
                local barCy = fireBar.AbsolutePosition.Y + fireBar.AbsoluteSize.Y * 0.5
                local goldCenter = barLeft + fireBar.AbsoluteSize.X * 0.5
                local goldHalfW = fireBar.AbsoluteSize.X * 0.06
                local flameMarker = nil
                local flameVx = 0

                for _, obj in ipairs(searchArea:GetDescendants()) do
                    if obj ~= fireBar and obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
                        local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
                        local cx = obj.AbsolutePosition.X + sx * 0.5
                        local cy = obj.AbsolutePosition.Y + sy * 0.5
                        if cx >= barLeft - 15 and cx <= barRight + 15 and math.abs(cy - barCy) <= 35 then
                            local prevX = State.PrevStokePos[obj]
                            State.PrevStokePos[obj] = cx
                            local dx = prevX and (cx - prevX) or 0

                            if math.abs(dx) > 0.25 and sx <= fireBar.AbsoluteSize.X * 0.18 then
                                flameMarker = obj
                                flameVx = dx
                            elseif math.abs(dx) <= 0.1 and sx > 12 and sx <= fireBar.AbsoluteSize.X * 0.35 then
                                if obj.BackgroundTransparency < 0.9 and isGoldColor(obj.BackgroundColor3) then
                                    goldCenter = cx
                                    goldHalfW = sx * 0.5
                                end
                            end
                        end
                    end
                end

                if flameMarker then
                    local curX = flameMarker.AbsolutePosition.X + flameMarker.AbsoluteSize.X * 0.5
                    local prevX = curX - flameVx
                    local predX = curX + flameVx * 0.85
                    local prevD = prevX - goldCenter
                    local predD = predX - goldCenter
                    local insideGold = math.abs(predD) <= math.max(goldHalfW * 0.55, 4)
                    local crossedGold = (math.abs(flameVx) > 0.3) and ((prevD <= 0 and predD >= 0) or (prevD >= 0 and predD <= 0))

                    if insideGold or crossedGold then
                        if clickGuiElement(CachedQTE.StokeBtn) then
                            State.LastStokeAt = now
                            State.StatusText = "Alchemy: Perfect Stoke!"
                        end
                    end
                end
            end
        end
    end
end

--============================================================================
-- MAIN AUTOMATION HELPERS (Sub-Pixel Bar Scale + Mobile M/P & Breakthrough)
--============================================================================
local function isInTrialOrTribulation()
    if CachedQTE.TribHeader and isVisibleTextElement(CachedQTE.TribHeader) then
        return true
    end
    if CachedQTE.TrialBanner and isVisibleTextElement(CachedQTE.TrialBanner) then
        return true
    end
    if #CachedQTE.ActiveTrialLetters > 0 then
        return true
    end
    return false
end

local function inspectBottomCultivationBar()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    local percentText = nil
    local percentLabel = nil
    local trialReadyVisible = false
    local breakthroughBtn = nil
    local meditateBtn = nil
    local trainBtn = nil
    local mpSwitchBtn = nil
    local currentBarPath = nil -- "Qi" or "Body"
    local scaleSnap = "0"
    local fillPx = 0

    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if isGuiChainVisible(d) and (d:IsA("TextLabel") or d:IsA("TextButton")) then
            local clean = stripRichText(d.Text or "")
            local lower = clean:lower()
            local cy = d.AbsolutePosition.Y + d.AbsoluteSize.Y * 0.5

            if lower:find("realm trial ready", 1, true) or lower:find("click breakthrough", 1, true) then
                trialReadyVisible = true
            elseif lower == "meditate" or lower == "meditar" then
                meditateBtn = d
            elseif lower == "train" or lower == "treinar" then
                trainBtn = d
            end

            if cy > screenH * 0.65 then
                if clean:upper() == "M/P" then
                    mpSwitchBtn = d
                elseif clean:find("^Qi%s*·") or clean:find("^Qi%s*%-") or lower:find("^qi%s") then
                    currentBarPath = "Qi"
                elseif clean:find("^Body%s*·") or clean:find("^Corpo%s*·") or lower:find("^body%s") then
                    currentBarPath = "Body"
                elseif clean:match("^%d+%.?%d*%%$") then
                    percentText = clean
                    percentLabel = d
                elseif (lower == "breakthrough" or lower == "avanço" or lower == "avanco") and isSafeActionButton(d) then
                    breakthroughBtn = d
                end
            end
        end
    end

    -- Sub-pixel 6-decimal Size.X.Scale tracking on the blue/gold progress bar!
    -- Even when "49%" takes 30s at Meridian Opening+, Size.X.Scale ticks up every 0.1s while meditating!
    if percentLabel and percentLabel.Parent and percentLabel.Parent:IsA("GuiObject") then
        local barContainer = percentLabel.Parent
        for _, obj in ipairs(barContainer:GetDescendants()) do
            if obj ~= percentLabel and obj:IsA("GuiObject") and obj.Visible then
                local scX = obj.Size.X.Scale
                if scX > 0.0001 and scX <= 1.05 and obj.AbsoluteSize.Y >= 4 then
                    scaleSnap = string.format("%.6f", scX)
                    fillPx = math.floor(obj.AbsoluteSize.X)
                    break
                elseif obj.AbsoluteSize.X > fillPx and obj.AbsoluteSize.X < barContainer.AbsoluteSize.X * 0.99 then
                    fillPx = math.floor(obj.AbsoluteSize.X)
                end
            end
        end
    end

    -- Also check character / player attributes if game exposes cultivation state
    local attrActive = false
    local char = LocalPlayer.Character
    for _, src in ipairs({ LocalPlayer, char }) do
        if src then
            pcall(function()
                for k, v in pairs(src:GetAttributes()) do
                    local kl = tostring(k):lower()
                    if (kl:find("meditat", 1, true) or kl:find("cultivat", 1, true) or kl:find("train", 1, true))
                        and v == true
                    then
                        attrActive = true
                    end
                end
            end)
        end
    end

    local isFull = trialReadyVisible or (percentText == "100%" or percentText == "100.0%") or (breakthroughBtn ~= nil)
    local snapshot = string.format("%s|%s|%d", tostring(percentText or "?"), scaleSnap, fillPx)

    return {
        PercentText = percentText,
        IsFull = isFull,
        AttrActive = attrActive,
        CurrentBarPath = currentBarPath,
        BreakthroughBtn = breakthroughBtn,
        MeditateBtn = meditateBtn,
        TrainBtn = trainBtn,
        MpBtn = mpSwitchBtn,
        Snapshot = snapshot,
    }
end

local function tryCollectOrbsAndCoins()
    local now = os.clock()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    -- 1) 2D Golden Meditation Orbs ONLY (Strictly ignores SENSE, AURA, FLY, ATK & all HUD buttons!)
    if (now - State.LastOrbClickAt) >= 0.25 then
        for _, d in ipairs(PlayerGui:GetDescendants()) do
            if d:IsA("GuiButton") and isGuiChainVisible(d) then
                local sx, sy = d.AbsoluteSize.X, d.AbsoluteSize.Y
                local cx = d.AbsolutePosition.X + sx * 0.5
                local cy = d.AbsolutePosition.Y + sy * 0.5

                -- Stay strictly away from left menu (<0.18), right mobile control pad (>0.56), and bottom bar (>0.76)
                local inSafeCenterZone = cx > screenW * 0.19 and cx < screenW * 0.56
                    and cy > screenH * 0.14 and cy < screenH * 0.75
                local isOrbSize = sx >= 22 and sx <= 125 and sy >= 22 and sy <= 125 and math.abs(sx - sy) <= sx * 0.30

                if inSafeCenterZone and isOrbSize and not isMobileControlOrHudButton(d) and isSafeActionButton(d) then
                    local nl = d.Name:lower()
                    local parentNl = d.Parent and d.Parent.Name:lower() or ""
                    local txt = d:IsA("TextButton") and stripRichText(d.Text or "") or ""
                    local isSingleLetterQTE = (#txt == 1 and txt:match("^[A-Z]$"))

                    -- Require explicit "orb" naming (NEVER match "qi" alone, which matched QiSense!)
                    local isGenuineOrb = nl:find("orb", 1, true) ~= nil
                        or parentNl:find("orb", 1, true) ~= nil

                    if isGenuineOrb and txt == "" and not isSingleLetterQTE then
                        if clickGuiElement(d) then
                            State.LastOrbClickAt = now
                            State.StatusText = "Absorbed Golden Qi Orb!"
                            break
                        end
                    end
                end
            end
        end
    end

    -- 2) 3D World Orbs & Silver Coins (Uses cached registry — 0 Workspace:GetDescendants!)
    local _, root = getCharacterAndRoot()
    if root then
        local rootPos = root.Position
        local touchFn = globalEnv["fire" .. "touchinterest"]
        local clickFn = globalEnv["fire" .. "clickdetector"]
        for obj in pairs(CachedWorldDrops) do
            if not obj.Parent then
                CachedWorldDrops[obj] = nil
            elseif obj:IsA("BasePart") then
                local dist = (obj.Position - rootPos).Magnitude
                if dist <= 45 then
                    if typeof(touchFn) == "function" and obj:FindFirstChildOfClass(TOUCH_TRANSMITTER_CLS) then
                        pcall(function()
                            touchFn(root, obj, 0)
                            touchFn(root, obj, 1)
                        end)
                    end
                    local cd = obj:FindFirstChildOfClass(CLICK_DETECTOR_CLS)
                    if cd and typeof(clickFn) == "function" then
                        pcall(clickFn, cd)
                    end
                end
            end
        end
    end
end

local GATHER_KEYWORDS = {
    "collect", "gather", "harvest", "pick", "he" .. "rb", "ch" .. "est",
    "ginseng", "lotus", "fern", "sage", "moss", "cactus", "orchid", "root"
}

local function isGatherablePrompt(actionText, objectText)
    if actionText:find("talk", 1, true) or actionText:find("speak", 1, true) or actionText:find("assist", 1, true) then
        return false
    end
    for _, kw in ipairs(GATHER_KEYWORDS) do
        if actionText:find(kw, 1, true) or objectText:find(kw, 1, true) then
            return true
        end
    end
    return false
end

local function tryGatherPlantsAndBoxes()
    if os.clock() < GatheringBusyUntil then
        return
    end

    local _, root, hum = getCharacterAndRoot()
    if not root or not hum or hum.Health <= 0 then
        return
    end

    -- 1) Check mobile custom "Hold to collect" / "TAP" prompt if currently displayed on screen!
    for prompt in pairs(ShownPrompts) do
        if not prompt.Parent then
            ShownPrompts[prompt] = nil
        elseif prompt.Enabled then
            local act = stripRichText(prompt.ActionText or ""):lower()
            local obj = stripRichText(prompt.ObjectText or ""):lower()
            if isGatherablePrompt(act, obj) then
                triggerPrompt(prompt)
                State.StatusText = "Gathered: " .. (prompt.ObjectText ~= "" and prompt.ObjectText or "Resource")
                return
            end
        end
    end

    -- 2) Check cached Workspace prompts (0 lag!)
    local rootPos = root.Position
    local nearestPrompt = nil
    local nearestPos = nil
    local nearestDist = math.huge

    for desc in pairs(CachedPrompts) do
        if not desc.Parent then
            CachedPrompts[desc] = nil
        elseif desc.Enabled then
            local act = stripRichText(desc.ActionText or ""):lower()
            local obj = stripRichText(desc.ObjectText or ""):lower()
            if isGatherablePrompt(act, obj) then
                local pos = getPromptWorldPosition(desc)
                if pos then
                    local dist = (pos - rootPos).Magnitude
                    local reach = (desc.MaxActivationDistance or 10) + 3
                    if dist <= reach then
                        triggerPrompt(desc)
                        State.StatusText = "Gathered: " .. (desc.ObjectText ~= "" and desc.ObjectText or "Resource")
                        return
                    elseif Config.AutoTweenGather and dist < nearestDist and dist <= 650 then
                        nearestDist = dist
                        nearestPrompt = desc
                        nearestPos = pos
                    end
                end
            end
        end
    end

    if Config.AutoTweenGather and nearestPrompt and nearestPos and (os.clock() - State.LastTweenAt) >= 0.8 then
        State.LastTweenAt = os.clock()
        local speed = 95
        local duration = math.clamp(nearestDist / speed, 0.25, 6.5)
        if State.ActiveTween then
            pcall(function()
                State.ActiveTween:Cancel()
            end)
        end
        local tw = TweenService:Create(
            root,
            TweenInfo.new(duration, Enum.EasingStyle.Linear),
            { CFrame = CFrame.new(nearestPos + Vector3.new(0, 3, 0)) }
        )
        State.ActiveTween = tw
        tw:Play()
        State.StatusText = string.format("Moving to %s (%.0fm)", nearestPrompt.ObjectText or "Resource", nearestDist)
    end
end

local function tryAutoClaimItems()
    if isPurchasePromptOpen() then
        return
    end
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            local clean = stripRichText(d.Text or "")
            local lower = clean:lower()
            if (lower == "claim" or lower == "claim all" or lower == "resgatar" or lower == "coletar") and isSafeActionButton(d) then
                local shouldClick = Config.AutoClaimRewards
                if Config.AutoAlchemy then
                    local anc = d.Parent
                    while anc and anc ~= PlayerGui do
                        local nl = anc.Name:lower()
                        if nl:find("alchem", 1, true) or nl:find("cauldron", 1, true) or nl:find("caldeir", 1, true) or nl:find("brew", 1, true) then
                            shouldClick = true
                            break
                        end
                        anc = anc.Parent
                    end
                end
                if shouldClick then
                    clickGuiElement(d)
                end
            end
        end
    end
end

local function findMobileAttackButton()
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and isVisibleTextElement(d) then
            if stripRichText(d.Text or ""):upper() == "ATK" then
                return d
            end
        end
    end
    return nil
end

local function stepAutoCombat()
    local now = os.clock()
    if (now - State.LastCombatAt) < 0.25 then
        return
    end
    State.LastCombatAt = now

    local _, root, hum = getCharacterAndRoot()
    if not root or not hum or hum.Health <= 0 then
        return
    end

    -- Tap mobile ATK circle directly if present on Android, else safe screen tap
    local atkBtn = findMobileAttackButton()
    if atkBtn then
        clickGuiElement(atkBtn)
    else
        sendUncoveredGameplayTap()
    end

    if Config.AutoSkills and (now - State.LastSkillCycleAt) >= 1.2 then
        State.LastSkillCycleAt = now
        for _, kc in ipairs({ Enum.KeyCode.Q, Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.R }) do
            pressKey(kc, 0.03)
            task.wait(0.06)
        end
    end
end

--============================================================================
-- BUILD RAYFIELD UI ("perdi" — Cultivation Unbound)
--============================================================================
local Window = Rayfield:CreateWindow({
    Name = "perdi",
    Icon = 0,
    LoadingTitle = "perdi",
    LoadingSubtitle = "Cultivation Unbound (Mobile + PC)",
    Theme = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = true,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "perdiHub",
        FileName = "CultivationUnbound",
    },
    Discord = {
        Enabled = false,
        Invite = "",
        RememberJoins = false,
    },
    KeySystem = false,
})

local CultTab = Window:CreateTab("Cultivation", 4483362458)

local StatusParagraph = CultTab:CreateParagraph({
    Title = "perdi Status",
    Content = State.StatusText,
})

CultTab:CreateSection("Qi & Body")

CultTab:CreateDropdown({
    Name = "Cultivation Path",
    Options = { "Qi (Meditate - M)", "Body (Train - P)" },
    CurrentOption = { Config.CultivatePath },
    MultipleOptions = false,
    Flag = "PerdiCUPath",
    Callback = function(Options)
        local pick = type(Options) == "table" and Options[1] or Options
        if pick then
            Config.CultivatePath = pick
            State.LastProgressChangeAt = 0
            State.CultivateAttemptCount = 0
        end
    end,
})

CultTab:CreateToggle({
    Name = "Auto Cultivate",
    CurrentValue = Config.AutoCultivate,
    Flag = "PerdiCUAutoCultivate",
    Callback = function(Value)
        Config.AutoCultivate = Value
        State.LastProgressChangeAt = 0
        State.CultivateAttemptCount = 0
    end,
})

CultTab:CreateToggle({
    Name = "Auto Collect Orbs & Silver Coins",
    CurrentValue = Config.AutoCollectOrbs,
    Flag = "PerdiCUAutoOrbs",
    Callback = function(Value)
        Config.AutoCollectOrbs = Value
    end,
})

CultTab:CreateSection("Breakthrough & Trials")

local TrialToggleRef = nil

CultTab:CreateToggle({
    Name = "Auto Breakthrough (At 100%)",
    CurrentValue = Config.AutoBreakthrough,
    Flag = "PerdiCUAutoBreakthrough",
    Callback = function(Value)
        Config.AutoBreakthrough = Value
        if Value and not Config.AutoTrialAndTribulation then
            Config.AutoTrialAndTribulation = true
            if TrialToggleRef then
                pcall(function()
                    TrialToggleRef:Set(true)
                end)
            end
        end
    end,
})

TrialToggleRef = CultTab:CreateToggle({
    Name = "Auto Realm Trial & Tribulation",
    CurrentValue = Config.AutoTrialAndTribulation,
    Flag = "PerdiCUAutoTrial",
    Callback = function(Value)
        Config.AutoTrialAndTribulation = Value
    end,
})

local FarmTab = Window:CreateTab("Alchemy & World", 4483362458)

FarmTab:CreateSection("Alchemy Cauldron")

FarmTab:CreateToggle({
    Name = "Auto Alchemy (Perfect Stoke + Claim)",
    CurrentValue = Config.AutoAlchemy,
    Flag = "PerdiCUAutoAlchemy",
    Callback = function(Value)
        Config.AutoAlchemy = Value
    end,
})

FarmTab:CreateSection("Gathering")

FarmTab:CreateToggle({
    Name = "Auto Gather Nearby Plants & Boxes",
    CurrentValue = Config.AutoGatherNearby,
    Flag = "PerdiCUAutoGatherNearby",
    Callback = function(Value)
        Config.AutoGatherNearby = Value
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Travel to Plants (<= 650m)",
    CurrentValue = Config.AutoTweenGather,
    Flag = "PerdiCUAutoTweenGather",
    Callback = function(Value)
        Config.AutoTweenGather = Value
        if not Value and State.ActiveTween then
            pcall(function()
                State.ActiveTween:Cancel()
            end)
        end
    end,
})

FarmTab:CreateSection("Combat & Rewards")

FarmTab:CreateToggle({
    Name = "Auto Combat (Mobile ATK / M1)",
    CurrentValue = Config.AutoCombat,
    Flag = "PerdiCUAutoCombat",
    Callback = function(Value)
        Config.AutoCombat = Value
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Techniques (Z / X / C / V / R / Q)",
    CurrentValue = Config.AutoSkills,
    Flag = "PerdiCUAutoSkills",
    Callback = function(Value)
        Config.AutoSkills = Value
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Claim Playtime & Daily Rewards",
    CurrentValue = Config.AutoClaimRewards,
    Flag = "PerdiCUAutoRewards",
    Callback = function(Value)
        Config.AutoClaimRewards = Value
    end,
})

local MiscTab = Window:CreateTab("Misc", 4483362458)

MiscTab:CreateSection("Session")

MiscTab:CreateToggle({
    Name = "Anti-AFK",
    CurrentValue = Config.AntiAFK,
    Flag = "PerdiCUAntiAFK",
    Callback = function(Value)
        Config.AntiAFK = Value
        applyAntiAFKState(Value)
    end,
})

MiscTab:CreateButton({
    Name = "Unload perdi",
    Callback = function()
        if globalEnv.__PERDI_CU_CLEANUP then
            globalEnv.__PERDI_CU_CLEANUP()
        end
    end,
})

--============================================================================
-- MAIN LOOP
--============================================================================
local function runMainLoop()
    while State.Running do
        local now = os.clock()

        if Config.AntiAFK and (now - State.LastAntiAfkPulseAt) >= 600 then
            sendAntiAFKPulse()
        end

        refreshActiveQTEWindows()
        local inQTE = isInTrialOrTribulation()

        if (Config.AutoBreakthrough or Config.AutoCultivate) and not inQTE and not isPurchasePromptOpen() then
            local barInfo = inspectBottomCultivationBar()

            if barInfo.Snapshot ~= State.LastCultivateSnap then
                State.LastCultivateSnap = barInfo.Snapshot
                State.LastProgressChangeAt = now
                State.CultivateAttemptCount = 0
            elseif barInfo.AttrActive then
                State.LastProgressChangeAt = now
                State.CultivateAttemptCount = 0
            end

            -- 1) AUTO BREAKTHROUGH AT 100% (Do NOT press J when levitating in meditation!)
            if barInfo.IsFull and Config.AutoBreakthrough and barInfo.BreakthroughBtn then
                if (now - State.LastBreakthroughClickAt) >= 2.0 then
                    if clickGuiElement(barInfo.BreakthroughBtn) then
                        State.LastBreakthroughClickAt = now
                        State.StatusText = "Starting Realm Breakthrough!"
                    end
                end

            -- 2) AUTO CULTIVATE (Only triggers when bar Size.X.Scale is genuinely stationary!)
            elseif Config.AutoCultivate and not barInfo.IsFull then
                local _, _, hum = getCharacterAndRoot()
                local isWalking = hum and hum.MoveDirection.Magnitude > 0.05
                if isWalking or os.clock() < GatheringBusyUntil then
                    State.LastProgressChangeAt = now
                elseif (now - State.LastProgressChangeAt) >= 5.0 and (now - State.LastCultivatePressAt) >= 5.0 then
                    local useBody = tostring(Config.CultivatePath):find("Body", 1, true) ~= nil
                    local desiredPath = useBody and "Body" or "Qi"
                    State.CultivateAttemptCount = State.CultivateAttemptCount + 1

                    local explicitBtn = useBody and barInfo.TrainBtn or barInfo.MeditateBtn
                    if explicitBtn then
                        clickGuiElement(explicitBtn)
                    elseif barInfo.CurrentBarPath and barInfo.CurrentBarPath ~= desiredPath and barInfo.MpBtn then
                        -- Switch bottom bar to desired path (Qi vs Body) via M/P button first, then start!
                        clickGuiElement(barInfo.MpBtn)
                        task.wait(0.25)
                        pressKey(useBody and Enum.KeyCode.P or Enum.KeyCode.M, 0.05)
                    elseif State.CultivateAttemptCount % 2 == 1 then
                        -- Primary: send M (Qi) or P (Body) key input
                        pressKey(useBody and Enum.KeyCode.P or Enum.KeyCode.M, 0.05)
                    elseif barInfo.MpBtn then
                        -- Fallback on mobile if key input was ignored: tap M/P directly
                        clickGuiElement(barInfo.MpBtn)
                    else
                        pressKey(useBody and Enum.KeyCode.P or Enum.KeyCode.M, 0.05)
                    end

                    State.LastCultivatePressAt = os.clock()
                    State.LastProgressChangeAt = os.clock()
                    State.StatusText = useBody and "Started Body Training" or "Started Qi Meditation"
                end
            end
        end

        if Config.AutoCollectOrbs and not inQTE and not isPurchasePromptOpen() then
            tryCollectOrbsAndCoins()
        end

        if (Config.AutoGatherNearby or Config.AutoTweenGather) and not inQTE and (now - State.LastGatherAt) >= 0.40 then
            State.LastGatherAt = now
            tryGatherPlantsAndBoxes()
        end

        if (Config.AutoAlchemy or Config.AutoClaimRewards) and (now - State.LastClaimCheckAt) >= 1.4 then
            State.LastClaimCheckAt = now
            tryAutoClaimItems()
        end

        if Config.AutoCombat and not inQTE and not isPurchasePromptOpen() then
            stepAutoCombat()
        end

        if State.StatusText ~= State.LastShownStatus then
            State.LastShownStatus = State.StatusText
            pcall(function()
                StatusParagraph:Set({
                    Title = "perdi Status",
                    Content = State.StatusText,
                })
            end)
        end

        task.wait(0.18)
    end
end

--============================================================================
-- LIFECYCLE & STARTUP
--============================================================================
local function cleanup()
    State.Running = false
    if State.ActiveTween then
        pcall(function()
            State.ActiveTween:Cancel()
        end)
    end
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
    globalEnv.__PERDI_CU_CLEANUP = nil
end

globalEnv.__PERDI_CU_CLEANUP = cleanup

initWorkspaceCacheAsync()
applyAntiAFKState(Config.AntiAFK)

table.insert(Connections, LocalPlayer.Idled:Connect(function()
    if Config.AntiAFK then
        sendAntiAFKPulse()
    end
end))

table.insert(Connections, LocalPlayer.CharacterAdded:Connect(function()
    State.LastProgressChangeAt = 0
    State.CultivateAttemptCount = 0
    if Config.AntiAFK then
        task.delay(1, function()
            if State.Running and Config.AntiAFK then
                applyAntiAFKState(true)
            end
        end)
    end
end))

table.insert(Connections, RunService.RenderStepped:Connect(stepRealmTrialAndTribulation))
task.spawn(runMainLoop)

pcall(function()
    Rayfield:LoadConfiguration()
end)

Rayfield:Notify({
    Title = "perdi",
    Content = "Cultivation Unbound (Mobile v2) loaded!",
    Duration = 4,
})
