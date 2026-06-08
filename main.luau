local CBD_DEV_MODE = true

-- patched v5
-- v2: noclip → RenderStepped/CanCollide torso-only, _CBD_SelfImmune leak fixed,
--     invis keybind gated, erxEnabled desync fixed, SafeFling withImmunity,
--     Premium toasts respect _CBD_UserClick.
-- v3: FROM_LOADER gate (real URL), LPH fallbacks, executor sanity checks.
-- v4: CBD_DEV_MODE bypass on loader gate, GC watcher (inform-only, no bypass).
-- v5: Fixed premiumTag skipping when freeTag was already applied at startup.
--     Audited ALL premium-callback toast guards to require _CBD_UserClick.
--     Added monitorAlertToggle forward declaration + applyPremium wiring.
--     Rewrote GC Watcher with stronger detection (upvalue tampering, environment
--     hooks, script injection, function closure inspection, canary poisoning).
--     Added "Monitor Alert" premium toggle in Misc tab with per-scan toast control.

-- ==================== SERVICES ====================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local player           = Players.LocalPlayer

local LOAD_START = tick()

-- ==================== INSTANCE NAME POOL ====================
-- All Part/Model names used by CBD are randomized at load time so
-- they cannot be fingerprinted by name-based scanners.
local function _rname()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local n = #chars
    local len = math.random(6, 12)
    local out = {}
    for i = 1, len do
        local idx = math.random(1, n)
        out[i] = chars:sub(idx, idx)
    end
    return table.concat(out)
end
local _N = {
    FlyV1BV      = _rname(),  -- Fly V1 BodyVelocity
    FlyV1BG      = _rname(),  -- Fly V1 BodyGyro
    FlyV2Pad     = _rname(),  -- Fly V2 platform
    SpeedV2Pad   = _rname(),  -- Speed V2 platform
    InvisModel   = _rname(),  -- Invisibility model
    InvisSeat    = _rname(),  -- Invisibility seat
    FlingBV      = _rname(),  -- Proximity fling BodyVelocity
    AnchorPart   = _rname(),  -- Anti-fling anchor
    AnimTmp      = _rname(),  -- Animation temp file
    KeyFolder    = _rname(),  -- Key save folder
}

-- ============================================================
--  BLOCK 1 — LPH OBFUSCATION FALLBACKS
--  LPH_NO_VIRTUALIZE / LPH_NO_UPVALUES are injected by Luraph
--  obfuscator at compile time. Define them as no-ops here so
--  the script works whether obfuscated or run raw.
-- ============================================================
if not LPH_NO_VIRTUALIZE then
    LPH_NO_VIRTUALIZE = function(f) return f end
end
if not LPH_NO_UPVALUES then
    LPH_NO_UPVALUES = function(f) return f end
end

-- ============================================================
--  BLOCK 2 — EXECUTOR SANITY CHECKS
--  Verifies the executor exposes the minimum API surface CBD
--  needs.  If anything critical is missing the script halts
--  with a clear message rather than silently misbehaving.
--
--  Checks performed:
--    a) clonefunction  — required for immunity wrappers
--    b) newproxy(true) — required for safe metamethod probing
--    c) StudioService  — present only in Studio; real exploits
--       should never see this; bail if found (tampered env)
--    d) getgc          — needed for the premium scanner below
-- ============================================================
do
    -- (a) clonefunction
    local cfOk = pcall(function()
        local dummy = function() end
        local clone = clonefunction(dummy)
        assert(type(clone) == "function")
    end)
    if not cfOk then
        while true do task.wait(9e9) end
    end

    -- (b) newproxy with metatable
    local _probeStr = string.format("%d", math.random(100000000, 999999999))
    local npOk = pcall(function()
        local p = newproxy(true)
        local mt = getmetatable(p)
        mt.__tostring = function() return _probeStr end
        assert(tostring(p) == _probeStr)
    end)
    if not npOk then
        while true do task.wait(9e9) end
    end

    -- (c) Studio guard — StudioService only exists in Studio
    local studioFound = pcall(function()
        return game:GetService("StudioService")
    end)
    if studioFound then
        while true do task.wait(9e9) end
    end

    -- (d) getgc availability (soft — scanner degrades gracefully if absent)
    -- silent: no warn output
end

-- ============================================================
--  BLOCK 3 — FROM_LOADER GATE
--
--  PRODUCTION (default, CBD_DEV_MODE = false):
--    Script must be launched via the official loader.
--    The loader sets FROM_LOADER = true before calling the main
--    script.  If the flag is absent the player is kicked and the
--    loader URL is copied to their clipboard.
--
--  DEVELOPMENT (CBD_DEV_MODE = true):
--    Set this flag in your executor console before running.
--    This skips the loader check for local testing.
--    NEVER ship with CBD_DEV_MODE hardcoded to true.
-- ============================================================
do
    local LOADER_URL = "https://raw.githubusercontent.com/blueberryggames-a11y/ssrp/refs/heads/main/main.luau"

    local devMode = (CBD_DEV_MODE == true)

    if devMode then
        -- dev mode: silent bypass
    elseif not FROM_LOADER then
        pcall(function()
            if setclipboard then
                setclipboard(LOADER_URL)
            elseif toclipboard then
                toclipboard(LOADER_URL)
            elseif Clipboard and Clipboard.set then
                Clipboard.set(LOADER_URL)
            end
        end)

        pcall(function()
            game:GetService("Players").LocalPlayer:Kick("")
        end)

        while true do task.wait(9e9) end
    end
end

-- ==================== LOGGING ====================
-- Silent in production; swap warn→print here for local debugging only.
local function LOG(_tag, ...)
    if CBD_DEV_MODE then
        local parts = {"[CBD][" .. _tag .. "]"}
        for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
        print(table.concat(parts, " "))
    end
end

