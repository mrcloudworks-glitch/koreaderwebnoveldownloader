--[[--
libread.com site backend: catalog browsing, search, novel info, chapter text.

The parsers are deliberately tolerant (several fallbacks each) so that small
changes in the site's markup do not break the plugin.
@module libread
]]

local H = require("htmlutil")
local Http = require("httpclient")

local Site = {
    name = "LibRead",
    base_url = "https://libread.com",
    -- Catalog sections shown on the plugin's home screen.
    sections = {
        { title = "Latest releases", path = "/sort/latest-release" },
        { title = "Newest novels", path = "/sort/latest-novel" },
        { title = "Completed novels", path = "/sort/completed-novel" },
        { title = "Most popular", path = "/most-popular" },
    },
    fallback_genres = {
        "Action", "Adult", "Adventure", "Comedy", "Drama", "Eastern", "Ecchi", "Fantasy",
        "Game", "Gender Bender", "Harem", "Historical", "Horror", "Josei", "Martial Arts",
        "Mature", "Mecha", "Mystery", "Psychological", "Reincarnation", "Romance", "Sci-fi",
        "Seinen", "Shoujo", "Shounen", "Slice of Life", "Smut", "Sports", "Supernatural",
        "Tragedy", "Wuxia", "Xianxia", "Xuanhuan", "Yaoi",
    },
}

-- URL helpers ----------------------------------------------------------------

--- Makes a URL absolute (relative to the site root).
function Site.absolute(url)
    if not url or url == "" then return nil end
    url = H.trim(url):gsub("\\/", "/")
    if url:find("^https?://") then return url end
    if url:find("^//") then return "https:" .. url end
    if url:sub(1, 1) ~= "/" then url = "/" .. url end
    return Site.base_url .. url
end

--- Returns the path of a URL on this site (no host, query or fragment),
-- or nil for external links.
function Site.path(url)
    if not url then return nil end
    url = H.trim(url):gsub("\\/", "/")
    local host, path = url:match("^https?://([^/]+)(.*)$")
    if not host then
        host, path = url:match("^//([^/]+)(.*)$")
    end
    if host then
        if not host:lower():find("libread", 1, true) then return nil end
        url = path
    end
    if url:find("^%a[%w+.-]*:") or url:sub(1, 1) == "#" then return nil end -- javascript:, mailto:
    url = url:gsub("[?#].*$", "")
    if url == "" then url = "/" end
    if url:sub(1, 1) ~= "/" then url = "/" .. url end
    return url
end

local function novelKey(path)
    return (path:gsub("/+$", ""):gsub("%.html?$", ""))
end

local reserved = {
    sort = true, genre = true, genres = true, search = true, author = true, authors = true,
    api = true, static = true, user = true, login = true, register = true, tag = true,
    tags = true, ["most-popular"] = true, contact = true, privacy = true, terms = true,
}

--- True if the path looks like a novel page (e.g. /libread/some-novel-12345).
local function isNovelPath(path)
    local key = novelKey(path)
    local first, slug, rest = key:match("^/([^/]+)/([^/]+)(.*)$")
    if not first or rest ~= "" or reserved[first:lower()] then return false end
    if slug:lower():find("^chapter") then return false end
    return first == "libread" or first == "novel" or first == "book" or slug:find("%-%d+$") ~= nil
end

local function fetch(url, opts)
    local body, err = Http.request(url, opts)
    if not body then return nil, err end
    if #body < 64 then return nil, "empty response from server" end
    return body
end

-- Catalog --------------------------------------------------------------------

