-- ==================== SERVICES ====================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local player           = Players.LocalPlayer

-- ==================== WINDUI ====================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

-- ==================== PREMIUM STATE ====================
local isPremium = false

-- ============================================================
--  LOGGER
-- ============================================================
local function LOG(tag, ...)
    local parts = {"[CBD][" .. tag .. "]"}
    for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
    warn(table.concat(parts, " "))
end

-- ============================================================
--  PANDA REST VALIDATOR (no Virtual Storage needed)
-- ============================================================
local PANDA_SERVICE_ID = "scprp"

local function getHWID()
    local hwid = tostring(player.UserId)
    pcall(function() hwid = gethwid() end)
    return hwid
end

local function pandaValidate(key, silent)
    key = (key or ""):gsub("%s+", "")
    if key == "" then return false, false, "Never" end

    local hwid = getHWID()
    LOG("REST", "Validating key:", key, "HWID:", hwid)

    local ok, response = pcall(function()
        local url = ("https://api.pandauth.com/api/v1/keys/validate?key=%s&hwid=%s&service=%s")
            :format(key, hwid, PANDA_SERVICE_ID)
        return HttpService:JSONDecode(game:HttpGet(url))
    end)

    if not ok or type(response) ~= "table" then
        LOG("REST", "Request failed:", tostring(response))
        if not silent then
            WindUI:Notify({ Title = "Auth Error", Content = "Could not reach Panda servers.", Icon = "wifi-off", Duration = 5 })
        end
        return false, false, "Never"
    end

    LOG("REST", "Response:", HttpService:JSONEncode(response))

    local valid   = response.valid   == true
    local premium = response.premium == true
    local expires = tostring(response.expires or response.expiry or "Never")

    if valid then
        return true, premium, expires
    else
        local reason = tostring(response.reason or response.message or "Invalid key")
        if not silent then
            WindUI:Notify({ Title = "❌ " .. reason, Content = "Get a key at pandauth.com", Icon = "x-circle", Duration = 6 })
        end
        return false, false, "Never"
    end
end

-- ============================================================
--  FORWARD DECLARATIONS
-- ============================================================
local premiumTag     = nil
local modWatchToggle = nil
local keyExpiry      = "Never"

local function applyPremium(value, source, expires)
    isPremium = value
    keyExpiry = expires or "Never"
    LOG("PREMIUM", "isPremium =", isPremium, "via", source, "expires =", keyExpiry)

    if premiumTag then
        pcall(function()
            premiumTag:Set({
                Title = isPremium and "⭐ Premium" or "Free",
                Color = isPremium and Color3.fromHex("#FFD700") or Color3.fromHex("#555555"),
            })
        end)
    end

    if modWatchToggle then
        pcall(function() modWatchToggle:SetLocked(not isPremium) end)
        pcall(function()
            if isPremium then modWatchToggle:Unlock() else modWatchToggle:Lock() end
        end)
    end

    if isPremium then
        WindUI:Notify({
            Title    = "⭐ Premium Active",
            Content  = "Premium features unlocked! Expires: " .. keyExpiry,
            Icon     = "crown",
            Duration = 6,
        })
    end
end

-- ==================== WINDOW ====================
local Window = WindUI:CreateWindow({
    Title         = "Containment Breach Deluxe",
    Icon          = "shield-alert",
    Author        = "CBD",
    Transparent   = true,
    Theme         = "Dark",
    Size          = UDim2.fromOffset(450, 550),
    Folder        = "CBD",
    HideSearchBar = false,

    User = {
        Enabled   = true,
        Anonymous = false,
        Callback  = function()
            WindUI:Notify({
                Title    = isPremium and "⭐ Premium User" or "Free User",
                Content  = player.Name .. " • " .. (isPremium and "Premium • Expires: " .. keyExpiry or "Free tier"),
                Icon     = "user",
                Duration = 3,
            })
        end,
    },

    KeySystem = {
        Note    = "Click 'Get Key' to complete the checkpoint, then paste your key.",
        SaveKey = true,
        API = {
            {
                Title     = "Containment Breach Deluxe",
                Desc      = "Click 'Get Key' to get your key.",
                Icon      = "shield-alert",
                Type      = "pandadevelopment",
                ServiceId = PANDA_SERVICE_ID,
            },
        },
        Callback = function(enteredKey)
            LOG("KEYSYSTEM", "Key entered:", tostring(enteredKey))
            task.spawn(function()
                local valid, premium, expires = pandaValidate(enteredKey, false)
                if valid then
                    applyPremium(premium, "KeySystem", expires)
                    -- Save key to disk for startup re-check
                    pcall(function()
                        if not isfolder("CBD") then makefolder("CBD") end
                        writefile("CBD/saved.key", enteredKey)
                    end)
                    WindUI:Notify({
                        Title    = "✅ Key Valid",
                        Content  = (premium and "⭐ Premium" or "Free") .. " • Expires: " .. expires,
                        Icon     = "check-circle",
                        Duration = 5,
                    })
                end
            end)
        end,
    },
})

