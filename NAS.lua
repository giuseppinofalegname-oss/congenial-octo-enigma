---@diagnostic disable: undefined-global

local index = {}
local defaultAudioPath = "audio_nr/"

local function loadFiles(path)
    if not path then path = "disk*/*"
    else path = path .. "/*" end
    for _, filepath in ipairs(fs.find(path)) do
        if fs.isDir(filepath) then loadFiles(filepath)
        else index[fs.combine(defaultAudioPath, fs.getName(filepath))] = filepath end
    end
end

local function rebuild()
    index = {}
    loadFiles()
end

local function chunked(filename)
    local parts = {}
    local prefix = filename .. ".part"
    local prefixLen = #prefix

    for name, path in pairs(index) do
        if name:sub(1, prefixLen) == prefix then
            local num = tonumber(name:sub(prefixLen + 1))
            if num then
                parts[#parts + 1] = { num = num, path = path }
            end
        end
    end

    if #parts == 0 then return {} end

    table.sort(parts, function(a, b) return a.num < b.num end)

    local ordered = {}
    for i, entry in ipairs(parts) do
        ordered[i] = entry.path
    end
    return ordered
end

local function find(filename)
    if index[filename] then
        return index[filename], false
    end
    local parts = chunked(filename)
    if #parts > 0 then
        return parts, true
    end
    return nil, false
end

local function loadFile(filename)
    local data = {}
    local filepaths, isChunked = find(filename)
    local handler
    if not filepaths then
        handler = fs.open(filename, "rb")
        if handler then
            data = handler.readAll()
            handler.close()
            return data
        else
            goto loadFileEnd
        end
    end
    if not isChunked then
        handler = fs.open(filepaths, "rb")
        if handler then
            data = handler.readAll()
            handler.close()
            return data
        else
            goto loadFileEnd
        end
    end
    for _, value in ipairs(filepaths) do
        handler = fs.open(value, "rb")
        if handler then
            table.insert(data, handler.readAll())
            handler.close()
        end
    end
    ::loadFileEnd::
    return table.concat(data)
end

local function lines(filename, chunksize)
    local i = 0
    local data = loadFile(filename)
    local chunk
    return function ()
        chunk = data:sub((chunksize*i)+1, chunksize*(i+1))
        i = i + 1
        if chunk == "" then return nil end
        return chunk
    end
end

rebuild()

return {
    get = find,
    open = loadFile,
    lines = lines,
    refresh = rebuild,
    all = function ()
        return index
    end
}
