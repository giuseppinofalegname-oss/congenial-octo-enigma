---@diagnostic disable: undefined-global, undefined-field

------------ OPTIONS --------------

local doPine3D = false
local maxBR = 30
local maxEnergyConsume = 1000000

-----------------------------------


local dfpwm = require("cc.audio.dfpwm")
local pb = require("pixelbox_lite")
local Pine3D = require("Pine3D")
local ccstring = require("cc.strings")
local json = require("json");
local aes = require("AES");
local nas = require("NAS")

local speakers = { peripheral.find("speaker") }
local relay = { peripheral.find("redstone_relay") }
local mon = peripheral.find("monitor")
local react = peripheral.find("fissionReactorLogicAdapter")
local turb = peripheral.find("turbineValve")
local meter = peripheral.find("energy_detector")
local tank = peripheral.find("ultimateChemicalTank")
local tube = peripheral.find("ultimatePressurizedTube")

mon.setTextScale(0.5)
mon.clear()
term.redirect(mon)
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.white)
X, Y = mon.getSize()
LCX, LCY = 0,0


DATASHEET = window.create(term.current(), 2, Y-30, X-74, 15)
DATASHEET.setBackgroundColor(colors.white)
DATASHEET.setTextColor(colors.black)
DATASHEET.clear()

LOG = window.create(term.current(), 2, Y-14, X-74, 14)
LOG.setBackgroundColor(colors.gray)
LOG.setTextColor(colors.white)
LOG.clear()


-- PixelBox
ECG = pb.new(window.create(term.current(), X-70, 1, 71, 41))
ECGX, ECGY = ECG.width, ECG.height

BRG = pb.new(window.create(term.current(), X-70, 41, 71, 41))
BRGX, BRGY = BRG.width, BRG.height
-- END

-- Pine3D
local tdf = Pine3D.newFrame(1,1,X-72, Y-32)
local camera = {
    x = -5,
    y = 1,
    z = 0,
    rotX = 0,
    rotY = 0,
    rotZ = 0,
}
tdf:setCamera(camera)
tdf:setFoV(80)
tdf:setBackgroundColor(colors.black)
local turbine = Pine3D.loadModel("models/turbine")
local blad = Pine3D.loadModel("models/turbine_blades")
local rec = Pine3D.loadModel("models/reattore1")
rec = rec:setOutline({[colors.green] = colors.lime,[colors.lime] = colors.green,})
turbine = turbine:setOutline({[colors.black] = colors.gray,[colors.cyan] = colors.black})
blad = blad:setOutline({[colors.red] = colors.red})
rec = rec:scale(0.14)
local rotateSpeed = 5
rotateSpeed = rotateSpeed * 0.01
tdf:setBackgroundColor(colors.orange)
tdf:setFoV(80)
-- END


local decoder = dfpwm.make_decoder()

local function relayGetAny()
    local sides = {"bottom", "top", "left", "right", "front", "back"}
    for _, val in pairs(sides) do
        for index, r in pairs(relay) do
            if r.getInput(val) then
                return true, index
            end
        end
    end
    return false
end

local function drawLine(box,x1,y1,x2,y2,color)
    local x, y = 0,0
    for t=0,1,0.1 do
        if x1 > x2 then
            x = math.floor(x1 + t * (x2 - x1))
        else
            x = math.ceil(x1 + t * (x2 - x1))
        end
        if y1 > y2 then
            y = math.floor(y1 + t * (y2 - y1))
        else
            y = math.ceil(y1 + t * (y2 - y1))
        end
        box.canvas[y][x] = color
    end
end

local function clamp(X, min, max)
    if X < min then return min end
    if X > max then return max end
    return X
end

local function round(num, numDecimalPlaces)
    local mult = 10^(numDecimalPlaces or 0)
    return math.floor(num * mult + 0.5) / mult
end