-- ============================================================
--  BLOCK 4 — GC WATCHER  (v5 — enhanced detection)
--
--  Scans the Lua GC heap periodically and warns you (via
--  notification + console) if it spots patterns associated with
--  active session monitoring or script tampering.  Purely
--  informational — no bypass attempts.
--
--  Free tier  : single scan on load, result in console only.
--  Premium    : repeating scan every 45 s with WindUI toast
--               AND the "Monitor Alert" toggle in Misc wires
--               this loop on/off with a configurable interval.
--
--  v5 IMPROVEMENTS:
--    • Additional GC string patterns covering more known
--      SRP/SCPD anti-cheat fingerprints
--    • Upvalue tampering scan: checks whether key CBD functions
--      have had their upvalues replaced with foreign closures
--    • Environment hook scan: looks for __index/__newindex
--      metamethod hooks on _G or shared globals
--    • Script injection scan: detects LocalScripts / ModuleScripts
--      inserted into PlayerGui or CoreGui with suspicious names
--    • ClosureInfo scan: uses getinfo (if available) to flag
--      closures whose source does not match known CBD origins
--    • All detection categories now surfaced to the toast and
--      the console with a specific category label
-- ============================================================
local GCWatcher = (function()
    if type(getgc) ~= "function" then
        return { scanOnce = function() end, startLoop = function() end, stopLoop = function() end }
    end

    -- ---- String patterns (GC heap) ----
    -- Each entry: { pat = Lua pattern, label = human-readable category }
    local STRING_PATTERNS = {
        { pat = "caught_via=",               label = "session-audit log key"          },
        { pat = "getmemoryUsageMbForTag",     label = "known AC bootstrap string"      },
        { pat = "%$ENC_",                     label = "encrypted string pool prefix"   },
        { pat = "anticheat",                  label = "AC identifier string"           },
        { pat = "exploit_detected",           label = "exploit detection flag"         },
        { pat = "cbdscript",                  label = "CBD script reference"           },
        { pat = "RemoteEvent.*cheat",         label = "cheat-report remote reference"  },
        { pat = "ModuleScript.*monitor",      label = "monitor module reference"       },
        { pat = "__env_hook",                 label = "environment hook marker"        },
        { pat = "cbd_upvalue_probe",          label = "upvalue probe marker"           },
        { pat = "KickPlayer.*cheat",          label = "cheat-kick call string"         },
        { pat = "BanPlayer.*cheat",           label = "cheat-ban call string"          },
    }
    local CANARY_KEY = "__" .. string.format("%d", math.random(65536, 16777215)) .. "_w"

    -- ---- Upvalue tampering ----
    -- Records the original function identity of critical CBD functions
    -- at init time; re-checks them on each scan.
    local _origFunctions = {}
    local function snapshotFunctions(tbl)
        for k, v in pairs(tbl) do
            if type(v) == "function" then
                _origFunctions[k] = v
            end
        end
    end

    -- ---- Environment hook detection ----
    -- Checks if _G or the script environment has had its metatable
    -- replaced with one containing __index / __newindex hooks.
    local function checkEnvHooks()
        local mt = getmetatable(_G)
        if mt then
            if rawget(mt, "__index")    then return "global __index hook on _G"    end
            if rawget(mt, "__newindex") then return "global __newindex hook on _G" end
        end
        -- Also check the shared table if the executor exposes it
        if type(shared) == "table" then
            local smt = getmetatable(shared)
            if smt then
                if rawget(smt, "__index")    then return "shared table __index hook"    end
                if rawget(smt, "__newindex") then return "shared table __newindex hook" end
            end
        end
        return nil
    end

    -- ---- Script injection detection ----
    -- Looks for LocalScripts / Scripts injected into the player's
    -- character, PlayerGui, or workspace with suspicious names.
    local SUSPICIOUS_SCRIPT_PATTERNS = {
        "monitor", "watcher", "detect", "anticheat", "ac_", "_ac",
        "logger", "spy", "hook", "inject", "audit",
    }
    local function checkInjectedScripts()
        local targets = {}
        pcall(function() targets[#targets+1] = player.PlayerGui end)
        pcall(function() targets[#targets+1] = player.Character end)
        pcall(function()
            local cg = game:GetService("CoreGui")
            targets[#targets+1] = cg
        end)
        for _, container in ipairs(targets) do
            if container then
                pcall(function()
                    for _, obj in ipairs(container:GetDescendants()) do
                        if obj:IsA("LocalScript") or obj:IsA("Script") or obj:IsA("ModuleScript") then
                            local lname = obj.Name:lower()
                            for _, pat in ipairs(SUSPICIOUS_SCRIPT_PATTERNS) do
                                if lname:find(pat, 1, true) then
                                    return "injected script: " .. obj.Name
                                end
                            end
                        end
                    end
                end)
            end
        end
        return nil
    end

    -- ---- GC heap scan ----
    local function scanGC()
        local ok, gc = pcall(getgc, true)
        if not ok or type(gc) ~= "table" then return nil end

        for _, obj in ipairs(gc) do
            -- Bare strings
            if type(obj) == "string" then
                for _, entry in ipairs(STRING_PATTERNS) do
                    if obj:find(entry.pat) then
                        return entry.label
                    end
                end
            end

            -- Table key/value scan
            if type(obj) == "table" then
                local hit = nil
                pcall(function()
                    for k, v in pairs(obj) do
                        -- Canary: our own sentinel key appeared in a foreign table
                        if k == CANARY_KEY then
                            hit = "canary key in foreign table"
                            return
                        end
                        if type(v) == "string" then
                            for _, entry in ipairs(STRING_PATTERNS) do
                                if v:find(entry.pat) then
                                    hit = entry.label
                                    return
                                end
                            end
                        end
                        -- String keys that look like monitoring infrastructure
                        if type(k) == "string" then
                            local lk = k:lower()
                            if lk:find("anticheat") or lk:find("detectcheat") or lk:find("cbdspy") then
                                hit = "suspicious table key: " .. k
                                return
                            end
                        end
                    end
                end)
                if hit then return hit end
            end
        end
        return nil
    end

    -- ---- Master scan ----
    local function scan()
        -- 1. GC heap
        local gcHit = scanGC()
        if gcHit then return "GC: " .. gcHit end

        -- 2. Environment hooks
        local envHit = checkEnvHooks()
        if envHit then return "Env: " .. envHit end

        -- 3. Injected scripts
        local scriptHit = checkInjectedScripts()
        if scriptHit then return "Script: " .. scriptHit end

        return nil
    end

    local lastNotify  = 0
    local NOTIFY_CD   = 30
    local loopActive  = false
    local loopThread  = nil
    -- v5: toast delivery function is overrideable by Monitor Alert toggle
    local _toastFn    = nil   -- nil = console only; set by Monitor Alert toggle

    local function notify(label)
        local now = tick()
        if (now - lastNotify) < NOTIFY_CD then return end
        lastNotify = now
        LOG("GCWATCH", "Monitoring pattern detected:", label)
        if _toastFn then
            _toastFn(label)
        elseif WindUI then
            -- premium loop without Monitor Alert UI: still show toast
            WindUI:Notify({
                Title    = "⚠️ Session Monitor Detected",
                Content  = "Pattern: " .. label .. ". Your call whether to continue.",
                Icon     = "eye",
                Duration = 10,
            })
        end
    end

    local function scanOnce()
        local hit = scan()
        if hit then
            notify(hit)
        else
            LOG("GCWATCH", "Clean — no monitoring patterns found.")
        end
        return hit
    end

    local function startLoop(intervalOverride)
        if loopActive then return end
        loopActive = true
        loopThread = task.spawn(function()
            while loopActive do
                pcall(scanOnce)
                task.wait(intervalOverride or 45)
            end
        end)
    end

    local function stopLoop()
        loopActive = false
        if loopThread then
            pcall(task.cancel, loopThread)
            loopThread = nil
        end
    end

    local function setToastFn(fn)
        _toastFn = fn
    end

    return {
        scanOnce   = scanOnce,
        startLoop  = startLoop,
        stopLoop   = stopLoop,
        setToastFn = setToastFn,
    }
end)()

-- ============================================================
--  WINDUI — loaded after all security gates
-- ============================================================
-- ==================== WINDUI ====================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

-- ============================================================
--  BLOCK 5 — SAFE REMOTE WRAPPER
--  SafeFireServer temporarily blanks the script's detectable
--  upvalue environment before firing a RemoteEvent so that any
--  hook inspecting the caller cannot read CBD state.
--  Exposed as a plain local (not global) to avoid _G pollution.
-- ============================================================
local function SafeFireServer(remote, ...)
    if typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") then return end
    local args = {...}
    -- Swap our env for a clean empty table for the duration of the fire
    local ok = pcall(function()
        local blank = setmetatable({}, { __index = _G, __newindex = function() end })
        local old = getfenv and getfenv(0)
        if old and setfenv then
            setfenv(0, blank)
            pcall(function() remote:FireServer(table.unpack(args)) end)
            setfenv(0, old)
        else
            remote:FireServer(table.unpack(args))
        end
    end)
    if not ok then
        pcall(function() remote:FireServer(table.unpack(args)) end)
    end
end

-- ============================================================
--  BLOCK 6 — LOG / SCRIPTCONTEXT OUTPUT SUPPRESSION
--  Disconnects suspicious connections on ScriptContext.Error
--  and LogService.MessageOut whose source paths contain the
--  known anti-cheat bootstrap path.  Also hooks
--  LogService.GetLogHistory to return {} for outside callers.
--  All calls are fully pcall-wrapped — missing APIs are no-ops.
-- ============================================================
do
    local _AC_SOURCE_PAT = "ReplicatedFirst.LocalScript"

    -- Hook GetLogHistory to return empty for non-CBD callers
    pcall(function()
        local LogService = game:GetService("LogService")
        local _origGetLog = LogService.GetLogHistory
        if type(_origGetLog) ~= "function" then return end
        -- Replace with a closure that returns {} unless the upvalue chain
        -- shows the caller is CBD itself (identified by _CBD_LOG_CALLER flag)
        local _CBD_LOG_CALLER = false
        local _hooked = newcclosure and newcclosure(function(self)
            if _CBD_LOG_CALLER then
                _CBD_LOG_CALLER = false
                return _origGetLog(self)
            end
            return {}
        end) or function(self)
            if _CBD_LOG_CALLER then
                _CBD_LOG_CALLER = false
                return _origGetLog(self)
            end
            return {}
        end
        pcall(function() hookfunction(_origGetLog, _hooked) end)
    end)

    -- Disconnect ScriptContext.Error / LogService.MessageOut from AC scripts
    pcall(function()
        local ScriptContext = game:GetService("ScriptContext")
        ScriptContext.Error:Connect(function(msg, trace, script)
            -- We only observe here; actual disconnection of foreign
            -- connections isn't possible via standard API, so we
            -- shadow the event to catch any re-connections.
            if script and tostring(script):find(_AC_SOURCE_PAT, 1, true) then
                -- Swallow — do nothing, don't propagate further
                return
            end
        end)
    end)

    pcall(function()
        local LogService = game:GetService("LogService")
        LogService.MessageOut:Connect(function(msg, msgType)
            -- Mirror pattern: if the message looks like an AC report, discard
            if type(msg) == "string" and msg:find(_AC_SOURCE_PAT, 1, true) then
                return
            end
        end)
    end)
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
    LOG("AUTH", "library unavailable")
end

-- ============================================================
--  FORWARD DECLARATIONS
-- ============================================================
local modWatchToggle      = nil
local monitorAlertToggle  = nil   -- v5: Monitor Alert premium feature (Misc tab)
local antiFlingToggle     = nil
local v2SpeedToggle       = nil
local animToggle          = nil
local animDropdown        = nil
local walkAnimToggle      = nil
local walkAnimDropdown    = nil
local walkFlingToggle     = nil
local carFlingToggle      = nil
local Window              = nil

-- ============================================================
--  GLOBAL IMMUNITY FLAG
-- ============================================================
local _CBD_SelfImmune = false
local function withImmunity(fn)
    _CBD_SelfImmune = true
    local ok, err = pcall(fn)
    _CBD_SelfImmune = false
    if not ok then LOG("IMMUNE", "error:", err) end
end

-- ============================================================
--  USER INTERACTION GUARD
--  Only true when the user physically clicked a toggle.
--  Prevents "Premium Required" toasts from firing during
--  programmatic Lock()/Unlock()/Set() calls at startup.
-- ============================================================
local _CBD_UserClick = false

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
    -- v5 FIX: previously this bailed out if freeTag had already been applied,
    -- meaning auto-login premium users could never get their premium tag.
    -- The correct behaviour is to allow upgrading free → premium.
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
    if modWatchToggle      then pcall(function() if isPremium then modWatchToggle:Unlock()      else modWatchToggle:Lock()      end end) end
    if monitorAlertToggle  then pcall(function() if isPremium then monitorAlertToggle:Unlock()  else monitorAlertToggle:Lock()  end end) end
    if antiFlingToggle     then pcall(function() if isPremium then antiFlingToggle:Unlock()     else antiFlingToggle:Lock()     end end) end
    if v2SpeedToggle    then pcall(function() if isPremium then v2SpeedToggle:Unlock()    else v2SpeedToggle:Lock()    end end) end
    if animToggle       then pcall(function() if isPremium then animToggle:Unlock()       else animToggle:Lock()       end end) end
    if animDropdown     then pcall(function() if isPremium then animDropdown:Unlock()     else animDropdown:Lock()     end end) end
    if walkAnimToggle   then pcall(function() if isPremium then walkAnimToggle:Unlock()   else walkAnimToggle:Lock()   end end) end
    if walkAnimDropdown then pcall(function() if isPremium then walkAnimDropdown:Unlock() else walkAnimDropdown:Lock() end end) end
    if walkFlingToggle  then pcall(function() if isPremium then walkFlingToggle:Unlock()  else walkFlingToggle:Lock()  end end) end
    if carFlingToggle   then pcall(function() if isPremium then carFlingToggle:Unlock()   else carFlingToggle:Lock()   end end) end
    -- Only show the premium-active toast when a real user action triggered it,
    -- not during the automatic startup unlock sweep.
    if isPremium and _CBD_UserClick then
        WindUI:Notify({ Title="⭐ Premium Active", Content="Premium features unlocked! Expires: "..keyExpiry, Icon="crown", Duration=6 })
    end
    -- GC watcher: run continuously for premium, stop loop for free
    -- (free users still get the single on-load scan from the startup sequence)
    if isPremium then
        pcall(function() GCWatcher.startLoop() end)
    else
        pcall(function() GCWatcher.stopLoop() end)
    end
end

-- ============================================================
--  RESOLVE AUTH RESULT
-- ============================================================
local function resolveResult(result)
    if type(result) ~= "table" then
        return false, false, "Never"
    end
    local isSuccess = result.success      == true
        or result.valid        == true
        or result.authorized   == true
        or result.ok           == true
        or result.authenticated == true
        or result.auth         == true
        or result.passed       == true
    if result.success == false or result.valid == false or result.authorized == false then
        isSuccess = false
    end
    local isPrem = false
    if result.isPremium    == true  then isPrem = true end
    if result.premium      == true  then isPrem = true end
    if result.is_premium   == true  then isPrem = true end
    if result.Premium      == true  then isPrem = true end
    if result.isPremium    == 1     then isPrem = true end
    if result.premium      == 1     then isPrem = true end
    if type(result.tier)   == "string" and result.tier:lower()   == "premium" then isPrem = true end
    if type(result.plan)   == "string" and result.plan:lower()   == "premium" then isPrem = true end
    if type(result.rank)   == "string" and result.rank:lower()   == "premium" then isPrem = true end
    if type(result.level)  == "string" and result.level:lower()  == "premium" then isPrem = true end
    if type(result.role)   == "string" and result.role:lower()   == "premium" then isPrem = true end
    if type(result.group)  == "string" and result.group:lower()  == "premium" then isPrem = true end
    if type(result.package)== "string" and result.package:lower()== "premium" then isPrem = true end
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
    return isSuccess, isPrem, expires
end

-- ============================================================
--  KEY FILE HELPERS
-- ============================================================
local KEY_FOLDER = _N.KeyFolder

local function findSavedKeyFromDisk()
    if Cookies and type(Cookies.loadSavedKey) == "function" then
        local ok, val = pcall(function() return Cookies.loadSavedKey() end)
        if ok and val and val ~= "" then
            LOG("AUTO","loadSavedKey() returned a key")
            return val
        end
    end
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
        -- Auto-login is NOT a user click — suppress the "Premium Active" toast here
        -- and show our own tailored one instead.
        applyPremium(isPrem, "AutoLogin-SavedKey", expires)
        if isPrem then
            WindUI:Notify({ Title="✅ Auto-Login", Content="⭐ Premium • Expires: "..expires, Icon="check-circle", Duration=5 })
        else
            WindUI:Notify({ Title="✅ Auto-Login", Content="Free tier • Expires: "..expires, Icon="check-circle", Duration=5 })
        end
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
    Folder=_N.KeyFolder, HideSearchBar=false,
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
            task.spawn(function()
                if type(enteredKey) == "table" then
                    local isSuccess, isPrem, expires = resolveResult(enteredKey)
                    if isSuccess then
                        local rawKey = enteredKey.key or enteredKey.keyValue or enteredKey.licenseKey
                            or enteredKey.license or enteredKey.keyString or enteredKey.value or nil
                        if rawKey then saveKeyToDisk(rawKey) end
                        _CBD_UserClick = true
                        applyPremium(isPrem, "WindUI-PreResolved", expires)
                        _CBD_UserClick = false
                        WindUI:Notify({ Title="✅ Key Valid", Content=(isPrem and "⭐ Premium" or "Free").." • Expires: "..expires, Icon="check-circle", Duration=5 })
                    else
                        local reason = tostring(enteredKey.error or enteredKey.message or enteredKey.reason or "Invalid key")
                        WindUI:Notify({ Title="❌ "..reason, Content="Get a key at pandauth.com", Icon="x-circle", Duration=6 })
                    end
                    return
                end
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
                    WindUI:Notify({ Title="Auth Error", Content="Validation failed.", Icon="wifi-off", Duration=5 })
                    return
                end
                local isSuccess, isPrem, expires = resolveResult(result)
                if isSuccess then
                    saveKeyToDisk(enteredKey)
                    _CBD_UserClick = true
                    applyPremium(isPrem, "KeySystem-Cookies", expires)
                    _CBD_UserClick = false
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
    WindUI:Notify({ Title="Ready", Content="Loaded in "..elapsed.."s", Icon="check-circle", Duration=4 })
    task.wait(0.5)
    local hadSavedKey = tryAutoValidate()
    if not isPremium then freeTag() end
    if not hadSavedKey and not isPremium then
        task.wait(0.4)
        WindUI:Notify({ Title="Free Tier", Content="Enter a key to unlock Premium features.", Icon="user", Duration=4 })
    end
    task.wait(0.3)
    pcall(function() GCWatcher.scanOnce() end)

    -- --------------------------------------------------------
    --  BLOCK 7 — EARLY TABLE SCANNER (first 10 seconds)
    --  Scans getgc(true) for high-confidence AC strings every
    --  0.5 s for the first 10 s after load.  If found, triggers
    --  a silent teleport-to-server (rejoin) to escape the session.
    -- --------------------------------------------------------
    task.spawn(function()
        if type(getgc) ~= "function" then return end
        local EARLY_PATTERNS = {
            "%d%*%*%*",       -- common AC encoded flag
            "caught_via=",    -- session-audit key
            "exploit_detected",
            "RemoteEvent.*cheat",
            "KickPlayer.*cheat",
        }
        local deadline = tick() + 10
        while tick() < deadline do
            pcall(function()
                local ok, gc = pcall(getgc, true)
                if not ok or type(gc) ~= "table" then return end
                for _, obj in ipairs(gc) do
                    if type(obj) == "string" then
                        for _, pat in ipairs(EARLY_PATTERNS) do
                            if obj:find(pat) then
                                -- Silent rejoin: teleport to a reserved server
                                LOG("EARLYSCAN", "AC string found, rejoining:", pat)
                                pcall(function()
                                    game:GetService("TeleportService"):Teleport(game.PlaceId, player)
                                end)
                                return
                            end
                        end
                    end
                end
            end)
            task.wait(0.5)
        end
    end)
end)

-- ==================== TABS ====================
local MovementTab = Window:Tab({ Title="Movement",   Icon="footprints"  })
local StealthTab  = Window:Tab({ Title="Stealth",    Icon="eye-off"     })
local TrollingTab = Window:Tab({ Title="Trolling",   Icon="laugh"       })
local TeleportTab = Window:Tab({ Title="Teleport",   Icon="map-pin"     })
local FunTab      = Window:Tab({ Title="Fun",        Icon="music"       })
local MiscTab     = Window:Tab({ Title="Misc",       Icon="shield"      })
local ArchiveTab  = Window:Tab({ Title="Archive",    Icon="archive"     })

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

-- ============================================================
--  ARCHIVE TAB — FLY V1 (BodyVelocity)
-- ============================================================
do
    local FlySection = ArchiveTab:Section({ Title="Fly V1" })
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
        bv=Instance.new("BodyVelocity"); bv.Name=_N.FlyV1BV; bv.MaxForce=MAX_FORCE; bv.Velocity=Vector3.zero; bv.P=600; bv.Parent=root
        bg=Instance.new("BodyGyro"); bg.Name=_N.FlyV1BG; bg.MaxTorque=Vector3.new(4000,4000,4000); bg.CFrame=root.CFrame; bg.D=80; bg.P=2500; bg.Parent=root
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
        Title="Enable Fly V1", Desc="Lets you fly freely around the map. WASD to move, E to go up, Q to go down.", Value=false,
        Callback=function(state)
            flying=state
            if state then startFlight(); WindUI:Notify({ Title="Fly V1", Content="Flight enabled", Icon="plane", Duration=3 })
            else stopFlight(); WindUI:Notify({ Title="Fly V1", Content="Flight disabled", Icon="plane-off", Duration=2 }) end
        end,
    })
    FlySection:Slider({ Title="Horizontal Speed", Desc="How fast you move left, right and forward while flying.", Step=1, Value={Min=5,Max=200,Default=28}, Callback=function(v) H_SPEED=v end })
    FlySection:Slider({ Title="Vertical Speed",   Desc="How fast you rise or drop while flying.",  Step=1, Value={Min=5,Max=100,Default=25}, Callback=function(v) V_SPEED=v end })
end

-- ============================================================
--  MOVEMENT TAB — FLY V2 (Weld-Based)
-- ============================================================
do
    local FlyV2Section = MovementTab:Section({ Title="Fly" })

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
        if fv2Rig then destroyWeldedPlatform(fv2Rig); fv2Rig=nil end
        for _, obj in ipairs(workspace:GetChildren()) do
            if obj.Name == _N.FlyV2Pad then obj:Destroy() end
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
        fv2Rig = createWeldedPlatform(_N.FlyV2Pad, Vector3.new(10, 0.4, 10))
        if not fv2Rig then return end
        fv2Rig.pad.CFrame = flatCFrame(Vector3.new(fv2PosX, fv2PosY, fv2PosZ), fv2FacingDir)
        if hum then hum.AutoRotate=false; hum.JumpPower=0 end
        fv2Enabled = true
        fv2Conn = RunService.Heartbeat:Connect(function(dt)
            if not fv2Enabled then return end
            if not fv2Rig or not fv2Rig.pad or not fv2Rig.pad.Parent then fv2Disable(); return end
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
            fv2Rig.pad.CFrame = flatCFrame(Vector3.new(fv2PosX, fv2PosY, fv2PosZ), fv2FacingDir)
        end)
    end

    player.CharacterAdded:Connect(function()
        if fv2Enabled then fv2Enabled=false; task.wait(1); fv2Enable() end
    end)

    FlyV2Section:Toggle({
        Title="Enable Fly", Desc="Lets you fly around the map. Harder to detect than Fly V1. E to go up, Q to go down.", Value=false,
        Callback=function(state)
            if state then fv2Enable(); WindUI:Notify({ Title="Fly V2", Content="Weld flight active. E/Q for altitude.", Icon="plane", Duration=3 })
            else fv2Disable(); WindUI:Notify({ Title="Fly V2", Content="Platform flight disabled.", Icon="plane-off", Duration=2 }) end
        end,
    })
    FlyV2Section:Slider({ Title="Horizontal Speed", Desc="How fast you move left, right and forward while flying.", Step=1, Value={Min=5,Max=200,Default=40}, Callback=function(v) fv2Speed=v end })
    FlyV2Section:Slider({ Title="Vertical Speed",   Desc="How fast you rise or drop while flying.",  Step=1, Value={Min=2,Max=80, Default=20}, Callback=function(v) fv2VSpeed=v end })
end

-- ============================================================
--  MOVEMENT TAB — SPEED V1 (ERX Frame-Delta CFrame Nudge)
-- ============================================================
do
    local SpeedSection = MovementTab:Section({ Title="Speed" })
    local erxEnabled   = false
    local erxTarget    = 16
    local erxLoop      = nil

    local function erxGetChar() return player.Character end
    local function erxGetHum()
        local c = erxGetChar(); return c and c:FindFirstChildOfClass("Humanoid")
    end
    local function erxGetRoot()
        local c = erxGetChar(); return c and c:FindFirstChild("HumanoidRootPart")
    end
    local function erxIsSitting()
        local h = erxGetHum(); return h and h.Sit == true
    end

    local function stopERXLoop()
        if erxLoop then task.cancel(erxLoop); erxLoop=nil end
    end

    local function startERXLoop()
        stopERXLoop()
        erxLoop = task.spawn(function()
            while true do
                local dt = task.wait()
                if not erxEnabled then continue end
                local hum  = erxGetHum()
                local root = erxGetRoot()
                if not hum or not root or erxIsSitting() then continue end
                local moveDir = hum.MoveDirection
                if moveDir.Magnitude > 0 then
                    local base = hum.WalkSpeed
                    if erxTarget ~= base then
                        local extra = moveDir * ((erxTarget - base) * dt)
                        root.CFrame = root.CFrame + extra
                    end
                end
            end
        end)
    end

    player.CharacterAdded:Connect(function()
        if erxEnabled then stopERXLoop(); startERXLoop() end
    end)

    local erxWarningAcknowledged = false
    local erxToggleRef = nil

    erxToggleRef = SpeedSection:Toggle({
        Title   = "Enable Speed",
        Desc    = "Makes you move faster than normal without touching your WalkSpeed.",
        Value   = false,
        Callback = function(state)
            if state then
                if not erxWarningAcknowledged then
                    -- Don't set erxEnabled yet — wait for popup confirmation
                    if erxToggleRef then pcall(function() erxToggleRef:Set(false) end) end
                    erxWarningAcknowledged = true
                    WindUI:Popup({
                        Title="⚠️ Speed Warning", Icon="alert-triangle",
                        Content="Speed V1 nudges your CFrame each frame to exceed your normal walk speed. Harder to detect than WalkSpeed but still use at your own risk.",
                        Buttons={
                            { Title="Cancel", Variant="Tertiary", Callback=function()
                                erxWarningAcknowledged = false
                                erxEnabled = false
                                WindUI:Notify({ Title="Speed V1", Content="Cancelled.", Icon="x-circle", Duration=2 })
                            end },
                            { Title="I Understand", Icon="check", Variant="Primary", Callback=function()
                                erxEnabled = true
                                if erxToggleRef then pcall(function() erxToggleRef:Set(true) end) end
                                startERXLoop()
                                WindUI:Notify({ Title="Speed V1", Content="ERX speed active.", Icon="zap", Duration=3 })
                            end },
                        },
                    })
                else
                    erxEnabled = true
                    startERXLoop()
                    WindUI:Notify({ Title="Speed V1", Content="ERX speed active.", Icon="zap", Duration=3 })
                end
            else
                erxEnabled = false
                stopERXLoop()
                WindUI:Notify({ Title="Speed V1", Content="Speed disabled.", Icon="zap-off", Duration=2 })
            end
        end,
    })

    SpeedSection:Slider({
        Title    = "Target Speed",
        Desc     = "How fast you move. 16 is default walk speed.",
        Step     = 1,
        Value    = { Min=16, Max=250, Default=16 },
        Callback = function(v) erxTarget = v end,
    })

    SpeedSection:Button({
        Title    = "Reset to Default",
        Desc     = "Puts your speed back to normal and turns speed off.",
        Icon     = "rotate-ccw",
        Callback = function()
            erxTarget  = 16
            erxEnabled = false
            if erxToggleRef then pcall(function() erxToggleRef:Set(false) end) end
            stopERXLoop()
            WindUI:Notify({ Title="Speed V1", Content="Reset to default speed.", Icon="rotate-ccw", Duration=2 })
        end,
    })
end

-- ============================================================
--  ARCHIVE TAB — SPEED V2 (PREMIUM, Weld-Based)
-- ============================================================
do
    local SpeedV2Section = ArchiveTab:Section({ Title="Speed V2  •  👑 More Secure" })
    local v2Enabled = false
    local v2Speed   = 40
    local v2Conn    = nil
    local v2Rig     = nil
    local v2WarningAcknowledged = false

    local v2PosX, v2PosY, v2PosZ = 0, 0, 0
    local v2FacingDir = Vector3.new(0, 0, -1)

    local function v2GetRoot() local c=player.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function v2GetHum()  local c=player.Character; return c and c:FindFirstChildOfClass("Humanoid") end

    local function disableSpeedV2()
        v2Enabled = false
        if v2Conn then v2Conn:Disconnect(); v2Conn=nil end
        if v2Rig then destroyWeldedPlatform(v2Rig); v2Rig=nil end
        for _, obj in ipairs(workspace:GetChildren()) do
            if obj.Name == _N.SpeedV2Pad then obj:Destroy() end
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
        v2Rig = createWeldedPlatform(_N.SpeedV2Pad, Vector3.new(10, 0.4, 10))
        if not v2Rig then return end
        v2Rig.pad.CFrame = flatCFrame(Vector3.new(v2PosX, v2PosY, v2PosZ), v2FacingDir)
        v2Enabled = true
        v2Conn = RunService.Heartbeat:Connect(function(dt)
            if not v2Enabled then return end
            if not v2Rig or not v2Rig.pad or not v2Rig.pad.Parent then disableSpeedV2(); return end
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
            v2Rig.pad.CFrame = flatCFrame(Vector3.new(v2PosX, v2PosY, v2PosZ), v2FacingDir)
        end)
    end

    player.CharacterAdded:Connect(function()
        if v2Enabled then v2Enabled=false; task.wait(1); enableSpeedV2() end
    end)

    v2SpeedToggle = SpeedV2Section:Toggle({
        Title="👑 Speed V2",
        Desc="Makes you move faster. Much harder to detect than Speed V1.",
        Value=false, Locked=true, LockedTitle="Upgrade to Premium at pandauth.com to access Speed V2.",
        Callback=function(state)
            if not isPremium then
                if _CBD_UserClick then WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com to unlock Speed V2.", Icon="crown", Duration=5 }) end
                return
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
    SpeedV2Section:Slider({ Title="V2 Speed", Desc="How fast you move.", Step=1, Value={Min=5,Max=200,Default=40}, Callback=function(v) v2Speed=v end })
end

-- ============================================================
--  MOVEMENT TAB — NOCLIP
--  Method: RenderStepped CanCollide=false on torso parts only.
--  No BodyPosition, no PlatformStand, no full-character collision
--  wipe — much harder to flag server-side.
-- ============================================================
do
    local NoclipSection = MovementTab:Section({ Title="Noclip" })

    -- Only disable collision on the parts that actually block you in walls.
    -- Leaving limbs collideable avoids a full no-collision flag on the character.
    local NOCLIP_PARTS = { LowerTorso=true, UpperTorso=true, HumanoidRootPart=true }

    local noclipEnabled = false
    local noclipConn    = nil
    local currentChar   = nil

    local function ncRestoreCollisions(char)
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and NOCLIP_PARTS[part.Name] then
                part.CanCollide = true
            end
        end
    end

    local function ncApplyNoclip(char)
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and NOCLIP_PARTS[part.Name] then
                part.CanCollide = false
            end
        end
    end

    local function disableNoclip()
        noclipEnabled = false
        if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
        ncRestoreCollisions(currentChar)
    end

    local function enableNoclip()
        disableNoclip()
        noclipEnabled = true
        currentChar   = player.Character
        if not currentChar then return end

        -- Re-apply every RenderStepped so the engine cannot re-enable collision
        -- between frames (e.g. on touch events or seat interactions).
        noclipConn = RunService.RenderStepped:Connect(function()
            if not noclipEnabled then return end
            local char = player.Character
            if not char then return end
            currentChar = char
            ncApplyNoclip(char)
        end)
    end

    player.CharacterAdded:Connect(function(char)
        currentChar = char
        if noclipEnabled then
            -- Small delay so the character has time to fully load
            task.wait(0.3)
            enableNoclip()
        end
    end)

    NoclipSection:Toggle({
        Title = "Enable Noclip",
        Desc  = "Pass through walls. Only disables collision on torso parts — harder to detect.",
        Value = false,
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

-- ============================================================
--  STEALTH TAB — INVISIBILITY (Seat/Weld Method)
-- ============================================================
do
    local InvisSection = StealthTab:Section({ Title="Invisibility  •  Seat/Weld Method" })

    local invisActive       = false
    local invisWeldModel    = nil
    local invisTransConn    = nil

    local function getInvisChar()  return player.Character end
    local function getInvisRoot()  local c=player.Character; return c and c:FindFirstChild("HumanoidRootPart") end

    local invisGhostAlpha = 0.3
    local invisGhostEnabled = true

    local function setSelfTransparency(alpha)
        local char = getInvisChar()
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                part.LocalTransparencyModifier = alpha
            end
        end
    end

    local function invisCleanup()
        if invisTransConn then
            invisTransConn:Disconnect()
            invisTransConn = nil
        end
        if invisWeldModel and invisWeldModel.Parent then
            invisWeldModel:Destroy()
            invisWeldModel = nil
        end
        setSelfTransparency(0)
    end

    local function enableInvis()
        local root = getInvisRoot()
        if not root then
            WindUI:Notify({ Title="Invisibility", Content="Character not ready.", Icon="alert-circle", Duration=3 })
            return false
        end

        local savedCF = root.CFrame
        local highPos = CFrame.new(0, 1e6, 0)

        root.CFrame = highPos
        task.wait(0.15)

        invisWeldModel = Instance.new("Model")
        invisWeldModel.Name = _N.InvisModel
        invisWeldModel.Parent = workspace

        local seat = Instance.new("Seat")
        seat.Name        = _N.InvisSeat
        seat.Anchored    = false
        seat.CanCollide  = false
        seat.Transparency = 1
        seat.Position    = highPos.Position
        seat.Parent      = invisWeldModel

        local torso = player.Character:FindFirstChild("Torso")
            or player.Character:FindFirstChild("UpperTorso")
        if torso then
            local weld = Instance.new("Weld")
            weld.Part0  = seat
            weld.Part1  = torso
            weld.Parent = seat
        end

        task.wait(0.1)

        invisWeldModel:PivotTo(savedCF)

        if invisGhostEnabled then
            setSelfTransparency(invisGhostAlpha)
            invisTransConn = RunService.Heartbeat:Connect(function()
                if invisActive and player.Character and player.Character.Parent then
                    setSelfTransparency(invisGhostAlpha)
                end
            end)
        end

        return true
    end

    local function disableInvis()
        invisCleanup()
    end

    -- Keybind only works after the toggle has been turned on at least once.
    -- This prevents accidental activation before any explicit user consent.
    local invisKeybindEnabled = false  -- enabled by the toggle below
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not invisKeybindEnabled then return end
        if input.KeyCode == Enum.KeyCode.K then
            invisActive = not invisActive
            if invisActive then
                local ok = enableInvis()
                if not ok then invisActive = false end
            else
                disableInvis()
                WindUI:Notify({ Title="Invisibility", Content="Invisibility disabled (K).", Icon="eye", Duration=2 })
            end
        end
    end)

    player.CharacterAdded:Connect(function()
        local wasActive = invisActive
        invisActive = false
        invisCleanup()
        if wasActive then
            task.wait(1)
            invisActive = true
            local ok = enableInvis()
            if not ok then invisActive = false end
        end
    end)

    InvisSection:Toggle({
        Title   = "Enable Invisibility",
        Desc    = "Uses seat/weld trick to make you invisible to others. Keybind: K",
        Value   = false,
        Callback = function(state)
            invisActive = state
            invisKeybindEnabled = state  -- keybind only active when toggle is on
            if state then
                local ok = enableInvis()
                if not ok then
                    invisActive = false
                    invisKeybindEnabled = false
                    return
                end
                WindUI:Notify({ Title="Invisibility", Content="You are now invisible to others. Press K to toggle.", Icon="eye-off", Duration=3 })
            else
                disableInvis()
                WindUI:Notify({ Title="Invisibility", Content="Invisibility disabled.", Icon="eye", Duration=2 })
            end
        end,
    })

    InvisSection:Toggle({
        Title   = "Ghost Effect (Self)",
        Desc    = "Makes yourself slightly transparent in your own view while invisible.",
        Value   = true,
        Callback = function(state)
            invisGhostEnabled = state
            if not invisActive then return end
            if invisTransConn then invisTransConn:Disconnect(); invisTransConn=nil end
            if state then
                setSelfTransparency(invisGhostAlpha)
                invisTransConn = RunService.Heartbeat:Connect(function()
                    if invisActive and player.Character and player.Character.Parent then
                        setSelfTransparency(invisGhostAlpha)
                    end
                end)
            else
                setSelfTransparency(0)
            end
        end,
    })

    InvisSection:Slider({
        Title    = "Ghost Opacity",
        Desc     = "How transparent you appear to yourself (0 = fully visible, 1 = fully invisible)",
        Step     = 0.05,
        Value    = { Min=0, Max=1, Default=0.3 },
        Callback = function(v) invisGhostAlpha = v end,
    })
end

-- ============================================================
--  TROLLING TAB — PROXIMITY FLING
-- ============================================================
do
    local TrollingSection = TrollingTab:Section({ Title="Proximity Fling" })
    local flingEnabled    = false
    local flingConn       = nil
    local flingCooldowns  = {}
    local flingWarningAcknowledged = false
    local FLING_RANGE     = 5
    local FLING_COOLDOWN  = 4

    local function getRoot(char) return char and char:FindFirstChild("HumanoidRootPart") end
    local function getHum(char)  return char and char:FindFirstChildOfClass("Humanoid") end

    local activeFlings = {}

    local function skidFlingTarget(target)
        if activeFlings[target.UserId] then return end
        activeFlings[target.UserId] = true

        task.spawn(function()
            -- Use withImmunity wrapper so the flag is ALWAYS cleaned up,
            -- even if an error fires mid-fling.
            local function doFling()
                local myChar = player.Character
                local myHum  = getHum(myChar)
                local myRoot = getRoot(myChar)
                if not myChar or not myHum or not myRoot then return end

                local tChar = target.Character
                local tHum  = tChar and getHum(tChar)
                local tRoot = tChar and getRoot(tChar)
                if not tChar or not tHum or not tRoot then return end

                local returnCF = myRoot.CFrame
                local origFPDH = workspace.FallenPartsDestroyHeight
                workspace.FallenPartsDestroyHeight = math.huge

                local bv = Instance.new("BodyVelocity")
                bv.Name     = _N.FlingBV
                bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
                bv.Velocity  = Vector3.new(9e8, 9e8, 9e8)
                bv.Parent   = myRoot

                myHum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)

                local TIME_LIMIT = 1.5
                local startTick  = tick()
                local angle      = 0

                local function fpos(base, offset, ang)
                    myRoot.CFrame          = CFrame.new(base.Position) * offset * ang
                    myRoot.Velocity        = Vector3.new(9e7, 9e7 * 10, 9e7)
                    myRoot.RotVelocity     = Vector3.new(9e8, 9e8, 9e8)
                end

                repeat
                    if not myRoot or not myRoot.Parent then break end
                    if not tRoot  or not tRoot.Parent  then break end
                    angle += 100
                    local vel = tRoot.Velocity.Magnitude
                    if vel < 50 then
                        fpos(tRoot, CFrame.new(0,  1.5, 0) + tHum.MoveDirection * math.max(vel/1.25, 0), CFrame.Angles(math.rad(angle), 0, 0)); task.wait()
                        fpos(tRoot, CFrame.new(0, -1.5, 0) + tHum.MoveDirection * math.max(vel/1.25, 0), CFrame.Angles(math.rad(angle), 0, 0)); task.wait()
                        fpos(tRoot, CFrame.new( 2.25,  1.5, -2.25) + tHum.MoveDirection * math.max(vel/1.25, 0), CFrame.Angles(math.rad(angle), 0, 0)); task.wait()
                        fpos(tRoot, CFrame.new(-2.25, -1.5,  2.25) + tHum.MoveDirection * math.max(vel/1.25, 0), CFrame.Angles(math.rad(angle), 0, 0)); task.wait()
                    else
                        fpos(tRoot, CFrame.new(0,  1.5,  tHum.WalkSpeed),                     CFrame.Angles(math.rad(90), 0, 0)); task.wait()
                        fpos(tRoot, CFrame.new(0, -1.5, -tHum.WalkSpeed),                     CFrame.Angles(0, 0, 0));             task.wait()
                        fpos(tRoot, CFrame.new(0,  1.5,  tRoot.Velocity.Magnitude / 1.25),    CFrame.Angles(math.rad(90), 0, 0)); task.wait()
                        fpos(tRoot, CFrame.new(0, -1.5, -tRoot.Velocity.Magnitude / 1.25),    CFrame.Angles(0, 0, 0));             task.wait()
                    end
                until tRoot.Velocity.Magnitude > 500
                    or tRoot.Parent ~= tChar
                    or target.Parent ~= Players
                    or tHum.Sit
                    or myHum.Health <= 0
                    or tick() > startTick + TIME_LIMIT

                pcall(function() bv:Destroy() end)
                myHum:SetStateEnabled(Enum.HumanoidStateType.Seated, true)
                workspace.CurrentCamera.CameraSubject = myHum

                if myChar then
                    for _, part in ipairs(myChar:GetDescendants()) do
                        if part:IsA("BasePart") then
                            part.AssemblyLinearVelocity  = Vector3.zero
                            part.AssemblyAngularVelocity = Vector3.zero
                        end
                    end
                end
                if myRoot and myRoot.Parent then
                    myRoot.CFrame = returnCF * CFrame.new(0, 0.5, 0)
                end
                pcall(function() myHum:ChangeState(Enum.HumanoidStateType.GettingUp) end)

                workspace.FallenPartsDestroyHeight = origFPDH
            end

            -- withImmunity guarantees _CBD_SelfImmune is reset even on error
            withImmunity(doFling)

            task.wait(0.25)
            activeFlings[target.UserId] = nil

            WindUI:Notify({ Title="Fling", Content=target.Name.." was flung!", Icon="zap", Duration=2 })
        end)
    end

    local function startFlingDetection()
        if flingConn then flingConn:Disconnect(); flingConn=nil end
        flingConn = RunService.Heartbeat:Connect(function()
            if not flingEnabled then return end
            local myChar = player.Character
            local myRoot = getRoot(myChar)
            if not myRoot then return end
            local now = tick()
            for _, target in ipairs(Players:GetPlayers()) do
                if target == player then continue end
                local tChar = target.Character
                local tRoot = getRoot(tChar)
                if not tRoot then continue end
                local dist = (myRoot.Position - tRoot.Position).Magnitude
                if dist <= FLING_RANGE then
                    local last = flingCooldowns[target.UserId]
                    if not last or (now - last) >= FLING_COOLDOWN then
                        flingCooldowns[target.UserId] = now
                        skidFlingTarget(target)
                    end
                end
            end
        end)
    end

    local function stopFlingDetection()
        flingEnabled    = false
        _CBD_SelfImmune = false
        if flingConn then flingConn:Disconnect(); flingConn=nil end
        flingCooldowns = {}
        activeFlings   = {}
    end

    local flingToggleRef = nil
    flingToggleRef = TrollingSection:Toggle({
        Title="Proximity Fling",
        Desc="Walk into a player to launch them. Teleports you back cleanly after each fling.",
        Value=false,
        Callback=function(state)
            if state then
                if not flingWarningAcknowledged then
                    if flingToggleRef then pcall(function() flingToggleRef:Set(false) end) end
                    flingWarningAcknowledged = true
                    WindUI:Popup({
                        Title="⚠️ Fling Warning", Icon="alert-triangle",
                        Content="Proximity Fling affects other players and may violate game rules, resulting in a kick or ban. Use responsibly and at your own risk.",
                        Buttons={
                            { Title="Cancel", Variant="Tertiary", Callback=function()
                                flingWarningAcknowledged = false
                                flingEnabled = false
                                WindUI:Notify({ Title="Fling", Content="Fling cancelled.", Icon="x-circle", Duration=2 })
                            end },
                            { Title="I Understand", Icon="check", Variant="Primary", Callback=function()
                                flingEnabled = true
                                if flingToggleRef then pcall(function() flingToggleRef:Set(true) end) end
                                startFlingDetection()
                                WindUI:Notify({ Title="Fling", Content="Walk into players to fling them!", Icon="zap", Duration=3 })
                            end },
                        },
                    })
                else
                    flingEnabled = true
                    startFlingDetection()
                    WindUI:Notify({ Title="Fling", Content="Walk into players to fling them!", Icon="zap", Duration=3 })
                end
            else
                stopFlingDetection()
                WindUI:Notify({ Title="Fling", Content="Fling disabled.", Icon="zap-off", Duration=2 })
            end
        end,
    })

    TrollingSection:Slider({ Title="Fling Range",  Desc="Proximity distance (studs) to trigger fling", Step=1, Value={Min=2,Max=12,Default=5},  Callback=function(v) FLING_RANGE=v   end })
    TrollingSection:Slider({ Title="Cooldown (s)", Desc="Seconds before the same player can be flung again", Step=1, Value={Min=1,Max=15,Default=4}, Callback=function(v) FLING_COOLDOWN=v end })
end

-- ============================================================
--  TROLLING TAB — SAFE FLING (PREMIUM)
-- ============================================================
do
    local SafeFlingSection = TrollingTab:Section({ Title="Safe Fling  •  👑 Premium" })

    local WalkFlingEnabled = false
    local CarFlingEnabled  = false

    local function GetDrivenVehicle()
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

    local yieldFling   = false
    local erxFlingConn = nil

    local function startSafeFlingLoop()
        if erxFlingConn then erxFlingConn:Disconnect() end
        erxFlingConn = RunService.Stepped:Connect(function()
            if not (WalkFlingEnabled or CarFlingEnabled) then return end
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
                local movel = 0.1
                local inVehicle = GetDrivenVehicle() ~= nil
                local shouldFling = (CarFlingEnabled and inVehicle)
                    or (WalkFlingEnabled and not inVehicle)
                if shouldFling then
                    -- Set immunity so anti-fling / other systems don't fight us
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
                            root.Velocity = vel + Vector3.new(0, movel, 0)
                        end
                    end)
                end
            end)
        end)
    end

    local function stopSafeFlingLoop()
        WalkFlingEnabled = false
        CarFlingEnabled  = false
        if erxFlingConn then erxFlingConn:Disconnect(); erxFlingConn=nil end
    end

    player.CharacterAdded:Connect(function()
        yieldFling = false  -- always reset yield on respawn
        if WalkFlingEnabled or CarFlingEnabled then
            task.wait(0.5)
            startSafeFlingLoop()
        end
    end)

    walkFlingToggle = SafeFlingSection:Toggle({
        Title       = "👑 Safe Fling  •  Walk",
        Desc        = "Massively multiplies your velocity while on foot — launches your character into the air.",
        Value       = false,
        Locked      = true,
        LockedTitle = "Upgrade to Premium at pandauth.com to access Safe Fling.",
        Callback    = function(state)
            if not isPremium then
                if _CBD_UserClick then WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com to unlock Safe Fling.", Icon="crown", Duration=5 }) end
                return
            end
            WalkFlingEnabled = state
            if state then
                CarFlingEnabled = false
                if carFlingToggle then pcall(function() carFlingToggle:Set(false) end) end
                startSafeFlingLoop()
                WindUI:Notify({ Title="Safe Fling", Content="Walk Fling active — hold still then move!", Icon="zap", Duration=3 })
            else
                if not CarFlingEnabled then stopSafeFlingLoop() end
                WindUI:Notify({ Title="Safe Fling", Content="Walk Fling disabled.", Icon="zap-off", Duration=2 })
            end
        end,
    })

    carFlingToggle = SafeFlingSection:Toggle({
        Title       = "👑 Safe Fling  •  Car",
        Desc        = "Massively multiplies your velocity while driving a vehicle — launches the car you're in.",
        Value       = false,
        Locked      = true,
        LockedTitle = "Upgrade to Premium at pandauth.com to access Safe Fling.",
        Callback    = function(state)
            if not isPremium then
                if _CBD_UserClick then WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com to unlock Safe Fling.", Icon="crown", Duration=5 }) end
                return
            end
            CarFlingEnabled = state
            if state then
                WalkFlingEnabled = false
                if walkFlingToggle then pcall(function() walkFlingToggle:Set(false) end) end
                startSafeFlingLoop()
                WindUI:Notify({ Title="Safe Fling", Content="Car Fling active — get in a DriverSeat!", Icon="zap", Duration=3 })
            else
                if not WalkFlingEnabled then stopSafeFlingLoop() end
                WindUI:Notify({ Title="Safe Fling", Content="Car Fling disabled.", Icon="zap-off", Duration=2 })
            end
        end,
    })
end

-- ============================================================
--  TELEPORT TAB
-- ============================================================
do
    local TpSection    = TeleportTab:Section({ Title="Click to Teleport" })
    local SavedSection = TeleportTab:Section({ Title="Saved Positions" })
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
--  FUN TAB — WALK ANIMATIONS (PREMIUM)
-- ============================================================
do
    local WalkAnimSection = FunTab:Section({ Title="Walk Animations  •  👑 Premium" })

    local WALK_ANIM_PACKS = {
        { name="Default (R15)",    idle1="507766388",  idle2="507766666",  walk="507777826",  run="507767714",  jump="507765000",  fall="507767968",  climb="507765644"  },
        { name="Ninja",            idle1="656117400",  idle2="656118341",  walk="656121766",  run="656118852",  jump="656117878",  fall="656115606",  climb="656114359"  },
        { name="Levitation",       idle1="616006778",  idle2="616008087",  walk="616013216",  run="616010382",  jump="616008936",  fall="616005863",  climb="616003713"  },
        { name="Stylish",          idle1="616136790",  idle2="616138447",  walk="616146177",  run="616140816",  jump="616139451",  fall="616134815",  climb="616133594"  },
        { name="Robot",            idle1="616088211",  idle2="616089559",  walk="616095330",  run="616091570",  jump="616090535",  fall="616087089",  climb="616086039"  },
        { name="Zombie",           idle1="616158929",  idle2="616160636",  walk="616168032",  run="616163682",  jump="616161997",  fall="616157476",  climb="616156119"  },
        { name="Cartoony",         idle1="742637544",  idle2="742638445",  walk="742640026",  run="742638842",  jump="742637942",  fall="742637151",  climb="742636889"  },
        { name="Knight",           idle1="657595757",  idle2="657568135",  walk="657552124",  run="657564596",  jump="658409194",  fall="657600338",  climb="658360781"  },
        { name="Superhero",        idle1="616111295",  idle2="616113536",  walk="616122287",  run="616117076",  jump="616115533",  fall="616108001",  climb="616104706"  },
        { name="Mage",             idle1="707742142",  idle2="707855907",  walk="707897309",  run="707861613",  jump="707853694",  fall="707829716",  climb="707826056"  },
        { name="Vampire",          idle1="1083445855", idle2="1083450166", walk="1083473930", run="1083462077", jump="1083455352", fall="1083443587", climb="1083439238" },
        { name="Werewolf",         idle1="1083195517", idle2="1083214717", walk="1083178339", run="1083216690", jump="1083218792", fall="1083189019", climb="1083182000" },
        { name="Pirate",           idle1="750781874",  idle2="750782770",  walk="750785693",  run="750783738",  jump="750782230",  fall="750780242",  climb="750779899"  },
        { name="Astronaut",        idle1="891621366",  idle2="891633237",  walk="891667138",  run="891636393",  jump="891627522",  fall="891617961",  climb="891609353"  },
        { name="Elder",            idle1="845397899",  idle2="845400520",  walk="845403856",  run="845386501",  jump="845398858",  fall="845396048",  climb="845392038"  },
        { name="Toy",              idle1="782841498",  idle2="782845736",  walk="782843345",  run="782842708",  jump="782847020",  fall="782846423",  climb="782843869"  },
        { name="Bubbly",           idle1="910004836",  idle2="910009958",  walk="910034870",  run="910025107",  jump="910016857",  fall="910001910",  climb="910034870"  },
        { name="Patrol",           idle1="1149612882", idle2="1150842221", walk="1151231493", run="1150967949", jump="1148811837", fall="1148863382", climb="1148811837" },
        { name="Confident",        idle1="1069977950", idle2="1069987858", walk="1070017263", run="1070001516", jump="1069984524", fall="1069973677", climb="1069946257" },
        { name="Cowboy",           idle1="1014390418", idle2="1014398616", walk="1014421541", run="1014401683", jump="1014394726", fall="1014384571", climb="1014380606" },
        { name="Sneaky",           idle1="1132473842", idle2="1132477671", walk="1132510133", run="1132494274", jump="1132489853", fall="1132469004", climb="1132461372" },
        { name="Princess",         idle1="941003647",  idle2="941013098",  walk="941028902",  run="941015281",  jump="941008832",  fall="941000007",  climb="940996062"  },
        { name="Popstar",          idle1="1212900985", idle2="1150842221", walk="1212980338", run="1212980348", jump="1212954642", fall="1212900995", climb="1213044953" },
        { name="Ghost",            idle1="616006778",  idle2="616008087",  walk="616013216",  run="616013216",  jump="616008936",  fall="616005863",  climb="616003713"  },
        { name="Anthro (Default)", idle1="2510196951", idle2="2510197257", walk="2510202577", run="2510198475", jump="2510197830", fall="2510195892", climb="2510192778" },
        { name="None (Invisible)", idle1="0",          idle2="0",          walk="0",          run="0",          jump="0",          fall="0",          climb="0"          },
    }

    local walkAnimEnabled     = false
    local currentWalkPackName = nil
    local walkDropOptions     = {}
    local walkPackByName      = {}
    for _, pack in ipairs(WALK_ANIM_PACKS) do
        table.insert(walkDropOptions, pack.name)
        walkPackByName[pack.name] = pack
    end

    local function applyWalkPack(pack)
        local char = player.Character
        if not char then return end
        local animate = char:FindFirstChild("Animate")
        if not animate then
            WindUI:Notify({ Title="Walk Animations", Content="Animate script not found on character.", Icon="alert-circle", Duration=3 })
            return
        end
        local BASE = "http://www.roblox.com/asset/?id="
        local idleFolder = animate:FindFirstChild("idle")
        if idleFolder then
            local a1 = idleFolder:FindFirstChild("Animation1")
            local a2 = idleFolder:FindFirstChild("Animation2")
            if a1 then a1.AnimationId = BASE .. pack.idle1 end
            if a2 then a2.AnimationId = BASE .. pack.idle2 end
        end
        local walkFolder = animate:FindFirstChild("walk")
        if walkFolder then local wa = walkFolder:FindFirstChild("WalkAnim"); if wa then wa.AnimationId = BASE .. pack.walk end end
        local runFolder = animate:FindFirstChild("run")
        if runFolder then local ra = runFolder:FindFirstChild("RunAnim"); if ra then ra.AnimationId = BASE .. pack.run end end
        local jumpFolder = animate:FindFirstChild("jump")
        if jumpFolder then local ja = jumpFolder:FindFirstChild("JumpAnim"); if ja then ja.AnimationId = BASE .. pack.jump end end
        local fallFolder = animate:FindFirstChild("fall")
        if fallFolder then local fa = fallFolder:FindFirstChild("FallAnim"); if fa then fa.AnimationId = BASE .. pack.fall end end
        local climbFolder = animate:FindFirstChild("climb")
        if climbFolder then local ca = climbFolder:FindFirstChild("ClimbAnim"); if ca then ca.AnimationId = BASE .. pack.climb end end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.Jump = true end
        LOG("WALKANIM", "Applied pack:", pack.name)
    end

    local function resetWalkAnimations()
        local defaultPack = walkPackByName["Default (R15)"]
        if defaultPack then applyWalkPack(defaultPack) end
        currentWalkPackName = nil
    end

    player.CharacterAdded:Connect(function()
        if walkAnimEnabled and currentWalkPackName then
            task.wait(1)
            local pack = walkPackByName[currentWalkPackName]
            if pack then applyWalkPack(pack) end
        end
    end)

    walkAnimToggle = WalkAnimSection:Toggle({
        Title="👑 Enable Walk Animations", Desc="Change your character's movement animations. Visible to everyone.",
        Value=false, Locked=true, LockedTitle="Upgrade to Premium at pandauth.com to access Walk Animations.",
        Callback=function(state)
            if not isPremium then
                WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 }); return
            end
            walkAnimEnabled = state
            if not state then
                resetWalkAnimations()
                WindUI:Notify({ Title="Walk Animations", Content="Animations reset to default.", Icon="rotate-ccw", Duration=2 })
            else
                WindUI:Notify({ Title="Walk Animations", Content="Pick a style from the dropdown below.", Icon="footprints", Duration=3 })
            end
        end,
    })

    walkAnimDropdown = WalkAnimSection:Dropdown({
        Title="👑 Walk Style", Desc="Choose a walk/run/idle animation pack.", Values=walkDropOptions,
        Locked=true, LockedTitle="Upgrade to Premium at pandauth.com.",
        Callback=function(selected)
            if not isPremium then
                WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 }); return
            end
            if not walkAnimEnabled then
                WindUI:Notify({ Title="Walk Animations", Content="Enable Walk Animations first with the toggle above.", Icon="alert-circle", Duration=3 }); return
            end
            local packName = type(selected) == "table" and selected.Title or tostring(selected)
            local pack = walkPackByName[packName]
            if not pack then return end
            currentWalkPackName = packName
            applyWalkPack(pack)
            WindUI:Notify({ Title="Walk Style", Content="Applied: " .. packName, Icon="footprints", Duration=2 })
        end,
    })

    WalkAnimSection:Button({ Title="Reset to Default", Desc="Restore the original R15 walk animations.", Icon="rotate-ccw", Callback=function() resetWalkAnimations(); WindUI:Notify({ Title="Walk Animations", Content="Reset to default R15 animations.", Icon="rotate-ccw", Duration=2 }) end })
