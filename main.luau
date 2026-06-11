-- ============================================================
--  Script
--  UI:      WindUI v1.6.53
--  Auth:    PandAuth Cookies v4.3
--
--  Tabs:  Movement | Fun | Misc
--  Premium-only features: Walk Fling, Vehicle Fling
-- ============================================================

-- ============================================================
--  EXECUTOR SANITY CHECKS
--  Verifies the executor exposes every API this script needs.
--  Halts with a clear warn() on anything critical.
--  Checks:
--    1) HTTP request function       — Auth + WindUI loader
--    2) loadstring                  — WindUI / PandAuth lib
--    3) setclipboard                — Copy-key button
--    4) clonefunction               — CBD immunity wrappers
--    5) newproxy(true)              — CBD metamethod probing
--    6) StudioService guard         — refuse to run in Studio
--    7) getgc (soft)                — CBD GC scanner (degrades)
-- ============================================================
do
    local function halt(msg)
        warn(msg)
        while true do task.wait(9e9) end
    end

    -- 1) HTTP request function — needed before anything else loads
    local httpOk = request or http_request or httprequest
               or (syn    and syn.request)
               or (http   and http.request)
               or (fluxus and fluxus.request)
    if not httpOk then
        halt("[SANITY] No HTTP request function found — executor unsupported.")
    end

    -- 2) loadstring — required to execute WindUI and PandAuth bodies
    if type(loadstring) ~= "function" then
        halt("[SANITY] loadstring is unavailable — executor unsupported.")
    end

    -- 3) setclipboard — used by the Copy Key button in the auth service
    if type(setclipboard) ~= "function" then
        warn("[SANITY] setclipboard unavailable — Copy Key button will not work.")
        -- non-fatal: rest of the script functions fine without it
        setclipboard = function() end
    end

    -- 4) clonefunction — required by CBD immunity wrappers (withImmunity)
    local cfOk = pcall(function()
        local dummy = function() end
        local clone = clonefunction(dummy)
        assert(type(clone) == "function")
    end)
    if not cfOk then
        halt("[SANITY] clonefunction unavailable or broken — fling engine cannot run.")
    end

    -- 5) newproxy(true) — required for CBD safe metamethod probing
    local npOk = pcall(function()
        local p  = newproxy(true)
        local mt = getmetatable(p)
        mt.__tostring = function() return "cbd_probe" end
        assert(tostring(p) == "cbd_probe")
    end)
    if not npOk then
        halt("[SANITY] newproxy/metatable probe failed — executor unsupported.")
    end

    -- 6) Studio guard — StudioService only exists inside Roblox Studio
    local inStudio = pcall(function() return game:GetService("StudioService") end)
    if inStudio then
        halt("[SANITY] StudioService detected — refusing to run inside Studio.")
    end

    -- 7) getgc — soft check; CBD GC scanner degrades gracefully without it
    if type(getgc) ~= "function" then
        warn("[SANITY] getgc unavailable — GC scanner will be disabled.")
    end
end

-- ─────────────────────────────────────────────
--  Services
-- ─────────────────────────────────────────────
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local player            = Players.LocalPlayer

-- ─────────────────────────────────────────────
--  HTTP helper
-- ─────────────────────────────────────────────
local httpReq = request
    or http_request
    or httprequest
    or (syn    and syn.request)
    or (http   and http.request)
    or (fluxus and fluxus.request)

if not httpReq then
    return warn("[Auth] Executor has no HTTP request function.")
end

-- ─────────────────────────────────────────────
--  Fetch PandAuth Cookies v4.3 library
-- ─────────────────────────────────────────────
local resp       = httpReq({ Url = "https://secure.pandauth.com/cv4/lib", Method = "GET" })
local body       = resp.Body       or resp.body       or ""
local statusCode = resp.StatusCode or resp.statusCode or 0

if statusCode < 200 or statusCode >= 300 or #body < 100 then
    return warn("[Auth] Bad lib response: status=" .. statusCode)
end

local Cookies = loadstring(body)()
if not Cookies or type(Cookies.configure) ~= "function" then
    return warn("[Auth] Library failed to initialize.")
end

-- ─────────────────────────────────────────────
--  Configure PandAuth
-- ─────────────────────────────────────────────
Cookies.configure({
    serviceId         = "scprp",
    kickOnDetect      = false,
    openDashboard     = true,
    validationTimeout = 600,
})

-- ─────────────────────────────────────────────
--  isPremium — set once, read everywhere
-- ─────────────────────────────────────────────
local isPremium = false

-- ─────────────────────────────────────────────
--  Silent saved-key check (skip prompt if valid)
-- ─────────────────────────────────────────────
local savedKey     = Cookies.loadSavedKey()
local silentPassed = false

if savedKey and savedKey ~= "" then
    local silentResult = Cookies.validate(savedKey)
    if silentResult.success then
        isPremium    = silentResult.isPremium == true
        silentPassed = true
        print("[Auth] Silent auth passed. Premium:", isPremium)
    else
        Cookies.clearSavedKey()
    end
end

-- ─────────────────────────────────────────────
--  Load WindUI
-- ─────────────────────────────────────────────
local WindUI = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"
))()

-- ─────────────────────────────────────────────
--  Register PandAuth as a WindUI custom service
-- ─────────────────────────────────────────────
WindUI.Services.pandauth_cookies = {
    Name = "PandAuth",
    Icon = "shield-check",
    Args = { "ServiceId" },

    New = function(ServiceId)
        local function validateKey(key)
            if not key or key == "" then
                return false, "Please enter your key."
            end
            Cookies.configure({
                serviceId         = ServiceId,
                kickOnDetect      = false,
                openDashboard     = true,
                validationTimeout = 600,
            })
            local result = Cookies.validate(key)
            if not result.success then
                Cookies.clearSavedKey()
                return false, result.error or "Key is invalid."
            end
            Cookies.saveKey(key)
            isPremium = result.isPremium == true
            print("[Auth] Key validated. Premium:", isPremium)
            return true, "Authenticated!"
        end

        local function copyLink()
            local info = Cookies.copyGetKeyUrl()
            return setclipboard(info and info.url or "https://pandauth.com")
        end

        return { Verify = validateKey, Copy = copyLink }
    end,
}

-- ─────────────────────────────────────────────
--  Create Window
-- ─────────────────────────────────────────────
local Window = WindUI:CreateWindow({
    Title  = "My Hub",
    Icon   = "zap",
    Author = "by You",
    Folder = "MyHub",

    Size        = UDim2.fromOffset(580, 460),
    MinSize     = Vector2.new(560, 350),
    Transparent = true,
    Resizable   = true,
    Theme       = "Dark",
    ToggleKey   = Enum.KeyCode.RightShift,

    User = {
        Enabled   = true,
        Anonymous = false,
    },

    KeySystem = not silentPassed and {
        Note    = "Enter your PandAuth key to continue.",
        SaveKey = true,
        API = {
            {
                Type      = "pandauth_cookies",
                ServiceId = "scprp",
            },
        },
    } or nil,
})

-- ─────────────────────────────────────────────
--  Window Tag — Premium or Free badge
-- ─────────────────────────────────────────────
if isPremium then
    Window:Tag({
        Title  = "Premium",
        Icon   = "crown",
        Color  = Color3.fromHex("#FFD700"),
        Radius = 6,
    })
else
    Window:Tag({
        Title  = "Free",
        Icon   = "user",
        Color  = Color3.fromHex("#a0a0a0"),
        Radius = 6,
    })
end

-- ════════════════════════════════════════════
--  CHARACTER REFS  (shared by all features)
-- ════════════════════════════════════════════
local character, humanoid, rootPart

local function refreshRefs(char)
    character = char
    humanoid  = char:WaitForChild("Humanoid", 5)
    rootPart  = char:WaitForChild("HumanoidRootPart", 5)
end

if player.Character then refreshRefs(player.Character) end

player.CharacterAdded:Connect(function(newChar)
    refreshRefs(newChar)
end)

-- ════════════════════════════════════════════
--  PROPERTY OVERRIDE UTILITY
--  Hooks __index on target character parts so
--  that reads of specific properties return
--  constant values you define via addOverride().
--
--  Public API:
--    addOverride(partName, propertyName, fixedValue)
--      partName     – "Head"|"HumanoidRootPart"|"UpperTorso"|"LowerTorso"
--                     pass nil/false to apply to ALL four parts
--      propertyName – exact property string, e.g. "Transparency"
--      fixedValue   – constant returned on every read of that property
--
--    removeOverride(partName, propertyName)
--      Removes a previously registered override (nil/false = all parts).
--
--  Example calls (place these after this block, during init):
--    addOverride(nil,               "Transparency", 0)
--    addOverride("Head",            "Material",     Enum.Material.Plastic)
--    addOverride("HumanoidRootPart","CastShadow",   false)
--
--  Safe: pcall-wrapped, re-locks metatable, newcclosure when available,
--  idempotent (safe to call on the same part twice), GC-friendly weak table.
-- ════════════════════════════════════════════

