--[[
    perdi | Fish, Train, Playtime Hop & Cloudphone Saver Hub (Rayfield UI)
    Features:
      - Auto Fish + Stop at Tier (1..10 / SEA KING) [Zero-Allocation Cached Engine]
      - Auto Perfect (Middle Bar) + Auto Perfect Reel (+25 Vertical Bar) [FPS-Independent]
      - Auto Train (Auto-learns plot bar offset & walks character into training circle on any server)
      - Auto 2x + Auto Upgrade
      - Auto Claim Playtime Rewards + Auto Server Hop once all 9 Playtime rewards are claimed
      - Cloudphone Saver: Potato Graphics, Hide Other Players/Plot Beasts, No-3D AFK Mode, 25 FPS Cap
      - Auto Save & Auto Load across Server Hops (JSON config + queue_on_teleport)
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
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
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
    ScriptURL = "https://pastebin.com/raw/AAbZU6nm",

    -- Cloudphone / Low-Spec Optimization Settings
    PotatoMode = false,
    HideOthers = false,
    Disable3DRender = false,
    CapFps25 = false,

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

loadPersistentConfig()

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
-- ZERO-ALLOCATION RUNTIME STATE & EVENT CACHES
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
    LastHideSweepAt = 0,
    HoppingInProgress = false,
    PlaytimeStatus = "Waiting...",
    LastShownPlaytimeStatus = "",
    LastAntiAfkPulseAt = os.clock(),
    PendingTapRelease = false,
    OwnedPlotPos = nil,
    LastPlotCheckAt = 0,

    -- Strong flat numeric maps cleared when bar closes (Luau weak tables drop Instance keys!)
    PrevMiddleX = {},
    PrevMiddleY = {},
    PrevReelX = {},
    PrevReelY = {},
}

local Connections = {}
local OriginalIdleConnections = nil

-- Strong live registries cleaned via DescendantRemoving (never use __mode="k" for Instances in Luau!)
local ShownPrompts = {}       -- [ProximityPrompt currently on screen] = true
local ActivePrompts = {}      -- [ProximityPrompt in Workspace] = true
local PlotSignLabels = {}     -- [TextLabel in Workspace] = true
local GuiTextPool = {}        -- [TextLabel / TextButton in PlayerGui] = true
local GuiButtonPool = {}      -- [GuiButton in PlayerGui] = true

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
            if nl:find("rayfield", 1, true) or nl:find("sirius", 1, true) or nl == "perdiafkoverlay" then
                return true
            end
        end
        cur = cur.Parent
    end
    return false
end

local CachedRayfieldGuis = {}
local LastRayfieldGuiCheckAt = 0

local function getRayfieldScreenGuis()
    local now = os.clock()
    if (now - LastRayfieldGuiCheckAt) < 1.5 and #CachedRayfieldGuis > 0 then
        return CachedRayfieldGuis
    end
    LastRayfieldGuiCheckAt = now

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
local LastPurchaseState = false

local function isPurchasePromptOpen()
    local now = os.clock()
    if (now - LastPurchaseCheckAt) < 0.5 then
        return LastPurchaseState
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
    LastPurchaseState = (ok and open) or false
    return LastPurchaseState
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
            if nl:find("rayfield", 1, true) or nl:find("sirius", 1, true) or nl == "perdiafkoverlay" then
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
-- CLOUDPHONE GRAPHICS & MEMORY OPTIMIZER
--============================================================================
local AfkOverlayGui = nil
local AfkToggleCallbackRef = nil

local function stripLagFromInstance(obj)
    if not obj or not obj.Parent then
        return
    end
    if obj:IsA("BasePart") then
        pcall(function()
            obj.CastShadow = false
            obj.Reflectance = 0
            if not obj:IsA("Terrain") then
                obj.Material = Enum.Material.SmoothPlastic
            end
        end)
    elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")
        or obj:IsA("Sparkles") or obj:IsA("Fire") or obj:IsA("Smoke")
        or obj:IsA("Highlight") or obj:IsA("PointLight")
        or obj:IsA("SpotLight") or obj:IsA("SurfaceLight")
    then
        pcall(function()
            obj.Enabled = false
        end)
    elseif (obj:IsA("Decal") or obj:IsA("Texture")) and obj:IsDescendantOf(Workspace) then
        -- Keep plot sign SurfaceGuis intact (TextLabels); only hide heavy 3D part textures/decals
        local char = LocalPlayer.Character
        if not char or not obj:IsDescendantOf(char) then
            pcall(function()
                obj.Transparency = 1
            end)
        end
    elseif obj:IsA("PostEffect") or obj:IsA("Atmosphere") or obj:IsA("Clouds") then
        pcall(function()
            if obj:IsA("PostEffect") then
                obj.Enabled = false
            elseif obj:IsA("Clouds") then
                obj.Enabled = false
            elseif obj:IsA("Atmosphere") then
                obj.Density = 0
            end
        end)
    end
end

local PotatoSweepRunning = false
local function applyPotatoGraphics(enabled)
    if not enabled then
        return
    end

    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)

    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 9e9
        Lighting.Brightness = 1
        for _, child in ipairs(Lighting:GetChildren()) do
            stripLagFromInstance(child)
        end
    end)

    pcall(function()
        local terrain = Workspace:FindFirstChildOfClass("Terrain")
        if terrain then
            terrain.WaterWaveSize = 0
            terrain.WaterWaveSpeed = 0
            terrain.WaterReflectance = 0
            terrain.WaterTransparency = 0
            pcall(function()
                terrain.Decoration = false
            end)
        end
    end)

    if PotatoSweepRunning then
        return
    end
    PotatoSweepRunning = true

    -- Yielded batch sweep so enabling Potato Mode never stalls a Cloudphone!
    task.spawn(function()
        local children = Workspace:GetDescendants()
        for i, inst in ipairs(children) do
            if not State.Running or not Config.PotatoMode then
                break
            end
            stripLagFromInstance(inst)
            if i % 350 == 0 then
                task.wait()
            end
        end
        PotatoSweepRunning = false
    end)