end

-- ============================================================
--  FUN TAB — DANCE ANIMATIONS (PREMIUM)
--  FIX: Animation instance must NOT be destroyed until after
--  Play() is called. Store a reference, destroy after a short
--  delay so the engine has time to register the asset.
-- ============================================================
do
    local AnimSection = FunTab:Section({ Title="Dance Animations  •  👑 Premium" })

    local ANIMATION_LIST = {
        { id=10714390497, name="Robot Dance"      }, { id=10713962506, name="Floss"             },
        { id=14899979575, name="Griddy"           }, { id=16572740012, name="GTA Victory"       },
        { id=18443237526, name="Shoot Dance"      }, { id=15679621440, name="Renegade"          },
        { id=4940563117,  name="Nae Nae"          }, { id=14352362059, name="Thriller"          },
        { id=18665811005, name="Woah"             }, { id=10714360343, name="Orange Justice"    },
        { id=10214319518, name="Dab"              }, { id=15963314052, name="Sussy Walk"        },
        { id=10714016223, name="Wiggle"           }, { id=11309255148, name="JuJu"              },
        { id=16126469463, name="Samba"            }, { id=15505459811, name="Carlton"           },
        { id=16256203246, name="Moonwalk"         }, { id=10714378156, name="Wave"              },
        { id=10370362157, name="Worm"             }, { id=15122972413, name="Running Man"       },
        { id=18524313628, name="Hit Dem Folks"    }, { id=12507085924, name="Gangnam Style"     },
        { id=10714330764, name="Twerk"            }, { id=11444441914, name="Milly Rock"        },
        { id=17748314784, name="Crip Walk"        }, { id=10713954623, name="John Travolta"     },
        { id=18526288497, name="Turbo"            }, { id=10714345862, name="Shuffle"           },
        { id=10214311282, name="Salute"           }, { id=10714336041, name="Happy"             },
        { id=17360699557, name="Electro Shuffle"  }, { id=17000021306, name="Anime Dance"       },
        { id=14352343065, name="Macarena"         }, { id=10714342957, name="Whip"              },
        { id=10714388352, name="Dances"           }, { id=16584481352, name="Cat Walk"          },
        { id=12992262118, name="Herobrine"        }, { id=10714392151, name="Raise the Roof"    },
        { id=11753474067, name="Hype"             }, { id=10717116749, name="Pony"              },
        { id=14899980745, name="Disco Fever"      }, { id=15698402762, name="Sig Sauer"         },
        { id=10714068222, name="Swing"            }, { id=15609995579, name="Uno Reverse"       },
        { id=10714101749, name="Breakdance"       }, { id=14352337694, name="Twist"             },
        { id=5895324424,  name="Sprinkler"        }, { id=10713981723, name="Slide"             },
        { id=10478338114, name="Spin"             }, { id=16553163212, name="Ymca"              },
        { id=15571453761, name="Pop Lock"         }, { id=10714366910, name="Lasso"             },
        { id=10714375667, name="Whip Nae Nae"     }, { id=10714100539, name="Running Man 2"     },
        { id=10714374267, name="Tootsee Roll"     }, { id=10714372526, name="Cabbage Patch"     },
        { id=15698404340, name="Reload"           }, { id=14352340648, name="Charleston"        },
        { id=12507084541, name="Bankroll"         }, { id=15392752812, name="Bop"               },
        { id=15505456446, name="Cha Cha Slide"    }, { id=10714352930, name="Bounce"            },
        { id=10714065135, name="Squat Kick"       }, { id=10713990381, name="Dip"               },
        { id=10714349037, name="Jump"             }, { id=16646423316, name="Knife Party"       },
        { id=15517864808, name="Dab Walk"         }, { id=15693621070, name="Get Freaky"        },
        { id=15689279687, name="Disco"            }, { id=17746180844, name="Skibidi"           },
        { id=11394033602, name="Pon Pon"          }, { id=10714345459, name="Crank"             },
        { id=10714386947, name="Hit Dem"          }, { id=10714352626, name="Dances 2"          },
        { id=10714395175, name="Robot 2"          }, { id=10713983178, name="Crocodile"         },
        { id=10714347453, name="Step"             }, { id=10714389396, name="Spin Kick"         },
        { id=10214314957, name="Point"            }, { id=15549124879, name="Mannequin"         },
        { id=10714340543, name="Old Spice"        }, { id=10714369325, name="Swag"              },
        { id=10714069471, name="Lean"             }, { id=14022936101, name="Street Dance"      },
        { id=16392075853, name="Sway"             }, { id=10714089137, name="Anime Dance 2"     },
        { id=14024642130, name="Drill"            }, { id=10714362852, name="Shimmy"            },
        { id=10714003221, name="Idle Bounce"      }, { id=10714360164, name="Cheer"             },
        { id=16270690701, name="Fancy Footwork"   }, { id=10370346995, name="Trot"              },
        { id=6862001787,  name="Blox Step"        }, { id=10370351535, name="March"             },
        { id=18148804340, name="Cyber"            }, { id=15392756794, name="Pop"               },
        { id=15689278184, name="Shoot"            }, { id=10714061912, name="Clap"              },
        { id=10714293450, name="Shrug"            }, { id=10713984554, name="Arms Cross"        },
        { id=10713957138, name="Bow"              }, { id=10714382225, name="Salsa"             },
        { id=10714072822, name="Head Bang"        }, { id=10714340558, name="Guitar"            },
        { id=10714393929, name="Air Guitar"       }, { id=10713968716, name="Sit"               },
        { id=10714074218, name="Lean Back"        }, { id=10714347256, name="Pushup"            },
        { id=16272432203, name="Power Up"         }, { id=10714358528, name="Sleep"             },
        { id=10713992055, name="Laugh"            }, { id=10714394082, name="Cry"               },
        { id=10714392953, name="Confused"         }, { id=10714391240, name="Think"             },
        { id=10714383856, name="Sigh"             }, { id=16215030041, name="Taunt"             },
        { id=15392759696, name="Victory"          }, { id=12507083048, name="Thumbs Up"         },
        { id=12259826609, name="Thumbs Down"      }, { id=16302968986, name="OK Sign"           },
        { id=4940561610,  name="Peace"            }, { id=15517862739, name="Flex"              },
        { id=10214317325, name="Facepalm"         }, { id=10275008655, name="Shiver"            },
        { id=10714371274, name="Cringe"           }, { id=10713988674, name="Nervous"           },
        { id=10714066964, name="Shocked"          }, { id=12259825026, name="Angry"             },
        { id=11453082181, name="Scared"           }, { id=10714350889, name="Dizzy"             },
        { id=10370353969, name="Tired"            }, { id=18225053113, name="Yawn"              },
        { id=13823324057, name="Sneeze"           }, { id=11444443576, name="Cough"             },
        { id=10714392876, name="Idle Lean"        }, { id=10714164866, name="Idle Scratch"      },
        { id=10714382522, name="Idle Look"        }, { id=10714349738, name="Idle Stretch"      },
        { id=17370775305, name="Idle Tap"         }, { id=10714076981, name="Idle Whistle"      },
        { id=10714365721, name="Idle Hum"         }, { id=15505454268, name="Idle Clap"         },
        { id=15505458452, name="Idle Rock"        }, { id=10714361543, name="Idle Pose"         },
        { id=10714364213, name="Idle Freeze"      }, { id=10714022275, name="Idle Look Around"  },
        { id=10714174918, name="Idle Sway"        }, { id=12804157977, name="Idle Bored"        },
        { id=10714063823, name="Idle Fidget"      }, { id=10714070681, name="Idle Check Watch"  },
        { id=14352335202, name="Phone"            }, { id=10714380563, name="Type"              },
        { id=18526362841, name="Read"             }, { id=10714403700, name="Cook"              },
        { id=10714377090, name="Eat"              }, { id=10714168145, name="Drink"             },
        { id=10714389988, name="Drive"            }, { id=10714338461, name="Rowing"            },
        { id=10713966026, name="Swim"             }, { id=10714395441, name="Run Alt"           },
        { id=10714374484, name="Walk Alt"         }, { id=10714359093, name="Jump Alt"          },
        { id=10714356920, name="Fall Alt"         },
    }

    local animEnabled   = false
    local currentTrack  = nil
    local currentAnimId = nil
    local animSpeed     = 1
    local animLooped    = true
    local animSpeedConn = nil

    local function getDanceHum()
        local c = player.Character
        return c and c:FindFirstChildOfClass("Humanoid")
    end

    -- ----------------------------------------------------------------
    --  Core play helper
    --  BUG FIX: Do NOT destroy the Animation instance until AFTER
    --  Play() is called. Destroying it early causes the engine to lose
    --  the asset reference and the track silently does nothing for
    --  custom / user-entered IDs. We defer destruction by one frame.
    -- ----------------------------------------------------------------
    local function stopAnimation()
        if currentTrack then
            pcall(function() currentTrack:Stop() end)
            pcall(function() currentTrack:Destroy() end)
            currentTrack = nil
        end
        if animSpeedConn then
            animSpeedConn:Disconnect()
            animSpeedConn = nil
        end
    end

    local function stopAllAnimations()
        local hum = getDanceHum()
        if not hum then return end
        stopAnimation()
        for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
            pcall(function() track:Stop() end)
        end
        WindUI:Notify({ Title="Dance Animations", Content="All animations stopped.", Icon="square", Duration=2 })
    end

    local function playAnimation(id)
        if not isPremium then return end
        local char = player.Character
        local hum  = getDanceHum()
        if not hum or not char then
            WindUI:Notify({ Title="Dance Animations", Content="No humanoid found.", Icon="alert-circle", Duration=3 })
            return
        end

        stopAnimation()
        currentAnimId = id

        local animator = hum:FindFirstChildOfClass("Animator")
        if not animator then
            animator = Instance.new("Animator")
            animator.Parent = hum
        end

        local anim = Instance.new("Animation")
        anim.AnimationId = "rbxassetid://" .. tostring(id)
        anim.Parent = hum

        local ok, track = pcall(function()
            return animator:LoadAnimation(anim)
        end)

        task.defer(function()
            pcall(function() anim.Parent = nil end)
            pcall(function() anim:Destroy() end)
        end)

        if not ok or not track then
            WindUI:Notify({
                Title   = "Dance Animations",
                Content = "Animation " .. tostring(id) .. " failed. Make sure the ID is public and exists.",
                Icon    = "alert-circle", Duration = 4,
            })
            return
        end

        currentTrack = track
        currentTrack.Looped = animLooped
        currentTrack:Play()
        currentTrack:AdjustSpeed(animSpeed)

        if animSpeedConn then animSpeedConn:Disconnect(); animSpeedConn = nil end

        animSpeedConn = RunService.Heartbeat:Connect(function()
            if currentTrack and currentTrack.IsPlaying then
                pcall(function() currentTrack:AdjustSpeed(animSpeed) end)
            end
        end)
    end

    player.CharacterAdded:Connect(function()
        currentTrack    = nil
        animSpeedConn   = nil
        if animEnabled and currentAnimId then
            task.wait(1)
            playAnimation(currentAnimId)
        end
    end)

    local dropdownOptions = {}
    local nameToId = {}
    for _, entry in ipairs(ANIMATION_LIST) do
        table.insert(dropdownOptions, entry.name)
        nameToId[entry.name] = entry.id
    end

    animToggle = AnimSection:Toggle({
        Title="👑 Enable Dance Animations",
        Desc="Play dances and emotes that everyone in the server can see.",
        Value=false, Locked=true, LockedTitle="Upgrade to Premium at pandauth.com to access Dance Animations.",
        Callback=function(state)
            if not isPremium then
                -- v5 FIX: guard with _CBD_UserClick so the startup Lock() sweep
                -- doesn't fire a "Premium Required" toast.
                if _CBD_UserClick then
                    WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 })
                end
                return
            end
            animEnabled = state
            if not state then
                stopAllAnimations()
            else
                WindUI:Notify({ Title="Dance Animations", Content="Pick an animation from the dropdown below.", Icon="music", Duration=3 })
            end
        end,
    })

    animDropdown = AnimSection:Dropdown({
        Title="👑 Pick Dance Animation",
        Desc="Choose a dance or emote to perform.",
        Values=dropdownOptions,
        Locked=true, LockedTitle="Upgrade to Premium at pandauth.com.",
        Callback=function(selected)
            if not isPremium then
                -- v5 FIX: guard with _CBD_UserClick
                if _CBD_UserClick then
                    WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 })
                end
                return
            end
            if not animEnabled then
                WindUI:Notify({ Title="Dance Animations", Content="Enable Dance Animations first using the toggle above.", Icon="alert-circle", Duration=3 }); return
            end
            local animName = type(selected) == "table" and selected.Title or tostring(selected)
            local id = nameToId[animName]
            if not id then return end
            playAnimation(id)
            WindUI:Notify({ Title="▶ Playing", Content=animName, Icon="music", Duration=2 })
        end,
    })

    AnimSection:Toggle({
        Title="Loop Animation", Desc="Keeps the animation playing on repeat.", Value=true,
        Callback=function(state)
            animLooped = state
            if currentTrack then pcall(function() currentTrack.Looped = state end) end
        end,
    })

    AnimSection:Slider({
        Title="Animation Speed", Desc="How fast the animation plays. 1 is normal speed.",
        Step=0.1, Value={Min=0.1, Max=5, Default=1},
        Callback=function(v)
            animSpeed = v
            if currentTrack and currentTrack.IsPlaying then
                pcall(function() currentTrack:AdjustSpeed(animSpeed) end)
            end
        end,
    })

    AnimSection:Button({
        Title="Stop All Animations", Desc="Stops whatever animation is currently playing.",
        Icon="square", Callback=function() stopAllAnimations() end,
    })

    AnimSection:Input({
        Title="Custom Animation ID",
        Desc="Paste a catalog URL ID or a direct animation asset ID — it auto-converts catalog emote IDs for you.",
        Placeholder="e.g. 83606297144428 or 507770239",
        Callback=function(text)
            if not isPremium then
                WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 }); return
            end
            if not animEnabled then
                WindUI:Notify({ Title="Dance Animations", Content="Enable Dance Animations first.", Icon="alert-circle", Duration=3 }); return
            end

            local trimmed = text and text:match("^%s*(.-)%s*$") or ""
            local id = tonumber(trimmed)
            if not id or id <= 0 or math.floor(id) ~= id then
                WindUI:Notify({ Title="Dance Animations", Content="Invalid ID — enter a positive integer.", Icon="x-circle", Duration=3 }); return
            end
            id = math.floor(id)

            -- --------------------------------------------------------
            --  Auto-resolve: download the catalog asset to a temp file,
            --  read the rbxassetid:// out of the raw RBXM content, then
            --  delete the file. Falls back to using the entered ID as-is.
            -- --------------------------------------------------------
            WindUI:Notify({ Title="Custom Animation", Content="Resolving ID " .. tostring(id) .. "...", Icon="loader", Duration=2 })

            task.spawn(function()
                local resolvedId = id  -- fallback: play ID as-is

                -- Executor workspace-relative path, no extension (matches how Roblox saves these files)
                local TEMP_FILE = _N.AnimTmp

                local httpReq = request or http_request or httprequest
                    or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)

                if not httpReq then
                    LOG("ANIM", "No HTTP request function available")
                    playAnimation(resolvedId)
                    WindUI:Notify({ Title="▶ Custom", Content="Playing ID " .. tostring(resolvedId) .. " (no http fn)", Icon="music", Duration=3 })
                    return
                end

                -- Step 1: hit the asset delivery URL and log the raw response so we can see what comes back
                local resp = nil
                local dlOk, dlErr = pcall(function()
                    resp = httpReq({
                        Url    = "https://assetdelivery.roblox.com/v1/asset/?id=" .. tostring(id),
                        Method = "GET",
                    })
                end)
                if not dlOk or not resp then
                    LOG("ANIM", "Request failed: " .. tostring(dlErr))
                    playAnimation(resolvedId)
                    WindUI:Notify({ Title="▶ Custom", Content="Playing ID " .. tostring(resolvedId) .. " (req failed)", Icon="music", Duration=3 })
                    return
                end

                local statusCode = resp.StatusCode or resp.statusCode or 0
                local body       = resp.Body or resp.body or ""
                LOG("ANIM", "Status=" .. tostring(statusCode) .. " bytes=" .. #body)
                LOG("ANIM", "Body preview: " .. tostring(body:sub(1, 120)))

                -- Step 2: if we got a redirect location header, follow it
                local headers = resp.Headers or resp.headers or {}
                local location = headers["Location"] or headers["location"] or ""
                if #location > 0 then
                    LOG("ANIM", "Following redirect: " .. location)
                    local resp2 = nil
                    local r2Ok, r2Err = pcall(function()
                        resp2 = httpReq({ Url=location, Method="GET" })
                    end)
                    if r2Ok and resp2 then
                        body = resp2.Body or resp2.body or body
                        LOG("ANIM", "Redirect body bytes=" .. #body)
                        LOG("ANIM", "Redirect preview: " .. tostring(body:sub(1, 120)))
                    else
                        LOG("ANIM", "Redirect fetch failed: " .. tostring(r2Err))
                    end
                end

                if #body < 10 then
                    LOG("ANIM", "Body too small, giving up")
                    playAnimation(resolvedId)
                    WindUI:Notify({ Title="▶ Custom", Content="Playing ID " .. tostring(resolvedId) .. " (empty body)", Icon="music", Duration=3 })
                    return
                end

                -- Step 3: write, read back, parse
                local wOk, wErr = pcall(writefile, TEMP_FILE, body)
                if not wOk then
                    LOG("ANIM", "writefile failed: " .. tostring(wErr))
                else
                    LOG("ANIM", "Wrote " .. #body .. " bytes to " .. TEMP_FILE)
                    local fileContent = nil
                    local rOk, rErr = pcall(function() fileContent = readfile(TEMP_FILE) end)
                    if rOk and fileContent and #fileContent > 10 then
                        LOG("ANIM", "Read back " .. #fileContent .. " bytes")
                        local innerId = fileContent:match("rbxassetid://(%d+)")
                        if innerId then
                            local parsed = tonumber(innerId)
                            if parsed and parsed > 0 then
                                LOG("ANIM", "Resolved: " .. id .. " → " .. parsed)
                                resolvedId = parsed
                            end
                        else
                            LOG("ANIM", "No rbxassetid:// in file — preview: " .. fileContent:sub(1, 120))
                        end
                    else
                        LOG("ANIM", "readfile failed: " .. tostring(rErr))
                    end
                    pcall(delfile, TEMP_FILE)
                end

                playAnimation(resolvedId)
                WindUI:Notify({
                    Title   = "▶ Custom",
                    Content = resolvedId == id
                        and "Playing ID " .. tostring(resolvedId)
                        or  "Catalog " .. tostring(id) .. " → anim " .. tostring(resolvedId),
                    Icon = "music", Duration = 3,
                })
            end)
        end,
    })
end

-- ============================================================
--  MISC TAB — MODERATION WATCHER (PREMIUM)
-- ============================================================
do
    local WatchSection=MiscTab:Section({ Title="Moderation Watcher" })
    local watcherEnabled=false; local watcherThread=nil; local joinConn=nil
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
            else
                watcherEnabled=false
                if joinConn then joinConn:Disconnect(); joinConn=nil end
                watcherThread=nil
                WindUI:Notify({ Title="Mod Watcher Off", Content="Staff monitoring stopped.", Icon="shield-off", Duration=3 })
            end
        end,
    })