local function getClicked(x,y,x1,y1,x2,y2)
    if (x >= x1 and x < x2) and (y >= y1 and y < y2) then
        return true
    else
        return false
    end
end

local function playAudioFile(filepath, priority)

    if priority then
        for _, speaker in pairs(speakers) do
            speaker.stop()
        end
    end

    for chunk in nas.lines(filepath, 8 * 1024) do
        local buffer = decoder(chunk)
        for _, speaker in pairs(speakers) do
            while not speaker.playAudio(buffer) do
                os.pullEvent("speaker_audio_empty")
            end
        end
    end
end

local state_to_audio = {"normal.dfpwm", "no_production.dfpwm", "low_rate.dfpwm", "safety_mode.dfpwm", "explosion.dfpwm"}
local defaultAudioPath = "audio_nr/"

local values = {efp= 0, prod=0, consume=0, genfuel=0, fuel=0, waste=0, coolant=0, br=0, temp=0, gendeltafuel=0, deltafuel=0, status=false, updaterate=0.5, rtbr=0, log={}}
local status = 1
local safeshutdown = false
local musicStart = false
local safetyfill = false
local startstopvar = false
local surgeEnd = os.clock()
local log = {"["..textutils.formatTime(os.time()).."] [INFO] Nuclear reactor plant computer has started correctly!"}