--- Extracts novels from a listing/search page.
function Site.parseNovelList(html)
    local results, index = {}, {}
    local function add(href, title)
        local path = Site.path(href)
        if not path then return end
        local key = novelKey(path)
        title = H.text(title)
        if index[key] then
            if index[key].title == "" and title ~= "" then index[key].title = title end
            return
        end
        local item = { title = title, url = Site.absolute(path) }
        index[key] = item
        results[#results + 1] = item
    end

    -- Preferred: <h3 class="tit"><a href="..." title="...">
    local pos = 1
    while true do
        local s, e, attrs = html:find("<h3([^>]*)>", pos)
        if not s then break end
        if H.hasClass(attrs, "tit") then
            local inner = H.innerOf(html, "h3", e)
            local a_attrs, a_inner = inner:match("<[aA]%s([^>]*)>(.-)</[aA]>")
            local href = H.attr(a_attrs, "href")
            if href and isNovelPath(Site.path(href) or "") then
                add(href, H.attr(a_attrs, "title") or a_inner)
            end
        end
        pos = e + 1
    end

    -- Fallback: any link that looks like a novel page.
    if #results == 0 then
        for attrs, inner in H.anchors(html) do
            local href = H.attr(attrs, "href")
            local path = href and Site.path(href)
            if path and isNovelPath(path) then
                local title = H.attr(attrs, "title")
                if not title or title == "" then title = H.text(inner) end
                if title == "" then
                    title = H.attr(inner:match("<img([^>]*)>") or "", "alt") or ""
                end
                add(href, title)
            end
        end
    end

    local out = {}
    for _, item in ipairs(results) do
        if item.title ~= "" then out[#out + 1] = item end
    end
    return out
end

--- Finds the URL of page `page + 1` of a listing, if the page links to it.
function Site.findNextPage(html, list_path, page)
    local want = page + 1
    local base = novelKey(list_path):gsub("/%d+$", "")
    for attrs in H.anchors(html) do
        local href = H.attr(attrs, "href")
        local path = href and Site.path(href)
        if path and path:sub(1, #base) == base then
            local rest = path:sub(#base + 1)
            local n = rest:match("^/(%d+)/?$") or rest:match("^/(%d+)%.html?$")
                or rest:match("^/page/(%d+)/?$") or rest:match("^[_-](%d+)%.html?$")
                or (href:match("[?&]page=(%d+)"))
            if tonumber(n) == want then
                return Site.absolute(href)
            end
        end
    end
    return nil
end

--- Loads one page of a catalog listing.
-- Returns { items = {...}, next_url = url|nil } or nil, err.
function Site.fetchList(url, page)
    page = page or 1
    local html, err = fetch(url)
    if not html then return nil, err end
    local items = Site.parseNovelList(html)
    local path = Site.path(url) or "/"
    local next_url = Site.findNextPage(html, path, page)
    if not next_url and #items >= 15 and not url:find("?", 1, true) then
        -- pagination links not found: guess the usual "<list>/<page>" scheme
        local base = novelKey(path):gsub("/%d+$", "")
        next_url = Site.absolute(base .. "/" .. (page + 1))
    end
    return { items = items, next_url = next_url }
end

--- Searches the catalog.
function Site.search(query)
    local html, err = Http.post(Site.base_url .. "/search", "searchkey=" .. H.urlencode(query),
                                { referer = Site.base_url .. "/" })
    if not html then return nil, err end
    return { items = Site.parseNovelList(html) }
end

--- Returns the genre list: { {title=, url=}, ... } (scraped, with a static fallback).
function Site.fetchGenres()
    local genres, seen = {}, {}
    local html = fetch(Site.base_url .. "/")
    if html then
        for attrs, inner in H.anchors(html) do
            local href = H.attr(attrs, "href")
            local path = href and Site.path(href)
            if path and path:find("^/genres?/[^/]+/?$") then
                local title = H.text(inner)
                if title == "" then title = H.attr(attrs, "title") or "" end
                if title ~= "" and not seen[path] then
                    seen[path] = true
                    genres[#genres + 1] = { title = title, url = Site.absolute(path) }
                end
            end
        end
    end
    if #genres == 0 then
        for _, name in ipairs(Site.fallback_genres) do
            genres[#genres + 1] = {
                title = name,
                url = Site.base_url .. "/genre/" .. name:gsub(" ", "+"),
            }
        end
    end
    return genres
end

-- Novel ----------------------------------------------------------------------

local function meta(html, name)
    for attrs in html:gmatch("<meta([^>]*)>") do
        if H.attr(attrs, "property") == name or H.attr(attrs, "name") == name then
            local content = H.attr(attrs, "content")
            if content and content ~= "" then return H.trim(content) end
        end
    end
end

local function chapterNumber(url)
    local n = url:match("/chapter[%-_](%d+)") or url:match("/(%d+)%.html?$") or url:match("/(%d+)/?$")
    return tonumber(n)
end

--- Extracts chapter links belonging to the novel at `novel_path`.
function Site.parseChapterLinks(html, novel_path)
    local base = novelKey(novel_path) .. "/"
    local list, seen = {}, {}
    for attrs, inner in H.anchors(html) do
        local href = H.attr(attrs, "href")
        local path = href and Site.path(href)
        if path and path:sub(1, #base) == base and #path > #base and not seen[path] then
            local title = H.attr(attrs, "title")
            if not title or H.trim(title) == "" then title = H.text(inner) end
            title = H.text(title)
            if title ~= "" then
                seen[path] = true
                list[#list + 1] = { title = title, url = Site.absolute(path) }
            end
        end
    end
    return list
end

--- Parses the <option value="url">title</option> list of the chapter API.
function Site.parseChapterOptions(html)
    local list, seen = {}, {}
    for attrs, inner in html:gmatch("<option([^>]*)>(.-)</option>") do
        local value = H.attr(attrs, "value")
        local path = value and Site.path(value)
        local title = H.text(inner)
        if path and path ~= "/" and title ~= "" and not seen[path] then
            seen[path] = true
            list[#list + 1] = { title = title, url = Site.absolute(path) }
        end
    end
    return list
end

local function sortByNumber(list)
    for i, ch in ipairs(list) do
        ch.number = chapterNumber(ch.url)
        ch.order = i
        if not ch.number then return list end
    end
    table.sort(list, function(a, b)
        if a.number ~= b.number then return a.number < b.number end
        return a.order < b.order
    end)
    return list
end

--- Parses a novel page (info only, no network access).
function Site.parseNovel(html, url)
    local novel = { url = url }
    local path = Site.path(url) or "/"

    local h1_attrs, h1 = html:match("<h1([^>]*)>(.-)</h1>")
    novel.title = h1 and H.text(h1) or ""
    if novel.title == "" then
        novel.title = meta(html, "og:title") or H.text(html:match("<title[^>]*>(.-)</title>") or "")
        novel.title = novel.title:gsub("%s*[|%-]%s*[Ll]ib[Rr]ead.*$", ""):gsub("%s+[Nn]ovel [Oo]nline.*$", "")
    end
    if novel.title == "" then novel.title = "Untitled novel" end
    local _ = h1_attrs

    local authors, seen = {}, {}
    for attrs, inner in H.anchors(html) do
        local href = H.attr(attrs, "href") or ""
        if href:find("/authors?/") then
            local name = H.text(inner)
            if name ~= "" and not seen[name] then
                seen[name] = true
                authors[#authors + 1] = name
            end
            if #authors >= 3 then break end
        end
    end
    novel.author = table.concat(authors, ", ")

    novel.cover_url = meta(html, "og:image")
    if not novel.cover_url then
        local pic = H.findElement(html, "div", function(a) return H.hasClass(a, "pic") end)
        local src = pic and H.attr(pic:match("<img([^>]*)>") or "", "src")
        novel.cover_url = src
    end
    novel.cover_url = Site.absolute(novel.cover_url)

    local desc = H.findElement(html, "div", function(a) return H.hasClass(a, "inner") end)
    if desc then
        novel.description = table.concat(H.paragraphs(desc), " ")
    end
    if not novel.description or novel.description == "" then
        novel.description = meta(html, "og:description") or meta(html, "description") or ""
    end
    if #novel.description > 3000 then
        novel.description = novel.description:sub(1, 3000):gsub("[\128-\191]*$", "") .. "…"
    end

    -- Chapter list embedded in the page.
    local chapters = {}
    local id_data = H.findElement(html, "ul", function(a) return H.attr(a, "id") == "idData" end)
    if id_data then
        chapters = Site.parseChapterLinks(id_data, path)
    end
    if #chapters == 0 then
        chapters = sortByNumber(Site.parseChapterLinks(html, path))
    end
    novel.chapters = chapters
    return novel
end

--- Loads a novel page and its complete chapter list.
function Site.fetchNovel(url)
    url = Site.absolute(url)
    local html, err = fetch(url)
    if not html then return nil, err end
    local novel = Site.parseNovel(html, url)

    -- The full chapter list is served by a small API keyed by the numeric id
    -- at the end of the novel slug; use it when it knows more chapters.
    local aid = novelKey(Site.path(url) or ""):match("(%d+)$")
    if aid then
        local api_html = Http.post(Site.base_url .. "/api/chapterlist.php", "aid=" .. aid,
                                   { referer = url, retries = 0 })
        if api_html then
            local list = Site.parseChapterOptions(api_html)
            if #list > #novel.chapters then
                novel.chapters = list
            end
        end
    end

    if #novel.chapters == 0 then
        return nil, "no chapters found on this page"
    end
    return novel
end

-- Chapter --------------------------------------------------------------------

local content_matchers = {
    function(a) return H.attr(a, "id") == "article" end,
    function(a) return H.hasClass(a, "txt") end,
    function(a)
        local id = H.attr(a, "id")
        return id == "chr-content" or id == "chapter-content" or id == "chaptercontent" or id == "content"
    end,
    function(a)
        return H.hasClass(a, "chapter-content") or H.hasClass(a, "chr-c") or H.hasClass(a, "m-read")
    end,
}

local function normalize(s)
    return (s:lower():gsub("[^%w]", ""))
end

--- Extracts the chapter text as a list of paragraphs.
function Site.parseChapter(html, title)
    local block
    for _, matcher in ipairs(content_matchers) do
        block = H.findElement(html, "div", matcher)
        if block and #H.text(block) > 80 then break end
        block = nil
    end
    if not block then
        block = html:match("<body[^>]*>(.*)</body>")
    end
    if not block then return nil, "chapter text not found" end

    local paragraphs = H.paragraphs(block)
    -- The title is rendered by the EPUB writer; drop a duplicate first line.
    if title and paragraphs[1] and #paragraphs > 1 then
        local a, b = normalize(paragraphs[1]), normalize(title)
        local dup = a ~= "" and (a == b
            or (#a > 8 and b:find(a, 1, true) ~= nil)
            or (#b > 8 and #a < #b + 20 and a:find(b, 1, true) ~= nil))
        if dup then
            table.remove(paragraphs, 1)
        end
    end
    if #paragraphs == 0 then return nil, "chapter is empty" end
    return paragraphs
end

--- Downloads a chapter. Returns the list of paragraphs or nil, err.
function Site.fetchChapter(chapter, referer)
    local html, err = fetch(chapter.url, { referer = referer })
    if not html then return nil, err end
    return Site.parseChapter(html, chapter.title)
end

--- Downloads the cover image bytes (or nil).
function Site.fetchCover(novel)
    if not novel.cover_url then return nil end
    return Http.request(novel.cover_url, { referer = novel.url, retries = 0 })
end

return Site