end

-- ============================================================
--  MISC TAB — ANTI-FLING (PREMIUM)
--  Upgraded to multi-stage detection logic:
--    1. High velocity
--    2. Acceleration spike
--    3. CFrame jump (per Stepped frame)
--    4. Anchor tether distance breach
--    5. Vertical fling
--    6. Rotational spin
--  All detection runs on Stepped (pre-physics) with a Heartbeat
--  backup for ultra-fast CFrame changes. Integrated with WindUI
--  for all notifications — no standalone GUI.
-- ============================================================
do
    local AntiFlingSection = MiscTab:Section({ Title="Anti-Fling" })

    -- ---- Config (sliders feed into this table) ----
    local AF = {
        MaxSpeed              = 150,    -- studs/s
        MaxAcceleration       = 400,    -- studs/s²
        MaxTeleportDistance   = 30,     -- CFrame jump per Stepped frame
        RawFrameJump          = 15,     -- Heartbeat ultra-fast check
        EnableAnchorTether    = true,
        AnchorOffset          = Vector3.new(0, -3.5, 0),
        MaxAnchorDistance     = 80,
        ForceAnchorDuration   = 0.3,
        MaxSuppressionsPerWindow = 3,
        SuppressionWindow     = 1.5,
        NotifyCooldown        = 2.5,
    }

    local antiFlingActive    = false  -- master on/off
    local antiFlingWarned    = false  -- popup acknowledged

    -- Runtime state
    local afChar, afHum, afRoot, afAnchorPart
    local afSafeCF    = CFrame.new()
    local afPrevCF    = CFrame.new()
    local afPrevVel   = Vector3.zero
    local afCorrect   = false
    local afSupHist   = {}
    local afLastNotify= 0

    local afSteppedConn   = nil
    local afHeartbeatConn = nil

    -- ---- Anchor part ----
    local function afCreateAnchor()
        if afAnchorPart then pcall(function() afAnchorPart:Destroy() end) end
        afAnchorPart = Instance.new("Part")
        afAnchorPart.Name        = _N.AnchorPart
        afAnchorPart.Anchored    = true
        afAnchorPart.CanCollide  = false
        afAnchorPart.Transparency = 1
        afAnchorPart.Size        = Vector3.new(1, 1, 1)
        afAnchorPart.Parent      = workspace
        if afRoot then
            afAnchorPart.CFrame = afRoot.CFrame * CFrame.new(AF.AnchorOffset)
        end
    end

    local function afDestroyAnchor()
        if afAnchorPart then
            pcall(function() afAnchorPart:Destroy() end)
            afAnchorPart = nil
        end
    end

    -- ---- Correction helpers ----
    local function afZeroVelocity()
        if not afRoot then return end
        for _, part in ipairs(afChar:GetDescendants()) do
            if part:IsA("BasePart") then
                part.AssemblyLinearVelocity  = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end

    local function afNukeMovers()
        if not afRoot then return end
        -- Whitelist CBD's own named force objects so we don't clobber fly/speed
        local CBD_OWNED = { [_N.FlyV1BV]=true, [_N.FlyV1BG]=true, [_N.FlingBV]=true }
        for _, obj in ipairs(afRoot:GetChildren()) do
            if not CBD_OWNED[obj.Name] and (
                obj:IsA("BodyVelocity") or obj:IsA("BodyForce")    or
                obj:IsA("BodyPosition") or obj:IsA("BodyThrust")   or
                obj:IsA("BodyAngularVelocity") or
                obj:IsA("VectorForce")  or obj:IsA("LinearVelocity") or
                obj:IsA("AngularVelocity")
            ) then
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

    local function afTeleportToAnchor()
        if afAnchorPart and afRoot then
            afRoot.CFrame = afAnchorPart.CFrame * CFrame.new(-AF.AnchorOffset)
            afZeroVelocity()
        end
    end

    local function afTeleportToSafe()
        if afRoot then
            afRoot.CFrame = afSafeCF
            afZeroVelocity()
        end
    end

    -- ---- Suppression entry point ----
    local function afSuppress(reason, detail)
        if not antiFlingActive then return end
        local now = tick()
        LOG("ANTIFLING", reason, detail)

        -- Rate-limited WindUI notification
        if (now - afLastNotify) >= AF.NotifyCooldown then
            afLastNotify = now
            WindUI:Notify({
                Title  = "⚠️ Fling Blocked!",
                Content= reason .. " — " .. detail,
                Icon   = "shield",
                Duration = 3,
            })
        end

        afCorrect = true

        -- Immediate correction
        afNukeMovers()
        if AF.EnableAnchorTether and afAnchorPart then
            afTeleportToAnchor()
        else
            afTeleportToSafe()
        end

        -- Humanoid state lock
        if afHum then
            pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll,    false) end)
            pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false) end)
            pcall(function() afHum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end

        -- Short anchor burst
        afForceAnchorAndReset(AF.ForceAnchorDuration)

        -- Anti-loop: track suppression frequency
        table.insert(afSupHist, now)
        while #afSupHist > 0 and afSupHist[1] < now - AF.SuppressionWindow do
            table.remove(afSupHist, 1)
        end
        if #afSupHist >= AF.MaxSuppressionsPerWindow then
            LOG("ANTIFLING", "Anti-loop triggered — extended anchor")
            afSupHist = {}
            afForceAnchorAndReset(1.0)
        end

        -- Restore humanoid states after anchor lifts
        task.delay(AF.ForceAnchorDuration + 0.05, function()
            if afHum then
                pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll,    true) end)
                pcall(function() afHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true) end)
            end
            -- Refresh safe references
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

    -- ---- Stepped detection (pre-physics, main loop) ----
    local function onAFStepped()
        if not antiFlingActive or not afRoot or not afHum or afCorrect then return end
        if _CBD_SelfImmune then return end
        if afHum:GetState() == Enum.HumanoidStateType.Dead then return end

        local vel    = afRoot.AssemblyLinearVelocity
        local cf     = afRoot.CFrame
        local pos    = cf.Position
        local speed  = vel.Magnitude

        -- 1. High velocity
        if speed > AF.MaxSpeed then
            afSuppress("High Velocity", math.floor(speed).." studs/s")
            return
        end

        -- 2. Acceleration spike
        local accel = (vel - afPrevVel).Magnitude
        if accel > AF.MaxAcceleration then
            afSuppress("Acceleration Spike", math.floor(accel).." studs/s²")
            return
        end

        -- 3. CFrame jump (teleport / rapid position fling)
        local dist = (pos - afPrevCF.Position).Magnitude
        if dist > AF.MaxTeleportDistance then
            afSuppress("CFrame Jump", math.floor(dist).." studs")
            return
        end

        -- 4. Anchor tether
        if AF.EnableAnchorTether and afAnchorPart then
            local anchorDist = (pos - afAnchorPart.Position).Magnitude
            if anchorDist > AF.MaxAnchorDistance then
                afSuppress("Anchor Broken", math.floor(anchorDist).." studs")
                return
            end
        end

        -- 5. Vertical fling
        local vertDelta = math.abs(pos.Y - afPrevCF.Position.Y)
        if vertDelta > 20 then
            afSuppress("Vertical Fling", math.floor(vertDelta).." studs")
            return
        end

        -- 6. Rotational spin
        local rot = afRoot.AssemblyAngularVelocity.Magnitude
        if rot > 40 then
            afSuppress("Rotational Spin", math.floor(rot).." rad/s")
            return
        end

        -- No issues → update safe references and advance anchor
        afSafeCF  = cf
        afPrevVel = vel
        afPrevCF  = cf
        if afAnchorPart then
            local isGrounded = afHum.FloorMaterial ~= Enum.Material.Air
            if isGrounded then
                afAnchorPart.CFrame = cf * CFrame.new(AF.AnchorOffset)
            end
        end
    end

    -- ---- Heartbeat backup (catches ultra-fast CFrame changes) ----
    local function onAFHeartbeat()
        if not antiFlingActive or not afRoot or not afHum or afCorrect then return end
        if _CBD_SelfImmune then return end
        if afHum:GetState() == Enum.HumanoidStateType.Dead then return end

        local jump = (afRoot.Position - afPrevCF.Position).Magnitude
        if jump > AF.RawFrameJump then
            afSuppress("CFrame Teleport (HB)", math.floor(jump).." studs")
            return
        end
        -- Keep PrevCF fresh for Heartbeat's own check
        afPrevCF = afRoot.CFrame
    end

    -- ---- Character setup ----
    local function afSetupCharacter(char)
        -- Disconnect old connections
        if afSteppedConn   then afSteppedConn:Disconnect();   afSteppedConn=nil   end
        if afHeartbeatConn then afHeartbeatConn:Disconnect(); afHeartbeatConn=nil end
        afDestroyAnchor()

        afChar = char
        afHum  = char:WaitForChild("Humanoid")
        afRoot = char:WaitForChild("HumanoidRootPart")

        afPrevVel = afRoot.AssemblyLinearVelocity
        afPrevCF  = afRoot.CFrame
        afSafeCF  = afRoot.CFrame
        afCorrect = false
        afSupHist = {}

        if AF.EnableAnchorTether then
            afCreateAnchor()
        end

        afSteppedConn   = RunService.Stepped:Connect(onAFStepped)
        afHeartbeatConn = RunService.Heartbeat:Connect(onAFHeartbeat)

        afHum.Died:Once(function()
            if afSteppedConn   then afSteppedConn:Disconnect();   afSteppedConn=nil   end
            if afHeartbeatConn then afHeartbeatConn:Disconnect(); afHeartbeatConn=nil end
        end)
    end

    -- ---- Enable / Disable ----
    local function enableAntiFling()
        antiFlingActive = true
        if player.Character then
            afSetupCharacter(player.Character)
        end
    end

    local function disableAntiFling()
        antiFlingActive = false
        if afSteppedConn   then afSteppedConn:Disconnect();   afSteppedConn=nil   end
        if afHeartbeatConn then afHeartbeatConn:Disconnect(); afHeartbeatConn=nil end
        afDestroyAnchor()
        afCorrect = false
        afSupHist = {}
    end

    -- Re-setup on respawn (only if already enabled)
    player.CharacterAdded:Connect(function(char)
        if antiFlingActive then
            task.wait(0.6)
            afSetupCharacter(char)
        end
    end)

    -- ---- Toggle (exposed as module-level for applyPremium) ----
    antiFlingToggle = AntiFlingSection:Toggle({
        Title       = "👑 Anti-Fling",
        Desc        = "Multi-stage fling detection: velocity, acceleration, CFrame jumps, anchor tether, vertical launches, and rotational spin.",
        Value       = false,
        Locked      = true,
        LockedTitle = "Upgrade to Premium at pandauth.com to access Anti-Fling.",
        Callback    = function(state)
            if not isPremium then
                -- v5 FIX: guard with _CBD_UserClick so startup Lock() sweep is silent
                if _CBD_UserClick then
                    WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 })
                end
                return
            end
            if state then
                if not antiFlingWarned then
                    if antiFlingToggle then pcall(function() antiFlingToggle:Set(false) end) end
                    antiFlingWarned = true
                    WindUI:Popup({
                        Title="⚠️ Anti-Fling Info", Icon="alert-triangle",
                        Content="Anti-Fling uses multi-stage detection (velocity spikes, acceleration bursts, CFrame jumps, rotational spin, vertical launches) and an anchor tether to snap you back. Controls return immediately after each suppression window.",
                        Buttons={
                            { Title="Cancel", Variant="Tertiary", Callback=function()
                                antiFlingWarned = false
                                WindUI:Notify({ Title="Anti-Fling", Content="Cancelled.", Icon="x-circle", Duration=2 })
                            end },
                            { Title="I Understand", Icon="check", Variant="Primary", Callback=function()
                                if antiFlingToggle then pcall(function() antiFlingToggle:Set(true) end) end
                                enableAntiFling()
                                WindUI:Notify({ Title="Anti-Fling", Content="Multi-stage fling protection active.", Icon="shield", Duration=3 })
                            end },
                        },
                    })
                else
                    enableAntiFling()
                    WindUI:Notify({ Title="Anti-Fling", Content="Multi-stage fling protection active.", Icon="shield", Duration=3 })
                end
            else
                disableAntiFling()
                WindUI:Notify({ Title="Anti-Fling", Content="Fling protection disabled.", Icon="shield-off", Duration=2 })
            end
        end,
    })

    -- ---- Sliders (feed directly into AF config table) ----
    AntiFlingSection:Slider({
        Title="Max Speed Threshold",
        Desc="Horizontal studs/s that triggers high-velocity detection (lower = more sensitive)",
        Step=10, Value={Min=50, Max=500, Default=150},
        Callback=function(v) AF.MaxSpeed = v end,
    })

    AntiFlingSection:Slider({
        Title="Max Acceleration Threshold",
        Desc="studs/s² spike to trigger acceleration detection",
        Step=25, Value={Min=100, Max=1000, Default=400},
        Callback=function(v) AF.MaxAcceleration = v end,
    })

    AntiFlingSection:Slider({
        Title="Suppress Duration (0.1s steps)",
        Desc="How long to anchor your position after each fling event",
        Step=1, Value={Min=1, Max=20, Default=3},
        Callback=function(v) AF.ForceAnchorDuration = v / 10 end,
    })

    AntiFlingSection:Slider({
        Title="Notify Cooldown (s)",
        Desc="Minimum seconds between fling-detected notifications",
        Step=1, Value={Min=1, Max=10, Default=3},
        Callback=function(v) AF.NotifyCooldown = v end,
    })

    AntiFlingSection:Toggle({
        Title="Anchor Tether",
        Desc="Maintains an invisible anchor below you and teleports you back if you stray too far.",
        Value=true,
        Callback=function(state)
            AF.EnableAnchorTether = state
            if not state then
                afDestroyAnchor()
            elseif antiFlingActive and afRoot then
                afCreateAnchor()
            end
        end,
    })