end

local function hideCharacterVisuals(char)
    if not char then
        return
    end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            pcall(function()
                d.LocalTransparencyModifier = 1
                d.CastShadow = false
            end)
        elseif d:IsA("Decal") or d:IsA("Texture") then
            pcall(function()
                d.Transparency = 1
            end)
        elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Highlight") then
            pcall(function()
                d.Enabled = false
            end)
        end
    end
end

local function restoreCharacterVisuals(char)
    if not char then
        return
    end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
            pcall(function()
                d.LocalTransparencyModifier = 0
            end)
        end
    end
end

local function sweepHideOthersAndPlotBeasts()
    if not Config.HideOthers then
        return
    end

    -- 1) Hide all other players' avatars
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            hideCharacterVisuals(plr.Character)
        end
    end

    -- 2) Hide giant animated Sea Beasts / Pets on OTHER players' plots (never touches floors or Abyss Holes)
    local myPlot = State.OwnedPlotPos
    for _, topChild in ipairs(Workspace:GetChildren()) do
        local nl = topChild.Name:lower()
        if nl:find("plot", 1, true) or nl:find("base", 1, true) or nl:find("aquarium", 1, true)
            or nl:find("pen", 1, true) or nl:find("animal", 1, true) or nl:find("pet", 1, true)
        then
            for _, sub in ipairs(topChild:GetDescendants()) do
                if sub:IsA("AnimationController") or (sub:IsA("Humanoid") and sub.Parent ~= LocalPlayer.Character) then
                    local mdl = sub.Parent
                    if mdl and mdl:IsA("Model") then
                        local ok, piv = pcall(function()
                            return mdl:GetPivot()
                        end)
                        local isFarFromMyPlot = true
                        if ok and piv and myPlot and (piv.Position - myPlot).Magnitude < 75 then
                            isFarFromMyPlot = false
                        end
                        if isFarFromMyPlot then
                            hideCharacterVisuals(mdl)
                        end
                    end
                end
            end
        end
    end
end

local function applyFpsCapState(enabled)
    local capFn = (typeof(setfpscap) == "function" and setfpscap)
        or (typeof(set_fps_cap) == "function" and set_fps_cap)
    if capFn then
        pcall(function()
            capFn(enabled and 25 or 60)
        end)
    end
end

