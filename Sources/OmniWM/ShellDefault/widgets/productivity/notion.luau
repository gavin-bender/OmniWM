-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
local notion = {}
local page, selectedPage, request, poll
local rows, problem
local base = "https://api.notion.com/v1/"

local function validID(id)
    return type(id) == "string" and #id == 32 and id:match("^%x+$") ~= nil
end

local function normalizeID(value)
    local compact = value:gsub("-", "")
    if validID(compact) and (#value == 32 or value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x+$")) then
        return compact:lower()
    end
    return nil
end

local function pageID(ctx)
    local value = (ctx.select("settings", "pageID") or ""):match("^%s*(.-)%s*$")
    if value == "" then return "" end
    local scheme, host, path = value:match("^(%a+)://([^/]+)/([^#]*)")
    if not scheme then return normalizeID(value) end
    scheme, host = scheme:lower(), host:lower()
    if scheme ~= "https" and scheme ~= "notion" then return nil end
    local domain = "." .. host
    if not (domain:match("%.notion%.so$") or domain:match("%.notion%.site$") or domain:match("%.notion%.com$")) then return nil end

    local query = path:match("%?(.*)$")
    if query then
        local openedPage = ("&" .. query):match("&p=([^&]*)")
        if openedPage then return normalizeID(openedPage) end
    end
    local segment = path:match("^[^?]*"):match("([^/]+)/?$") or ""
    for _, length in {36, 32} do
        if #segment == length or (#segment > length and segment:sub(-length - 1, -length - 1) == "-") then
            local id = normalizeID(segment:sub(-length))
            if id then
                local view = query and ("&" .. query):match("&v=([^&]+)")
                local viewID = view and normalizeID(view)
                return if viewID then id .. "/" .. viewID else id
            end
        end
    end
    return nil
end

local function failure(result)
    if result.error == "notion_token_unavailable" then return omniwm.l10n("Save your connection token in widget settings.") end
    if result.status == 401 then return omniwm.l10n("The Notion token was rejected.") end
    if result.status == 403 or result.status == 404 then return omniwm.l10n("Check page sharing and connection permissions.") end
    if result.status == 429 then return omniwm.l10n("Notion is busy. Try again shortly.") end
    if result.error and result.error:match("^network_") then return omniwm.l10n("Allow api.notion.com in Network & Permissions.") end
    return omniwm.l10n("Couldn’t sync with Notion. Try refreshing.")
end

local function send(id, method, path, body, complete, onError)
    local handle, err = omniwm.http({ url = base .. path, method = method,
        headers = { ["X-OmniWM-Notion-Connection"] = "1" }, body = body, response = "json" }, function(result)
        if page ~= id then return end
        request = nil
        if not result.ok then
            if onError and onError(result) then return end
            problem = failure(result)
            return
        end
        complete(result.json)
    end)
    request = handle
    if not handle then problem = err or omniwm.l10n("Refresh unavailable.") end
end

-- Compare all-day dates as written and timed events in the Mac's local time zone.
local function localDay(start)
    if type(start) ~= "string" then return nil end
    local year, month, day, hour, minute = start:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
    if not year then return start end
    local utc = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = 0 })
    local sign, hours, minutes = start:match("([+-])(%d%d):(%d%d)$")
    if sign then utc -= (if sign == "+" then 1 else -1) * (tonumber(hours) * 3600 + tonumber(minutes) * 60) end
    return os.date("%Y-%m-%d", utc)
end

local function field(properties, kind, preferred)
    local found
    for name, prop in properties do
        if prop.type == kind then
            if name:lower() == preferred then return name end
            if not found or name < found then found = name end
        end
    end
    return found
end