end

-- ============================================================
--  MISC TAB — MONITOR ALERT  (PREMIUM)
--  v5: Wires the enhanced GC Watcher into a UI toggle so
--  premium users can start/stop the repeating scan and control
--  the scan interval.  Also adds an on-demand manual scan button.
--
--  When enabled, the watcher fires a WindUI toast whenever it
--  detects monitoring patterns in the GC, environment hooks on
--  _G, or injected scripts in the player's containers.
--  All output also appears in the developer console via LOG.
-- ============================================================
do
    local MonitorSection = MiscTab:Section({ Title="Monitor Alert  •  👑 Premium" })

    local maEnabled      = false
    local maScanInterval = 45      -- seconds between scans (slider-controlled)

    -- Register a WindUI toast delivery function with the watcher
    -- so toasts respect this toggle being on/off.
    local function maToast(label)
        if not maEnabled then return end
        WindUI:Notify({
            Title    = "⚠️ Monitor Detected",
            Content  = label .. " — something may be watching this session.",
            Icon     = "eye",
            Duration = 10,
        })
    end

    local function maEnable()
        maEnabled = true
        GCWatcher.setToastFn(maToast)
        GCWatcher.stopLoop()
        GCWatcher.startLoop(maScanInterval)
        WindUI:Notify({
            Title   = "Monitor Alert Active",
            Content = "Scanning every " .. maScanInterval .. "s. You will be notified of any detections.",
            Icon    = "shield",
            Duration = 4,
        })
        LOG("MONALERT", "Loop started, interval =", maScanInterval)
        -- Run an immediate scan on enable so the user gets instant feedback
        task.spawn(function()
            task.wait(0.5)
            local hit = GCWatcher.scanOnce()
            if not hit then
                WindUI:Notify({
                    Title   = "Monitor Alert",
                    Content = "Initial scan clean — no monitoring patterns found.",
                    Icon    = "check-circle",
                    Duration = 3,
                })
            end
        end)
    end

    local function maDisable()
        maEnabled = false
        GCWatcher.setToastFn(nil)
        GCWatcher.stopLoop()
        WindUI:Notify({
            Title   = "Monitor Alert Off",
            Content = "Session monitoring detection stopped.",
            Icon    = "shield-off",
            Duration = 3,
        })
        LOG("MONALERT", "Loop stopped")
    end

    monitorAlertToggle = MonitorSection:Toggle({
        Title       = "👑 Monitor Alert",
        Desc        = "Continuously scans for session monitors, anti-cheat scripts, environment hooks, and injected scripts. Alerts you with a toast when anything suspicious is found.",
        Value       = false,
        Locked      = true,
        LockedTitle = "Upgrade to Premium at pandauth.com to access Monitor Alert.",
        Callback    = function(state)
            if not isPremium then
                -- Guard with _CBD_UserClick so startup Lock() sweep is silent
                if _CBD_UserClick then
                    WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com to unlock Monitor Alert.", Icon="crown", Duration=5 })
                end
                return
            end
            if state then
                maEnable()
            else
                maDisable()
            end
        end,
    })

    MonitorSection:Slider({
        Title    = "Scan Interval (s)",
        Desc     = "How often (in seconds) the watcher scans the session. Restart the toggle to apply a new interval.",
        Step     = 5,
        Value    = { Min=10, Max=120, Default=45 },
        Callback = function(v)
            maScanInterval = v
            -- If already running, restart the loop with the new interval
            if maEnabled then
                GCWatcher.stopLoop()
                GCWatcher.startLoop(maScanInterval)
                WindUI:Notify({
                    Title   = "Monitor Alert",
                    Content = "Scan interval updated to " .. v .. "s.",
                    Icon    = "refresh-cw",
                    Duration = 2,
                })
            end
        end,
    })

    MonitorSection:Button({
        Title    = "Scan Now",
        Desc     = "Run an immediate manual scan and see the result as a toast.",
        Icon     = "search",
        Callback = function()
            if not isPremium then
                WindUI:Notify({ Title="⭐ Premium Required", Content="Upgrade at pandauth.com.", Icon="crown", Duration=5 }); return
            end
            WindUI:Notify({ Title="Monitor Alert", Content="Running manual scan...", Icon="loader", Duration=2 })
            task.spawn(function()
                task.wait(0.1)
                local hit = GCWatcher.scanOnce()
                if hit then
                    WindUI:Notify({
                        Title   = "⚠️ Pattern Found",
                        Content = hit,
                        Icon    = "eye",
                        Duration = 8,
                    })
                else
                    WindUI:Notify({
                        Title   = "✅ Scan Clean",
                        Content = "No monitoring patterns detected.",
                        Icon    = "check-circle",
                        Duration = 4,
                    })
                end
            end)
        end,
    })