local function ensureAfkOverlayGui()
    if AfkOverlayGui and AfkOverlayGui.Parent then
        return AfkOverlayGui
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = "perdiAfkOverlay"
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 10
    sg.ResetOnSpawn = false

    local parentTarget = PlayerGui
    if typeof(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then
            parentTarget = hui
        end
    else
        pcall(function()
            parentTarget = CoreGui
        end)
    end
    sg.Parent = parentTarget

    -- IMPORTANT: Never place a fullscreen Frame in CoreGui/gethui, or it blocks PlayerGui touches!
    -- Only show a compact corner button so gameplay bars & taps work 100% unobstructed.
    local restoreBtn = Instance.new("TextButton")
    restoreBtn.Name = "Restore3DBtn"
    restoreBtn.Size = UDim2.new(0, 175, 0, 30)
    restoreBtn.Position = UDim2.new(0, 14, 0, 62)
    restoreBtn.BackgroundColor3 = Color3.fromRGB(24, 30, 38)
    restoreBtn.BorderSizePixel = 0
    restoreBtn.Font = Enum.Font.GothamSemibold
    restoreBtn.TextSize = 12
    restoreBtn.TextColor3 = Color3.fromRGB(160, 235, 185)
    restoreBtn.Text = "No-3D ON (Tap to Restore)"
    restoreBtn.Parent = sg

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = restoreBtn

    restoreBtn.Activated:Connect(function()
        Config.Disable3DRender = false
        savePersistentConfig()
        pcall(function()
            RunService:Set3dRenderingEnabled(true)
        end)
        sg.Enabled = false
        if AfkToggleCallbackRef then
            pcall(function()
                AfkToggleCallbackRef:Set(false)
            end)
        end
    end)

    AfkOverlayGui = sg
    return sg
end

local function applyNo3DRenderState(enabled)
    local sg = ensureAfkOverlayGui()
    sg.Enabled = enabled and true or false
    pcall(function()
        RunService:Set3dRenderingEnabled(not enabled)
    end)
end

--============================================================================
-- LIVE EVENT REGISTRIES (Eliminates GetDescendants Lag Spikes!)
--============================================================================
local function registerWorkspaceInstance(inst)
    if not inst then
        return
    end
    if inst:IsA("ProximityPrompt") then
        ActivePrompts[inst] = true
    elseif inst:IsA("TextLabel") then
        local up = stripRichText(inst.Text or ""):upper()
        if up == "YOURS" or inst.Parent and (inst.Parent:IsA("BillboardGui") or inst.Parent:IsA("SurfaceGui")) then
            PlotSignLabels[inst] = true
        end
    end
    if Config.PotatoMode then
        stripLagFromInstance(inst)
    end
end

local function registerPlayerGuiInstance(inst)
    if not inst or isRayfieldInstance(inst) then
        return
    end
    if inst:IsA("TextLabel") or inst:IsA("TextButton") then
        GuiTextPool[inst] = true
    end
    if inst:IsA("GuiButton") then
        GuiButtonPool[inst] = true
    end
end

local function initializeCachesAsync()
    -- Track currently visible ProximityPrompts directly from Roblox's ProximityPromptService!
    pcall(function()
        table.insert(Connections, ProximityPromptService.PromptShown:Connect(function(prompt)
            if prompt then
                ShownPrompts[prompt] = true
                ActivePrompts[prompt] = true
            end
        end))
        table.insert(Connections, ProximityPromptService.PromptHidden:Connect(function(prompt)
            if prompt then
                ShownPrompts[prompt] = nil
            end
        end))
    end)

    -- Register live listeners immediately so nothing is missed
    table.insert(Connections, Workspace.DescendantAdded:Connect(registerWorkspaceInstance))
    table.insert(Connections, Workspace.DescendantRemoving:Connect(function(inst)
        ShownPrompts[inst] = nil
        ActivePrompts[inst] = nil
        PlotSignLabels[inst] = nil
    end))

    table.insert(Connections, PlayerGui.DescendantAdded:Connect(registerPlayerGuiInstance))
    table.insert(Connections, PlayerGui.DescendantRemoving:Connect(function(inst)
        GuiTextPool[inst] = nil
        GuiButtonPool[inst] = nil
    end))

    -- Instant spatial scan around player so nearby Abyss Hole / Bar prompts work in 0.00s!
    pcall(function()
        local char = LocalPlayer.Character
        local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
        if root then
            for _, part in ipairs(Workspace:GetPartBoundsInRadius(root.Position, 28)) do
                registerWorkspaceInstance(part)
                for _, d in ipairs(part:GetDescendants()) do
                    registerWorkspaceInstance(d)
                end
                if part.Parent then
                    for _, sib in ipairs(part.Parent:GetChildren()) do
                        if sib:IsA("ProximityPrompt") then
                            ActivePrompts[sib] = true
                        end
                    end
                end
            end
        end
    end)

    -- Yielded one-time bootstrap scan (zero frame spike on Cloudphones)
    task.spawn(function()
        for i, inst in ipairs(PlayerGui:GetDescendants()) do
            if not State.Running then
                return
            end
            registerPlayerGuiInstance(inst)
            if i % 2000 == 0 then
                task.wait()
            end
        end
    end)

    task.spawn(function()
        for i, inst in ipairs(Workspace:GetDescendants()) do
            if not State.Running then
                return
            end
            registerWorkspaceInstance(inst)
            if i % 1500 == 0 then
                task.wait()
            end
        end
    end)
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
    if btn and btn:IsA("TextButton") and stripRichText(btn.Text or ""):upper() == "STOP" then
        return false
    end

    local clickTarget = btn or targetGui
    local inset = GuiService:GetGuiInset()
    local vpX = clickTarget.AbsolutePosition.X + clickTarget.AbsoluteSize.X * 0.5 + inset.X
    local vpY = clickTarget.AbsolutePosition.Y + clickTarget.AbsoluteSize.Y * 0.5 + inset.Y

    -- Prefer VirtualInputManager tap first when unobstructed (works on all Android Cloudphone UI buttons!)
    if not isPointCoveredByRayfield(vpX, vpY) then
        if sendScreenTap(vpX, vpY) then
            return true
        end
    else
        -- If "Show Rayfield" badge covers top-center of a button, try bottom edge of that button
        local altY = clickTarget.AbsolutePosition.Y + clickTarget.AbsoluteSize.Y * 0.85 + inset.Y
        if clickTarget.AbsoluteSize.Y >= 24 and not isPointCoveredByRayfield(vpX, altY) then
            if sendScreenTap(vpX, altY) then
                return true
            end
        end
    end

    -- Fallback to signal firing if Rayfield window is covering the button
    if btn and fireSingleButtonSignal(btn) then
        return true
    end
    return false
end

-- Pre-allocated candidate ratios so fireInstantMiddleTap allocates zero tables
local TAP_RATIO_X = { 0.18, 0.82, 0.50, 0.18, 0.82 }
local TAP_RATIO_Y = { 0.32, 0.32, 0.28, 0.60, 0.60 }

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

    local vpX = math.floor(vs.X * TAP_RATIO_X[1])
    local vpY = math.floor(vs.Y * TAP_RATIO_Y[1])
    for i = 1, #TAP_RATIO_X do
        local cx = vs.X * TAP_RATIO_X[i]
        local cy = vs.Y * TAP_RATIO_Y[i]
        if not isPointCoveredByRayfield(cx, cy) then
            vpX, vpY = math.floor(cx), math.floor(cy)
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
-- CHARACTER & CACHED PROXIMITY PROMPT HELPERS (0 Workspace:GetDescendants!)
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
    -- 1) Instant check: prompts Roblox is actively showing on screen right now!
    for prompt in pairs(ShownPrompts) do
        if not prompt.Parent then
            ShownPrompts[prompt] = nil
        elseif prompt.Enabled then
            local actionText = stripRichText(prompt.ActionText or ""):lower()
            local objectText = stripRichText(prompt.ObjectText or ""):lower()
            if predicate(actionText, objectText, prompt) then
                return prompt
            end
        end
    end

    -- 2) Cached Workspace prompt registry check
    local _, root = getCharacterAndRoot()
    if not root then
        return nil
    end
    local rootPos = root.Position
    local bestPrompt = nil
    local bestDist = math.huge

    for desc in pairs(ActivePrompts) do
        if not desc.Parent then
            ActivePrompts[desc] = nil
        elseif desc.Enabled then
            local actionText = stripRichText(desc.ActionText or ""):lower()
            local objectText = stripRichText(desc.ObjectText or ""):lower()
            if predicate(actionText, objectText, desc) then
                local promptPos = getPromptWorldPosition(desc)
                if promptPos then
                    local dist = (promptPos - rootPos).Magnitude
                    local maxDist = customMaxRadius or ((desc.MaxActivationDistance or 10) + 4)
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
local CachedStopBtn = nil