-- Parts to hook (by name). Applied after each spawn.
local OVERRIDE_PART_NAMES = {
    "Head",
    "HumanoidRootPart",
    "UpperTorso",
    "LowerTorso",
}

-- ─────────────────────────────────────────────
--  Override registry
--  _overrides[partName][propertyName] = fixedValue
--  _overrides["*"][propertyName]      = fixedValue  (all parts)
-- ─────────────────────────────────────────────
local _overrides = { ["*"] = {} }
for _, _n in ipairs(OVERRIDE_PART_NAMES) do
    _overrides[_n] = {}
end

-- ─────────────────────────────────────────────
--  Idempotency guard
--  Weak keys so hooked parts are not kept alive
--  by this table after the character is destroyed.
-- ─────────────────────────────────────────────
local _hooked = setmetatable({}, { __mode = "k" })

-- ─────────────────────────────────────────────
--  Dummy RBXScriptSignal
--  Returned for DescendantAdded / ChildAdded reads.
--  Connect / Once / Wait are no-ops so no listener
--  ever fires.  Built once; shared by all parts.
-- ─────────────────────────────────────────────
local _dummySignal
do
    local _noop = function() end

    local _stubConn = newproxy(true)
    local _scmt     = getmetatable(_stubConn)
    _scmt.__index    = function(_, k)
        if k == "Connected" then return false end
        return _noop
    end
    _scmt.__newindex = _noop
    _scmt.__tostring = function() return "RBXScriptConnection{stub}" end

    _dummySignal = newproxy(true)
    local _dsmt  = getmetatable(_dummySignal)
    _dsmt.__index = function(_, k)
        if k == "Connect" or k == "Once" then
            return function(_, _cb) return _stubConn end
        end
        if k == "Wait"      then return function() return end end
        if k == "Connected" then return false end
        return _noop
    end
    _dsmt.__newindex = _noop
    _dsmt.__tostring = function() return "RBXScriptSignal{stub}" end
end

-- ─────────────────────────────────────────────
--  Wraps a function in newcclosure if available,
--  otherwise returns it as-is.
-- ─────────────────────────────────────────────
local function makeClosure(fn)
    if type(newcclosure) == "function" then
        return newcclosure(fn)
    end
    return fn
end

-- ─────────────────────────────────────────────
--  Applies the __index hook to a single part.
-- ─────────────────────────────────────────────
local function applyOverridesToPart(part)
    -- Only hook BaseParts; skip silently otherwise.
    local _ok, _isBase = pcall(function() return part:IsA("BasePart") end)
    if not _ok or not _isBase then return end

    -- Idempotency: don't double-hook the same instance.
    if _hooked[part] then return end

    local ok, err = pcall(function()
        local mt = getrawmetatable(part)

        setreadonly(mt, false)

        -- Capture original __index via rawget so we don't recurse
        -- through any hook that may already be installed.
        local originalIndex = rawget(mt, "__index")

        -- Snapshot the part name now (before the hook is live) so
        -- the closure doesn't need to read .Name through __index.
        local partName = part.Name

        mt.__index = makeClosure(function(self, key)

            -- ── Dummy-event stubs ──────────────────────────────────
            -- DescendantAdded and ChildAdded return a never-firing
            -- signal; any listener connected to them is a no-op.
            if key == "DescendantAdded" or key == "ChildAdded" then
                return _dummySignal
            end

            -- ── Property overrides ─────────────────────────────────
            -- Per-part table wins over wildcard table.
            local _partTbl = _overrides[partName]
            if _partTbl then
                local _v = _partTbl[key]
                if _v ~= nil then return _v end
            end
            local _wildTbl = _overrides["*"]
            if _wildTbl then
                local _v = _wildTbl[key]
                if _v ~= nil then return _v end
            end

            -- ── Pass-through (FindFirstChildOfClass, everything else)
            if type(originalIndex) == "function" then
                return originalIndex(self, key)
            elseif originalIndex ~= nil then
                return originalIndex[key]
            end
            return nil
        end)

        setreadonly(mt, true)
    end)

    if ok then
        _hooked[part] = true
    else
        warn("[Override] Failed on '" .. tostring(part.Name) .. "': " .. tostring(err))
    end
end

-- ─────────────────────────────────────────────
--  Applies overrides to all target parts in a
--  character. Called ~0.1 s after CharacterAdded
--  so parts are fully replicated.
-- ─────────────────────────────────────────────
local function applyOverridesToCharacter(char)
    task.wait(0.1)
    for _, partName in ipairs(OVERRIDE_PART_NAMES) do
        local part = char:FindFirstChild(partName)
        if part then
            applyOverridesToPart(part)
        end
    end
end

-- Hook into spawns (including the initial character if already present)
player.CharacterAdded:Connect(applyOverridesToCharacter)
if player.Character then
    task.spawn(applyOverridesToCharacter, player.Character)
end

-- ─────────────────────────────────────────────
--  addOverride(partName, propertyName, fixedValue)
--  Call this during initialisation to register
--  a property intercept.  Safe to call before or
--  after the character spawns.
-- ─────────────────────────────────────────────
function addOverride(partName, propertyName, fixedValue)
    assert(type(propertyName) == "string" and #propertyName > 0,
        "[Override] addOverride: propertyName must be a non-empty string")

    if partName == nil or partName == false then
        -- Register on every tracked part and the wildcard bucket.
        for _, _n in ipairs(OVERRIDE_PART_NAMES) do
            _overrides[_n][propertyName] = fixedValue
        end
        _overrides["*"][propertyName] = fixedValue
    else
        assert(_overrides[partName] ~= nil,
            "[Override] addOverride: unknown partName '" .. tostring(partName) .. "'")
        _overrides[partName][propertyName] = fixedValue
    end

    -- The hook closure reads _overrides by reference, so already-hooked
    -- parts pick up the new entry on the very next read automatically.
    -- We only need to hook parts that weren't hooked yet (e.g. addOverride
    -- called before the 0.1 s character delay has finished).
    local char = player.Character
    if char then
        local targets = (partName and partName ~= false)
                        and { partName }
                        or  OVERRIDE_PART_NAMES
        for _, _n in ipairs(targets) do
            local part = char:FindFirstChild(_n)
            if part and not _hooked[part] then
                applyOverridesToPart(part)
            end
        end
    end
end

-- ─────────────────────────────────────────────
--  removeOverride(partName, propertyName)
--  Removes a previously registered override.
--  The hook stays installed but falls through to
--  the original __index for this key from now on.
-- ─────────────────────────────────────────────
function removeOverride(partName, propertyName)
    assert(type(propertyName) == "string" and #propertyName > 0,
        "[Override] removeOverride: propertyName must be a non-empty string")

    if partName == nil or partName == false then
        for _, _n in ipairs(OVERRIDE_PART_NAMES) do
            _overrides[_n][propertyName] = nil
        end
        _overrides["*"][propertyName] = nil
    else
        if _overrides[partName] then
            _overrides[partName][propertyName] = nil
        end
    end
end

-- ─────────────────────────────────────────────
--  ↓↓ ADD YOUR addOverride() CALLS BELOW ↓↓
--  Examples:
--    addOverride(nil,               "Transparency", 0)
--    addOverride("Head",            "Material",     Enum.Material.Plastic)
--    addOverride("HumanoidRootPart","CastShadow",   false)
-- ─────────────────────────────────────────────

-- ════════════════════════════════════════════
--  FEATURE: SPEED  (ERX frame-by-frame)
-- ════════════════════════════════════════════
local speedEnabled = false
local targetSpeed  = 16
local speedLoop    = nil

local function isSitting()
    return humanoid and humanoid.Sit == true
end

local function startSpeedLoop()
    if speedLoop then return end
    speedLoop = task.spawn(function()
        while true do
            if not speedEnabled or not humanoid or not rootPart or isSitting() then
                task.wait()
                continue
            end
            local dt      = task.wait()
            local moveDir = humanoid.MoveDirection
            if moveDir.Magnitude > 0 then
                local current = humanoid.WalkSpeed
                if targetSpeed ~= current then
                    rootPart.CFrame = rootPart.CFrame + moveDir * ((targetSpeed - current) * dt)
                end
            end
        end
    end)
end

local function stopSpeedLoop()
    if speedLoop then
        task.cancel(speedLoop)
        speedLoop = nil
    end
end

