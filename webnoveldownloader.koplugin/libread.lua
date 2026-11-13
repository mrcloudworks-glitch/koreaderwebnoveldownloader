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

local function useLonger(novel, list)
    if list and #list > #novel.chapters then
        novel.chapters = list
        return true
    end
    return false
end

--- Parses a chapter-list API response (options and/or links, possibly
-- JSON-escaped).
function Site.parseChapterApi(body, novel_path)
    body = H.unescapeJs(body)
    local list = Site.parseChapterOptions(body)
    local links = Site.parseChapterLinks(body, novel_path)
    if #links > #list then list = links end
    return list
end

--- Candidate numeric ids of the novel: from the slug, then from the page.
local function novelIds(html, path)
    local ids, seen = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    add(novelKey(path):match("(%d+)$"))
    add(html:match("chapterlist%.php%?aid=(%d+)"))
    add(html:match("[%s\"'{,]aid[\"']?%s*[:=]%s*[\"']?(%d+)"))
    add(html:match("data%-aid%s*=%s*[\"']?(%d+)"))
    add(html:match("[%s\"'{,]bookid[\"']?%s*[:=]%s*[\"']?(%d+)"))
    add(html:match("[%s\"'{,]novelid[\"']?%s*[:=]%s*[\"']?(%d+)"))
    return ids
end

--- Asks the site's chapter-list API for the complete list.
local function fetchChapterApi(novel, html, path)
    local api = Site.base_url .. "/api/chapterlist.php"
    local opts = function()
        return { referer = novel.url, retries = 0, headers = { ["X-Requested-With"] = "XMLHttpRequest" } }
    end
    for _, aid in ipairs(novelIds(html, path)) do
        local body = Http.post(api, "aid=" .. aid, opts())
        if body and useLonger(novel, Site.parseChapterApi(body, path)) then return true end
        body = Http.request(api .. "?aid=" .. aid, opts())
        if body and useLonger(novel, Site.parseChapterApi(body, path)) then return true end
    end
    return false
end