local function isCurrentlyTraining()
    if CachedStopBtn and CachedStopBtn.Parent and isVisibleTextElement(CachedStopBtn) then
        if stripRichText(CachedStopBtn.Text or ""):upper() == "STOP" then
            return true
        end
    end
    for d in pairs(GuiTextPool) do
        if d.Parent and isVisibleTextElement(d) then
            if stripRichText(d.Text or ""):upper() == "STOP" then
                CachedStopBtn = d
                return true
            end
        end
    end
    return false
end

local function findOwnedPlotAnchorPos()
    local now = os.clock()
    if State.OwnedPlotPos and (now - State.LastPlotCheckAt) < 15.0 then
        return State.OwnedPlotPos
    end
    State.LastPlotCheckAt = now

    for d in pairs(PlotSignLabels) do
        if d.Parent and stripRichText(d.Text or ""):upper() == "YOURS" then
            local gui = d:FindFirstAncestorWhichIsA("BillboardGui") or d:FindFirstAncestorWhichIsA("SurfaceGui")
            if gui and gui.Adornee and gui.Adornee:IsA("BasePart") then
                State.OwnedPlotPos = gui.Adornee.Position
                return State.OwnedPlotPos
            end
            local part = d:FindFirstAncestorWhichIsA("BasePart")
            if part then
                State.OwnedPlotPos = part.Position
                return State.OwnedPlotPos
            end
        end
    end
    return State.OwnedPlotPos
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

    for desc in pairs(ActivePrompts) do
        if desc.Parent and desc.Enabled then
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

local CachedTrainPadPart = nil

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

    -- 1) Use saved plot-relative offset if learned
    if upgradePart and Config.BarOffsetX and Config.BarOffsetY and Config.BarOffsetZ then
        local localOffset = Vector3.new(Config.BarOffsetX, Config.BarOffsetY, Config.BarOffsetZ)
        if localOffset.Magnitude <= 35 then
            return upgradePart.CFrame:PointToWorldSpace(localOffset)
        end
    end

    -- 2) Check cached pad part if already found near this plot
    if CachedTrainPadPart and CachedTrainPadPart.Parent and (CachedTrainPadPart.Position - promptPos).Magnitude <= 30 then
        return CachedTrainPadPart.Position
    end

    -- 3) Local search only around the upgrade prompt's ancestor model/plot (not all Workspace!)
    local localContainer = upgradePrompt:FindFirstAncestorOfClass("Model")
    if localContainer and localContainer.Parent and localContainer.Parent ~= Workspace then
        localContainer = localContainer.Parent
    end

    if localContainer then
        local bestTouchPart = nil
        local bestTouchDist = math.huge
        for _, obj in ipairs(localContainer:GetDescendants()) do
            if obj:IsA("BasePart") and math.abs(obj.Position.Y - root.Position.Y) <= 14 then
                local dist = (obj.Position - promptPos).Magnitude
                if dist <= 28 and obj:FindFirstChildOfClass(CLS_TOUCH) then
                    if dist < bestTouchDist then
                        bestTouchDist = dist
                        bestTouchPart = obj
                    end
                end
            end
        end
        if bestTouchPart then
            CachedTrainPadPart = bestTouchPart
            return bestTouchPart.Position
        end
    end

    -- 4) Fallback: probe around Upgrade prompt until "STOP" triggers, then auto-save!
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

        State.PlaytimeStatus = "Fallback teleporting to another server..."
        pcall(function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
        task.wait(6)
        State.HoppingInProgress = false
    end)