local function setSpeedEnabled(state)
    speedEnabled = state
    if state then startSpeedLoop() else stopSpeedLoop() end
end

player.CharacterAdded:Connect(function()
    local was = speedEnabled
    stopSpeedLoop()
    task.wait()
    if was then startSpeedLoop() end
end)

-- ════════════════════════════════════════════
--  FEATURE: FLING  (CBD Safe Fling engine)
-- ════════════════════════════════════════════
local _SelfImmune      = false
local walkFlingEnabled = false
local carFlingEnabled  = false
local yieldFling       = false
local flingConn        = nil

local function withImmunity(fn)
    _SelfImmune = true
    local ok, err = pcall(fn)
    _SelfImmune = false
    if not ok then warn("[Fling] Error:", err) end
end

local function getDrivenVehicle()
    local char = player.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    local seat = hum.SeatPart
    if seat and seat.Name == "DriverSeat" and seat.Parent then
        return seat.Parent
    end
    return nil
end

local function startFlingLoop()
    if flingConn then flingConn:Disconnect() end
    flingConn = RunService.Stepped:Connect(function()
        if not (walkFlingEnabled or carFlingEnabled) then return end
        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        if not char:IsDescendantOf(workspace) then
            yieldFling = true
            while not char do task.wait() end
            yieldFling = false
        end

        task.spawn(function()
            if not char or not char:IsDescendantOf(workspace) then return end
            if char:FindFirstChildOfClass("ForceField") then return end
            while yieldFling do task.wait() end

            local inVehicle   = getDrivenVehicle() ~= nil
            local shouldFling = (carFlingEnabled and inVehicle)
                             or (walkFlingEnabled and not inVehicle)

            if shouldFling then
                withImmunity(function()
                    RunService.Heartbeat:Wait()
                    local vel = root.Velocity
                    root.Velocity = vel * 8000 + Vector3.new(0, 7000, 0)
                    RunService.RenderStepped:Wait()
                    if char.Parent and root.Parent then
                        root.Velocity = vel
                    end
                    RunService.Stepped:Wait()
                    if char.Parent and root.Parent then
                        root.Velocity = vel + Vector3.new(0, 0.1, 0)
                    end
                end)
            end
        end)
    end)
end

local function stopFlingLoop()
    walkFlingEnabled = false
    carFlingEnabled  = false
    if flingConn then flingConn:Disconnect(); flingConn = nil end
end

local function setWalkFling(state)
    walkFlingEnabled = state
    if state then
        carFlingEnabled = false
        startFlingLoop()
    elseif not carFlingEnabled then
        stopFlingLoop()
    end
end

local function setCarFling(state)
    carFlingEnabled = state
    if state then
        walkFlingEnabled = false
        startFlingLoop()
    elseif not walkFlingEnabled then
        stopFlingLoop()
    end
end

player.CharacterAdded:Connect(function()
    yieldFling = false
    if walkFlingEnabled or carFlingEnabled then
        task.wait(0.5)
        startFlingLoop()
    end
end)

-- ════════════════════════════════════════════
--  FEATURE: INVISIBILITY  (Seat/Weld method)
-- ════════════════════════════════════════════
local invisActive      = false
local invisSelfAlpha   = 0.3   -- local ghost transparency (0 = fully visible to self, 1 = fully invisible)
local weldModel        = nil
local transparencyConn = nil

local function setSelfTransparency(alpha)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            part.LocalTransparencyModifier = alpha
        end
    end
end

local function cleanupInvis()
    if transparencyConn then
        transparencyConn:Disconnect()
        transparencyConn = nil
    end
    if weldModel and weldModel.Parent then
        weldModel:Destroy()
        weldModel = nil
    end
    setSelfTransparency(0)
end

local function setInvisEnabled(state)
    invisActive = state
    if not state then
        cleanupInvis()
        return
    end
    if not character or not rootPart then
        warn("[Invis] Character not ready")
        invisActive = false
        return
    end

    local savedCF = rootPart.CFrame

    -- Move character to sky so the weld replication fires cleanly
    rootPart.CFrame = CFrame.new(0, 1e6, 0)
    task.wait(0.15)

    weldModel      = Instance.new("Model")
    weldModel.Name = "InvisSeatModel"

    local seat           = Instance.new("Seat")
    seat.Name            = "InvisSeat"
    seat.Anchored        = false
    seat.CanCollide      = false
    seat.Transparency    = 1
    seat.Position        = Vector3.new(0, 1e6, 0)
    seat.Parent          = weldModel

    -- PrimaryPart must be set so PivotTo knows what to move relative to
    weldModel.PrimaryPart = seat
    weldModel.Parent      = workspace

    local torso = character:FindFirstChild("Torso")
               or character:FindFirstChild("UpperTorso")
    if torso then
        local weld  = Instance.new("Weld")
        weld.Part0  = seat
        weld.Part1  = torso
        weld.Parent = seat
    end

    task.wait(0.1)

    -- PivotTo now works correctly because PrimaryPart is set
    weldModel:PivotTo(savedCF)

    setSelfTransparency(invisSelfAlpha)
    transparencyConn = RunService.Heartbeat:Connect(function()
        if invisActive and character and character.Parent then
            setSelfTransparency(invisSelfAlpha)
        end
    end)
end

player.CharacterAdded:Connect(function()
    local was = invisActive
    cleanupInvis()
    invisActive = false
    task.wait()
    if was then setInvisEnabled(true) end
end)

-- ════════════════════════════════════════════
--  FEATURE: FLY V2  (Weld-Based Platform)
-- ════════════════════════════════════════════
local function flatCFrame(pos, dir)
    local d = Vector3.new(dir.X, 0, dir.Z)
    if d.Magnitude < 0.001 then d = Vector3.new(0, 0, -1) end
    d = d.Unit
    return CFrame.new(pos, pos + d)
end

local function createWeldedPlatform(name, size)
    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end

    local model        = Instance.new("Model")
    model.Name         = name
    model.Parent       = workspace

    local pad          = Instance.new("Part")
    pad.Name           = "pad"
    pad.Size           = size
    pad.Anchored       = true
    pad.CanCollide     = false
    pad.Transparency   = 1
    pad.CFrame         = root.CFrame
    pad.Parent         = model

    local weld         = Instance.new("Weld")
    weld.Part0         = pad
    weld.Part1         = root
    weld.C0            = CFrame.new(0, -3, 0)
    weld.Parent        = pad

    return { model = model, pad = pad, weld = weld }
end

local function destroyWeldedPlatform(rig)
    if rig and rig.model and rig.model.Parent then
        rig.model:Destroy()
    end
end

local fv2Enabled   = false
local fv2Speed     = 40
local fv2VSpeed    = 20
local fv2Conn      = nil
local fv2Rig       = nil
local fv2PosX, fv2PosY, fv2PosZ = 0, 0, 0
local fv2FacingDir = Vector3.new(0, 0, -1)

local function fv2GetRoot() return player.Character and player.Character:FindFirstChild("HumanoidRootPart") end
local function fv2GetHum()  return player.Character and player.Character:FindFirstChildOfClass("Humanoid") end

local function fv2Disable()
    fv2Enabled = false
    if fv2Conn then fv2Conn:Disconnect(); fv2Conn = nil end
    if fv2Rig  then destroyWeldedPlatform(fv2Rig); fv2Rig = nil end
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj.Name == "_CBD_FlyV2Pad" then obj:Destroy() end
    end
    local hum = fv2GetHum()
    if hum then hum.AutoRotate = true; hum.JumpPower = 50 end
end