local function add_log(type, message)
    local temp = "["..textutils.formatTime(os.time()).."] ["..type.."] "..message
    local lines = ccstring.wrap(temp, Y+5)
    for i = 1, #lines do
        log[#log+1] = lines[i]
    end

end

local function safeShutdownCall()
    react.scram()
    safeshutdown = true
end

local function logErrorHandler( err )
    add_log("ERROR", "An error occurred: ")
    log[#log+1] = err
    safeShutdownCall()
end

local function criticalEventHandler()
    while true do
        local event = os.pullEventRaw()
        if event == "terminate" or event == "peripheral_detach" then
            logErrorHandler("Critical event fired: " .. event)
            os.shutdown()
        end
    end
end

local function getValuesFast()
    while safeshutdown == false do
        values.prod = turb.getProductionRate()
        values.consume = meter.getTransferRate()
        sleep(1)
    end
end

local function getFuelValues()
    local oldGenFuel = 0
    local clock = os.clock()
    local oldClock = clock-0.2
    while safeshutdown == false do
        values.fuel = react.getFuel().amount
        values.genfuel = tank.getStored().amount + tube.getBuffer().amount + values.fuel
        values.gendeltafuel = ((values.genfuel-oldGenFuel)/(clock-oldClock))/20
        oldGenFuel = values.genfuel
        oldClock = clock
        sleep(0.2)
        clock = os.clock()
    end
end

local function getValuesSlow()
    local oldFuel = 0
    local clock = os.clock()
    local oldClock = clock-0.2
    while safeshutdown == false do
        values.status = react.getStatus()
        if values.status then values.br = react.getActualBurnRate() end
        values.efp = turb.getEnergyFilledPercentage()
        values.waste = react.getWasteFilledPercentage()
        values.coolant = react.getCoolantFilledPercentage()
        values.temp = react.getTemperature() - 273.15
        values.deltafuel = ((values.fuel-oldFuel)/(clock-oldClock))/20
        oldFuel = values.fuel
        values.log = log
        oldClock = clock
        sleep(0.2)
        clock = os.clock()
    end
end

local function getValues()
    parallel.waitForAll(getValuesFast, getValuesSlow, getFuelValues)
end

local function surge()
    surgeEnd = os.clock() + 5
end

local function startStop()
    if values.status then
        react.scram()
        startstopvar = true
    else
        react.activate()
        sleep(1)
        surge()
        startstopvar = false
    end
end

local function musicloop()
    while safeshutdown == false do
        if musicStart then
            if safetyfill == false then
                local num = math.random(2)
                playAudioFile(fs.combine(defaultAudioPath, "/song"..num..".dfpwm"), true)
            end
        end
        sleep()
    end
end

local function music()
    if musicStart then
        for _, v in pairs(speakers) do
            v.stop()
            musicStart = false

        end
    else
        musicStart = true
    end
end

local function safetyfill_loop()
    local audio_played = false
    while safeshutdown == false do

        if safetyfill == false then audio_played = false end

        if safetyfill and audio_played == false then
            for _, v in pairs(speakers) do
                v.stop()
                musicStart = false
            end
            add_log("WARN", "Safety Fill activated! System will now rely on it's own auto-shutdown!")
            playAudioFile(fs.combine(defaultAudioPath, "safetyfill.dfpwm"), true)
            audio_played = true
        end
        sleep()
    end
end

local function safetyfill_start()
    safetyfill = true
end

local function pine3dstart()
    if doPine3D then
        doPine3D = false
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1,1)
        term.setTextColor(colors.white)
        DATASHEET.clear()
        LOG.clear()
    else
        doPine3D = true
    end
end

local function safety_logic()
    sleep(1.5)
    local insfuelprinted = false
    local tempbr = 0
    while safeshutdown == false do
        local clock = os.clock()
        if values.coolant >= 0.3 and values.fuel >= 2000 and values.status == false and values.consume > 1000 and startstopvar == false then
            react.activate()
            values.status = true
        end

        if values.status then
            if values.deltafuel < 0 and values.gendeltafuel < 0 then
                status = 2
                if not insfuelprinted then add_log("WARN", "Not enough fissile fuel to sustain the reaction!") insfuelprinted = true end
            else
                status = 1
                insfuelprinted = false
            end

            -- burn rate calculation

            local burn = (values.consume/1.14211)*(1/20000)
            if values.efp <= 0.1 then
                if values.consume <= maxEnergyConsume then
                    tempbr = clamp(burn*2,0,maxBR)
                    values.rtbr = clamp(burn*2,0,maxBR)
                end
            else
                tempbr = clamp(burn,0,maxBR)
                values.rtbr = clamp(burn,0,maxBR)
            end

            -- safety logic
            if values.coolant <= 0.2 or values.efp > 0.9 or values.waste > 0.01 or values.temp > 5000 and values.status then
                values.rtbr = 0
                react.setBurnRate(0)
                if safetyfill and values.temp < 5000 and values.waste < 0.01 and values.coolant >= 0.3 then
                    safetyfill = false
                    playAudioFile(fs.combine(defaultAudioPath, "safetyfill_success.dfpwm"), true)
                    add_log("INFO/SF", "Safety fill completed with success!")
                else
                    startstopvar = true
                    react.scram()
                    add_log("WARN", "The security system has gone off! Possible reasons: (EFP: "..values.efp.."/1, Waste: "..values.waste.."/1)")
                end
                sleep(5)
            end

            if surgeEnd >= clock then
                tempbr = maxBR
                values.rtbr = maxBR
            end

            if safetyfill then
                tempbr = maxBR
                values.rtbr = maxBR
            end

        else
            status = 4
        end

        if values.br == 0 and values.status and values.consume < 900 and values.efp > 0.1 and startstopvar == false then
            react.scram()
            values.status = false
        end

        react.setBurnRate(tempbr)
        tempbr = 0
        sleep()
    end
end

local function get_player_touch()
    while safeshutdown == false do
        local e, s, x, y = os.pullEvent("monitor_touch")
        LCX, LCY = x,y
    end
end

local function displaySimple()
    local buttons = {{text = "Start/Stop", action=startStop, bgc=colors.red, fgc=colors.black}, {text = "Surge", action=surge, bgc=colors.red, fgc=colors.black}, {text = "Pine3D", action=pine3dstart, bgc=colors.red, fgc=colors.black}, {text = "Safety Fill", action=safetyfill_start, bgc=colors.red, fgc=colors.black}, {text = "Music", action=music, bgc=colors.red, fgc=colors.black}}
    local bx, by = X-110, Y-32
    while safeshutdown == false do
        DATASHEET.setCursorPos(4,3)
        DATASHEET.write("Energy Consumption: "..round(values.consume, 2).." FE/t     ")
        DATASHEET.setCursorPos(4,4)
        DATASHEET.write("Energy Production: "..round(values.prod/2.5, 2).." FE/t     ")
        DATASHEET.setCursorPos(4,5)
        DATASHEET.write("Energy Filled: "..(round(values.efp*100, 2)).." %   ")
        DATASHEET.setCursorPos(4,6)
        DATASHEET.write("Burn Rate: "..values.br.." mB/t    ")
        DATASHEET.setCursorPos(4,7)
        DATASHEET.write("Reactor Temperature: "..math.floor(values.temp)..string.char(176).."C      ")
        DATASHEET.setCursorPos(4,8)
        DATASHEET.write("General Delta Fuel: "..round(values.gendeltafuel,3).." mB/t      ")
        DATASHEET.setCursorPos(4,9)
        DATASHEET.write("General Fuel: "..round(values.genfuel,3).." mB/t      ")
        DATASHEET.setCursorPos(4,10)
        DATASHEET.write("Status: "..tostring(values.status).."       ")
        -- Data.Log
        LOG.setCursorPos((X-70)/2-3, 2)
        LOG.write("Log")
        for k, v in pairs(log) do
            LOG.setCursorPos(4, clamp(k+3,0,13))
            LOG.write(v.."                                                      ")
        end
        if #log > 10 then
            table.remove(log, 1)
        end


        for k, v in pairs(buttons) do
            local xi, yi, xf, yf
            if k <= 3 then
                xi, yi, xf, yf = bx, by+(3*k), bx+#v.text, by+(3*k)+1
            else
                xi, yi, xf, yf = bx+20, by+((k-3)*3), bx+20+#v.text, by+((k-3)*3)+1
            end
            paintutils.drawFilledBox(xi-1, yi-1+k, xf+1, yf+k, v.bgc)
            term.setCursorPos(xi+1, yi+k)
            term.setTextColor(v.fgc)
            term.write(v.text)
            if getClicked(LCX, LCY, xi-1, yi-1+k, xf+1, yf+k) then
                LCX, LCY = 0,0
                add_log("INFO", "Button clicked: " .. v.text)
                v.action()
            end
        end

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        sleep(0.2)
    end
end

local function displayComplex()
    local ctable = {}
    local ptable = {}
    local brtable = {}
    while safeshutdown == false do
        pb.restore(ECG, colors.gray)
        pb.restore(BRG, colors.white)

        -- Table Assignement
        brtable[#brtable+1] = clamp(round(BRGY-values.rtbr*(100/maxBR), 2), 1, BRGY-3)

        if values.prod/2.5 > 200000 then
            ctable[#ctable+1] = clamp(round(ECGY-values.consume/8000, 2), 1, ECGY-3)
            ptable[#ptable+1] = clamp(round(ECGY-values.prod/25000, 2), 1, ECGY-3)
        else
            ctable[#ctable+1] = clamp(round(ECGY-values.consume/4000, 2), 1, ECGY-3)
            ptable[#ptable+1] = clamp(round(ECGY-values.prod/12500, 2), 1, ECGY-3)
        end


        -- Energy Prod/Consumption graph

        local ox, oy = 0,0
        for k, v in pairs(ptable) do
            if k <= 1 then
                v = math.floor(v)
                k = math.floor(k)
                ECG.canvas[v][k] = colors.green
            else
                drawLine(ECG, ox,oy,k,v, colors.green)
            end
            ox, oy = k,v
        end
        ox, oy = 0,0
        for k, v in pairs(ctable) do
            if k <= 1 then
                v = math.floor(v)
                k = math.floor(k)
                ECG.canvas[v][k] = colors.lime
            else
                drawLine(ECG, ox,oy,k,v, colors.lime)
            end
            ox, oy = k,v
        end

        ox, oy = 0,0
        for k, v in pairs(brtable) do
            if k <= 1 then
                v = math.floor(v)
                k = math.floor(k)
                BRG.canvas[v][k] = colors.red
            else
                drawLine(BRG, ox,oy,k,v, colors.red)
            end
            ox, oy = k,v
        end

        ECG:render()
        BRG:render()

        -- Table clear
        if #ptable > ECG.width-2 then
            table.remove(ptable, 1)
            table.remove(ctable, 1)
        end

        if #brtable > BRG.width-2 then
            table.remove(brtable, 1)
        end

        -- Draw Graphs titles
        term.setCursorPos(math.floor(((X-70)+71)/2), 1)
        term.write("ENERGIA")

        sleep(0.2)
    end
end

local function pine3dLoop()
    tdf:depthInterpolation(false)
    while safeshutdown == false do
        if doPine3D then
            turbine = turbine:rotate(0, rotateSpeed, 0)
            blad = blad:rotate(0,0.1+rotateSpeed,0)
            rec = rec:rotate(0,rotateSpeed,0)
            local turbineObject = tdf:newObject(turbine, 0, 0, -1.5)
            local bladObject = tdf:newObject(blad, 0, 0, -1.5)
            local recobj = tdf:newObject(rec, 0, 0, 1.5)
            local objects = {turbineObject,bladObject,recobj}
            tdf:drawObjects(objects)
            tdf:drawBuffer()
            sleep()
        else
            term.setCursorPos(35,25)
            term.write("Pine3D is deactivated")
            sleep(2)
        end
    end
end

local function messages()
    while safeshutdown == false do
        local val, i = relayGetAny()
        if val and i == 2 then
            add_log("INFO/AUDIO", "New player has entered the plant! Playing welcome message n."..status)
            if safetyfill == false then playAudioFile(fs.combine(defaultAudioPath, state_to_audio[status]), true) end
            sleep(5)
        elseif val and i == 1 then
            add_log("INFO", "Delivery arrived!")
            if safetyfill == false then playAudioFile(fs.combine(defaultAudioPath, "delivery.dfpwm")) end
            sleep(5)
        end
        os.pullEvent("redstone")
    end
end

local function random_tip()
    local chance = 20
    while safeshutdown == false do
        local roll = math.random(100)
        local tip = math.random(6)
        if roll <= chance then
            if safetyfill == false then playAudioFile(fs.combine(defaultAudioPath, "/tip"..tip..".dfpwm"), false) end
        end
        sleep(30)
    end
end

local function broadcast()
    peripheral.find("modem", rednet.open)
    local key = aes.StringToKey("CCTweakedReactor", 1024)
    while safeshutdown == false do
        rednet.broadcast(aes.Encrypt(aes.StringToTable(json.encode(values)), key))
        sleep(values.updaterate)
    end
end

local function safe_safety_logic() xpcall(safety_logic, logErrorHandler) end
local function safe_critical_events() xpcall(criticalEventHandler, logErrorHandler) end
local function safe_getValues() xpcall(getValues, logErrorHandler) end
local function safe_displaySimple() xpcall(displaySimple, logErrorHandler) end
local function safe_displayComplex() xpcall(displayComplex, logErrorHandler) end
local function safe_pine3dloop() xpcall(pine3dLoop, logErrorHandler) end
local function safe_broadcast() xpcall(broadcast, logErrorHandler) end
local function safe_safetyfill_loop() xpcall(safetyfill_loop, logErrorHandler) end

parallel.waitForAll(messages, random_tip, safe_safety_logic, safe_critical_events, safe_getValues, safe_displaySimple, safe_displayComplex, safe_pine3dloop, safe_broadcast, safe_safetyfill_loop, musicloop, get_player_touch)