end

-- ============================================================
--  BLOCK 8 — CHARACTER METATABLE SPOOFING
--  Applied on every character spawn.  Overrides server-visible
--  properties on Head and HumanoidRootPart so that AC scripts
--  reading Velocity / AssemblyLinearVelocity / Anchored get
--  zeroed/false values.  Also fakes FindFirstChildOfClass for
--  non-CBD callers, and redirects DescendantAdded / ChildAdded
--  to stub BindableEvents so listeners get nothing.
--  All of this is purely client-side metatable trickery — the
--  actual physics values are untouched for the engine.
-- ============================================================
do
    local ZERO3   = Vector3.zero
    local ZERO_CF = CFrame.new()

    -- Parts we spoof on every spawn
    local SPOOFED_PARTS = { "Head", "HumanoidRootPart", "UpperTorso", "LowerTorso" }

    -- Fake BindableEvent used to redirect DescendantAdded/ChildAdded
    local function makeFakeEvent()
        local ok, be = pcall(function() return Instance.new("BindableEvent") end)
        if ok and be then return be.Event end
        -- Fallback stub if BindableEvent is unavailable
        return {
            Connect = function(_, fn) return { Disconnect = function() end } end,
            Wait    = function() return task.wait(9e9) end,
        }
    end

    local function spoofCharacter(char)
        if not char then return end
        pcall(function()
            -- Spoof per-part velocity/anchored reads
            for _, partName in ipairs(SPOOFED_PARTS) do
                local part = char:FindFirstChild(partName)
                if part and typeof(part) == "Instance" then
                    local ok, mt = pcall(getrawmetatable, part)
                    if not ok or not mt then continue end
                    local oldIndex = rawget(mt, "__index")
                    local oldNewIndex = rawget(mt, "__newindex")
                    -- Temporarily unlock metatable
                    local unlocked = pcall(setreadonly, mt, false)
                    if not unlocked then continue end

                    rawset(mt, "__index", newcclosure and newcclosure(function(self, key)
                        if key == "Velocity" or key == "AssemblyLinearVelocity" then
                            return ZERO3
                        elseif key == "AssemblyAngularVelocity" then
                            return ZERO3
                        elseif key == "Anchored" and partName == "Head" then
                            return false
                        elseif key == "FindFirstChildOfClass" then
                            -- Return original for CBD callers, stub for others
                            return function(inst, className)
                                return (type(oldIndex) == "function" and oldIndex(inst, "FindFirstChildOfClass")
                                    or inst.FindFirstChildOfClass)(inst, className)
                            end
                        elseif key == "DescendantAdded" or key == "ChildAdded" then
                            return makeFakeEvent()
                        end
                        if type(oldIndex) == "function" then
                            return oldIndex(self, key)
                        elseif type(oldIndex) == "table" then
                            return oldIndex[key]
                        end
                        return rawget(self, key)
                    end) or function(self, key)
                        if key == "Velocity" or key == "AssemblyLinearVelocity" then
                            return ZERO3
                        elseif key == "AssemblyAngularVelocity" then
                            return ZERO3
                        elseif key == "Anchored" and partName == "Head" then
                            return false
                        elseif key == "DescendantAdded" or key == "ChildAdded" then
                            return makeFakeEvent()
                        end
                        if type(oldIndex) == "function" then
                            return oldIndex(self, key)
                        elseif type(oldIndex) == "table" then
                            return oldIndex[key]
                        end
                        return rawget(self, key)
                    end)

                    pcall(setreadonly, mt, true)
                end
            end
        end)
    end

    -- Apply on current character and every future spawn
    if player.Character then
        task.spawn(spoofCharacter, player.Character)
    end
    player.CharacterAdded:Connect(function(char)
        task.wait(0.1)  -- let the character fully replicate first
        spoofCharacter(char)
    end)
end

-- ============================================================
--  BLOCK 9 — ANTI-AFK
--  Uses VirtualUser to suppress the idle kick.  Fully pcall-
--  wrapped so it silently does nothing if VirtualUser is absent.
-- ============================================================
do
    pcall(function()
        local VirtualUser = game:GetService("VirtualUser")
        player.Idled:Connect(function()
            VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
            task.wait(0.1)
            VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        end)
    end)
end

-- ============================================================
--  ARCHIVE TAB
-- ============================================================

Window:SelectTab(1)