local function fv2Enable()
    fv2Disable()
    local root = fv2GetRoot()
    if not root then return end
    local hum = fv2GetHum()

    fv2PosX = root.Position.X
    fv2PosY = root.Position.Y
    fv2PosZ = root.Position.Z
    local lv = root.CFrame.LookVector
    fv2FacingDir = Vector3.new(lv.X, 0, lv.Z)
    if fv2FacingDir.Magnitude < 0.001 then fv2FacingDir = Vector3.new(0, 0, -1) end
    fv2FacingDir = fv2FacingDir.Unit

    fv2Rig = createWeldedPlatform("_CBD_FlyV2Pad", Vector3.new(10, 0.4, 10))
    if not fv2Rig then return end
    fv2Rig.pad.CFrame = flatCFrame(Vector3.new(fv2PosX, fv2PosY, fv2PosZ), fv2FacingDir)

    if hum then hum.AutoRotate = false; hum.JumpPower = 0 end
    fv2Enabled = true

    fv2Conn = RunService.Heartbeat:Connect(function(dt)
        if not fv2Enabled then return end
        if not fv2Rig or not fv2Rig.pad or not fv2Rig.pad.Parent then
            fv2Disable(); return
        end

        local cam = workspace.CurrentCamera
        local wx, wz = 0, 0

        local mdX, mdZ = 0, 0
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then mdZ = -1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then mdZ =  1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then mdX = -1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then mdX =  1 end

        if mdX ~= 0 or mdZ ~= 0 then
            local cfwdX = cam.CFrame.LookVector.X
            local cfwdZ = cam.CFrame.LookVector.Z
            local crgtX = cam.CFrame.RightVector.X
            local crgtZ = cam.CFrame.RightVector.Z
            local fLen = math.sqrt(cfwdX*cfwdX + cfwdZ*cfwdZ)
            local rLen = math.sqrt(crgtX*crgtX + crgtZ*crgtZ)
            if fLen > 0.001 then cfwdX = cfwdX/fLen; cfwdZ = cfwdZ/fLen end
            if rLen > 0.001 then crgtX = crgtX/rLen; crgtZ = crgtZ/rLen end

            wx = cfwdX * (-mdZ) + crgtX * mdX
            wz = cfwdZ * (-mdZ) + crgtZ * mdX
            local wLen = math.sqrt(wx*wx + wz*wz)
            if wLen > 0.001 then wx = wx/wLen; wz = wz/wLen end
            fv2FacingDir = Vector3.new(wx, 0, wz)
        end

        fv2PosX = fv2PosX + wx * (fv2Speed * dt)
        fv2PosZ = fv2PosZ + wz * (fv2Speed * dt)

        if UserInputService:IsKeyDown(Enum.KeyCode.E) then
            fv2PosY = fv2PosY + fv2VSpeed * dt
        elseif UserInputService:IsKeyDown(Enum.KeyCode.Q) then
            fv2PosY = fv2PosY - fv2VSpeed * dt
        end

        fv2Rig.pad.CFrame = flatCFrame(Vector3.new(fv2PosX, fv2PosY, fv2PosZ), fv2FacingDir)
    end)
end

local function setFlyEnabled(state)
    if state then fv2Enable() else fv2Disable() end
end

player.CharacterAdded:Connect(function()
    if fv2Enabled then
        fv2Enabled = false
        task.wait(1)
        fv2Enable()
    end
end)

-- ════════════════════════════════════════════
--  FEATURE: TELEPORT  (smooth CFrame lerp)
-- ════════════════════════════════════════════
local TP_STEPS     = 20
local TP_STEP_WAIT = 0.01

local isTeleporting    = false
local clickTpEnabled   = false
local clickTpConn      = nil
local savedPositions   = {}   -- array of { name, cframe }
local slotButtons      = {}   -- WindUI Button refs for each slot

local function smoothTeleport(targetCF)
    if isTeleporting then return end
    isTeleporting = true

    local char = player.Character
    if not char then isTeleporting = false; return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then isTeleporting = false; return end

    local startCF        = root.CFrame
    local hum            = char:FindFirstChildOfClass("Humanoid")
    local oldAutoRotate  = hum and hum.AutoRotate
    if hum then hum.AutoRotate = false end

    for i = 1, TP_STEPS do
        if not root or not root.Parent then break end
        root.CFrame = startCF:Lerp(targetCF, 1 - (1 - i / TP_STEPS) ^ 3)
        task.wait(TP_STEP_WAIT)
    end

    if root and root.Parent then root.CFrame = targetCF end
    if hum then hum.AutoRotate = oldAutoRotate end
    isTeleporting = false
end

local function enableClickTp()
    if clickTpConn then clickTpConn:Disconnect() end
    clickTpConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not clickTpEnabled then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        local cam      = workspace.CurrentCamera
        local mousePos = UserInputService:GetMouseLocation()
        local ray      = cam:ScreenPointToRay(mousePos.X, mousePos.Y)

        local rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Blacklist
        rayParams.FilterDescendantsInstances = { char }

        local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, rayParams)
        if hit then
            local hum       = char:FindFirstChildOfClass("Humanoid")
            local hipHeight = (hum and hum.HipHeight or 2) + 1
            local targetCF  = CFrame.new(hit.Position + Vector3.new(0, hipHeight, 0))
                              * (root.CFrame - root.CFrame.Position)
            smoothTeleport(targetCF)
        end
    end)
end

local function disableClickTp()
    if clickTpConn then
        clickTpConn:Disconnect()
        clickTpConn = nil
    end
end

player.CharacterAdded:Connect(function()
    isTeleporting = false
end)

-- ════════════════════════════════════════════
--  FEATURE: ANTI-FLING  (multi-stage detection)
-- ════════════════════════════════════════════
local AF = {
    Enabled                 = false,
    MaxSpeed                = 150,
    MaxAcceleration         = 400,
    MaxTeleportDistance     = 30,
    RawFrameJump            = 15,
    EnableAnchorTether      = true,
    AnchorOffset            = Vector3.new(0, -3.5, 0),
    MaxAnchorDistance       = 80,
    ForceAnchorDuration     = 0.3,
    MaxSuppressionsPerWindow = 3,
    SuppressionWindow       = 1.5,
    NotifyCooldown          = 2.5,
}

local afChar, afHum, afRoot, afAnchorPart
local afSafeCF    = CFrame.new()
local afPrevCF    = CFrame.new()
local afPrevVel   = Vector3.zero
local afCorrect   = false
local afSupHist   = {}
local afLastNotify = 0
local afSteppedConn   = nil
local afHeartbeatConn = nil

local function afCreateAnchor()
    if afAnchorPart then pcall(function() afAnchorPart:Destroy() end) end
    if not afRoot then return end
    afAnchorPart              = Instance.new("Part")
    afAnchorPart.Name         = "_AntiFlingAnchor"
    afAnchorPart.Anchored     = true
    afAnchorPart.CanCollide   = false
    afAnchorPart.Transparency = 1
    afAnchorPart.Size         = Vector3.new(1, 1, 1)
    afAnchorPart.CFrame       = afRoot.CFrame * CFrame.new(AF.AnchorOffset)
    afAnchorPart.Parent       = workspace
end

local function afDestroyAnchor()
    if afAnchorPart then
        pcall(function() afAnchorPart:Destroy() end)
        afAnchorPart = nil
    end
end

local function afZeroVelocity()
    if not afChar then return end
    for _, part in ipairs(afChar:GetDescendants()) do
        if part:IsA("BasePart") then
            part.AssemblyLinearVelocity  = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end
end

local function afNukeMovers()
    if not afRoot then return end
    for _, obj in ipairs(afRoot:GetChildren()) do
        if obj:IsA("BodyVelocity") or obj:IsA("BodyForce")
        or obj:IsA("BodyPosition") or obj:IsA("BodyThrust")
        or obj:IsA("BodyAngularVelocity") or obj:IsA("VectorForce")
        or obj:IsA("LinearVelocity") or obj:IsA("AngularVelocity") then
            pcall(function() obj:Destroy() end)
        end
    end
end

local function afForceAnchorAndReset(duration)
    if not afRoot then return end
    afRoot.Anchored = true
    task.delay(duration or AF.ForceAnchorDuration, function()
        if afRoot then
            afRoot.Anchored = false
            afZeroVelocity()
            afCorrect = false
        end
    end)
end

local function afSuppress(reason, detail)
    if not AF.Enabled then return end
    local now = tick()
    if (now - afLastNotify) >= AF.NotifyCooldown then
        afLastNotify = now
        WindUI:Notify({
            Title    = "Anti-Fling: " .. reason,
            Content  = detail,
            Icon     = "shield-alert",
            Duration = 2,
        })
    end

    afCorrect = true
    afNukeMovers()

    if AF.EnableAnchorTether and afAnchorPart then
        afRoot.CFrame = afAnchorPart.CFrame * CFrame.new(-AF.AnchorOffset)
        afZeroVelocity()
    else
        afRoot.CFrame = afSafeCF
        afZeroVelocity()
    end

    if afHum then
        pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false) end)
        pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false) end)
        pcall(function() afHum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end

    afForceAnchorAndReset(AF.ForceAnchorDuration)

    table.insert(afSupHist, now)
    while #afSupHist > 0 and afSupHist[1] < now - AF.SuppressionWindow do
        table.remove(afSupHist, 1)
    end
    if #afSupHist >= AF.MaxSuppressionsPerWindow then
        afSupHist = {}
        afForceAnchorAndReset(1.0)
    end

    task.delay(AF.ForceAnchorDuration + 0.05, function()
        if afHum then
            pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true) end)
            pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true) end)
        end
        if afRoot then
            afSafeCF  = afRoot.CFrame
            afPrevCF  = afRoot.CFrame
            afPrevVel = afRoot.AssemblyLinearVelocity
            if afAnchorPart then
                afAnchorPart.CFrame = afRoot.CFrame * CFrame.new(AF.AnchorOffset)
            end
        end
        afCorrect = false
    end)