-- ==================== TAG ====================
premiumTag = Window:Tag({
    Title  = "Free",
    Icon   = "crown",
    Color  = Color3.fromHex("#555555"),
    Radius = 6,
})

-- ============================================================
--  STARTUP — auto re-validate saved key
-- ============================================================
task.defer(function()
    task.wait(2)
    if isPremium then return end
    LOG("STARTUP", "Checking for saved key...")

    local savedKey = nil

    pcall(function()
        local d = readfile("CBD/saved.key")
        if d and #d > 5 then savedKey = d:gsub("%s+", "") end
    end)

    if not savedKey then
        pcall(function()
            local hwid = getHWID()
            local d = readfile("CBD/" .. hwid .. ".key")
            if d and #d > 5 then savedKey = d:gsub("%s+", "") end
        end)
    end

    if not savedKey then
        pcall(function()
            for _, path in ipairs(listfiles("CBD")) do
                if path:sub(-4) == ".key" then
                    local d = readfile(path)
                    if d and #d > 5 then savedKey = d:gsub("%s+", ""); break end
                end
            end
        end)
    end

    if not savedKey then LOG("STARTUP", "No saved key found"); return end

    LOG("STARTUP", "Re-validating:", savedKey)
    local valid, premium, expires = pandaValidate(savedKey, true)
    if valid then
        applyPremium(premium, "startup", expires)
        WindUI:Notify({
            Title    = premium and "⭐ Premium Restored" or "Key Restored",
            Content  = premium and ("Welcome back! Expires: " .. expires) or "Logged in as Free tier",
            Icon     = premium and "crown" or "check-circle",
            Duration = 4,
        })
    end
end)

-- ==================== TABS ====================
local FlyTab      = Window:Tab({ Title = "Fly",      Icon = "plane"   })
local SpeedTab    = Window:Tab({ Title = "Speed",    Icon = "zap"     })
local NoclipTab   = Window:Tab({ Title = "Noclip",   Icon = "ghost"   })
local TeleportTab = Window:Tab({ Title = "Teleport", Icon = "map-pin" })
local MiscTab     = Window:Tab({ Title = "Misc",     Icon = "shield"  })

