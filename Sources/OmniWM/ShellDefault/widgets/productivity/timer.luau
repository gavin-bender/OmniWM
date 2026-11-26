-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
local timer = {}
local record = { mode = "Pomodoro", phase = "Focus", round = 1 }
local completion, restored
local function save()
    omniwm.store.set("timer", record)
end
local function finish()
    record.deadline, record.remaining = nil, nil
    if record.mode == "Timer" then record.done = true
    elseif record.phase == "Focus" then record.phase = if record.round == 4 then "Long break" else "Break"
    else record.phase = "Focus"; record.round = record.round % 4 + 1 end
    save()
end
local function arm()
    if completion then completion:cancel(); completion = nil end
    if not record.deadline then return end
    local remaining = record.deadline - os.time()
    if remaining <= 0 then finish(); return end
    completion = omniwm.after(remaining, function()
        completion = nil
        arm()
    end)
end
function timer.restore()
    if restored then return end
    restored = true
    local saved = omniwm.store.get("timer")
    if type(saved) == "table" and (saved.mode == "Timer" or saved.mode == "Pomodoro")
        and table.find({"Focus", "Break", "Long break"}, saved.phase)
        and type(saved.round) == "number" and saved.round >= 1 and saved.round <= 4
        and (saved.deadline == nil or type(saved.deadline) == "number")
        and (saved.remaining == nil or type(saved.remaining) == "number") then
        record = table.clone(saved)
        arm()
    end
end
function timer.read(ctx)
    local seconds = record.remaining
    if record.deadline then seconds = math.max(0, record.deadline - (ctx.data.seconds or os.time())) end
    if not seconds then
        if record.mode == "Timer" then seconds = math.clamp(tonumber(ctx.select("settings", "minutes")) or 10, 1, 180) * 60
        elseif record.phase == "Focus" then seconds = 1500
        elseif record.phase == "Break" then seconds = 300
        else seconds = 900 end
    end
    return record, math.ceil(seconds)
end
function timer.mode(mode)
    if mode == record.mode then return end
    record = { mode = mode, phase = "Focus", round = 1 }
    arm()
    save()
end
function timer.toggle(ctx)
    if record.deadline then
        local remaining = record.deadline - os.time()
        if remaining <= 0 then arm(); return end
        record.remaining, record.deadline = remaining, nil
    else
        local _, duration = timer.read(ctx)
        record.deadline, record.remaining, record.done = os.time() + duration, nil, nil
    end
    arm()
    save()
end
return timer