end

local function findRewardsHudOpenButton()
    for d in pairs(GuiTextPool) do
        if d.Parent and isVisibleTextElement(d) then
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
    for d in pairs(GuiButtonPool) do
        if d.Parent and isGuiChainVisible(d) and d.AbsolutePosition.Y < 160 then
            local nl = d.Name:lower()
            if nl:find("reward", 1, true) or nl:find("playtime", 1, true) or nl:find("gift", 1, true) then
                return d
            end
        end
    end
    return nil
end

local function hasHiddenOrVisibleReadyPlaytime()
    for d in pairs(GuiTextPool) do
        if d.Parent then
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
    local playtimeTabBtn = nil
    local rewardsTitle = nil

    for d in pairs(GuiTextPool) do
        if d.Parent and isVisibleTextElement(d) then
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
    if (now - State.JoinedAt) < 5.0 then
        return
    end
    if (now - State.LastPlaytimeScanAt) < 5.5 then
        return
    end
    State.LastPlaytimeScanAt = now

    local openInfo = findOpenRewardsModal()
    local hasReadySignal = hasHiddenOrVisibleReadyPlaytime()
    local duePeriodicVerify = (now - State.LastFullPlaytimeVerifyAt) >= 45.0

    if not openInfo and not hasReadySignal and not duePeriodicVerify then
        return
    end

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

    local grid = inspectPlaytimeGrid(openInfo.Modal)
    if not grid.SubtitleSeen and openInfo.PlaytimeTabBtn then
        clickGuiElement(openInfo.PlaytimeTabBtn)
        task.wait(0.30)
        grid = inspectPlaytimeGrid(openInfo.Modal)
    end

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

    if openedByScript and openInfo.CloseBtn then
        clickGuiElement(openInfo.CloseBtn)
    end
end

--============================================================================
-- FPS-INDEPENDENT ZERO-ALLOCATION AUTO MIDDLE (RenderStepped)
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

local function stepAutoMiddle()
    if not State.Running or not Config.AutoPerfect then
        return
    end

    local now = os.clock()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    local screenGui = nil
    local trackObj = nil
    local curX = nil
    local dx = 0
    local middleX = screenW * 0.5
    local yellowHalfW = screenW * 0.018

    if CachedBar.Header and isVisibleTextElement(CachedBar.Header)
        and CachedBar.Cursor and isGuiChainVisible(CachedBar.Cursor)
    then
        local cursor = CachedBar.Cursor
        local cx = cursor.AbsolutePosition.X + cursor.AbsoluteSize.X * 0.5
        local cy = cursor.AbsolutePosition.Y + cursor.AbsoluteSize.Y * 0.5
        local prevX = State.PrevMiddleX[cursor]
        dx = prevX and (cx - prevX) or 0
        State.PrevMiddleX[cursor] = cx
        State.PrevMiddleY[cursor] = cy

        local track = (CachedBar.Track and isGuiChainVisible(CachedBar.Track)) and CachedBar.Track or nil
        middleX = track and (track.AbsolutePosition.X + track.AbsoluteSize.X * 0.5) or (screenW * 0.5)
        yellowHalfW = track and (track.AbsoluteSize.X * 0.042) or (screenW * 0.018)
        screenGui = CachedBar.ScreenGui
        trackObj = track
        curX = cx
    else
        if not CachedBar.Header or not isVisibleTextElement(CachedBar.Header) then
            if (now - CachedBar.LastIdleScanAt) < 0.10 then
                return
            end
            CachedBar.LastIdleScanAt = now
            CachedBar.Header = nil
            CachedBar.Cursor = nil
            CachedBar.Track = nil
            table.clear(State.PrevMiddleX)
            table.clear(State.PrevMiddleY)

            for _, desc in ipairs(PlayerGui:GetDescendants()) do
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
                return
            end
        end

        local searchRoot = CachedBar.ScreenGui or PlayerGui
        local bestCursor = nil
        local bestSpeed = 0
        local bestDx = 0

        for _, obj in ipairs(searchRoot:GetDescendants()) do
            if obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
                local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
                if sx >= 2 and sx <= screenW * 0.12 and sy >= 8 and sy <= screenH * 0.35 and sx <= sy * 1.5 then
                    local cx = obj.AbsolutePosition.X + sx * 0.5
                    local cy = obj.AbsolutePosition.Y + sy * 0.5
                    local px = State.PrevMiddleX[obj]
                    local py = State.PrevMiddleY[obj]
                    State.PrevMiddleX[obj] = cx
                    State.PrevMiddleY[obj] = cy

                    if px and py then
                        local stepDx = cx - px
                        local stepDy = cy - py
                        if math.abs(stepDx) > 0.3 and math.abs(stepDy) < 1.5 then
                            if math.abs(stepDx) > bestSpeed then
                                bestSpeed = math.abs(stepDx)
                                bestDx = stepDx
                                bestCursor = obj
                            end
                        end
                    end
                end
            end
        end

        if not bestCursor then
            return
        end

        CachedBar.Cursor = bestCursor
        CachedBar.Track = findTrackForCursor(bestCursor, searchRoot, screenW)
        curX = bestCursor.AbsolutePosition.X + bestCursor.AbsoluteSize.X * 0.5
        dx = bestDx
        local track = CachedBar.Track
        middleX = track and (track.AbsolutePosition.X + track.AbsoluteSize.X * 0.5) or (screenW * 0.5)
        yellowHalfW = track and (track.AbsoluteSize.X * 0.042) or (screenW * 0.018)
        screenGui = CachedBar.ScreenGui
        trackObj = track
    end

    if (now - State.LastPerfectTapAt) < 0.30 then
        return
    end

    local prevX = curX - dx
    local predictedX = curX + dx * 0.85
    local tolerance = math.max(yellowHalfW * 0.65, 4)

    local prevDelta = prevX - middleX
    local predDelta = predictedX - middleX

    local insideYellow = math.abs(predDelta) <= tolerance
    local crossedMiddle = (math.abs(dx) > 0.3)
        and ((prevDelta <= 0 and predDelta >= 0) or (prevDelta >= 0 and predDelta <= 0))

    if insideYellow or crossedMiddle then
        if fireInstantMiddleTap(screenGui, trackObj) then
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

