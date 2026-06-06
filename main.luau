-- ==================== SERVICES ====================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local player           = Players.LocalPlayer

local LOAD_START = tick()

-- ==================== WINDUI ====================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

-- ==================== LOGGING ====================
local function LOG(tag, ...)
    local parts = {"[CBD][" .. tag .. "]"}
    for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
    warn(table.concat(parts, " "))
end

-- ==================== PANDA AUTH ====================
local isPremium = false
local keyExpiry = "Never"

local Cookies = (function()
    local httpReq = request or http_request or httprequest
        or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)
    if not httpReq then LOG("COOKIES","No HTTP request function found"); return nil end
    local ok, resp = pcall(function()
        return httpReq({ Url = "https://secure.pandauth.com/cv4/lib", Method = "GET" })
    end)
    if not ok then LOG("COOKIES","Fetch failed:", resp); return nil end
    local body       = resp.Body or resp.body or ""
    local statusCode = resp.StatusCode or resp.statusCode or 0
    if statusCode < 200 or statusCode >= 300 or #body < 100 then
        LOG("COOKIES","Bad response, status =", statusCode); return nil
    end
    local lib
    local loadOk, loadErr = pcall(function() lib = loadstring(body)() end)
    if not loadOk or not lib or type(lib.configure) ~= "function" then
        LOG("COOKIES","Lib init failed:", loadErr); return nil
    end
    lib.configure({ serviceId="scprp", kickOnDetect=false, openDashboard=true, validationTimeout=600 })
    LOG("COOKIES","Library loaded and configured")
    return lib
end)()

if not Cookies then
    warn("[CBD] WARNING: Panda auth library failed to load. Key validation will not work.")
end

-- ============================================================
--  FORWARD DECLARATIONS
-- ============================================================
local modWatchToggle  = nil
local antiFlingToggle = nil
local v2SpeedToggle   = nil
local Window          = nil  -- forward declared; assigned after CreateWindow

-- ============================================================
--  TAG SYSTEM
-- ============================================================
local _tagState = nil

local function freeTag()
    if _tagState == "free" then return end
    if _tagState == "premium" then LOG("TAG","freeTag skipped — premium already applied"); return end
    if not Window then LOG("TAG","freeTag skipped — Window not ready"); return end
    _tagState = "free"
    Window:Tag({ Title="Free", Icon="crown", Color=Color3.fromHex("#555555"), Radius=6 })
    LOG("TAG","freeTag applied")
end

local function premiumTag()
    if _tagState == "premium" then return end
    if _tagState == "free" then LOG("TAG","premiumTag skipped — free tag already shown"); return end
    if not Window then LOG("TAG","premiumTag skipped — Window not ready"); return end
    _tagState = "premium"
    Window:Tag({ Title="⭐ Premium", Icon="crown", Color=Color3.fromHex("#B8860B"), Radius=6 })
    task.spawn(function()
        local label, deadline = nil, tick() + 2
        while tick() < deadline do
            pcall(function()
                for _, gui in ipairs(player.PlayerGui:GetChildren()) do
                    if gui:IsA("ScreenGui") then
                        for _, obj in ipairs(gui:GetDescendants()) do
                            if obj:IsA("TextLabel") and obj.Text == "⭐ Premium" then label = obj end
                        end
                    end
                end
            end)
            if label then break end
            task.wait(0.05)
        end
        if not label then LOG("TAG","premiumTag: label not found"); return end
        local WHITE = Color3.fromHex("#FFFFFF")
        local _locked = false
        local function forceWhite()
            if _locked then return end
            if label.TextColor3 ~= WHITE then _locked=true; label.TextColor3=WHITE; _locked=false end
        end
        forceWhite()
        label:GetPropertyChangedSignal("TextColor3"):Connect(forceWhite)
    end)
    LOG("TAG","premiumTag applied")
end

-- ============================================================
--  APPLY PREMIUM
-- ============================================================
local function applyPremium(value, source, expires)
    isPremium = value; keyExpiry = expires or "Never"
    LOG("PREMIUM","isPremium =", isPremium, "via", source, "expires =", keyExpiry)
    task.spawn(function() if isPremium then premiumTag() else freeTag() end end)
    if modWatchToggle  then pcall(function() if isPremium then modWatchToggle:Unlock()  else modWatchToggle:Lock()  end end) end
    if antiFlingToggle then pcall(function() if isPremium then antiFlingToggle:Unlock() else antiFlingToggle:Lock() end end) end
    if v2SpeedToggle   then pcall(function() if isPremium then v2SpeedToggle:Unlock()   else v2SpeedToggle:Lock()   end end) end
    if isPremium then
        WindUI:Notify({ Title="⭐ Premium Active", Content="Premium features unlocked! Expires: "..keyExpiry, Icon="crown", Duration=6 })
    end
end

-- ============================================================
--  RESOLVE AUTH RESULT  (FIXED — handles V4.3 Cookies fields)
-- ============================================================
local function resolveResult(result)
    if type(result) ~= "table" then
        LOG("KEYSYSTEM","resolveResult: not a table, type =", type(result))
        return false, false, "Never"
    end

    -- Debug dump — shows every key/value so you can spot new field names
    LOG("KEYSYSTEM","RAW RESULT DUMP:")
    for k, v in pairs(result) do
        LOG("KEYSYSTEM","  " .. tostring(k) .. " = " .. tostring(v))
    end

    -- V4.3 Cookies returns { success, isPremium, error, expires }
    -- Broaden the success check to cover any reasonable field name
    local isSuccess = result.success      == true
        or result.valid        == true
        or result.authorized   == true
        or result.ok           == true
        or result.authenticated == true
        or result.auth         == true
        or result.passed       == true

    -- If success is explicitly false, don't let other fields override it
    if result.success == false or result.valid == false or result.authorized == false then
        isSuccess = false
    end

    -- Premium detection — cover every reasonable field name / type
    local isPrem = false
    if result.isPremium    == true  then isPrem = true end
    if result.premium      == true  then isPrem = true end
    if result.is_premium   == true  then isPrem = true end
    if result.Premium      == true  then isPrem = true end
    if result.isPremium    == 1     then isPrem = true end  -- some libs return 1/0
    if result.premium      == 1     then isPrem = true end
    if type(result.tier)   == "string" and result.tier:lower()   == "premium" then isPrem = true end
    if type(result.plan)   == "string" and result.plan:lower()   == "premium" then isPrem = true end
    if type(result.rank)   == "string" and result.rank:lower()   == "premium" then isPrem = true end
    if type(result.level)  == "string" and result.level:lower()  == "premium" then isPrem = true end
    if type(result.role)   == "string" and result.role:lower()   == "premium" then isPrem = true end
    if type(result.group)  == "string" and result.group:lower()  == "premium" then isPrem = true end
    if type(result.package)== "string" and result.package:lower()== "premium" then isPrem = true end

    -- Expiry — cover every reasonable field name
    local expires = result.expires
        or result.expiry
        or result.expiresAt
        or result.expire_at
        or result.expiration
        or result.exp
        or result.validUntil
        or result.valid_until
        or "Never"
    expires = tostring(expires)

    LOG("KEYSYSTEM","RESOLVED → success=" .. tostring(isSuccess) .. "  premium=" .. tostring(isPrem) .. "  expires=" .. expires)
    return isSuccess, isPrem, expires
