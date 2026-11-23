---@diagnostic disable: undefined-field, undefined-global

-- ComputerCraft / CC:Tweaked GitHub installer.
-- Downloads only changed files, creates parent directories and backs off
-- on transient failures / GitHub rate limits.

local json = require("json")

---------------- OPTIONS ----------------

local REPO_USER = "giuseppinofalegname-oss"
local REPO_NAME = "congenial-octo-enigma"
local BRANCH = "main"

local MAX_RETRIES = 5
local REQUEST_INTERVAL = 1       -- Minimum delay between HTTP requests.
local INITIAL_BACKOFF = 2        -- Retry delays: 2, 4, 8, 16, 32 seconds...
local MAX_BACKOFF = 60
local MANIFEST_FILE = ".install_manifest"

------------------------------------------

local API_BASE = "https://api.github.com/repos/" .. REPO_USER .. "/" .. REPO_NAME
local RAW_BASE = "https://raw.githubusercontent.com/" .. REPO_USER .. "/" .. REPO_NAME .. "/"

local hasMadeRequest = false

local function encodeURL(value, keepSlashes)
    local result = {}

    for i = 1, #value do
        local char = value:sub(i, i)
        local safe = char:match("^[%w%._~-]$") or (keepSlashes and char == "/")

        if safe then
            result[#result + 1] = char
        else
            result[#result + 1] = string.format("%%%02X", string.byte(char))
        end
    end

    return table.concat(result)
end

local function getHeader(headers, wanted)
    wanted = wanted:lower()

    for name, value in pairs(headers or {}) do
        if tostring(name):lower() == wanted then
            return tostring(value)
        end
    end

    return nil
end

local function retryDelay(attempt, headers, code, secondaryRateLimit)
    local retryAfter = tonumber(getHeader(headers, "Retry-After"))
    local delay = retryAfter or math.min(INITIAL_BACKOFF * (2 ^ attempt), MAX_BACKOFF)

    local resetAt = tonumber(getHeader(headers, "X-RateLimit-Reset"))
    if resetAt and os.epoch then
        local now = os.epoch("utc") / 1000
        delay = math.max(delay, resetAt - now + 1)
    elseif secondaryRateLimit and not retryAfter then
        -- GitHub asks clients to wait at least one minute for secondary limits.
        delay = math.max(delay, math.min(60 * (2 ^ attempt), 900))
    elseif code == 429 and not retryAfter then
        delay = math.max(delay, 60)
    end

    return math.max(1, delay)
end

-- Returns an open response on success, otherwise nil and an error string.
local function request(url, label, headers, binary)
    for attempt = 0, MAX_RETRIES do
        if hasMadeRequest then
            sleep(REQUEST_INTERVAL)
        end
        hasMadeRequest = true

        local ok, response, err, failedResponse = pcall(http.get, url, headers, binary)
        if not ok then
            err = response
            response = nil
            failedResponse = nil
        end

        -- CC:Tweaked may return the HTTP error response as the third result.
        local httpResponse = response or failedResponse
        if httpResponse then
            local code = httpResponse.getResponseCode()
            if code == 200 then
                return httpResponse
            end

            local responseHeaders = httpResponse.getResponseHeaders() or {}
            local retryAfter = tonumber(getHeader(responseHeaders, "Retry-After"))
            local resetAt = tonumber(getHeader(responseHeaders, "X-RateLimit-Reset"))
            local isRateLimited = getHeader(responseHeaders, "X-RateLimit-Remaining") == "0"

            local readOK, responseBody = pcall(httpResponse.readAll)
            if not readOK then responseBody = "" end
            local lowerBody = tostring(responseBody):lower()
            local secondaryRateLimit = lowerBody:find("secondary rate limit", 1, true) ~= nil
                or lowerBody:find("abuse detection", 1, true) ~= nil
            local canWaitForLimit = retryAfter ~= nil
                or (isRateLimited and resetAt ~= nil)
                or secondaryRateLimit
            local retryable = code == 408 or code == 429 or code == 500
                or code == 502 or code == 503 or code == 504
                or (code == 403 and canWaitForLimit)

            httpResponse.close()

            if not retryable then
                return nil, "HTTP " .. tostring(code)
            end

            if attempt >= MAX_RETRIES then
                return nil, "HTTP " .. tostring(code) .. " after retries"
            end

            local delay = retryDelay(attempt, responseHeaders, code, secondaryRateLimit)
            print(label .. " failed (HTTP " .. tostring(code) .. "). Retrying in "
                .. tostring(math.ceil(delay)) .. "s...")
            sleep(delay)
        else
            local errorText = tostring(err or "connection failed")
            local lowerError = errorText:lower()
            if errorText:find("404", 1, true) or lowerError:find("not found", 1, true) then
                return nil, errorText
            end

            if attempt >= MAX_RETRIES then
                return nil, errorText
            end

            local delay = math.min(INITIAL_BACKOFF * (2 ^ attempt), MAX_BACKOFF)
            print(label .. " failed (" .. tostring(err or "connection failed")
                .. "). Retrying in " .. tostring(delay) .. "s...")
            sleep(delay)
        end
    end

    return nil, "request failed"
end

local function readResponse(response)
    local ok, data = pcall(response.readAll)
    response.close()

    if not ok then
        return nil, tostring(data)
    end

    return data
end

local function decodeJSON(data, description)
    local ok, decoded = pcall(json.decode, data)
    if not ok or type(decoded) ~= "table" then
        return nil, "Invalid JSON while reading " .. description
    end

    return decoded
end

local function isSafePath(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    if path:sub(1, 1) == "/" or path:find("\\", 1, true) or path:find("\0", 1, true) then
        return false
    end

    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return false
        end
    end

    return true
end

local function loadManifest()
    if not fs.exists(MANIFEST_FILE) or fs.isDir(MANIFEST_FILE) then
        return {}
    end

    local handle = fs.open(MANIFEST_FILE, "r")
    if not handle then
        return {}
    end

    local contents = handle.readAll()
    handle.close()

    local ok, manifest = pcall(textutils.unserialize, contents)
    if ok and type(manifest) == "table" then
        return manifest
    end

    print("Warning: local manifest is invalid; all files will be checked again.")
    return {}
end

local function saveManifest(manifest)
    local temporary = MANIFEST_FILE .. ".tmp"
    local handle, err = fs.open(temporary, "w")

    if not handle then
        return false, "Cannot write manifest: " .. tostring(err)
    end

    local ok, writeErr = pcall(handle.write, textutils.serialize(manifest))
    handle.close()

    if not ok then
        fs.delete(temporary)
        return false, "Cannot write manifest: " .. tostring(writeErr)
    end

    if fs.exists(MANIFEST_FILE) then
        fs.delete(MANIFEST_FILE)
    end

    local moved, moveErr = pcall(fs.move, temporary, MANIFEST_FILE)
    if not moved then
        return false, "Cannot replace manifest: " .. tostring(moveErr)
    end

    return true
end

local function showProgress(index, total, filename, state)
    term.clear()
    term.setCursorPos(1, 1)
    local terminalWidth = term.getSize()
    term.write((state .. " " .. filename):sub(1, terminalWidth))

    local percent = math.floor((index / math.max(total, 1)) * 100)
    local width = 20
    local filled = math.floor((index / math.max(total, 1)) * width)

    term.setCursorPos(1, 2)
    term.write(string.format("%3d%% [%s%s] (%d/%d)", percent,
        string.rep("#", filled), string.rep("-", width - filled), index, total))
end

local function makeParentDirectories(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function downloadFile(entry, commitSHA)
    local url = RAW_BASE .. commitSHA .. "/" .. encodeURL(entry.path, true)
    local response, err = request(url, entry.path, nil, true)

    if not response then
        return false, err
    end

    local data, readErr = readResponse(response)
    if data == nil then
        return false, "Read failed: " .. tostring(readErr)
    end

    makeParentDirectories(entry.path)

    local handle, openErr = fs.open(entry.path, "wb")
    if not handle then
        return false, "Cannot create file: " .. tostring(openErr)
    end

    local ok, writeErr = pcall(handle.write, data)
    handle.close()

    if not ok then
        if fs.exists(entry.path) then
            fs.delete(entry.path)
        end
        return false, "Write failed: " .. tostring(writeErr)
    end

    return true
end

---------------- INSTALL -----------------

local function main()
    print("Getting latest commit...")

    local commitResponse, commitErr = request(
        API_BASE .. "/commits/" .. encodeURL(BRANCH, false),
        "Commit lookup",
        { ["Accept"] = "application/vnd.github+json" },
        false
    )

    if not commitResponse then
        print("Cannot get repository commit: " .. tostring(commitErr))
        return
    end

    local commitBody, commitReadErr = readResponse(commitResponse)
    if not commitBody then
        print("Cannot read commit response: " .. tostring(commitReadErr))
        return
    end

    local commitData, commitJSONErr = decodeJSON(commitBody, "commit response")
    if not commitData or type(commitData.sha) ~= "string"
        or type(commitData.commit) ~= "table"
        or type(commitData.commit.tree) ~= "table"
        or type(commitData.commit.tree.sha) ~= "string" then
        print(commitJSONErr or "Unexpected commit response from GitHub.")
        return
    end

    local commitSHA = commitData.sha
    local treeSHA = commitData.commit.tree.sha

    print("Getting repository file list...")

    local treeResponse, treeErr = request(
        API_BASE .. "/git/trees/" .. treeSHA .. "?recursive=1",
        "Repository tree lookup",
        { ["Accept"] = "application/vnd.github+json" },
        false
    )

    if not treeResponse then
        print("Cannot get repository tree: " .. tostring(treeErr))
        return
    end

    local treeBody, treeReadErr = readResponse(treeResponse)
    if not treeBody then
        print("Cannot read repository tree: " .. tostring(treeReadErr))
        return
    end

    local treeData, treeJSONErr = decodeJSON(treeBody, "repository tree")
    if not treeData or type(treeData.tree) ~= "table" then
        print(treeJSONErr or "Unexpected repository tree response from GitHub.")
        return
    end

    if treeData.truncated then
        print("Repository tree is too large for GitHub's recursive tree response.")
        print("No files were installed. The installer needs a paged/directory-based strategy.")
        return
    end

    local files = {}
    for _, entry in ipairs(treeData.tree) do
        -- Ignore directories, submodules, symlinks and unsafe paths.
        if entry.type == "blob" and entry.mode ~= "120000" and isSafePath(entry.path) then
            files[#files + 1] = entry
        end
    end

    table.sort(files, function(a, b)
        return a.path < b.path
    end)

    local oldManifest = loadManifest()
    local newManifest = {}
    local downloaded, skipped, failed = 0, 0, 0
    local failures = {}

    print("Found " .. #files .. " files. Starting install...")

    for index, entry in ipairs(files) do
        if oldManifest[entry.path] == entry.sha
            and fs.exists(entry.path)
            and not fs.isDir(entry.path) then
            newManifest[entry.path] = entry.sha
            skipped = skipped + 1
            showProgress(index, #files, entry.path, "Unchanged:")
        else
            showProgress(index, #files, entry.path, "Downloading:")

            local ok, err = downloadFile(entry, commitSHA)
            if ok then
                newManifest[entry.path] = entry.sha
                downloaded = downloaded + 1
            else
                failed = failed + 1
                failures[#failures + 1] = entry.path .. " - " .. tostring(err)
            end
        end
    end

    local manifestOK, manifestErr = saveManifest(newManifest)

    term.clear()
    term.setCursorPos(1, 1)
    print("Install finished.")
    print("Downloaded: " .. downloaded)
    print("Unchanged:  " .. skipped)
    print("Failed:     " .. failed)

    if not manifestOK then
        print("Manifest warning: " .. tostring(manifestErr))
    end

    if failed > 0 then
        print("\nFailed files:")
        for _, message in ipairs(failures) do
            print(message)
        end
        print("\nRun the installer again to retry failed files.")
    else
        print("All repository files are up to date.")
    end

    print("\nCommit: " .. commitSHA:sub(1, 7))

end

main()