-- ============================================================
--  FLY
-- ============================================================
do
    local FlySection = FlyTab:Section({ Title = "Flight Control" })
    local V_SPEED   = 25
    local H_SPEED   = 28
    local MAX_FORCE = Vector3.new(4000, 25000, 4000)
    local flying    = false
    local bv, bg, heartbeatConn

    local function getRoot()
        local c = player.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end
    local function getHum()
        local c = player.Character
        return c and c:FindFirstChildOfClass("Humanoid")
    end
    local function stopFlight()
        flying = false
        if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
        if bv then bv:Destroy(); bv = nil end
        if bg then bg:Destroy(); bg = nil end
        local h = getHum()
        if h then h.AutoRotate = true; h.JumpPower = 50 end
    end
    local function startFlight()
        if bv or bg then return end
        local root = getRoot(); local hum = getHum()
        if not root or not hum then return end
        bv = Instance.new("BodyVelocity")
        bv.Name = "AirResistance"; bv.MaxForce = MAX_FORCE
        bv.Velocity = Vector3.zero; bv.P = 600; bv.Parent = root
        bg = Instance.new("BodyGyro")
        bg.Name = "Stabilizer"; bg.MaxTorque = Vector3.new(4000,4000,4000)
        bg.CFrame = root.CFrame; bg.D = 80; bg.P = 2500; bg.Parent = root
        hum.AutoRotate = false; hum.JumpPower = 0
        heartbeatConn = RunService.Heartbeat:Connect(function()
            if not flying then stopFlight(); return end
            local r = getRoot()
            if not r or not r.Parent then stopFlight(); return end
            local cam = workspace.CurrentCamera
            local md = Vector3.zero
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then md += Vector3.new(0,0,-1) end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then md += Vector3.new(0,0, 1) end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then md += Vector3.new(-1,0,0) end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then md += Vector3.new( 1,0,0) end
            local wm = Vector3.zero
            if md.Magnitude > 0 then
                local fwd = Vector3.new(cam.CFrame.LookVector.X,0,cam.CFrame.LookVector.Z).Unit
                local rgt = Vector3.new(cam.CFrame.RightVector.X,0,cam.CFrame.RightVector.Z).Unit
                wm = (fwd * -md.Z + rgt * md.X).Unit
            end
            local vert = 0
            if     UserInputService:IsKeyDown(Enum.KeyCode.E) then vert =  V_SPEED
            elseif UserInputService:IsKeyDown(Enum.KeyCode.Q) then vert = -V_SPEED
            else   vert = -workspace.Gravity * 0.015 end
            local noise = Vector3.new((math.random()-.5)*.1,(math.random()-.5)*.05,(math.random()-.5)*.1)
            bv.Velocity = wm * H_SPEED + Vector3.new(0,vert,0) + noise
            bg.CFrame = CFrame.lookAt(r.Position, r.Position + (wm.Magnitude > .01 and wm or cam.CFrame.LookVector))
        end)
    end
    player.CharacterAdded:Connect(function() stopFlight() end)

    FlySection:Toggle({
        Title = "Enable Fly", Desc = "WASD to move  •  E = up  •  Q = down", Value = false,
        Callback = function(state)
            flying = state
            if state then startFlight()
                WindUI:Notify({ Title = "Fly", Content = "Flight enabled", Icon = "plane", Duration = 3 })
            else stopFlight()
                WindUI:Notify({ Title = "Fly", Content = "Flight disabled", Icon = "plane-off", Duration = 2 })
            end
        end,
    })
    FlySection:Slider({ Title = "Horizontal Speed", Desc = "Sideways movement speed",
        Step = 1, Value = { Min = 5, Max = 200, Default = 28 },
        Callback = function(v) H_SPEED = v end,
    })
    FlySection:Slider({ Title = "Vertical Speed", Desc = "Up/down speed with E and Q",
        Step = 1, Value = { Min = 5, Max = 100, Default = 25 },
        Callback = function(v) V_SPEED = v end,
    })
end

-- ============================================================
--  SPEED
-- ============================================================
do
    local SpeedSection = SpeedTab:Section({ Title = "Walk Speed" })
    local currentSpeed = 16
    local function applySpeed(speed)
        currentSpeed = math.clamp(speed, 2, 200)
        local c = player.Character
        if c then local h = c:FindFirstChild("Humanoid"); if h then h.WalkSpeed = currentSpeed end end
    end
    player.CharacterAdded:Connect(function(c)
        task.wait(0.1)
        local h = c:FindFirstChild("Humanoid"); if h then h.WalkSpeed = currentSpeed end
    end)
    SpeedSection:Slider({ Title = "Walk Speed", Desc = "Adjust your character walk speed",
        Step = 1, Value = { Min = 2, Max = 200, Default = 16 },
        Callback = function(v)
            applySpeed(v)
            WindUI:Notify({ Title = "Speed", Content = "Walk speed set to " .. v, Icon = "zap", Duration = 2 })
        end,
    })
    SpeedSection:Button({ Title = "Reset Speed", Desc = "Reset to default (16)", Icon = "rotate-ccw",
        Callback = function()
            applySpeed(16)
            WindUI:Notify({ Title = "Speed", Content = "Walk speed reset to 16", Icon = "rotate-ccw", Duration = 2 })
        end,
    })
end