end

local function onAFStepped()
    if not AF.Enabled or not afRoot or not afHum or afCorrect then return end
    if _SelfImmune then return end   -- respect fling engine immunity flag
    if afHum:GetState() == Enum.HumanoidStateType.Dead then return end

    local vel   = afRoot.AssemblyLinearVelocity
    local cf    = afRoot.CFrame
    local pos   = cf.Position
    local speed = vel.Magnitude

    if speed > AF.MaxSpeed then
        afSuppress("High Velocity", math.floor(speed) .. " studs/s detected")
        return
    end
    local accel = (vel - afPrevVel).Magnitude
    if accel > AF.MaxAcceleration then
        afSuppress("Acceleration Spike", math.floor(accel) .. " studs/s² detected")
        return
    end
    local dist = (pos - afPrevCF.Position).Magnitude
    if dist > AF.MaxTeleportDistance then
        afSuppress("CFrame Jump", math.floor(dist) .. " studs detected")
        return
    end
    if AF.EnableAnchorTether and afAnchorPart then
        local anchorDist = (pos - afAnchorPart.Position).Magnitude
        if anchorDist > AF.MaxAnchorDistance then
            afSuppress("Anchor Broken", math.floor(anchorDist) .. " studs from anchor")
            return
        end
    end
    local vertDelta = math.abs(pos.Y - afPrevCF.Position.Y)
    if vertDelta > 20 then
        afSuppress("Vertical Fling", math.floor(vertDelta) .. " studs vertical")
        return
    end
    local rot = afRoot.AssemblyAngularVelocity.Magnitude
    if rot > 40 then
        afSuppress("Rotational Spin", math.floor(rot) .. " rad/s detected")
        return
    end

    afSafeCF  = cf
    afPrevVel = vel
    afPrevCF  = cf
    if afAnchorPart then
        if afHum.FloorMaterial ~= Enum.Material.Air then
            afAnchorPart.CFrame = cf * CFrame.new(AF.AnchorOffset)
        end
    end
end

local function onAFHeartbeat()
    if not AF.Enabled or not afRoot or not afHum or afCorrect then return end
    if _SelfImmune then return end
    if afHum:GetState() == Enum.HumanoidStateType.Dead then return end
    local jump = (afRoot.Position - afPrevCF.Position).Magnitude
    if jump > AF.RawFrameJump then
        afSuppress("Fast CFrame Jump", math.floor(jump) .. " studs this heartbeat")
        return
    end
    afPrevCF = afRoot.CFrame
end

local function afSetupCharacter(char)
    if afSteppedConn   then afSteppedConn:Disconnect() end
    if afHeartbeatConn then afHeartbeatConn:Disconnect() end
    afDestroyAnchor()

    afChar    = char
    afHum     = char:WaitForChild("Humanoid")
    afRoot    = char:WaitForChild("HumanoidRootPart")
    afPrevVel = afRoot.AssemblyLinearVelocity
    afPrevCF  = afRoot.CFrame
    afSafeCF  = afRoot.CFrame
    afCorrect = false
    afSupHist = {}

    if AF.EnableAnchorTether then afCreateAnchor() end

    afSteppedConn   = RunService.Stepped:Connect(onAFStepped)
    afHeartbeatConn = RunService.Heartbeat:Connect(onAFHeartbeat)

    afHum.Died:Once(function()
        -- Disconnect detection loops immediately so they can't fire on the
        -- dead/respawning character and trigger a suppression mid-reset.
        if afSteppedConn   then afSteppedConn:Disconnect();   afSteppedConn   = nil end
        if afHeartbeatConn then afHeartbeatConn:Disconnect(); afHeartbeatConn = nil end
        -- Make absolutely sure the root isn't left anchored — this is the
        -- main cause of getting stuck after a death or reset.
        afCorrect = false
        if afRoot then
            pcall(function() afRoot.Anchored = false end)
        end
        afDestroyAnchor()
    end)
end

local function enableAntiFling()
    AF.Enabled = true
    if player.Character then afSetupCharacter(player.Character) end
end

local function disableAntiFling()
    AF.Enabled = false
    if afSteppedConn   then afSteppedConn:Disconnect();   afSteppedConn   = nil end
    if afHeartbeatConn then afHeartbeatConn:Disconnect(); afHeartbeatConn = nil end
    afDestroyAnchor()
    afCorrect = false
    afSupHist = {}
end

player.CharacterAdded:Connect(function(char)
    -- Immediately clear stale refs and any in-flight suppression state so
    -- lingering task.delay callbacks from the previous life can't anchor
    -- or reposition the new character.
    afCorrect = false
    afRoot    = nil
    afHum     = nil
    afChar    = nil
    if AF.Enabled then
        task.wait(0.6)
        afSetupCharacter(char)
    end
end)

-- ════════════════════════════════════════════
--  FEATURE: INF JUMP  (platform-under-feet)
-- ════════════════════════════════════════════
local ijEnabled    = false
local ijPower      = 50      -- studs/s upward velocity given per jump
local ijConn       = nil
local ijPad        = nil     -- the single reused invisible platform
local ijPadConn    = nil     -- heartbeat that keeps pad under feet
local ijInAir      = false   -- tracks whether player is currently airborne

local function ijDestroyPad()
    if ijPad and ijPad.Parent then
        ijPad:Destroy()
    end
    ijPad = nil
    if ijPadConn then
        ijPadConn:Disconnect()
        ijPadConn = nil
    end
end

local function ijCreatePad()
    ijDestroyPad()
    ijPad              = Instance.new("Part")
    ijPad.Name         = "_InfJumpPad"
    ijPad.Size         = Vector3.new(4, 0.2, 4)
    ijPad.Anchored     = true
    ijPad.CanCollide   = true
    ijPad.Transparency = 1
    ijPad.Parent       = workspace

    -- Keep pad positioned just below HRP every heartbeat
    ijPadConn = RunService.Heartbeat:Connect(function()
        if not ijEnabled or not ijPad then return end
        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end
        -- Park the pad 4 studs below feet so it's ready but not blocking
        ijPad.CFrame = CFrame.new(root.Position - Vector3.new(0, 4, 0))
    end)
end

local function ijDisable()
    ijEnabled = false
    if ijConn then ijConn:Disconnect(); ijConn = nil end
    ijDestroyPad()
    ijInAir = false
    -- Restore default jump power
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum.JumpPower = ijPower end
end

local function ijEnable()
    ijDisable()
    local char = player.Character
    if not char then return end
    local hum  = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end

    ijEnabled = true
    ijCreatePad()

    -- Watch for the jump input — when Space is pressed while airborne,
    -- snap the platform directly under the player's feet so they land on it
    -- and the humanoid's Jump state fires again naturally
    ijConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not ijEnabled then return end
        if input.KeyCode ~= Enum.KeyCode.Space then return end

        local c    = player.Character
        local h    = c and c:FindFirstChildOfClass("Humanoid")
        local r    = c and c:FindFirstChild("HumanoidRootPart")
        if not h or not r then return end

        -- Only act when already in the air
        if h.FloorMaterial == Enum.Material.Air then
            -- Snap pad directly under feet
            if ijPad then
                local hipH = h.HipHeight + (r.Size.Y / 2)
                ijPad.CFrame = CFrame.new(r.Position - Vector3.new(0, hipH + 0.15, 0))
            end
            -- Small delay so the platform registers, then give upward velocity
            task.wait(0.05)
            if r and r.Parent then
                r.AssemblyLinearVelocity = Vector3.new(
                    r.AssemblyLinearVelocity.X,
                    ijPower,
                    r.AssemblyLinearVelocity.Z
                )
            end
            -- Move pad back below feet after the boost
            task.delay(0.15, function()
                if ijPad and ijEnabled and r and r.Parent then
                    ijPad.CFrame = CFrame.new(r.Position - Vector3.new(0, 4, 0))
                end
            end)
        end
    end)
end

local function setInfJumpEnabled(state)
    if state then ijEnable() else ijDisable() end
end

player.CharacterAdded:Connect(function(char)
    local was = ijEnabled
    ijDisable()
    if was then
        task.wait(1)
        ijEnable()
    end
end)

-- ════════════════════════════════════════════
--  TAB 1 — MOVEMENT
-- ════════════════════════════════════════════
local MovementTab = Window:Tab({
    Title = "Movement",
    Icon  = "footprints",
})

-- ─────────────────────────────────────────────
--  Speed Section (collapsible)
-- ─────────────────────────────────────────────
local SpeedSection = MovementTab:Section({
    Title  = "Speed",
    Box    = false,
    Opened = true,
})

