--[[--
Small HTML helpers built on Lua patterns (no external dependencies).
@module htmlutil
]]

local H = {}

local named_entities = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    ndash = "–", mdash = "—", hellip = "…", lsquo = "‘", rsquo = "’",
    ldquo = "“", rdquo = "”", copy = "©", reg = "®", trade = "™",
    laquo = "«", raquo = "»", middot = "·", bull = "•", deg = "°",
    eacute = "é", egrave = "è", agrave = "à", ccedil = "ç", uuml = "ü",
    ouml = "ö", auml = "ä", ntilde = "ñ", times = "×", zwnj = "", zwj = "",
    shy = "", ensp = " ", emsp = " ", thinsp = " ",
}

--- Encodes a Unicode code point as UTF-8.
function H.utf8char(cp)
    if not cp or cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return ""
    end
    local floor, char = math.floor, string.char
    if cp < 0x80 then
        return char(cp)
    elseif cp < 0x800 then
        return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40,
                0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

--- Decodes HTML entities to UTF-8 text.
function H.decodeEntities(s)
    if not s or not s:find("&", 1, true) then return s end
    s = s:gsub("&#[xX](%x+);", function(hex) return H.utf8char(tonumber(hex, 16)) end)
    s = s:gsub("&#(%d+);", function(dec) return H.utf8char(tonumber(dec)) end)
    s = s:gsub("&(%a%w*);", function(name)
        local r = named_entities[name]
        if r == nil then r = named_entities[name:lower()] end
        return r
    end)
    return s
end

--- Escapes text for use in XML/XHTML (also drops characters XML forbids).
function H.escape(s)
    s = tostring(s or "")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return s
end

function H.trim(s)
    s = (s or ""):gsub("\194\160", " ") -- nbsp
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Removes all tags, decodes entities and collapses whitespace.
function H.text(s)
    s = (s or ""):gsub("<[^>]*>", " ")
    s = H.decodeEntities(s)
    s = s:gsub("\194\160", " "):gsub("%s+", " ")
    return H.trim(s)
end

--- Returns the value of an attribute from the inside of a tag.
function H.attr(attrs, name)
    if not attrs then return nil end
    attrs = " " .. attrs
    local v = attrs:match("[%s\"']" .. name .. "%s*=%s*\"([^\"]*)\"")
        or attrs:match("[%s\"']" .. name .. "%s*=%s*'([^']*)'")
        or attrs:match("[%s\"']" .. name .. "%s*=%s*([^%s\"'>]+)")
    if v then return H.decodeEntities(v) end
end

--- True if the class attribute contains the given class name.
function H.hasClass(attrs, class)
    local v = H.attr(attrs, "class")
    if not v then return false end
    for word in v:gmatch("%S+") do
        if word == class then return true end
    end
    return false
end

--- Iterates over anchors: yields (attrs, inner_html).
function H.anchors(html)
    return html:gmatch("<[aA]%s([^>]*)>(.-)</[aA]>")
end

--- Returns the inner HTML of the element whose open tag ends at open_end.
function H.innerOf(html, tag, open_end)
    local depth, pos = 1, open_end + 1
    local pat = "<(/?)" .. tag .. "[%s>/]"
    while true do
        local s, e, slash = html:find(pat, pos)
        if not s then
            return html:sub(open_end + 1)
        end
        if slash == "/" then
            depth = depth - 1
            if depth == 0 then
                return html:sub(open_end + 1, s - 1)
            end
        else
            depth = depth + 1
        end
        pos = e
    end
end

--- Finds elements of `tag` whose attributes satisfy `pred`; returns the inner
-- HTML of the one containing the most data (or nil).
function H.findElement(html, tag, pred)
    local best
    local pos = 1
    local pat = "<" .. tag .. "([^>]*)>"
    while true do
        local s, e, attrs = html:find(pat, pos)
        if not s then break end
        -- make sure we matched "<div ...>" and not e.g. "<divider>"
        if (attrs == "" or attrs:find("^[%s/]")) and pred(attrs) then
            local inner = H.innerOf(html, tag, e)
            if not best or #inner > #best then best = inner end
        end
        pos = e + 1
    end
    return best
end

local block_tags = {
    p = true, br = true, div = true, h1 = true, h2 = true, h3 = true, h4 = true,
    h5 = true, h6 = true, li = true, tr = true, blockquote = true, hr = true,
    section = true, article = true, ul = true, ol = true, table = true,
}

--- Strips non-content elements (scripts, ads...) from a HTML fragment.
function H.stripJunk(html)
    html = html:gsub("<!%-%-.-%-%->", "")
    for _, tag in ipairs({ "script", "style", "noscript", "iframe", "ins", "select",
                           "button", "form", "svg" }) do
        html = html:gsub("<" .. tag .. "[%s>].-</" .. tag .. "%s*>", "")
    end
    return html
end

--- Converts a HTML fragment to a list of plain-text paragraphs.
function H.paragraphs(html)
    html = H.stripJunk(html)
    html = html:gsub("[\r\n]+", " ")
    html = html:gsub("<(/?)(%w+)([^>]*)>", function(_, name)
        if block_tags[name:lower()] then return "\n" end
        return ""
    end)
    local out = {}
    for line in html:gmatch("[^\n]+") do
        line = H.trim(H.decodeEntities(line):gsub("%s+", " "))
        if line ~= "" then
            out[#out + 1] = line
        end
    end
    return out
end

--- Undoes JSON/JavaScript string escaping (\" \/ \n \uXXXX) in markup that
-- was delivered inside a JSON value or a document.write() call.
function H.unescapeJs(s)
    if not s or not s:find("\\", 1, true) then return s end
    s = s:gsub("\\u(%x%x%x%x)", function(hex) return H.utf8char(tonumber(hex, 16)) end)
    s = s:gsub("\\([\"'/])", "%1")
    s = s:gsub("\\[nrt]", " ")
    return s
end

--- Percent-encodes a string for URLs / form bodies.
function H.urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        if c == " " then return "+" end
        return string.format("%%%02X", c:byte())
    end))
end

return H