-- ============================================================
--  NOCLIP
-- ============================================================
do
    local NoclipSection   = NoclipTab:Section({ Title = "Noclip" })
    local SettingsSection = NoclipTab:Section({ Title = "Settings" })
    local RAY_LENGTH     = 100
    local GROUND_OFFSET  = 3
    local VERTICAL_FORCE = 1e6
    local autoOffset     = true
    local noclipEnabled  = false
    local noclipConn, bodyPosition

    local function setCollisions(char, state)
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = state end
        end
    end
    local function setupBP(char)
        local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso")
        if not root then return nil end
        for _, o in ipairs(root:GetChildren()) do if o:IsA("BodyPosition") then o:Destroy() end end
        local bp = Instance.new("BodyPosition")
        bp.MaxForce = Vector3.new(0, VERTICAL_FORCE, 0)
        bp.P = 10000; bp.D = 1000; bp.Position = root.Position; bp.Parent = root
        return bp
    end
    local function getAutoOffset(char)
        local h = char:FindFirstChildOfClass("Humanoid")
        return h and (h.HipHeight + 1.5) or 3
    end
    local function noclipLoop()
        local char = player.Character; if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso")
        if not root then return end
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Blacklist
        rp.FilterDescendantsInstances = {char}
        local hit = workspace:Raycast(root.Position, Vector3.new(0,-RAY_LENGTH,0), rp)
        if hit and bodyPosition then
            local off = autoOffset and getAutoOffset(char) or GROUND_OFFSET
            bodyPosition.Position = Vector3.new(root.Position.X, hit.Position.Y + off, root.Position.Z)
        end
    end
    local function enableNoclip()
        local char = player.Character or player.CharacterAdded:Wait()
        if not char then return end
        local h = char:FindFirstChildOfClass("Humanoid")
        if h then h.PlatformStand = false end
        setCollisions(char, false)
        bodyPosition = setupBP(char)
        if noclipConn then noclipConn:Disconnect() end
        noclipConn = RunService.Stepped:Connect(function()
            if noclipEnabled then noclipLoop() end
        end)
    end
    local function disableNoclip()
        noclipEnabled = false
        if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
        if bodyPosition then bodyPosition:Destroy(); bodyPosition = nil end
        local char = player.Character
        if char then
            setCollisions(char, true)
            local h = char:FindFirstChildOfClass("Humanoid"); if h then h.PlatformStand = false end
        end
    end
    player.CharacterAdded:Connect(function()
        if noclipEnabled then task.wait(0.5); enableNoclip() end
    end)

    NoclipSection:Toggle({ Title = "Enable Noclip", Desc = "Walk through walls while staying on the ground", Value = false,
        Callback = function(state)
            noclipEnabled = state
            if state then enableNoclip()
                WindUI:Notify({ Title = "Noclip", Content = "Noclip enabled", Icon = "ghost", Duration = 3 })
            else disableNoclip()
                WindUI:Notify({ Title = "Noclip", Content = "Collisions restored", Icon = "box", Duration = 2 })
            end
        end,
    })
    SettingsSection:Toggle({ Title = "Auto Ground Offset", Desc = "Auto-detects correct floor height", Value = true,
        Callback = function(state) autoOffset = state end,
    })
    SettingsSection:Slider({ Title = "Manual Ground Offset", Desc = "Used when Auto is off",
        Step = 1, Value = { Min = 1, Max = 15, Default = 3 }, Callback = function(v) GROUND_OFFSET = v end,
    })
    SettingsSection:Slider({ Title = "Ray Length", Desc = "How far down to scan for the floor",
        Step = 5, Value = { Min = 20, Max = 500, Default = 100 }, Callback = function(v) RAY_LENGTH = v end,
    })
    SettingsSection:Slider({ Title = "Vertical Hold Force", Desc = "Strength keeping you at floor level",
        Step = 100000, Value = { Min = 100000, Max = 5000000, Default = 1000000 },
        Callback = function(v)
            VERTICAL_FORCE = v
            if bodyPosition then bodyPosition.MaxForce = Vector3.new(0, VERTICAL_FORCE, 0) end
        end,
    })
end