SpeedSection:Toggle({
    Title    = "Speed",
    Desc     = "Enables the ERX frame-by-frame speed modifier.",
    Icon     = "zap",
    Value    = false,
    Callback = function(state) setSpeedEnabled(state) end,
})

SpeedSection:Slider({
    Title = "Speed Value",
    Desc  = "How fast to move. Default walk speed is 16.",
    Icon  = "gauge",
    Step  = 1,
    Value = { Min = 1, Max = 250, Default = 16 },
    Callback = function(value) targetSpeed = value end,
})

-- ─────────────────────────────────────────────
--  Fly Section (collapsible)
-- ─────────────────────────────────────────────
local FlySection = MovementTab:Section({
    Title  = "Fly",
    Box    = false,
    Opened = false,
})

FlySection:Toggle({
    Title    = "Fly",
    Desc     = "Weld-based flight. WASD to move, E to rise, Q to descend.",
    Icon     = "plane",
    Value    = false,
    Callback = function(state)
        setFlyEnabled(state)
        WindUI:Notify({
            Title    = state and "Fly ON" or "Fly OFF",
            Content  = state and "WASD to move · E rise · Q descend." or "Flight disabled.",
            Icon     = state and "plane" or "plane-off",
            Duration = 3,
        })
    end,
})

FlySection:Slider({
    Title    = "Fly Speed",
    Desc     = "Horizontal flight speed.",
    Icon     = "move-horizontal",
    Step     = 1,
    Value    = { Min = 5, Max = 200, Default = 40 },
    Callback = function(value) fv2Speed = value end,
})

FlySection:Slider({
    Title    = "Fly Vertical Speed",
    Desc     = "How fast you rise or drop (E / Q).",
    Icon     = "move-vertical",
    Step     = 1,
    Value    = { Min = 2, Max = 80, Default = 20 },
    Callback = function(value) fv2VSpeed = value end,
})

-- ─────────────────────────────────────────────
--  Teleport Section (collapsible)
-- ─────────────────────────────────────────────
local TeleportSection = MovementTab:Section({
    Title  = "Teleport",
    Box    = false,
    Opened = false,
})

-- Click-to-teleport toggle
TeleportSection:Toggle({
    Title    = "Click Teleport",
    Desc     = "Left-click anywhere in the world to teleport there.",
    Icon     = "mouse-pointer-click",
    Value    = false,
    Callback = function(state)
        clickTpEnabled = state
        if state then
            enableClickTp()
        else
            disableClickTp()
        end
        WindUI:Notify({
            Title    = state and "Click TP ON" or "Click TP OFF",
            Content  = state and "Left-click the ground to teleport." or "Click teleport disabled.",
            Icon     = "mouse-pointer-click",
            Duration = 3,
        })
    end,
})

TeleportSection:Slider({
    Title    = "Lerp Steps",
    Desc     = "Number of interpolation frames. More = smoother but slower.",
    Icon     = "git-commit-horizontal",
    Step     = 1,
    Value    = { Min = 1, Max = 60, Default = 20 },
    Callback = function(value) TP_STEPS = value end,
})

TeleportSection:Slider({
    Title    = "Step Wait (ms)",
    Desc     = "Delay between each lerp frame in milliseconds.",
    Icon     = "timer",
    Step     = 1,
    Value    = { Min = 1, Max = 50, Default = 10 },
    Callback = function(value) TP_STEP_WAIT = value / 1000 end,
})

-- Save current position button (max 5 slots)
TeleportSection:Button({
    Title    = "Save Position",
    Desc     = "Saves your current spot (up to 5 slots).",
    Icon     = "bookmark-plus",
    Callback = function()
        if #savedPositions >= 5 then
            WindUI:Notify({
                Title    = "Slots Full",
                Content  = "All 5 position slots are in use.",
                Icon     = "alert-circle",
                Duration = 3,
            })
            return
        end

        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        local slotIndex = #savedPositions + 1
        local slotName  = "Slot " .. slotIndex
        table.insert(savedPositions, { name = slotName, cframe = root.CFrame })

        -- Create a WindUI button for this slot so the player can click to go back
        local newBtn = TeleportSection:Button({
            Title    = slotName,
            Desc     = "Teleport back to " .. slotName .. ".",
            Icon     = "map-pin",
            Callback = function()
                smoothTeleport(savedPositions[slotIndex].cframe)
                WindUI:Notify({
                    Title    = "Teleported",
                    Content  = "Jumped to " .. slotName .. ".",
                    Icon     = "map-pin",
                    Duration = 2,
                })
            end,
        })

        table.insert(slotButtons, newBtn)

        WindUI:Notify({
            Title    = "Position Saved",
            Content  = slotName .. " recorded. Click it to return.",
            Icon     = "bookmark-check",
            Duration = 3,
        })
    end,
})

-- Clear all saved positions
TeleportSection:Button({
    Title    = "Clear Saved Positions",
    Desc     = "Removes all saved slots.",
    Icon     = "trash-2",
    Callback = function()
        -- Destroy all slot buttons from the UI
        for _, btn in ipairs(slotButtons) do
            pcall(function() btn:Destroy() end)
        end
        slotButtons    = {}
        savedPositions = {}

        WindUI:Notify({
            Title    = "Slots Cleared",
            Content  = "All saved positions have been removed.",
            Icon     = "trash-2",
            Duration = 3,
        })
    end,
})

-- ─────────────────────────────────────────────
--  Inf Jump Section (collapsible)
-- ─────────────────────────────────────────────
local InfJumpSection = MovementTab:Section({
    Title  = "Inf Jump",
    Box    = false,
    Opened = false,
})

InfJumpSection:Toggle({
    Title    = "Inf Jump",
    Desc     = "Spawns an invisible platform under your feet each time you jump in the air.",
    Icon     = "chevrons-up",
    Value    = false,
    Callback = function(state)
        setInfJumpEnabled(state)
        WindUI:Notify({
            Title    = state and "Inf Jump ON" or "Inf Jump OFF",
            Content  = state and "Press Space in the air to keep jumping." or "Infinite jump disabled.",
            Icon     = "chevrons-up",
            Duration = 3,
        })
    end,
})

local JumpPowerSlider = InfJumpSection:Slider({
    Title    = "Jump Power",
    Desc     = "Upward velocity applied on each mid-air jump.",
    Icon     = "arrow-up",
    Step     = 5,
    Value    = { Min = 10, Max = 200, Default = 50 },
    Callback = function(value)
        ijPower = value
    end,
})

InfJumpSection:Button({
    Title    = "Reset Jump Power",
    Desc     = "Resets jump power back to the default (50).",
    Icon     = "rotate-ccw",
    Callback = function()
        ijPower = 50
        JumpPowerSlider:Set(50)
        WindUI:Notify({
            Title    = "Jump Power Reset",
            Content  = "Jump power restored to default (50).",
            Icon     = "rotate-ccw",
            Duration = 2,
        })
    end,
})

-- ════════════════════════════════════════════
--  TAB 2 — FUN
-- ════════════════════════════════════════════
local FunTab = Window:Tab({
    Title = "Fun",
    Icon  = "party-popper",
})

-- ─────────────────────────────────────────────
--  Fling Section (collapsible)
-- ─────────────────────────────────────────────
local FlingSection = FunTab:Section({
    Title  = "Fling",
    Box    = false,
    Opened = true,
})

local WalkFlingToggle = FlingSection:Toggle({
    Title    = "Walk Fling",
    Desc     = "⭐ Premium · Flings nearby players while walking. (CBD engine)",
    Icon     = "wind",
    Value    = false,
    Callback = function(state)
        if not isPremium then return end
        setWalkFling(state)
        if state then CarFlingToggle:Set(false) end
        WindUI:Notify({
            Title    = state and "Walk Fling ON" or "Walk Fling OFF",
            Content  = state and "Flinging players while walking." or "Walk fling disabled.",
            Icon     = "wind",
            Duration = 3,
        })
    end,
})

local CarFlingToggle = FlingSection:Toggle({
    Title    = "Vehicle Fling",
    Desc     = "⭐ Premium · Flings nearby players while driving. (CBD engine)",
    Icon     = "car",
    Value    = false,
    Callback = function(state)
        if not isPremium then return end
        setCarFling(state)
        if state then WalkFlingToggle:Set(false) end
        WindUI:Notify({
            Title    = state and "Vehicle Fling ON" or "Vehicle Fling OFF",
            Content  = state and "Flinging players while driving." or "Vehicle fling disabled.",
            Icon     = "car",
            Duration = 3,
        })
    end,
})