local function stepAutoPerfectReel()
    if not State.Running or not Config.AutoPerfectReel then
        return
    end

    local now = os.clock()
    local cam = Workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local screenW, screenH = vs.X, vs.Y

    local screenGui = nil
    local trackObj = nil
    local curY = nil
    local dy = 0
    local topY = screenH * 0.21
    local barH = screenH * 0.52

    if CachedReelBar.Header and isVisibleTextElement(CachedReelBar.Header)
        and CachedReelBar.Cursor and isGuiChainVisible(CachedReelBar.Cursor)
    then
        local cursor = CachedReelBar.Cursor
        local cx = cursor.AbsolutePosition.X + cursor.AbsoluteSize.X * 0.5
        local cy = cursor.AbsolutePosition.Y + cursor.AbsoluteSize.Y * 0.5
        local py = State.PrevReelY[cursor]
        dy = py and (cy - py) or 0
        State.PrevReelX[cursor] = cx
        State.PrevReelY[cursor] = cy

        local track = (CachedReelBar.Track and isGuiChainVisible(CachedReelBar.Track)) and CachedReelBar.Track or nil
        topY = track and track.AbsolutePosition.Y or CachedReelBar.FallbackTopY or (screenH * 0.21)
        barH = track and track.AbsoluteSize.Y or (screenH * 0.52)
        screenGui = CachedReelBar.ScreenGui
        trackObj = track
        curY = cy
    else
        if not CachedReelBar.Header or not isVisibleTextElement(CachedReelBar.Header) then
            if (now - CachedReelBar.LastIdleScanAt) < 0.10 then
                return
            end
            CachedReelBar.LastIdleScanAt = now
            CachedReelBar.Header = nil
            CachedReelBar.Cursor = nil
            CachedReelBar.Track = nil
            CachedReelBar.FallbackTopY = nil
            table.clear(State.PrevReelX)
            table.clear(State.PrevReelY)

            for _, desc in ipairs(PlayerGui:GetDescendants()) do
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
                return
            end
        end

        local searchRoot = CachedReelBar.ScreenGui or PlayerGui
        local bestCursor = nil
        local bestSpeed = 0
        local bestDy = 0

        for _, obj in ipairs(searchRoot:GetDescendants()) do
            if obj:IsA("GuiObject") and not obj:IsA("TextLabel") and isGuiChainVisible(obj) then
                local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
                if sy >= 2 and sy <= screenH * 0.12 and sx >= 12 and sx <= screenW * 0.35 and sy <= sx * 1.3 then
                    local cx = obj.AbsolutePosition.X + sx * 0.5
                    local cy = obj.AbsolutePosition.Y + sy * 0.5
                    local px = State.PrevReelX[obj]
                    local py = State.PrevReelY[obj]
                    State.PrevReelX[obj] = cx
                    State.PrevReelY[obj] = cy

                    if px and py then
                        local stepDx = cx - px
                        local stepDy = cy - py
                        if math.abs(stepDy) > 0.3 and math.abs(stepDx) < 1.5 then
                            if math.abs(stepDy) > bestSpeed then
                                bestSpeed = math.abs(stepDy)
                                bestDy = stepDy
                                bestCursor = obj
                            end
                        end
                    end
                end
            end
        end

        if not bestCursor then
            return
        end

        CachedReelBar.Cursor = bestCursor
        CachedReelBar.Track = findVerticalTrackForCursor(bestCursor, searchRoot, screenH)
        CachedReelBar.FallbackTopY = findTopPerfectAnchorY(searchRoot)

        curY = bestCursor.AbsolutePosition.Y + bestCursor.AbsoluteSize.Y * 0.5
        dy = bestDy
        local track = CachedReelBar.Track
        topY = track and track.AbsolutePosition.Y or CachedReelBar.FallbackTopY or (screenH * 0.21)
        barH = track and track.AbsoluteSize.Y or (screenH * 0.52)
        screenGui = CachedReelBar.ScreenGui
        trackObj = track
    end

    if (now - State.LastReelTapAt) < 0.35 then
        return
    end

    local predictedY = curY + dy * 0.85
    local perfectZoneBottom = topY + math.max(barH * 0.042, 6)
    local perfectZoneTop = topY - math.max(barH * 0.06, 12)

    if predictedY <= perfectZoneBottom and curY >= perfectZoneTop and dy <= 1.0 then
        if fireInstantMiddleTap(screenGui, trackObj) then
            State.LastReelTapAt = now
        end
    end