end

-- ============================================================
--  KEY FILE HELPERS
--  Panda V4.3 saves keys as <workspace>/CBD/<hwid>.key
--  We scan the CBD folder for any .key file and read it directly
--  so we never depend on loadSavedKey() working correctly.
-- ============================================================
local KEY_FOLDER = "CBD"

local function findSavedKeyFromDisk()
    -- Try Cookies.loadSavedKey first (works on some executors)
    if Cookies and type(Cookies.loadSavedKey) == "function" then
        local ok, val = pcall(function() return Cookies.loadSavedKey() end)
        if ok and val and val ~= "" then
            LOG("AUTO","loadSavedKey() returned a key")
            return val
        end
    end
    -- Fallback: scan the CBD folder for .key files directly
    if type(listfiles) ~= "function" or type(readfile) ~= "function" then
        LOG("AUTO","listfiles/readfile not available on this executor")
        return nil
    end
    local ok, files = pcall(listfiles, KEY_FOLDER)
    if not ok or not files then LOG("AUTO","listfiles failed for:", KEY_FOLDER); return nil end
    LOG("AUTO","Scanning", KEY_FOLDER, "—", #files, "file(s)")
    for _, path in ipairs(files) do
        LOG("AUTO","  checking:", tostring(path))
        if tostring(path):sub(-4):lower() == ".key" then
            local rok, content = pcall(readfile, path)
            if rok and content and #content > 8 then
                local key = content:match("^%s*(.-)%s*$")
                if key and #key > 8 then
                    LOG("AUTO","Key found in:", tostring(path), "len:", #key)
                    return key
                end
            end
        end
    end
    LOG("AUTO","No .key file found in", KEY_FOLDER)
    return nil
end

local function saveKeyToDisk(keyStr)
    if not keyStr or keyStr == "" then return end
    if Cookies and type(Cookies.saveKey) == "function" then
        pcall(function() Cookies.saveKey(keyStr) end)
        LOG("AUTO","Cookies.saveKey called")
    end
end

-- ============================================================
--  AUTO-VALIDATE SAVED KEY
-- ============================================================
local function tryAutoValidate()
    if not Cookies then LOG("AUTO","No Cookies lib"); return false end
    local savedKey = findSavedKeyFromDisk()
    if not savedKey or savedKey == "" then LOG("AUTO","No saved key found"); return false end
    LOG("AUTO","Key found, length =", #savedKey, "— validating...")
    WindUI:Notify({ Title="Auto-Login", Content="Validating saved key...", Icon="loader", Duration=3 })
    local vok, result = pcall(function() return Cookies.validate(savedKey) end)
    if not vok then
        LOG("AUTO","validate error:", tostring(result))
        WindUI:Notify({ Title="Auto-Login Failed", Content="Could not validate saved key.", Icon="wifi-off", Duration=4 })
        return true
    end
    local isSuccess, isPrem, expires = resolveResult(result)
    if isSuccess then
        applyPremium(isPrem, "AutoLogin-SavedKey", expires)
        WindUI:Notify({ Title="✅ Auto-Login", Content=(isPrem and "⭐ Premium" or "Free").." • Expires: "..expires, Icon="check-circle", Duration=5 })
    else
        local reason = type(result)=="table" and tostring(result.error or result.message or result.reason or "Invalid key") or "Invalid key"
        WindUI:Notify({ Title="Auto-Login Failed: "..reason, Content="Re-enter your key in the key system.", Icon="x-circle", Duration=5 })
    end
    return true
end

-- ============================================================
--  WINDOW
-- ============================================================
Window = WindUI:CreateWindow({
    Title="Containment Breach Deluxe", Icon="shield-alert", Author="CBD",
    Transparent=true, Theme="Dark", Size=UDim2.fromOffset(450,550),
    Folder="CBD", HideSearchBar=false,
    User={
        Enabled=true, Anonymous=false,
        Callback=function()
            WindUI:Notify({
                Title=isPremium and "⭐ Premium User" or "Free User",
                Content=player.Name.." • "..(isPremium and "Premium • Expires: "..keyExpiry or "Free tier"),
                Icon="user", Duration=3,
            })
        end,
    },
    KeySystem={
        Note="Enter your key below. Your key is saved locally for auto-login next session.",
        SaveKey=true,
        API={{ Title="Containment Breach Deluxe", Desc="Click 'Get Key' to obtain your key.", Icon="shield-alert", Type="pandadevelopment", ServiceId="scprp" }},
        Callback=function(enteredKey)
            LOG("KEYSYSTEM","Callback received, type =", type(enteredKey), "value =", tostring(enteredKey))
            task.spawn(function()
                -- WindUI pre-resolved the key into a table already
                -- This happens when Type="pandadevelopment" — WindUI calls Panda internally
                -- and passes back the result. We still need to saveKey ourselves.
                if type(enteredKey) == "table" then
                    LOG("KEYSYSTEM","WindUI pre-resolved path — RAW DUMP:")
                    for k, v in pairs(enteredKey) do
                        LOG("KEYSYSTEM","  " .. tostring(k) .. " = " .. tostring(v))
                    end
                    local isSuccess, isPrem, expires = resolveResult(enteredKey)
                    if isSuccess then
                        -- Save the raw key string — check every field WindUI might store it in
                        local rawKey = enteredKey.key or enteredKey.keyValue or enteredKey.licenseKey
                            or enteredKey.license or enteredKey.keyString or enteredKey.value or nil
                        if rawKey then saveKeyToDisk(rawKey) end
                        applyPremium(isPrem, "WindUI-PreResolved", expires)
                        WindUI:Notify({ Title="✅ Key Valid", Content=(isPrem and "⭐ Premium" or "Free").." • Expires: "..expires, Icon="check-circle", Duration=5 })
                    else
                        local reason = tostring(enteredKey.error or enteredKey.message or enteredKey.reason or "Invalid key")
                        WindUI:Notify({ Title="❌ "..reason, Content="Get a key at pandauth.com", Icon="x-circle", Duration=6 })
                    end
                    return
                end

                -- Manual string key path — validate via Cookies lib
                if not Cookies then
                    WindUI:Notify({ Title="Auth Error", Content="Panda library failed to load.", Icon="wifi-off", Duration=6 })
                    return
                end
                if type(enteredKey) ~= "string" or #enteredKey < 3 then
                    WindUI:Notify({ Title="Auth Error", Content="Key appears empty or malformed.", Icon="x-circle", Duration=4 })
                    return
                end

                WindUI:Notify({ Title="Checking...", Content="Contacting Panda servers...", Icon="loader", Duration=2 })
                local ok, result = pcall(function() return Cookies.validate(enteredKey) end)
                if not ok then
                    WindUI:Notify({ Title="Auth Error", Content="Validation call failed: "..tostring(result), Icon="wifi-off", Duration=5 })
                    return
                end

                local isSuccess, isPrem, expires = resolveResult(result)
                if isSuccess then
                    saveKeyToDisk(enteredKey)
                    applyPremium(isPrem, "KeySystem-Cookies", expires)
                    WindUI:Notify({ Title="✅ Key Valid", Content=(isPrem and "⭐ Premium" or "Free").." • Expires: "..expires, Icon="check-circle", Duration=5 })
                else
                    local reason = type(result)=="table"
                        and tostring(result.error or result.message or result.reason or result.msg or "Invalid key")
                        or "Invalid key"
                    WindUI:Notify({ Title="❌ "..reason, Content="Get a key at pandauth.com", Icon="x-circle", Duration=6 })
                end
            end)
        end,
    },
})

-- ============================================================
--  STARTUP SEQUENCE
-- ============================================================
task.defer(function()
    local elapsed = string.format("%.2f", tick()-LOAD_START)
    WindUI:Notify({ Title="CBD Loaded", Content="Loaded in "..elapsed.."s", Icon="shield-alert", Duration=4 })
    task.wait(0.5)
    local hadSavedKey = tryAutoValidate()
    if not isPremium then freeTag() end
    if not hadSavedKey and not isPremium then
        task.wait(0.4)
        WindUI:Notify({ Title="Free Tier", Content="Enter a key to unlock Premium features.", Icon="user", Duration=4 })
    end
end)

-- ==================== TABS ====================
local FlyTab      = Window:Tab({ Title="Fly",      Icon="plane"   })
local SpeedTab    = Window:Tab({ Title="Speed",    Icon="zap"     })
local NoclipTab   = Window:Tab({ Title="Noclip",   Icon="ghost"   })
local TrollingTab = Window:Tab({ Title="Trolling", Icon="laugh"   })
local TeleportTab = Window:Tab({ Title="Teleport", Icon="map-pin" })
local MiscTab     = Window:Tab({ Title="Misc",     Icon="shield"  })

-- ============================================================
--  SAFE CFRAME HELPER
-- ============================================================
local function flatCFrame(pos, dir)
    local flatDir = Vector3.new(dir.X, 0, dir.Z)
    if flatDir.Magnitude < 0.001 then
        flatDir = Vector3.new(0, 0, -1)
    else
        flatDir = flatDir.Unit
    end
    return CFrame.lookAt(pos, pos + flatDir)
end

-- ============================================================
--  SHARED PLATFORM UTILITY
-- ============================================================
local function createWeldedPlatform(padName, padSize)
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end

    local pad = Instance.new("Part")
    pad.Name         = padName
    pad.Size         = padSize or Vector3.new(10, 0.4, 10)
    pad.Anchored     = true
    pad.CanCollide   = true
    pad.Transparency = 1
    pad.Material     = Enum.Material.SmoothPlastic
    pad.CastShadow   = false
    pad.CanTouch     = false
    pad.Parent       = workspace

    pad.CFrame = root.CFrame

    local weld = Instance.new("WeldConstraint")
    weld.Part0  = pad
    weld.Part1  = root
    weld.Parent = pad

    return { pad = pad, weld = weld }
end

local function destroyWeldedPlatform(t)
    if not t then return end
    pcall(function() t.weld:Destroy() end)
    pcall(function() t.pad:Destroy()  end)
end

local function groundY(worldX, worldY, worldZ, ignoreList)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Blacklist
    rp.FilterDescendantsInstances = ignoreList or {}
    local hit = workspace:Raycast(
        Vector3.new(worldX, worldY + 10, worldZ),
        Vector3.new(0, -600, 0),
        rp
    )
    return hit and hit.Position.Y or nil
end

-- ============================================================
--  FLY V1  (BodyVelocity)
-- ============================================================
do
    local FlySection = FlyTab:Section({ Title="Flight Control" })
    local V_SPEED = 25
    local H_SPEED = 28
    local MAX_FORCE = Vector3.new(4000,25000,4000)
    local flying = false
    local bv, bg, heartbeatConn

    local function getRoot() local c=player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function getHum()  local c=player.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    local function stopFlight()
        flying = false
        if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn=nil end
        if bv then bv:Destroy(); bv=nil end
        if bg then bg:Destroy(); bg=nil end
        local h=getHum(); if h then h.AutoRotate=true; h.JumpPower=50 end
    end
    local function startFlight()
        if bv or bg then return end
        local root=getRoot(); local hum=getHum()
        if not root or not hum then return end
        bv=Instance.new("BodyVelocity"); bv.Name="AirResistance"; bv.MaxForce=MAX_FORCE; bv.Velocity=Vector3.zero; bv.P=600; bv.Parent=root
        bg=Instance.new("BodyGyro"); bg.Name="Stabilizer"; bg.MaxTorque=Vector3.new(4000,4000,4000); bg.CFrame=root.CFrame; bg.D=80; bg.P=2500; bg.Parent=root
        hum.AutoRotate=false; hum.JumpPower=0
        heartbeatConn=RunService.Heartbeat:Connect(function()
            if not flying then stopFlight(); return end
            local r=getRoot()
            if not r or not r.Parent then stopFlight(); return end
            local cam=workspace.CurrentCamera
            local md=Vector3.zero
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then md+=Vector3.new(0,0,-1) end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then md+=Vector3.new(0,0, 1) end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then md+=Vector3.new(-1,0,0) end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then md+=Vector3.new( 1,0,0) end
            local wm=Vector3.zero
            if md.Magnitude>0 then
                local fwd=Vector3.new(cam.CFrame.LookVector.X,0,cam.CFrame.LookVector.Z).Unit
                local rgt=Vector3.new(cam.CFrame.RightVector.X,0,cam.CFrame.RightVector.Z).Unit
                wm=(fwd*-md.Z+rgt*md.X).Unit
            end
            local vert=0
            if     UserInputService:IsKeyDown(Enum.KeyCode.E) then vert= V_SPEED
            elseif UserInputService:IsKeyDown(Enum.KeyCode.Q) then vert=-V_SPEED
            else   vert=-workspace.Gravity*0.015 end
            local noise=Vector3.new((math.random()-.5)*.1,(math.random()-.5)*.05,(math.random()-.5)*.1)
            bv.Velocity=wm*H_SPEED+Vector3.new(0,vert,0)+noise
            bg.CFrame=CFrame.lookAt(r.Position, r.Position+(wm.Magnitude>.01 and wm or cam.CFrame.LookVector))
        end)
    end
    player.CharacterAdded:Connect(function() if flying then stopFlight() end end)

    FlySection:Toggle({
        Title="Enable Fly", Desc="WASD to move  •  E = ascend  •  Q = descend", Value=false,
        Callback=function(state)
            flying=state
            if state then startFlight(); WindUI:Notify({ Title="Fly", Content="Flight enabled", Icon="plane", Duration=3 })
            else stopFlight(); WindUI:Notify({ Title="Fly", Content="Flight disabled", Icon="plane-off", Duration=2 }) end
        end,
    })
    FlySection:Slider({ Title="Horizontal Speed", Desc="Sideways and forward movement speed", Step=1, Value={Min=5,Max=200,Default=28}, Callback=function(v) H_SPEED=v end })
    FlySection:Slider({ Title="Vertical Speed",   Desc="Ascend/descend speed with E and Q",  Step=1, Value={Min=5,Max=100,Default=25}, Callback=function(v) V_SPEED=v end })
end

-- ============================================================
--  FLY V2  — Weld-based platform flight
-- ============================================================
do
    local FlyV2Section = FlyTab:Section({ Title="Fly V2  •  Weld-Based" })

    local fv2Enabled = false
    local fv2Speed   = 40
    local fv2VSpeed  = 20
    local fv2Conn    = nil
    local fv2Rig     = nil

    local fv2PosX, fv2PosY, fv2PosZ = 0, 0, 0
    local fv2FacingDir = Vector3.new(0, 0, -1)

    local function fv2GetRoot() local c=player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function fv2GetHum()  local c=player.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    local function fv2Disable()
        fv2Enabled = false
        if fv2Conn then fv2Conn:Disconnect(); fv2Conn=nil end
        if fv2Rig then
            destroyWeldedPlatform(fv2Rig)
            fv2Rig = nil
        end
        for _, obj in ipairs(workspace:GetChildren()) do
            if obj.Name == "_CBD_FlyV2Pad" then obj:Destroy() end
        end
        local hum = fv2GetHum()
        if hum then hum.AutoRotate=true; hum.JumpPower=50 end
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
        if fv2FacingDir.Magnitude < 0.001 then fv2FacingDir = Vector3.new(0,0,-1) end
        fv2FacingDir = fv2FacingDir.Unit

        fv2Rig = createWeldedPlatform("_CBD_FlyV2Pad", Vector3.new(10, 0.4, 10))
        if not fv2Rig then return end

        fv2Rig.pad.CFrame = flatCFrame(Vector3.new(fv2PosX, fv2PosY, fv2PosZ), fv2FacingDir)

        if hum then
            hum.AutoRotate = false
            hum.JumpPower  = 0
        end

        fv2Enabled = true

        fv2Conn = RunService.Heartbeat:Connect(function(dt)
            if not fv2Enabled then return end
            if not fv2Rig or not fv2Rig.pad or not fv2Rig.pad.Parent then
                fv2Disable(); return
            end

            local cam = workspace.CurrentCamera

            local wx, wz = 0, 0
            local goUp   = UserInputService:IsKeyDown(Enum.KeyCode.E)
            local goDown = UserInputService:IsKeyDown(Enum.KeyCode.Q)

            local mdX, mdZ = 0, 0
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then mdZ = -1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then mdZ =  1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then mdX = -1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then mdX =  1 end

            local moving = (mdX ~= 0 or mdZ ~= 0)
            if moving then
                local camFwdX = cam.CFrame.LookVector.X
                local camFwdZ = cam.CFrame.LookVector.Z
                local camRgtX = cam.CFrame.RightVector.X
                local camRgtZ = cam.CFrame.RightVector.Z
                local fLen = math.sqrt(camFwdX*camFwdX + camFwdZ*camFwdZ)
                local rLen = math.sqrt(camRgtX*camRgtX + camRgtZ*camRgtZ)
                if fLen > 0.001 then camFwdX=camFwdX/fLen; camFwdZ=camFwdZ/fLen end
                if rLen > 0.001 then camRgtX=camRgtX/rLen; camRgtZ=camRgtZ/rLen end

                wx = camFwdX * (-mdZ) + camRgtX * mdX
                wz = camFwdZ * (-mdZ) + camRgtZ * mdX
                local wLen = math.sqrt(wx*wx + wz*wz)
                if wLen > 0.001 then wx=wx/wLen; wz=wz/wLen end

                fv2FacingDir = Vector3.new(wx, 0, wz)
            end

            local speed = fv2Speed * dt
            fv2PosX = fv2PosX + wx * speed
            fv2PosZ = fv2PosZ + wz * speed

            if goUp then
                fv2PosY = fv2PosY + fv2VSpeed * dt
            elseif goDown then
                fv2PosY = fv2PosY - fv2VSpeed * dt
            end

            local newCF = flatCFrame(Vector3.new(fv2PosX, fv2PosY, fv2PosZ), fv2FacingDir)
            fv2Rig.pad.CFrame = newCF
        end)
    end

    player.CharacterAdded:Connect(function()
        if fv2Enabled then
            fv2Enabled = false
            task.wait(1)
            fv2Enable()
        end
    end)

    FlyV2Section:Toggle({
        Title="Enable Fly V2",
        Desc="Weld-based platform flight. WASD = move  •  E = up  •  Q = down",
        Value=false,
        Callback=function(state)
            if state then
                fv2Enable()
                WindUI:Notify({ Title="Fly V2", Content="Weld flight active. E/Q for altitude.", Icon="plane", Duration=3 })
            else
                fv2Disable()
                WindUI:Notify({ Title="Fly V2", Content="Platform flight disabled.", Icon="plane-off", Duration=2 })
            end
        end,
    })
    FlyV2Section:Slider({ Title="Horizontal Speed", Desc="Platform slide speed (studs/s)", Step=1, Value={Min=5,Max=200,Default=40}, Callback=function(v) fv2Speed=v end })
    FlyV2Section:Slider({ Title="Vertical Speed",   Desc="Ascend/descend speed (studs/s)",  Step=1, Value={Min=2,Max=80, Default=20}, Callback=function(v) fv2VSpeed=v end })
end

-- ============================================================
--  SPEED V1  (WalkSpeed)
-- ============================================================
do
    local SpeedSection = SpeedTab:Section({ Title="Walk Speed" })
    local currentSpeed = 16
    local speedEnabled = false
    local speedWarningAcknowledged = false

    local function applySpeed(speed)
        currentSpeed = math.clamp(speed,2,200)
        local c=player.Character; if c then local h=c:FindFirstChild("Humanoid"); if h then h.WalkSpeed=currentSpeed end end
    end
    local function resetSpeed() speedEnabled=false; applySpeed(16) end

    player.CharacterAdded:Connect(function(c)
        if not speedEnabled then return end
        task.wait(0.1)
        local h=c:FindFirstChild("Humanoid"); if h then h.WalkSpeed=currentSpeed end
    end)

    local pendingSpeedValue = nil

    SpeedSection:Slider({
        Title="Walk Speed", Desc="Adjust your character's movement speed", Step=1, Value={Min=2,Max=200,Default=16},
        Callback=function(v)
            if v==16 then resetSpeed(); return end
            if not speedWarningAcknowledged then
                pendingSpeedValue=v; speedWarningAcknowledged=true
                WindUI:Popup({
                    Title="⚠️ Speed Warning", Icon="alert-triangle",
                    Content="Modifying walk speed is detectable by server anti-cheat and may result in a ban. Use at your own risk.",
                    Buttons={
                        { Title="Cancel", Variant="Tertiary", Callback=function() speedWarningAcknowledged=false; pendingSpeedValue=nil; resetSpeed(); WindUI:Notify({ Title="Speed", Content="Speed change cancelled.", Icon="x-circle", Duration=2 }) end },
                        { Title="I Understand", Icon="check", Variant="Primary", Callback=function() speedEnabled=true; applySpeed(pendingSpeedValue or v); pendingSpeedValue=nil; WindUI:Notify({ Title="Speed", Content="Walk speed set to "..currentSpeed, Icon="zap", Duration=2 }) end },
                    },
                }); return
            end
            speedEnabled=true; applySpeed(v)
            WindUI:Notify({ Title="Speed", Content="Walk speed set to "..v, Icon="zap", Duration=2 })
        end,
    })
    SpeedSection:Button({ Title="Reset Speed", Desc="Reset to default (16)", Icon="rotate-ccw", Callback=function() resetSpeed(); WindUI:Notify({ Title="Speed", Content="Walk speed reset to 16", Icon="rotate-ccw", Duration=2 }) end })
end

-- ============================================================
--  SPEED V2 (PREMIUM) — Weld-based platform speed
-- ============================================================
do
    local SpeedV2Section = SpeedTab:Section({ Title="Speed V2  •  👑 More Secure" })
    local v2Enabled      = false
    local v2Speed        = 40
    local v2Conn         = nil
    local v2Rig          = nil
    local v2WarningAcknowledged = false

    local v2PosX, v2PosY, v2PosZ = 0, 0, 0
    local v2FacingDir = Vector3.new(0, 0, -1)

    local function v2GetRoot() local c=player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function v2GetHum()  local c=player.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    local function disableSpeedV2()
        v2Enabled = false
        if v2Conn then v2Conn:Disconnect(); v2Conn=nil end
        if v2Rig then
            destroyWeldedPlatform(v2Rig)
            v2Rig = nil
        end
        for _, obj in ipairs(workspace:GetChildren()) do
            if obj.Name == "_CBD_SpeedV2Pad" then obj:Destroy() end
        end
    end

    local function enableSpeedV2()
        disableSpeedV2()

        local root = v2GetRoot()
        if not root then return end

        v2PosX = root.Position.X
        v2PosY = root.Position.Y
        v2PosZ = root.Position.Z

        local lv = root.CFrame.LookVector
        v2FacingDir = Vector3.new(lv.X, 0, lv.Z)
        if v2FacingDir.Magnitude < 0.001 then v2FacingDir = Vector3.new(0, 0, -1) end
        v2FacingDir = v2FacingDir.Unit

        v2Rig = createWeldedPlatform("_CBD_SpeedV2Pad", Vector3.new(10, 0.4, 10))
        if not v2Rig then return end

        v2Rig.pad.CFrame = flatCFrame(Vector3.new(v2PosX, v2PosY, v2PosZ), v2FacingDir)

        v2Enabled = true

        v2Conn = RunService.Heartbeat:Connect(function(dt)
            if not v2Enabled then return end
            if not v2Rig or not v2Rig.pad or not v2Rig.pad.Parent then
                disableSpeedV2(); return
            end

            local hum2 = v2GetHum()
            if not hum2 then return end

            local cam = workspace.CurrentCamera

            local mdX, mdZ = 0, 0
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then mdZ = -1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then mdZ =  1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then mdX = -1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then mdX =  1 end

            local moveX, moveZ = 0, 0
            local moving = (mdX ~= 0 or mdZ ~= 0)
            if moving then
                local camFwdX = cam.CFrame.LookVector.X
                local camFwdZ = cam.CFrame.LookVector.Z
                local camRgtX = cam.CFrame.RightVector.X
                local camRgtZ = cam.CFrame.RightVector.Z

                local fLen = math.sqrt(camFwdX*camFwdX + camFwdZ*camFwdZ)
                local rLen = math.sqrt(camRgtX*camRgtX + camRgtZ*camRgtZ)
                if fLen > 0.001 then camFwdX=camFwdX/fLen; camFwdZ=camFwdZ/fLen end
                if rLen > 0.001 then camRgtX=camRgtX/rLen; camRgtZ=camRgtZ/rLen end

                moveX = camFwdX * (-mdZ) + camRgtX * mdX
                moveZ = camFwdZ * (-mdZ) + camRgtZ * mdX
                local mLen = math.sqrt(moveX*moveX + moveZ*moveZ)
                if mLen > 0.001 then moveX=moveX/mLen; moveZ=moveZ/mLen end

                v2FacingDir = Vector3.new(moveX, 0, moveZ)
            end

            v2PosX = v2PosX + moveX * v2Speed * dt
            v2PosZ = v2PosZ + moveZ * v2Speed * dt

            local root2 = v2GetRoot()
            if root2 then
                local rp = RaycastParams.new()
                rp.FilterType = Enum.RaycastFilterType.Blacklist
                rp.FilterDescendantsInstances = {player.Character}
                local hit = workspace:Raycast(root2.Position, Vector3.new(0, -500, 0), rp)
                if hit then
                    local hipOff = (hum2.HipHeight + root2.Size.Y * 0.5)
                    v2PosY = hit.Position.Y + hipOff
                end
            end

            local newCF = flatCFrame(Vector3.new(v2PosX, v2PosY, v2PosZ), v2FacingDir)
            v2Rig.pad.CFrame = newCF
        end)
    end

    player.CharacterAdded:Connect(function()
        if v2Enabled then
            v2Enabled = false
            task.wait(1)
            enableSpeedV2()
        end
    end)

    v2SpeedToggle = SpeedV2Section:Toggle({
        Title="👑 Speed V2",
        Desc="Welds you to an invisible platform and slides it — no WalkSpeed or forces touched. Much harder to detect.",
        Value=false, Locked=true, LockedTitle="Upgrade to Premium at pandauth.com to access Speed V2.",
        Callback=function(state)
            if not isPremium then
                WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com to unlock Speed V2.", Icon="crown", Duration=5 }); return
            end
            if state then
                if not v2WarningAcknowledged then
                    if v2SpeedToggle then pcall(function() v2SpeedToggle:Set(false) end) end
                    v2WarningAcknowledged=true
                    WindUI:Popup({
                        Title="⚠️ Speed V2 Info", Icon="alert-triangle",
                        Content="Speed V2 welds you to an invisible platform and slides it forward. No velocity or WalkSpeed is touched. Much harder to detect, but may feel slightly different to normal movement.",
                        Buttons={
                            { Title="Cancel", Variant="Tertiary", Callback=function() v2WarningAcknowledged=false; v2Enabled=false; WindUI:Notify({ Title="Speed V2", Content="Cancelled.", Icon="x-circle", Duration=2 }) end },
                            { Title="I Understand", Icon="check", Variant="Primary", Callback=function()
                                if v2SpeedToggle then pcall(function() v2SpeedToggle:Set(true) end) end
                                enableSpeedV2()
                                WindUI:Notify({ Title="Speed V2", Content="Platform speed active.", Icon="zap", Duration=3 })
                            end },
                        },
                    })
                else
                    enableSpeedV2()
                    WindUI:Notify({ Title="Speed V2", Content="Platform speed active.", Icon="zap", Duration=3 })
                end
            else
                disableSpeedV2()
                WindUI:Notify({ Title="Speed V2", Content="Platform speed disabled.", Icon="zap-off", Duration=2 })
            end
        end,
    })
    SpeedV2Section:Slider({ Title="V2 Speed", Desc="Platform slide speed (studs per second)", Step=1, Value={Min=5,Max=200,Default=40}, Callback=function(v) v2Speed=v end })
end

-- ============================================================
--  NOCLIP
-- ============================================================
do
    local NoclipSection   = NoclipTab:Section({ Title="Noclip" })
    local SettingsSection = NoclipTab:Section({ Title="Settings" })
    local RAY_LENGTH=100; local GROUND_OFFSET=3; local VERTICAL_FORCE=1e6
    local autoOffset=true; local noclipEnabled=false; local noclipConn=nil; local bodyPosition=nil

    local function setCollisions(char,state) for _,p in ipairs(char:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide=state end end end
    local function setupBP(char)
        local root=char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso"); if not root then return nil end
        for _,o in ipairs(root:GetChildren()) do if o:IsA("BodyPosition") then o:Destroy() end end
        local bp=Instance.new("BodyPosition"); bp.MaxForce=Vector3.new(0,VERTICAL_FORCE,0); bp.P=10000; bp.D=1000; bp.Position=root.Position; bp.Parent=root; return bp
    end
    local function getAutoOffset(char) local h=char:FindFirstChildOfClass("Humanoid"); return h and (h.HipHeight+1.5) or 3 end
    local function noclipLoop()
        local char=player.Character; if not char then return end
        local root=char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso"); if not root then return end
        local rp=RaycastParams.new(); rp.FilterType=Enum.RaycastFilterType.Blacklist; rp.FilterDescendantsInstances={char}
        local hit=workspace:Raycast(root.Position,Vector3.new(0,-RAY_LENGTH,0),rp)
        if hit and bodyPosition then
            local off=autoOffset and getAutoOffset(char) or GROUND_OFFSET
            bodyPosition.Position=Vector3.new(root.Position.X,hit.Position.Y+off,root.Position.Z)
        end
    end
    local function disableNoclip()
        noclipEnabled=false; if noclipConn then noclipConn:Disconnect(); noclipConn=nil end
        if bodyPosition then bodyPosition:Destroy(); bodyPosition=nil end
        local char=player.Character; if char then setCollisions(char,true); local h=char:FindFirstChildOfClass("Humanoid"); if h then h.PlatformStand=false end end
    end
    local function enableNoclip()
        disableNoclip(); noclipEnabled=true
        local char=player.Character; if not char then return end
        local h=char:FindFirstChildOfClass("Humanoid"); if h then h.PlatformStand=false end
        setCollisions(char,false); bodyPosition=setupBP(char)
        noclipConn=RunService.Stepped:Connect(function() if not noclipEnabled then return end; noclipLoop() end)
    end
    player.CharacterAdded:Connect(function() if noclipEnabled then task.wait(0.5); enableNoclip() end end)

    NoclipSection:Toggle({ Title="Enable Noclip", Desc="Pass through walls and obstacles while staying grounded", Value=false, Callback=function(state) if state then enableNoclip(); WindUI:Notify({ Title="Noclip", Content="Noclip enabled", Icon="ghost", Duration=3 }) else disableNoclip(); WindUI:Notify({ Title="Noclip", Content="Collisions restored", Icon="box", Duration=2 }) end end })
    SettingsSection:Toggle({ Title="Auto Ground Offset", Desc="Auto-detects correct floor height based on your character rig", Value=true, Callback=function(state) autoOffset=state end })
    SettingsSection:Slider({ Title="Manual Ground Offset", Desc="Floor offset used when Auto Ground is disabled", Step=1, Value={Min=1,Max=15,Default=3}, Callback=function(v) GROUND_OFFSET=v end })
    SettingsSection:Slider({ Title="Ray Length", Desc="Downward scan distance to detect the floor", Step=5, Value={Min=20,Max=500,Default=100}, Callback=function(v) RAY_LENGTH=v end })
    SettingsSection:Slider({ Title="Vertical Hold Force", Desc="Force keeping you pinned at floor level", Step=100000, Value={Min=100000,Max=5000000,Default=1000000}, Callback=function(v) VERTICAL_FORCE=v; if bodyPosition then bodyPosition.MaxForce=Vector3.new(0,VERTICAL_FORCE,0) end end })
end

-- ============================================================
--  TELEPORT
-- ============================================================
do
    local TpSection=TeleportTab:Section({ Title="Click to Teleport" }); local SavedSection=TeleportTab:Section({ Title="Saved Positions" })
    local TP_STEPS=20; local TP_STEP_WAIT=0.01; local isTeleporting=false; local clickTpEnabled=false; local clickConn; local savedPositions={}

    local function smoothTeleport(targetCF)
        if isTeleporting then WindUI:Notify({ Title="Teleport", Content="Already teleporting, please wait", Icon="loader", Duration=2 }); return end
        isTeleporting=true
        local char=player.Character; if not char then isTeleporting=false; return end
        local root=char:FindFirstChild("HumanoidRootPart"); if not root then isTeleporting=false; return end
        local startCF=root.CFrame; local hum=char:FindFirstChildOfClass("Humanoid"); local oldAR=hum and hum.AutoRotate
        if hum then hum.AutoRotate=false end
        for i=1,TP_STEPS do if not root or not root.Parent then break end; root.CFrame=startCF:Lerp(targetCF,1-(1-i/TP_STEPS)^3); task.wait(TP_STEP_WAIT) end
        if root and root.Parent then root.CFrame=targetCF end; if hum then hum.AutoRotate=oldAR end; isTeleporting=false
    end
    local function enableClickTp()
        if clickConn then clickConn:Disconnect() end
        clickConn=UserInputService.InputBegan:Connect(function(input,gpe)
            if gpe or not clickTpEnabled then return end
            if input.UserInputType~=Enum.UserInputType.MouseButton1 then return end
            local char=player.Character; if not char then return end
            local root=char:FindFirstChild("HumanoidRootPart"); if not root then return end
            local cam=workspace.CurrentCamera; local mp=UserInputService:GetMouseLocation()
            local ray=cam:ScreenPointToRay(mp.X,mp.Y)
            local rp=RaycastParams.new(); rp.FilterType=Enum.RaycastFilterType.Blacklist; rp.FilterDescendantsInstances={char}
            local hit=workspace:Raycast(ray.Origin,ray.Direction*2000,rp)
            if hit then
                local hum=char:FindFirstChildOfClass("Humanoid"); local hipH=(hum and hum.HipHeight or 2)+1
                local tCF=CFrame.new(hit.Position+Vector3.new(0,hipH,0))*(root.CFrame-root.CFrame.Position); smoothTeleport(tCF)
            else WindUI:Notify({ Title="Teleport", Content="No surface found", Icon="map-x", Duration=2 }) end
        end)
    end
    local function disableClickTp() if clickConn then clickConn:Disconnect(); clickConn=nil end end

    TpSection:Toggle({ Title="Click to Teleport", Desc="Left-click anywhere to smoothly dash to that location", Value=false, Callback=function(state) clickTpEnabled=state; if state then enableClickTp(); WindUI:Notify({ Title="Teleport", Content="Click anywhere to teleport", Icon="map-pin", Duration=3 }) else disableClickTp(); WindUI:Notify({ Title="Teleport", Content="Click teleport off", Icon="map-pin-off", Duration=2 }) end end })
    TpSection:Slider({ Title="Teleport Steps", Desc="Higher = smoother animation, lower = snappier", Step=1, Value={Min=5,Max=60,Default=20}, Callback=function(v) TP_STEPS=v end })
    TpSection:Slider({ Title="Step Delay (ms)", Desc="Time between each interpolation step", Step=1, Value={Min=1,Max=50,Default=10}, Callback=function(v) TP_STEP_WAIT=v/1000 end })
    TpSection:Button({ Title="Save Current Position", Desc="Saves your current standing position (max 5 slots)", Icon="bookmark", Callback=function()
        local char=player.Character; if not char then return end; local root=char:FindFirstChild("HumanoidRootPart"); if not root then return end
        if #savedPositions>=5 then WindUI:Notify({ Title="Slots Full", Content="All 5 slots are used. Restart to clear.", Icon="alert-circle", Duration=3 }); return end
        local name="Pos "..(#savedPositions+1); table.insert(savedPositions,{name=name,cframe=root.CFrame}); WindUI:Notify({ Title="Position Saved", Content=name.." saved!", Icon="bookmark-check", Duration=3 })
    end })
    for i=1,5 do
        SavedSection:Button({ Title="Teleport to Pos "..i, Desc="Dash to saved position "..i, Icon="map-pin", Callback=function()
            local e=savedPositions[i]; if not e then WindUI:Notify({ Title="Empty Slot", Content="Slot "..i.." has no saved position", Icon="alert-circle", Duration=3 }); return end
            WindUI:Notify({ Title="Teleporting", Content="Dashing to "..e.name, Icon="map-pin", Duration=2 }); smoothTeleport(e.cframe)
        end })
    end
end

-- ============================================================
--  TROLLING – Proximity Fling
-- ============================================================
do
    local TrollingSection=TrollingTab:Section({ Title="Fling" })
    local flingEnabled=false; local flingConn=nil; local flingCooldowns={}; local activeFlings={}; local flingWarningAcknowledged=false
    local FLING_RANGE=4; local FLING_HEIGHT=120; local FLING_STEPS=12; local FLING_COOLDOWN=3

    local function getRoot(char) return char and char:FindFirstChild("HumanoidRootPart") end
    local function flingTarget(target)
        if activeFlings[target.UserId] then return end
        local myChar=player.Character; local myRoot=getRoot(myChar); if not myRoot then return end
        local targetChar=target.Character; local targetRoot=getRoot(targetChar); if not targetRoot then return end
        local dir=targetRoot.Position-myRoot.Position; dir=Vector3.new(dir.X,0,dir.Z)
        if dir.Magnitude<0.01 then dir=myRoot.CFrame.LookVector end; dir=dir.Unit
        activeFlings[target.UserId]=true
        task.spawn(function()
            local startPos=targetRoot.Position
            for i=1,FLING_STEPS do
                if not targetRoot or not targetRoot.Parent then break end; if not flingEnabled then break end
                local t=i/FLING_STEPS; local height=math.sin(t*math.pi)*FLING_HEIGHT; local forward=dir*(t*20)
                local newPos=startPos+forward+Vector3.new(0,height,0); local currentCF=targetRoot.CFrame
                targetRoot.CFrame=CFrame.new(newPos)*(currentCF-currentCF.Position); task.wait(0.02)
            end; activeFlings[target.UserId]=nil
        end)
        WindUI:Notify({ Title="Fling", Content=target.Name.." was flung!", Icon="zap", Duration=2 })
    end
    local function startFlingDetection()
        if flingConn then flingConn:Disconnect(); flingConn=nil end
        flingConn=RunService.Heartbeat:Connect(function()
            if not flingEnabled then return end
            local myChar=player.Character; local myRoot=getRoot(myChar); if not myRoot then return end
            local now=tick()
            for _,target in ipairs(Players:GetPlayers()) do
                if target==player then continue end
                local tChar=target.Character; local tRoot=getRoot(tChar); if not tRoot then continue end
                local dist=(myRoot.Position-tRoot.Position).Magnitude
                if dist<=FLING_RANGE then
                    local last=flingCooldowns[target.UserId]
                    if not last or (now-last)>=FLING_COOLDOWN then flingCooldowns[target.UserId]=now; flingTarget(target) end
                end
            end
        end)
    end
    local function stopFlingDetection() flingEnabled=false; if flingConn then flingConn:Disconnect(); flingConn=nil end; flingCooldowns={}; activeFlings={} end

    local flingToggleRef=nil
    flingToggleRef=TrollingSection:Toggle({
        Title="Proximity Fling", Desc="Walk into a player to fling them via CFrame arc.", Value=false,
        Callback=function(state)
            if state then
                if not flingWarningAcknowledged then
                    if flingToggleRef then pcall(function() flingToggleRef:Set(false) end) end; flingWarningAcknowledged=true
                    WindUI:Popup({ Title="⚠️ Fling Warning", Icon="alert-triangle", Content="Proximity Fling affects other players and may violate game rules, resulting in a kick or ban. Use responsibly and at your own risk.",
                        Buttons={
                            { Title="Cancel", Variant="Tertiary", Callback=function() flingWarningAcknowledged=false; flingEnabled=false; WindUI:Notify({ Title="Fling", Content="Fling cancelled.", Icon="x-circle", Duration=2 }) end },
                            { Title="I Understand", Icon="check", Variant="Primary", Callback=function() flingEnabled=true; if flingToggleRef then pcall(function() flingToggleRef:Set(true) end) end; startFlingDetection(); WindUI:Notify({ Title="Fling", Content="Walk into players to fling them!", Icon="zap", Duration=3 }) end },
                        },
                    })
                else flingEnabled=true; startFlingDetection(); WindUI:Notify({ Title="Fling", Content="Walk into players to fling them!", Icon="zap", Duration=3 }) end
            else stopFlingDetection(); WindUI:Notify({ Title="Fling", Content="Fling disabled.", Icon="zap-off", Duration=2 }) end
        end,
    })
    TrollingSection:Slider({ Title="Fling Range", Desc="How close (studs) you need to be to trigger a fling", Step=1, Value={Min=2,Max=10,Default=4}, Callback=function(v) FLING_RANGE=v end })
    TrollingSection:Slider({ Title="Fling Height", Desc="How high the target arcs upward", Step=5, Value={Min=20,Max=300,Default=120}, Callback=function(v) FLING_HEIGHT=v end })
    TrollingSection:Slider({ Title="Cooldown (s)", Desc="Seconds before the same player can be flung again", Step=1, Value={Min=1,Max=15,Default=3}, Callback=function(v) FLING_COOLDOWN=v end })
end

-- ============================================================
--  MISC – Moderation Watcher (PREMIUM)
-- ============================================================
do
    local WatchSection=MiscTab:Section({ Title="Moderation Watcher" }); local watcherEnabled=false; local watcherThread=nil; local joinConn=nil
    modWatchToggle=WatchSection:Toggle({
        Title="👑 Mod Watcher", Desc="Scans the group's staff roles and alerts you whenever a moderator or admin joins the server.",
        Value=false, Locked=true, LockedTitle="Upgrade to Premium at pandauth.com to access Mod Watcher.",
        Callback=function(state)
            if not isPremium then WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com to unlock this.", Icon="crown", Duration=5 }); return end
            if state then
                local GROUP_ID=2935212; local STAFF_RANK_NAMES={"game moderation","administration"}; local SCAN_INTERVAL=0.6; local modUserIds={}; local modUserIdSet={}
                local function fetchRoleMembers(roleId)
                    local ids={}; local cursor=""
                    repeat
                        local url=("https://groups.roblox.com/v1/groups/%d/roles/%d/users?limit=100&sortOrder=Asc"):format(GROUP_ID,roleId)
                        if cursor~="" then url=url.."&cursor="..cursor end
                        local ok,res=pcall(function() return HttpService:JSONDecode(game:HttpGet(url)) end)
                        if not ok or not res or not res.data then break end
                        for _,member in ipairs(res.data) do table.insert(ids,member.userId) end; cursor=res.nextPageCursor or ""
                    until cursor==""; return ids
                end
                local function fetchStaffRoleIds()
                    local url=("https://groups.roblox.com/v1/groups/%d/roles"):format(GROUP_ID)
                    local ok,res=pcall(function() return HttpService:JSONDecode(game:HttpGet(url)) end)
                    if not ok or not res or not res.roles then return {} end
                    local ids={}
                    for _,role in ipairs(res.roles) do
                        local lname=role.name:lower()
                        for _,keyword in ipairs(STAFF_RANK_NAMES) do if lname:find(keyword,1,true) then table.insert(ids,role.id); break end end
                    end; return ids
                end
                local function buildModList()
                    modUserIds={}; modUserIdSet={}
                    WindUI:Notify({ Title="Mod Watcher", Content="Fetching staff list from group...", Icon="loader", Duration=3 })
                    for _,rid in ipairs(fetchStaffRoleIds()) do for _,uid in ipairs(fetchRoleMembers(rid)) do if not modUserIdSet[uid] then modUserIdSet[uid]=true; table.insert(modUserIds,uid) end end end
                    return #modUserIds
                end
                local function checkPlayer(p) if not watcherEnabled then return end; if modUserIdSet[p.UserId] then WindUI:Notify({ Title="⚠️ Moderator Detected", Content=p.Name.." (ID: "..p.UserId..") is in the server!", Icon="shield-alert", Duration=8 }) end end
                local count=buildModList()
                if count==0 then WindUI:Notify({ Title="Mod Watcher", Content="No staff members found in the group.", Icon="alert-circle", Duration=5 }); return end
                watcherEnabled=true; WindUI:Notify({ Title="Mod Watcher Active", Content="Tracking "..count.." staff members.", Icon="shield", Duration=4 })
                for _,p in ipairs(Players:GetPlayers()) do checkPlayer(p) end
                watcherThread=task.spawn(function() while watcherEnabled do for _,p in ipairs(Players:GetPlayers()) do checkPlayer(p) end; task.wait(SCAN_INTERVAL) end end)
                joinConn=Players.PlayerAdded:Connect(checkPlayer)
            else watcherEnabled=false; if joinConn then joinConn:Disconnect(); joinConn=nil end; watcherThread=nil; WindUI:Notify({ Title="Mod Watcher Off", Content="Staff monitoring stopped.", Icon="shield-off", Duration=3 }) end
        end,
    })
end

-- ============================================================
--  MISC – Anti-Fling (PREMIUM)
-- ============================================================
do
    local AntiFlingSection=MiscTab:Section({ Title="Anti-Fling" }); local antiFlingEnabled=false; local antiFlingConn=nil
    local antiFlingWarningAcknowledged=false; local antiFlingToggleRef=nil
    local SPIKE_THRESHOLD=80; local RUBBER_STRENGTH=0.25; local RECOVER_TICKS=20
    local safePosition=nil; local recoverCounter=0

    local function getRoot() local c=player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function getHum()  local c=player.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    local function disableAntiFling() antiFlingEnabled=false; if antiFlingConn then antiFlingConn:Disconnect(); antiFlingConn=nil end; safePosition=nil; recoverCounter=0 end
    local function enableAntiFling()
        disableAntiFling(); antiFlingEnabled=true; safePosition=nil; recoverCounter=0
        antiFlingConn=RunService.Stepped:Connect(function()
            if not antiFlingEnabled then return end
            local root=getRoot(); local hum=getHum(); if not root or not hum then return end
            local vel=root.AssemblyLinearVelocity; local horizMag=Vector3.new(vel.X,0,vel.Z).Magnitude
            local isGrounded=hum.FloorMaterial~=Enum.Material.Air
            if isGrounded and horizMag<SPIKE_THRESHOLD then safePosition=root.CFrame end
            if horizMag>SPIKE_THRESHOLD then recoverCounter=RECOVER_TICKS end
            if recoverCounter>0 and safePosition then
                recoverCounter-=1; root.AssemblyLinearVelocity=Vector3.new(0,math.min(vel.Y,0),0)
                local alpha=RUBBER_STRENGTH*(recoverCounter/RECOVER_TICKS+0.5)
                root.CFrame=root.CFrame:Lerp(safePosition,math.clamp(alpha,0.1,0.6))
            end
            if root.AssemblyAngularVelocity.Magnitude>0.3 then root.AssemblyAngularVelocity=Vector3.zero end
        end)
    end

    player.CharacterAdded:Connect(function() safePosition=nil; recoverCounter=0; if antiFlingEnabled then task.wait(0.5); enableAntiFling() end end)

    antiFlingToggle=AntiFlingSection:Toggle({
        Title="👑 Anti-Fling", Desc="Detects velocity spikes and rubber-bands you back to your last safe position.",
        Value=false, Locked=true, LockedTitle="Upgrade to Premium at pandauth.com to access Anti-Fling.",
        Callback=function(state)
            if not isPremium then WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 }); return end
            if state then
                if not antiFlingWarningAcknowledged then
                    if antiFlingToggleRef then pcall(function() antiFlingToggleRef:Set(false) end) end; antiFlingWarningAcknowledged=true
                    WindUI:Popup({ Title="⚠️ Anti-Fling Warning", Icon="alert-triangle", Content="Anti-Fling modifies your character's velocity and CFrame each physics step to snap you back when flung. May conflict with certain game mechanics.",
                        Buttons={
                            { Title="Cancel", Variant="Tertiary", Callback=function() antiFlingWarningAcknowledged=false; antiFlingEnabled=false; WindUI:Notify({ Title="Anti-Fling", Content="Cancelled.", Icon="x-circle", Duration=2 }) end },
                            { Title="I Understand", Icon="check", Variant="Primary", Callback=function() if antiFlingToggleRef then pcall(function() antiFlingToggleRef:Set(true) end) end; enableAntiFling(); WindUI:Notify({ Title="Anti-Fling", Content="Fling protection active.", Icon="shield", Duration=3 }) end },
                        },
                    })
                else enableAntiFling(); WindUI:Notify({ Title="Anti-Fling", Content="Fling protection active.", Icon="shield", Duration=3 }) end
            else disableAntiFling(); WindUI:Notify({ Title="Anti-Fling", Content="Fling protection disabled.", Icon="shield-off", Duration=2 }) end
        end,
    })
    antiFlingToggleRef=antiFlingToggle
end

Window:SelectTab(1)