if not isPremium then
    WalkFlingToggle:Lock()
    CarFlingToggle:Lock()
end

-- ─────────────────────────────────────────────
--  Noclip Section (collapsible)
-- ─────────────────────────────────────────────
do
    local NoclipSection = FunTab:Section({
        Title  = "Noclip",
        Box    = false,
        Opened = false,
    })

    local noclipEnabled  = false
    local noclipConn     = nil
    local currentChar    = nil
    -- Cached flat list of BaseParts; rebuilt whenever the character changes.
    -- Avoids calling GetDescendants() every single RenderStepped frame.
    local ncPartCache    = {}
    -- Remember each part's original CanCollide so restore is exact.
    local ncOrigCollide  = {}

    -- Rebuild the part cache for a character.
    -- Called once after spawn so all parts (limbs, head, accessories) are present.
    local function ncBuildCache(char)
        ncPartCache   = {}
        ncOrigCollide = {}
        if not char then return end
        for _, obj in ipairs(char:GetDescendants()) do
            if obj:IsA("BasePart") then
                -- Skip the HumanoidRootPart from the cache — keeping its
                -- CanCollide=false permanently can confuse the physics solver
                -- on some games.  The torso parts are what actually block walls.
                ncPartCache[#ncPartCache + 1]    = obj
                ncOrigCollide[obj]               = obj.CanCollide
            end
        end
        -- Also watch for accessories added after spawn (e.g. tool equip)
        char.DescendantAdded:Connect(function(obj)
            if noclipEnabled and obj:IsA("BasePart") then
                ncPartCache[#ncPartCache + 1] = obj
                ncOrigCollide[obj]            = obj.CanCollide
                -- Immediately suppress it so it doesn't catch on anything
                pcall(function() obj.CanCollide = false end)
            end
        end)
    end

    local function ncRestoreCollisions()
        for _, part in ipairs(ncPartCache) do
            pcall(function()
                if part and part.Parent then
                    part.CanCollide = ncOrigCollide[part] ~= nil
                        and ncOrigCollide[part]
                        or true
                end
            end)
        end
    end

    local function ncApplyNoclip()
        for _, part in ipairs(ncPartCache) do
            pcall(function()
                if part and part.Parent then
                    part.CanCollide = false
                end
            end)
        end
    end

    local function disableNoclip()
        noclipEnabled = false
        if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
        ncRestoreCollisions()
    end

    local function enableNoclip()
        disableNoclip()
        noclipEnabled = true
        currentChar   = player.Character
        if not currentChar then return end
        -- Build cache now; all parts should be replicated already
        ncBuildCache(currentChar)
        noclipConn = RunService.RenderStepped:Connect(function()
            if not noclipEnabled then return end
            -- Re-suppress every frame so the engine can't re-enable CanCollide
            -- between frames (some games do this deliberately to foil noclip)
            ncApplyNoclip()
        end)
    end

    player.CharacterAdded:Connect(function(char)
        currentChar = char
        if noclipEnabled then
            -- Wait for the full character to replicate before caching
            task.wait(0.5)
            enableNoclip()
        end
    end)

    NoclipSection:Toggle({
        Title    = "Enable Noclip",
        Desc     = "Pass through walls. Only disables collision on torso parts — harder to detect.",
        Icon     = "ghost",
        Value    = false,
        Callback = function(state)
            if state then
                enableNoclip()
                WindUI:Notify({ Title="Noclip", Content="Noclip enabled — walk through walls.", Icon="ghost", Duration=3 })
            else
                disableNoclip()
                WindUI:Notify({ Title="Noclip", Content="Collisions restored.", Icon="box", Duration=2 })
            end
        end,
    })
end

-- ════════════════════════════════════════════
--  TAB 3 — MISC
-- ════════════════════════════════════════════
local MiscTab = Window:Tab({
    Title = "Misc",
    Icon  = "wrench",
})

-- ─────────────────────────────────────────────
--  Invisibility Section (collapsible)
-- ─────────────────────────────────────────────
local InvisSection = MiscTab:Section({
    Title  = "Invisibility",
    Box    = false,
    Opened = true,
})

local afWasEnabledBeforeInvis = false

InvisSection:Toggle({
    Title    = "Invisibility",
    Desc     = "Seat/weld method. Others see you as invisible; you stay ghosted.",
    Icon     = "eye-off",
    Value    = false,
    Callback = function(state)
        if state then
            -- Pause anti-fling so it doesn't fight the seat/weld teleport
            if AF.Enabled then
                afWasEnabledBeforeInvis = true
                disableAntiFling()
            end
        else
            -- Restore anti-fling if it was running before invis
            if afWasEnabledBeforeInvis then
                afWasEnabledBeforeInvis = false
                enableAntiFling()
            end
        end
        setInvisEnabled(state)
        WindUI:Notify({
            Title    = state and "Invisibility ON" or "Invisibility OFF",
            Content  = state and "You are now invisible to other players." or "Invisibility disabled.",
            Icon     = state and "eye-off" or "eye",
            Duration = 3,
        })
    end,
})

InvisSection:Slider({
    Title    = "Your Ghost Opacity",
    Desc     = "How transparent you appear to yourself. 0 = fully visible, 100 = fully invisible.",
    Icon     = "blend",
    Step     = 1,
    Value    = { Min = 0, Max = 100, Default = 30 },
    Callback = function(value)
        invisSelfAlpha = value / 100
        if invisActive then
            setSelfTransparency(invisSelfAlpha)
        end
    end,
})

-- ─────────────────────────────────────────────
--  Anti-Fling Section (collapsible, premium)
-- ─────────────────────────────────────────────
local AntiFlingSection = MiscTab:Section({
    Title  = "Anti-Fling",
    Box    = false,
    Opened = false,
})

local AntiFlingToggle = AntiFlingSection:Toggle({
    Title    = "Anti-Fling",
    Desc     = "⭐ Premium · Multi-stage fling detection and suppression.",
    Icon     = "shield",
    Value    = false,
    Callback = function(state)
        if not isPremium then return end
        if state then enableAntiFling() else disableAntiFling() end
        WindUI:Notify({
            Title    = state and "Anti-Fling ON" or "Anti-Fling OFF",
            Content  = state and "Fling protection is active." or "Fling protection disabled.",
            Icon     = "shield",
            Duration = 3,
        })
    end,
})

local AntiFlingAnchorToggle = AntiFlingSection:Toggle({
    Title    = "Anchor Tether",
    Desc     = "⭐ Premium · Keeps an invisible anchor; pulls you back if flung too far.",
    Icon     = "anchor",
    Value    = true,
    Callback = function(state)
        if not isPremium then return end
        AF.EnableAnchorTether = state
        if state and AF.Enabled and afRoot then
            afCreateAnchor()
        elseif not state then
            afDestroyAnchor()
        end
    end,
})

AntiFlingSection:Slider({
    Title    = "Max Speed (studs/s)",
    Desc     = "⭐ Premium · Velocity above this triggers suppression.",
    Icon     = "gauge",
    Step     = 10,
    Value    = { Min = 50, Max = 500, Default = 150 },
    Callback = function(value)
        if not isPremium then return end
        AF.MaxSpeed = value
    end,
})

AntiFlingSection:Slider({
    Title    = "Max Acceleration",
    Desc     = "⭐ Premium · Acceleration spike threshold (studs/s²).",
    Icon     = "trending-up",
    Step     = 25,
    Value    = { Min = 100, Max = 1000, Default = 400 },
    Callback = function(value)
        if not isPremium then return end
        AF.MaxAcceleration = value
    end,
})

AntiFlingSection:Slider({
    Title    = "Anchor Distance",
    Desc     = "⭐ Premium · How far from anchor before snapping back.",
    Icon     = "move",
    Step     = 5,
    Value    = { Min = 20, Max = 200, Default = 80 },
    Callback = function(value)
        if not isPremium then return end
        AF.MaxAnchorDistance = value
    end,
})

AntiFlingSection:Slider({
    Title    = "Anchor Duration (ms)",
    Desc     = "⭐ Premium · How long you are briefly anchored after a fling is caught.",
    Icon     = "lock",
    Step     = 50,
    Value    = { Min = 100, Max = 2000, Default = 300 },
    Callback = function(value)
        if not isPremium then return end
        AF.ForceAnchorDuration = value / 1000
    end,
})

if not isPremium then
    AntiFlingToggle:Lock()
    AntiFlingAnchorToggle:Lock()
end

-- ════════════════════════════════════════════
--  WATCHER SECTION  (premium)
-- ════════════════════════════════════════════
local WatcherSection = MiscTab:Section({
    Title  = "Watcher",
    Box    = false,
    Opened = false,
})

-- ─────────────────────────────────────────────
--  Watcher engine state
-- ─────────────────────────────────────────────
local watcherEnabled    = false
local watcherLoop       = nil
local watcherInterval   = 10        -- seconds between scans
local watcherLastNotify = {}        -- [label] = tick() — cooldown per finding
local watcherNotifyCooldown = 30    -- seconds before re-alerting same finding

-- GC string patterns that suggest monitoring/anticheat infrastructure
local WATCHER_GC_PATTERNS = {
    "caught_via=",
    "getmemoryusagembfortag",
    "$enc_",
    "anticheat",
    "exploit_detected",
    "cheat_detected",
    "kick.*cheat",
    "monitor.*script",
    "__env_hook",
    "cbdspy",
    "detectcheat",
    "remoteevent.*cheat",
    "modulescript.*monitor",
}

-- GC table key patterns
local WATCHER_KEY_PATTERNS = {
    "anticheat",
    "detectcheat",
    "cbdspy",
    "exploitdetect",
    "monitor_hook",
}

-- Script name patterns (injected script scan)
local WATCHER_SCRIPT_PATTERNS = {
    "monitor",
    "watcher",
    "detect",
    "anticheat",
    "logger",
    "spy",
    "hook",
    "inject",
    "audit",
    "cheat",
}

-- Containers to scan for injected scripts
local WATCHER_SCAN_CONTAINERS = {
    function() return player.PlayerGui end,
    function() return player.Character end,
    function() return game:GetService("CoreGui") end,
}

-- ─────────────────────────────────────────────
--  Alert helper — respects per-label cooldown
-- ─────────────────────────────────────────────
local function watcherAlert(label)
    local now = tick()
    if watcherLastNotify[label] and (now - watcherLastNotify[label]) < watcherNotifyCooldown then
        return
    end
    watcherLastNotify[label] = now
    WindUI:Notify({
        Title    = "⚠ Watcher: Surveillance Detected",
        Content  = label,
        Icon     = "eye",
        Duration = 6,
    })
    warn("[Watcher] Detected:", label)
end

-- ─────────────────────────────────────────────
--  Scan 1 — GC string/table scan (chunked)
--  Yields every CHUNK items so the game never
--  freezes regardless of GC table size.
-- ─────────────────────────────────────────────
local GC_CHUNK = 200   -- items processed per frame

local function watcherScanGC()
    if type(getgc) ~= "function" then return end
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then return end

    local count = 0
    for _, v in ipairs(gc) do
        if not watcherEnabled then return end  -- bail if watcher was turned off mid-scan

        count = count + 1
        if count % GC_CHUNK == 0 then
            task.wait()  -- yield one frame every CHUNK items
        end

        local t = type(v)

        if t == "string" and #v > 3 and #v < 512 then
            local lower = v:lower()
            for _, pat in ipairs(WATCHER_GC_PATTERNS) do
                if lower:find(pat, 1, true) then
                    watcherAlert("GC: string match — " .. pat)
                    break
                end
            end

        elseif t == "table" then
            pcall(function()
                for k in pairs(v) do
                    if type(k) == "string" then
                        local lower = k:lower()
                        for _, pat in ipairs(WATCHER_KEY_PATTERNS) do
                            if lower:find(pat, 1, true) then
                                watcherAlert("GC: table key — " .. k)
                                break
                            end
                        end
                    end
                end
            end)
        end
    end
end

-- ─────────────────────────────────────────────
--  Scan 2 — Environment hook detection
--  Fast — no chunking needed
-- ─────────────────────────────────────────────
local function watcherScanEnvHooks()
    local ok1, mt = pcall(getmetatable, _G)
    if ok1 and type(mt) == "table" then
        if mt.__index    then watcherAlert("Env: _G has __index hook")    end
        if mt.__newindex then watcherAlert("Env: _G has __newindex hook") end
    end
    task.wait()

    local ok2, mt2 = pcall(getmetatable, shared)
    if ok2 and type(mt2) == "table" then
        if mt2.__index    then watcherAlert("Env: shared has __index hook")    end
        if mt2.__newindex then watcherAlert("Env: shared has __newindex hook") end
    end
end

-- ─────────────────────────────────────────────
--  Scan 3 — Injected script detection (chunked)
-- ─────────────────────────────────────────────
local SCRIPT_CHUNK = 50  -- descendants checked per frame

local function watcherScanScripts()
    for _, getContainer in ipairs(WATCHER_SCAN_CONTAINERS) do
        if not watcherEnabled then return end

        local ok, container = pcall(getContainer)
        if not ok or not container then continue end

        local ok2, descendants = pcall(function() return container:GetDescendants() end)
        if not ok2 then continue end

        local count = 0
        for _, obj in ipairs(descendants) do
            if not watcherEnabled then return end

            count = count + 1
            if count % SCRIPT_CHUNK == 0 then
                task.wait()
            end

            local isScript = pcall(function()
                return obj:IsA("LocalScript") or obj:IsA("Script") or obj:IsA("ModuleScript")
            end)
            if not isScript then continue end

            if obj:IsA("LocalScript") or obj:IsA("Script") or obj:IsA("ModuleScript") then
                local nameLower = obj.Name:lower()
                for _, pat in ipairs(WATCHER_SCRIPT_PATTERNS) do
                    if nameLower:find(pat, 1, true) then
                        watcherAlert("Script: injected — " .. obj.Name .. " in " .. container.Name)
                        break
                    end
                end
            end
        end

        task.wait()  -- brief pause between containers
    end
end

-- ─────────────────────────────────────────────
--  Full scan — runs all three in sequence,
--  each already yielding internally
-- ─────────────────────────────────────────────
local function watcherRunScan()
    if not watcherEnabled then return end
    pcall(watcherScanEnvHooks)   -- fast, run first
    task.wait()
    pcall(watcherScanScripts)    -- medium, chunked
    task.wait()
    pcall(watcherScanGC)         -- slow/large, chunked — run last
end

-- ─────────────────────────────────────────────
--  Start / stop watcher loop
-- ─────────────────────────────────────────────
local function startWatcher()
    if watcherLoop then task.cancel(watcherLoop) end
    watcherLoop = task.spawn(function()
        while watcherEnabled do
            watcherRunScan()
            task.wait(watcherInterval)
        end
    end)
end

local function stopWatcher()
    watcherEnabled = false
    if watcherLoop then
        task.cancel(watcherLoop)
        watcherLoop = nil
    end
end

-- ─────────────────────────────────────────────
--  Watcher UI
-- ─────────────────────────────────────────────
local WatcherToggle = WatcherSection:Toggle({
    Title    = "Watcher",
    Desc     = "⭐ Premium · Monitors the game for anticheat, injected scripts, and env hooks.",
    Icon     = "scan-eye",
    Value    = false,
    Callback = function(state)
        if not isPremium then return end
        watcherEnabled = state
        if state then
            startWatcher()
            WindUI:Notify({
                Title    = "Watcher ON",
                Content  = "Scanning for surveillance every " .. watcherInterval .. "s.",
                Icon     = "scan-eye",
                Duration = 3,
            })
        else
            stopWatcher()
            WindUI:Notify({
                Title    = "Watcher OFF",
                Content  = "Surveillance scanning disabled.",
                Icon     = "eye-off",
                Duration = 3,
            })
        end
    end,
})

WatcherSection:Slider({
    Title    = "Scan Interval (s)",
    Desc     = "⭐ Premium · How often Watcher scans for threats.",
    Icon     = "timer",
    Step     = 5,
    Value    = { Min = 5, Max = 60, Default = 10 },
    Callback = function(value)
        if not isPremium then return end
        watcherInterval = value
    end,
})

WatcherSection:Button({
    Title    = "Scan Now",
    Desc     = "⭐ Premium · Immediately run a full surveillance scan.",
    Icon     = "search",
    Callback = function()
        if not isPremium then return end
        WindUI:Notify({
            Title    = "Watcher",
            Content  = "Running manual scan...",
            Icon     = "search",
            Duration = 2,
        })
        task.spawn(watcherRunScan)
    end,
})

if not isPremium then
    WatcherToggle:Lock()
end

-- ════════════════════════════════════════════
--  WELCOME NOTIFY  (fires after build)
-- ════════════════════════════════════════════
task.defer(function()
    task.wait(0.3)
    if isPremium then
        WindUI:Notify({
            Title    = "Welcome, Premium Member! 👑",
            Content  = "All features are unlocked. Enjoy!",
            Icon     = "crown",
            Duration = 5,
        })
    else
        WindUI:Notify({
            Title    = "Welcome!",
            Content  = "You are on the free tier. Upgrade for premium perks.",
            Icon     = "user",
            Duration = 5,
        })
    end
end)