end

--============================================================================
-- TIER LADDER DETECTOR + REEL IN / GO DEEPER (Cached Pool - Zero Lag!)
--============================================================================
local CachedSeaKingLbl = nil

local function detectTierFromLadder(searchRoot)
    local seaKingLabel = nil
    if CachedSeaKingLbl and CachedSeaKingLbl.Parent and isVisibleTextElement(CachedSeaKingLbl) then
        seaKingLabel = CachedSeaKingLbl
    else
        for desc in pairs(GuiTextPool) do
            if desc.Parent and desc:IsA("TextLabel") and desc:IsDescendantOf(searchRoot) and isVisibleTextElement(desc) then
                if stripRichText(desc.Text or ""):upper() == "SEA KING" then
                    seaKingLabel = desc
                    CachedSeaKingLbl = desc
                    break
                end
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

local CachedReelLbl = nil
local CachedDeeperLbl = nil

local function findDecisionContext()
    local reelLabel = nil
    local deeperLabel = nil

    if CachedReelLbl and CachedReelLbl.Parent and isVisibleTextElement(CachedReelLbl) then
        local up = stripRichText(CachedReelLbl.Text or ""):upper()
        if up == "REEL IN" or up:find("^REEL IN") then
            reelLabel = CachedReelLbl
        end
    end
    if CachedDeeperLbl and CachedDeeperLbl.Parent and isVisibleTextElement(CachedDeeperLbl) then
        local up = stripRichText(CachedDeeperLbl.Text or ""):upper()
        if up == "GO DEEPER" or up:find("^GO DEEPER") then
            deeperLabel = CachedDeeperLbl
        end
    end

    if not reelLabel and not deeperLabel then
        for desc in pairs(GuiTextPool) do
            if desc.Parent and isVisibleTextElement(desc) then
                local upper = stripRichText(desc.Text or ""):upper()
                if upper == "REEL IN" or upper:find("^REEL IN") then
                    reelLabel = desc
                    CachedReelLbl = desc
                elseif upper == "GO DEEPER" or upper:find("^GO DEEPER") then
                    deeperLabel = desc
                    CachedDeeperLbl = desc
                end
            end
        end
    end

    if not reelLabel and not deeperLabel then
        return nil
    end

    local searchRoot = (reelLabel or deeperLabel):FindFirstAncestorWhichIsA("LayerCollector") or PlayerGui
    local doubloonsText = ""
    local isFirstTierUncommonNext = false

    for desc in pairs(GuiTextPool) do
        if desc.Parent and desc:IsDescendantOf(searchRoot) and isVisibleTextElement(desc) then
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
local CachedFishAgainLbl = nil

