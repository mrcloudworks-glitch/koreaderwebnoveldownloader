--[[--
Minimal blocking HTTP client on top of KOReader's bundled LuaSocket/LuaSec.
@module httpclient
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local Http = {
    user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
    block_timeout = 20,
    total_timeout = 90,
    retries = 2,
}

local function once(url, opts)
    local sink = {}
    local headers = {
        ["User-Agent"] = Http.user_agent,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
        -- no Accept-Encoding: LuaSocket does not decompress gzip for us
    }
    if opts.referer then headers["Referer"] = opts.referer end
    local request = {
        url = url,
        method = opts.method or "GET",
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if opts.body then
        request.method = opts.method or "POST"
        headers["Content-Type"] = opts.content_type or "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(#opts.body)
        request.source = ltn12.source.string(opts.body)
    end

    socketutil:set_timeout(Http.block_timeout, Http.total_timeout)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return nil, tostring(code)
    end
    if type(code) ~= "number" then
        return nil, tostring(code or "network error")
    end
    local body = table.concat(sink)
    if code < 200 or code >= 300 then
        local err = "HTTP " .. tostring(status or code)
        if (code == 403 or code == 503) and body:find("[Cc]loudflare") then
            err = err .. " (blocked by the site's anti-bot protection)"
        end
        return nil, err, code
    end
    return body, nil, code, resp_headers
end

--- Performs a request. Returns body on success, or nil + error message.
-- opts: { method, body, content_type, referer, retries }
function Http.request(url, opts)
    opts = opts or {}
    local attempts = (opts.retries or Http.retries) + 1
    local body, err, code
    for attempt = 1, attempts do
        body, err, code = once(url, opts)
        if body then return body end
        logger.warn("WebNovelDownloader: request failed", url, err, "attempt", attempt)
        -- client errors won't get better by retrying
        if code and code >= 400 and code < 500 and code ~= 429 then break end
        if attempt < attempts then socket.sleep(1.5 * attempt) end
    end
    return nil, err
end

function Http.get(url, opts)
    return Http.request(url, opts)
end

function Http.post(url, body, opts)
    opts = opts or {}
    opts.body = body
    opts.method = "POST"
    return Http.request(url, opts)
end

return Http