-- ============================================================
--  TELEPORT
-- ============================================================
do
    local TpSection    = TeleportTab:Section({ Title = "Click to Teleport" })
    local SavedSection = TeleportTab:Section({ Title = "Saved Positions" })
    local TP_STEPS       = 20
    local TP_STEP_WAIT   = 0.01
    local isTeleporting  = false
    local clickTpEnabled = false
    local clickConn
    local savedPositions = {}

    local function smoothTeleport(targetCF)
        if isTeleporting then
            WindUI:Notify({ Title = "Teleport", Content = "Already teleporting, please wait", Icon = "loader", Duration = 2 })
            return
        end
        isTeleporting = true
        local char = player.Character; if not char then isTeleporting = false; return end
        local root = char:FindFirstChild("HumanoidRootPart"); if not root then isTeleporting = false; return end
        local startCF = root.CFrame
        local hum = char:FindFirstChildOfClass("Humanoid")
        local oldAR = hum and hum.AutoRotate
        if hum then hum.AutoRotate = false end
        for i = 1, TP_STEPS do
            if not root or not root.Parent then break end
            root.CFrame = startCF:Lerp(targetCF, 1-(1-i/TP_STEPS)^3)
            task.wait(TP_STEP_WAIT)
        end
        if root and root.Parent then root.CFrame = targetCF end
        if hum then hum.AutoRotate = oldAR end
        isTeleporting = false
    end
    local function enableClickTp()
        if clickConn then clickConn:Disconnect() end
        clickConn = UserInputService.InputBegan:Connect(function(input, gpe)
            if gpe or not clickTpEnabled then return end
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
            local char = player.Character; if not char then return end
            local root = char:FindFirstChild("HumanoidRootPart"); if not root then return end
            local cam = workspace.CurrentCamera
            local mp  = UserInputService:GetMouseLocation()
            local ray = cam:ScreenPointToRay(mp.X, mp.Y)
            local rp  = RaycastParams.new()
            rp.FilterType = Enum.RaycastFilterType.Blacklist
            rp.FilterDescendantsInstances = {char}
            local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, rp)
            if hit then
                local hum = char:FindFirstChildOfClass("Humanoid")
                local hipH = (hum and hum.HipHeight or 2) + 1
                local tCF = CFrame.new(hit.Position + Vector3.new(0,hipH,0)) * (root.CFrame - root.CFrame.Position)
                smoothTeleport(tCF)
            else
                WindUI:Notify({ Title = "Teleport", Content = "No surface found", Icon = "map-x", Duration = 2 })
            end
        end)
    end
    local function disableClickTp()
        if clickConn then clickConn:Disconnect(); clickConn = nil end
    end

    TpSection:Toggle({ Title = "Click to Teleport", Desc = "Left-click anywhere to dash there smoothly", Value = false,
        Callback = function(state)
            clickTpEnabled = state
            if state then enableClickTp()
                WindUI:Notify({ Title = "Teleport", Content = "Click anywhere to teleport", Icon = "map-pin", Duration = 3 })
            else disableClickTp()
                WindUI:Notify({ Title = "Teleport", Content = "Click teleport off", Icon = "map-pin-off", Duration = 2 })
            end
        end,
    })
    TpSection:Slider({ Title = "Teleport Steps", Desc = "More = smoother, less = snappier",
        Step = 1, Value = { Min = 5, Max = 60, Default = 20 }, Callback = function(v) TP_STEPS = v end,
    })
    TpSection:Slider({ Title = "Step Delay (ms)", Desc = "Time between each step",
        Step = 1, Value = { Min = 1, Max = 50, Default = 10 }, Callback = function(v) TP_STEP_WAIT = v/1000 end,
    })
    TpSection:Button({ Title = "Save Current Position", Desc = "Saves where you are standing", Icon = "bookmark",
        Callback = function()
            local char = player.Character; if not char then return end
            local root = char:FindFirstChild("HumanoidRootPart"); if not root then return end
            if #savedPositions >= 5 then
                WindUI:Notify({ Title = "Slots Full", Content = "All 5 slots are used", Icon = "alert-circle", Duration = 3 })
                return
            end
            local name = "Pos " .. (#savedPositions + 1)
            table.insert(savedPositions, { name = name, cframe = root.CFrame })
            WindUI:Notify({ Title = "Position Saved", Content = name .. " saved!", Icon = "bookmark-check", Duration = 3 })
        end,
    })
    for i = 1, 5 do
        SavedSection:Button({ Title = "Teleport to Pos " .. i, Desc = "Dash to saved position " .. i, Icon = "map-pin",
            Callback = function()
                local e = savedPositions[i]
                if not e then
                    WindUI:Notify({ Title = "Empty Slot", Content = "Slot " .. i .. " is empty", Icon = "alert-circle", Duration = 3 })
                    return
                end
                WindUI:Notify({ Title = "Teleporting", Content = "Dashing to " .. e.name, Icon = "map-pin", Duration = 2 })
                smoothTeleport(e.cframe)
            end,
        })
    end
end

-- ============================================================
--  MISC – Moderation Watcher (PREMIUM)
-- ============================================================
do
    local WatchSection = MiscTab:Section({ Title = "⭐ Moderation Watcher  [PREMIUM]" })
    local watcherEnabled = false
    local watcherThread  = nil
    local joinConn       = nil

    modWatchToggle = WatchSection:Toggle({
        Title       = "👑 Enable Mod Watcher",
        Desc        = "⭐ Requires a Premium key — upgrade at pandauth.com",
        Value       = false,
        Locked      = true,
        LockedTitle = "This feature isn't available to free users.",
        Callback    = function(state)
            if not isPremium then
                WindUI:Notify({ Title = "⭐ Premium Required", Content = "Upgrade at pandauth.com", Icon = "crown", Duration = 5 })
                return
            end
            if state then
                local GROUP_ID         = 2935212
                local STAFF_RANK_NAMES = { "game moderation", "administration" }
                local SCAN_INTERVAL    = 0.6
                local modUserIds       = {}
                local modUserIdSet     = {}

                local function fetchRoleMembers(roleId)
                    local ids = {}; local cursor = ""
                    repeat
                        local url = ("https://groups.roblox.com/v1/groups/%d/roles/%d/users?limit=100&sortOrder=Asc"):format(GROUP_ID, roleId)
                        if cursor ~= "" then url = url .. "&cursor=" .. cursor end
                        local ok, res = pcall(function() return HttpService:JSONDecode(game:HttpGet(url)) end)
                        if not ok or not res or not res.data then break end
                        for _, member in ipairs(res.data) do table.insert(ids, member.userId) end
                        cursor = res.nextPageCursor or ""
                    until cursor == ""
                    return ids
                end
                local function fetchStaffRoleIds()
                    local url = ("https://groups.roblox.com/v1/groups/%d/roles"):format(GROUP_ID)
                    local ok, res = pcall(function() return HttpService:JSONDecode(game:HttpGet(url)) end)
                    if not ok or not res or not res.roles then return {} end
                    local ids = {}
                    for _, role in ipairs(res.roles) do
                        local lname = role.name:lower()
                        for _, keyword in ipairs(STAFF_RANK_NAMES) do
                            if lname:find(keyword, 1, true) then table.insert(ids, role.id); break end
                        end
                    end
                    return ids
                end
                local function buildModList()
                    modUserIds = {}; modUserIdSet = {}
                    WindUI:Notify({ Title = "Mod Watcher", Content = "Fetching staff list...", Icon = "loader", Duration = 3 })
                    for _, rid in ipairs(fetchStaffRoleIds()) do
                        for _, uid in ipairs(fetchRoleMembers(rid)) do
                            if not modUserIdSet[uid] then modUserIdSet[uid] = true; table.insert(modUserIds, uid) end
                        end
                    end
                    return #modUserIds
                end
                local function checkPlayer(p)
                    if not watcherEnabled then return end
                    if modUserIdSet[p.UserId] then
                        WindUI:Notify({ Title = "⚠️ Moderator Detected", Content = p.Name .. " (ID: " .. p.UserId .. ") joined!", Icon = "shield-alert", Duration = 6 })
                    end
                end

                local count = buildModList()
                if count == 0 then
                    WindUI:Notify({ Title = "Mod Watcher", Content = "No staff found.", Icon = "alert-circle", Duration = 5 })
                    return
                end
                watcherEnabled = true
                WindUI:Notify({ Title = "Mod Watcher On", Content = "Watching " .. count .. " staff.", Icon = "shield", Duration = 4 })
                watcherThread = task.spawn(function()
                    while watcherEnabled do
                        for _, p in ipairs(Players:GetPlayers()) do checkPlayer(p) end
                        task.wait(SCAN_INTERVAL)
                    end
                end)
                joinConn = Players.PlayerAdded:Connect(checkPlayer)
            else
                watcherEnabled = false
                if joinConn then joinConn:Disconnect(); joinConn = nil end
                watcherThread = nil
                WindUI:Notify({ Title = "Mod Watcher Off", Content = "No longer monitoring.", Icon = "shield-off", Duration = 3 })
            end
        end,
    })
end

Window:SelectTab(1)