local function tryClickFishAgain()
    if CachedFishAgainLbl and CachedFishAgainLbl.Parent and isVisibleTextElement(CachedFishAgainLbl) then
        if stripRichText(CachedFishAgainLbl.Text or ""):upper() == "FISH AGAIN" then
            if clickGuiElement(CachedFishAgainLbl) then
                return true
            end
        end
    end
    for desc in pairs(GuiTextPool) do
        if not desc.Parent then
            GuiTextPool[desc] = nil
        elseif isVisibleTextElement(desc) then
            if stripRichText(desc.Text or ""):upper() == "FISH AGAIN" then
                CachedFishAgainLbl = desc
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
    for desc in pairs(GuiTextPool) do
        if not desc.Parent then
            GuiTextPool[desc] = nil
        elseif isVisibleTextElement(desc) and desc.AbsolutePosition.Y > 90 then
            if stripRichText(desc.Text or ""):lower() == "2x" and isSafeGameplayElement(desc) then
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
-- BUILD RAYFIELD UI ("perdi")
--============================================================================
local Window = Rayfield:CreateWindow({
    Name = "perdi",
    Icon = 0,
    LoadingTitle = "perdi",
    LoadingSubtitle = "Cloudphone Optimized Auto Hub",
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

-- TAB 2: CLOUDPHONE OPTIMIZER
local OptTab = Window:CreateTab("Cloudphone", 4483362458)

OptTab:CreateSection("Anti-Crash & Low Graphics (Auto-Saved)")

OptTab:CreateToggle({
    Name = "Cloudphone Potato Graphics (Strip Lag)",
    CurrentValue = Config.PotatoMode,
    Callback = function(Value)
        Config.PotatoMode = Value
        savePersistentConfig()
        if Value then
            applyPotatoGraphics(true)
        end
    end,
})

OptTab:CreateToggle({
    Name = "Hide Other Players & Plot Beasts",
    CurrentValue = Config.HideOthers,
    Callback = function(Value)
        Config.HideOthers = Value
        savePersistentConfig()
        if Value then
            sweepHideOthersAndPlotBeasts()
        else
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and plr.Character then
                    restoreCharacterVisuals(plr.Character)
                end
            end
        end
    end,
})

AfkToggleCallbackRef = OptTab:CreateToggle({
    Name = "AFK No-3D Screen (Max GPU/RAM Saver)",
    CurrentValue = Config.Disable3DRender,
    Callback = function(Value)
        Config.Disable3DRender = Value
        savePersistentConfig()
        applyNo3DRenderState(Value)
    end,
})

OptTab:CreateToggle({
    Name = "Cloudphone 25 FPS Cap",
    CurrentValue = Config.CapFps25,
    Callback = function(Value)
        Config.CapFps25 = Value
        savePersistentConfig()
        applyFpsCapState(Value)
    end,
})

-- TAB 3: PLAYTIME & SERVER HOP
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
    PlaceholderText = "https://pastebin.com/raw/AAbZU6nm",
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

        -- 2) Periodic sweep for newly spawned avatars / plot beasts when HideOthers is ON
        if Config.HideOthers and (now - State.LastHideSweepAt) >= 8.0 then
            State.LastHideSweepAt = now
            findOwnedPlotAnchorPos()
            sweepHideOthersAndPlotBeasts()
        end

        local barActive = (CachedBar.Header and isVisibleTextElement(CachedBar.Header))
            or (CachedReelBar.Header and isVisibleTextElement(CachedReelBar.Header))

        -- 3) Auto Claim Playtime & Server Hop (runs when not mid-fishing bar)
        if Config.AutoPlaytime and not barActive then
            stepAutoPlaytimeAndHop()
        end

        -- 4) Auto Train (walks onto plot training area if not currently fishing or already training)
        if Config.AutoTrain and not Config.AutoFish and not barActive and not State.HoppingInProgress then
            stepAutoTrain()
        end

        -- 5) Auto Fish (Cast + Stop at Tier - Zero-Allocation Cached Engine)
        if Config.AutoFish and not State.HoppingInProgress then
            local middleBarActive = CachedBar.Header and isVisibleTextElement(CachedBar.Header)
            local decisionCtx = (not middleBarActive) and findDecisionContext() or nil

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

                if (now - State.LastCastAt) >= 1.1 and not isPurchasePromptOpen() then
                    local startedCast = false

                    -- 1) Click green "FISH AGAIN" button if visible at bottom of screen
                    if tryClickFishAgain() then
                        startedCast = true
                    else
                        -- 2) Otherwise trigger the Abyss Hole / Fish ProximityPrompt
                        local fishPrompt = findNearestPromptMatching(function(actionText, objectText)
                            return actionText == "fish"
                                or actionText:find("fish", 1, true) ~= nil
                                or objectText:find("abyss hole", 1, true) ~= nil
                                or objectText:find("hole", 1, true) ~= nil
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

        -- 6) Auto 2x
        if Config.Auto2x and (now - State.Last2xAt) >= 0.7 then
            if tryClick2x() then
                State.Last2xAt = now
            end
        end

        -- 7) Auto Upgrade
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

        task.wait(0.18)
    end
end

--============================================================================
-- LIFECYCLE & STARTUP
--============================================================================
local function cleanup()
    State.Running = false
    applyAntiAFKState(false)
    pcall(function()
        RunService:Set3dRenderingEnabled(true)
    end)
    if AfkOverlayGui then
        pcall(function()
            AfkOverlayGui:Destroy()
        end)
        AfkOverlayGui = nil
    end
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

initializeCachesAsync()
applyAntiAFKState(Config.AntiAFK)
recordCurrentServerVisited()
armQueueOnTeleport()

-- Apply saved Cloudphone optimizations automatically on startup / server hop!
if Config.PotatoMode then
    applyPotatoGraphics(true)
end
if Config.CapFps25 then
    applyFpsCapState(true)
end
if Config.Disable3DRender then
    applyNo3DRenderState(true)
end
if Config.HideOthers then
    task.delay(2.0, function()
        if State.Running and Config.HideOthers then
            findOwnedPlotAnchorPos()
            sweepHideOthersAndPlotBeasts()
        end
    end)
end

table.insert(Connections, LocalPlayer.OnTeleport:Connect(function()
    savePersistentConfig()
    armQueueOnTeleport()
end))

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
    Title = "perdi",
    Content = "Cloudphone Engine Ready! Saved config loaded.",
    Duration = 4,
})