local function readCalendar(id, databaseID, viewID)
    local function readSource(sourceID, view)
        send(id, "GET", "data_sources/" .. sourceID, nil, function(schema)
            local props = schema.properties
            if type(props) ~= "table" then problem = omniwm.l10n("Invalid Notion response."); return end
            local date = field(props, "date", "date")
            local config = view.configuration
            if type(config) == "table" and config.date_property_id then
                for name, prop in props do
                    if prop.id == config.date_property_id then date = name; break end
                end
            end
            local title = field(props, "title", "name")
            local progress = field(props, "status", "status") or field(props, "checkbox", "done")
            if not (date and title and progress) then
                problem = omniwm.l10n("Calendar tasks need a date and a Status or checkbox property.")
                return
            end
            local kind = props[progress].type
            local doneIDs, doneID, openID = {}, nil, nil
            if kind == "status" then
                local groups = props[progress].status.groups
                for _, group in groups or {} do
                    if group.name == "Complete" then
                        for _, option in group.option_ids do doneIDs[option] = true end
                        doneID = group.option_ids[1]
                    elseif group.name == "To-do" then openID = group.option_ids[1] end
                end
                if not doneID or not openID then
                    problem = omniwm.l10n("Check the Notion Status groups for this calendar.")
                    return
                end
            end

            local now = os.time()
            local today = os.date("%Y-%m-%d", now)
            -- Include adjacent UTC dates so timed tasks near local midnight are available.
            local filters = {
                { property = date, date = { on_or_after = os.date("!%Y-%m-%d", now - 86400) } },
                { property = date, date = { on_or_before = os.date("!%Y-%m-%d", now + 2 * 86400) } },
            }
            if type(view.filter) == "table" and next(view.filter) then table.insert(filters, view.filter) end
            local query = { page_size = 100, filter = { ["and"] = filters } }
            if type(view.sorts) == "table" and #view.sorts > 0 then query.sorts = view.sorts end
            local collected, cursors = {}, {}
            local function read(cursor)
                query.start_cursor = cursor
                send(id, "POST", "data_sources/" .. sourceID .. "/query", json.encode(query), function(data)
                    if type(data.results) ~= "table" then problem = omniwm.l10n("Invalid Notion response."); return end
                    for _, item in data.results do
                        local values = item.properties
                        local range = values and values[date] and values[date].date
                        if type(range) == "table" and localDay(range.start) == today then
                            local parts = {}
                            for _, span in values[title].title do table.insert(parts, span.plain_text or "") end
                            local name = table.concat(parts)
                            local status = values[progress].status
                            local statusID = type(status) == "table" and status.id
                            table.insert(collected, { id = item.id, property = progress, kind = kind,
                                title = if name ~= "" then name else omniwm.l10n("Untitled task"),
                                checked = values[progress].checkbox == true or doneIDs[statusID] == true,
                                doneID = doneID, openID = if statusID and not doneIDs[statusID] then statusID else openID })
                        end
                    end
                    if data.has_more then
                        local nextCursor = data.next_cursor
                        if type(nextCursor) ~= "string" or nextCursor == "" or cursors[nextCursor] then
                            problem = omniwm.l10n("Invalid Notion cursor."); return
                        end
                        cursors[nextCursor] = true
                        read(nextCursor)
                    else rows = collected end
                end)
            end
            read(nil)
        end)
    end

    -- Older or inaccessible view metadata can still resolve through a single-source database.
    local function readDatabase()
        send(id, "GET", "databases/" .. databaseID, nil, function(database)
            if type(database.data_sources) ~= "table" or #database.data_sources ~= 1 then
                problem = omniwm.l10n("Copy the link to a specific calendar view in Notion.")
                return
            end
            readSource(database.data_sources[1].id, {})
        end)
    end
    send(id, "GET", "views/" .. viewID, nil, function(view)
        if type(view.data_source_id) == "string" then readSource(view.data_source_id, view)
        else readDatabase() end
    end, function(result)
        if result.status == 404 or result.status == 400 then readDatabase(); return true end
        return false
    end)
end

local function refresh(id)
    if id ~= page then
        if request then request:cancel() end
        page, rows, request, problem = id, nil, nil, nil
    end
    if request or not id or id == "" then return end
    problem = nil
    local databaseID, viewID = id:match("^(%x+)/(%x+)$")
    if viewID then
        readCalendar(id, databaseID, viewID)
        return
    end
    local collected, cursors = {}, {}
    local function read(cursor)
        local path = id .. "/children?page_size=100"
        if cursor then
            local encoded = cursor:gsub("[^%w%-._~]", function(byte) return string.format("%%%02X", string.byte(byte)) end)
            path ..= "&start_cursor=" .. encoded
        end
        send(id, "GET", "blocks/" .. path, nil, function(data)
            if type(data) ~= "table" or type(data.results) ~= "table" then problem = omniwm.l10n("Invalid Notion response."); return end
            for _, block in data.results do
                if block.type == "to_do" and block.to_do and type(block.id) == "string" then
                    local parts = {}
                    for _, span in block.to_do.rich_text or {} do table.insert(parts, span.plain_text or "") end
                    local title = table.concat(parts)
                    table.insert(collected, { id = block.id, checked = block.to_do.checked == true,
                        title = if title == "" then omniwm.l10n("Untitled task") else title })
                end
            end
            if data.has_more then
                if type(data.next_cursor) ~= "string" or data.next_cursor == "" or cursors[data.next_cursor] then
                    problem = omniwm.l10n("Invalid Notion cursor."); return
                end
                cursors[data.next_cursor] = true
                read(data.next_cursor)
            else
                rows = collected
            end
        end)
    end
    read(nil)
end

function notion.toggle(ctx, task)
    if request or pageID(ctx) ~= page or not rows or not table.find(rows, task) then return end
    local checked = not task.checked
    problem = nil
    local path = "blocks/" .. task.id
    local changes = { to_do = { checked = checked } }
    if task.property then
        path = "pages/" .. task.id
        local value = if task.kind == "checkbox" then { checkbox = checked }
            else { status = { id = if checked then task.doneID else task.openID } }
        changes = { properties = { [task.property] = value } }
    end
    send(page, "PATCH", path, json.encode(changes), function()
        task.checked = checked
    end)
end

function notion.refresh(ctx)
    selectedPage = pageID(ctx)
    refresh(selectedPage)
end

function notion.start(ctx)
    notion.refresh(ctx)
    if poll then return end
    local function schedule()
        poll = omniwm.after(60, function()
            refresh(selectedPage)
            schedule()
        end)
    end
    schedule()
end

function notion.snapshot(ctx)
    local id = pageID(ctx)
    selectedPage = id
    if id == "" then return nil, omniwm.l10n("Set a checklist page and token in widget settings.") end
    if not id then return nil, omniwm.l10n("Paste the page link from Notion’s Share menu.") end
    if id ~= page then return nil, omniwm.l10n("Refresh to load your checklist.") end
    if rows and #rows == 0 and id:find("/", 1, true) and not problem then
        return rows, omniwm.l10n("No calendar tasks scheduled for today."), request ~= nil
    end
    return rows, problem or (if not rows then omniwm.l10n("Loading checklist…") else nil), request ~= nil
end

return notion