--- Finds further pages of a paginated chapter index (…/2, …/2.html, ?page=2).
function Site.parseIndexPages(html, novel_path)
    local base = novelKey(novel_path)
    local pages, seen = {}, {}
    local function consider(value)
        local path = value and Site.path(value)
        if not path or path:sub(1, #base) ~= base then return end
        local rest = path:sub(#base + 1)
        local n = rest:match("^/(%d+)/?$") or rest:match("^/(%d+)%.html?$")
            or rest:match("^/page[/-](%d+)/?$") or rest:match("^[_-](%d+)%.html?$")
        if not n and rest:gsub("%.html?$", ""):gsub("/$", "") == "" then
            n = value:match("[?&]page=(%d+)")
        end
        n = tonumber(n)
        if n and n > 1 and n < 2000 and not seen[n] then
            seen[n] = true
            pages[#pages + 1] = { n = n, url = Site.absolute(value) }
        end
    end
    for attrs in html:gmatch("<option([^>]*)>") do consider(H.attr(attrs, "value")) end
    for attrs in H.anchors(html) do consider(H.attr(attrs, "href")) end
    table.sort(pages, function(x, y) return x.n < y.n end)
    return pages
end

--- Removes index-page links that were mistaken for chapters.
local function dropIndexPages(chapters, pages)
    if #pages == 0 then return chapters end
    local is_page = {}
    for _, pg in ipairs(pages) do is_page[novelKey(Site.path(pg.url) or "")] = true end
    local out = {}
    for _, ch in ipairs(chapters) do
        if not is_page[novelKey(Site.path(ch.url) or "")] then out[#out + 1] = ch end
    end
    return out
end

--- Walks a paginated chapter index and merges all pages.
local function fetchIndexPages(novel, html, path)
    local pages = Site.parseIndexPages(html, path)
    if #pages == 0 then return false end
    -- Only the first/last page may be linked: fill the gaps (same URL scheme).
    local last = pages[#pages]
    local have = {}
    for _, pg in ipairs(pages) do have[pg.n] = pg end
    local template = last.url
    local all, seen = {}, {}
    for _, ch in ipairs(dropIndexPages(novel.chapters, pages)) do
        seen[ch.url] = true
        all[#all + 1] = ch
    end
    for n = 2, last.n do
        local pg = have[n]
        local page_url = pg and pg.url
        if not page_url then
            local count
            page_url, count = template:gsub(tostring(last.n) .. "(%.?h?t?m?l?/?)$", tostring(n) .. "%1")
            if count == 0 then page_url = nil end
        end
        local page_html = page_url and Http.request(page_url, { referer = novel.url, retries = 1 })
        if page_html then
            local block = H.findElement(page_html, "ul", function(a) return H.attr(a, "id") == "idData" end)
            local list = dropIndexPages(Site.parseChapterLinks(block or page_html, path), pages)
            for _, ch in ipairs(list) do
                if not seen[ch.url] then
                    seen[ch.url] = true
                    all[#all + 1] = ch
                end
            end
        end
    end
    return useLonger(novel, sortByNumber(all))
end

--- Last resort: the page links to the newest chapter (say chapter-1500) but
-- lists fewer. When chapter addresses are plainly numbered, fill in the
-- missing ones; their real titles are read from the chapter pages later.
function Site.fillNumberedChapters(novel, html, path)
    local base = novelKey(path) .. "/"
    local prefix, numbered = nil, {}
    for _, ch in ipairs(novel.chapters) do
        local p = Site.path(ch.url) or ""
        local pre, n = p:match("^(.-chapter[%-_])(%d+)$")
        if not pre or (prefix and pre ~= prefix) then return false end
        prefix = pre
        numbered[tonumber(n)] = ch
    end
    if not prefix or prefix:sub(1, #base) ~= base then return false end
    local max = 0
    for n in pairs(numbered) do if n > max then max = n end end
    local plain = prefix:gsub("%p", "%%%0")
    for attrs in H.anchors(html) do
        local p = Site.path(H.attr(attrs, "href") or "")
        local n = p and tonumber(p:match("^" .. plain .. "(%d+)$"))
        if n and n > max then max = n end
    end
    if max <= #novel.chapters or max > 20000 then return false end
    local first = numbered[0] and 0 or 1
    local list = {}
    for n = first, max do
        list[#list + 1] = numbered[n] or {
            title = "Chapter " .. n,
            url = Site.absolute(prefix .. n),
            title_guess = true,
        }
    end
    novel.chapters = list
    novel.chapters_guessed = true
    return true
end

--- Loads a novel page and its complete chapter list.
function Site.fetchNovel(url)
    url = Site.absolute(url)
    local html, err = fetch(url)
    if not html then return nil, err end
    local novel = Site.parseNovel(html, url)
    local path = Site.path(url) or "/"

    -- The novel page only embeds the first chapters (40 at the time of
    -- writing). Try, in order: the site's chapter-list API, the paginated
    -- chapter index, and finally numbering up to the newest linked chapter.
    local ok = fetchChapterApi(novel, html, path)
    if not ok then ok = fetchIndexPages(novel, html, path) end
    if not ok then Site.fillNumberedChapters(novel, html, path) end

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

--- Reads the chapter title shown on a chapter page (or nil).
function Site.parseChapterTitle(html)
    local span = html:match("<span[^>]*class%s*=%s*[\"'][^\"']*chapter[^\"']*[\"'][^>]*>(.-)</span>")
    local title = span and H.text(span) or ""
    if title == "" then
        for _, tag in ipairs({ "h1", "h2", "h3", "h4" }) do
            for inner in html:gmatch("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">") do
                local t = H.text(inner)
                if t:lower():find("chapter", 1, true) and #t < 200 then
                    title = t
                    break
                end
            end
            if title ~= "" then break end
        end
    end
    if title ~= "" then return title end
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
    local title = chapter.title
    if chapter.title_guess then
        title = Site.parseChapterTitle(html) or title
    end
    local paragraphs
    paragraphs, err = Site.parseChapter(html, title)
    if not paragraphs then return nil, err end
    return paragraphs, nil, title
end

--- Downloads the cover image bytes (or nil).
function Site.fetchCover(novel)
    if not novel.cover_url then return nil end
    return Http.request(novel.cover_url, { referer = novel.url, retries = 0 })
end

return Site
