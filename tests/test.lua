-- Offline tests: parsers run against sample markup, HTTP is stubbed.
package.path = "webnoveldownloader.koplugin/?.lua;" .. package.path

local requests = {}
local responses = {}
package.loaded["httpclient"] = {
    request = function(url, opts)
        requests[#requests + 1] = { url = url, opts = opts or {} }
        local r = responses[url]
        if r then return r end
        return nil, "HTTP 404"
    end,
}
package.loaded["httpclient"].post = function(url, body, opts)
    opts = opts or {}
    opts.body = body
    return package.loaded["httpclient"].request(url, opts)
end

local H = require("htmlutil")
local Site = require("libread")
local Epub = require("epubwriter")

local function eq(a, b, what)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", what or "eq", tostring(b), tostring(a)), 2)
    end
end
local pad = string.rep("<!-- filler -->", 10)

-- htmlutil
eq(H.decodeEntities("a &amp; b &#8217; &#x201C;q&nbsp;&unknown;"), "a & b ’ “q &unknown;", "entities")
eq(H.escape('<a & "b">'), "&lt;a &amp; &quot;b&quot;&gt;", "escape")
eq(H.attr([[class="x y" href='/a/b' data-id=5]], "href"), "/a/b", "attr")
eq(H.attr([[data-href="/no" href="/yes"]], "href"), "/yes", "attr prefix")
eq(H.hasClass('class="txt2 m"', "txt"), false, "hasClass")
eq(H.innerOf("<div>a<div>b</div>c</div>d", "div", 5), "a<div>b</div>c", "innerOf")
local ps = H.paragraphs("<p>One &amp; two</p><script>bad()</script><p> <i>Three</i><br/>Four </p>\nFive<div>Six</div>")
eq(table.concat(ps, "|"), "One & two|Three|Four|Five|Six", "paragraphs")

-- catalog list
local list_html = pad .. [[
<div class="li-row"><div class="pic"><a href="/libread/first-novel-101"><img src="/a.jpg" alt="First Novel"></a></div>
 <div class="txt"><h3 class="tit"><a href="/libread/first-novel-101" title="First Novel">First Novel</a></h3>
 <a href="/libread/first-novel-101/chapter-9">Chapter 9</a></div></div>
<div class="li-row"><h3 class="tit"><a href="https://libread.com/libread/second-novel-202">Second &amp; Novel</a></h3></div>
<a href="/genre/Action">Action</a><a href="/sort/latest-release/2">2</a><a href="/sort/latest-release/3">3</a>
<a href="https://example.com/libread/evil-1">x</a>]]
local novels = Site.parseNovelList(list_html)
eq(#novels, 2, "novel count")
eq(novels[1].title, "First Novel", "novel 1 title")
eq(novels[1].url, "https://libread.com/libread/first-novel-101", "novel 1 url")
eq(novels[2].title, "Second & Novel", "novel 2 title")
eq(Site.findNextPage(list_html, "/sort/latest-release", 1), "https://libread.com/sort/latest-release/2", "next page")
eq(Site.findNextPage(list_html, "/sort/latest-release/2", 2), "https://libread.com/sort/latest-release/3", "next page 2")
eq(Site.findNextPage(list_html, "/sort/latest-release/3", 3), nil, "no next page")

-- fallback list parsing (no h3.tit)
local novels2 = Site.parseNovelList([[<a href="/libread/a-novel-5"><img alt="A Novel"></a>
<a href="/libread/a-novel-5">A Novel</a><a href="/libread/a-novel-5/chapter-1">c1</a><a href="/sort/latest-novel">s</a>]])
eq(#novels2, 1, "fallback count")
eq(novels2[1].title, "A Novel", "fallback title")

-- novel page + chapter API
local novel_url = "https://libread.com/libread/first-novel-101"
responses[novel_url] = pad .. [[<html><head><meta property="og:image" content="/files/cover.jpg">
<meta property="og:description" content="Short desc"></head><body>
<h1 class="tit">First Novel</h1><a href="/author/Jane+Doe">Jane Doe</a>
<div class="inner"><p>A long</p><p>description.</p></div>
<ul class="latest"><li><a href="/libread/first-novel-101/chapter-3">Chapter 3: C</a></li></ul>
<ul id="idData"><li><a href="/libread/first-novel-101/chapter-1" title="Chapter 1: A">Chapter 1: A</a></li>
<li><a href="/libread/first-novel-101/chapter-2">Chapter 2: B</a></li></ul></body></html>]]
responses["https://libread.com/api/chapterlist.php"] = [[<select>
<option value="\/libread\/first-novel-101\/chapter-1">Chapter 1: A</option>
<option value="\/libread\/first-novel-101\/chapter-2">Chapter 2: B</option>
<option value="\/libread\/first-novel-101\/chapter-3">Chapter 3: C</option></select>]]
local novel = assert(Site.fetchNovel(novel_url))
eq(novel.title, "First Novel", "title")
eq(novel.author, "Jane Doe", "author")
eq(novel.description, "A long description.", "description")
eq(novel.cover_url, "https://libread.com/files/cover.jpg", "cover")
eq(#novel.chapters, 3, "chapters via api")
eq(novel.chapters[3].url, novel_url .. "/chapter-3", "chapter url")
eq(requests[#requests].opts.body, "aid=101", "api body")

-- without the API: page list (idData), then whole-page fallback sorted by number
responses["https://libread.com/api/chapterlist.php"] = nil
eq(#assert(Site.fetchNovel(novel_url)).chapters, 2, "chapters via idData")
local p = Site.parseNovel([[<h1>T</h1><a href="/libread/t-7/chapter-10">Ch 10</a>
<a href="/libread/t-7/chapter-2">Ch 2</a><a href="/libread/t-7/chapter-10">Ch 10</a><a href="/libread/t-70/chapter-1">other</a>]],
    "https://libread.com/libread/t-7")
eq(#p.chapters, 2, "page fallback count")
eq(p.chapters[1].title, "Ch 2", "page fallback order")

-- chapter text
local chapter_html = [[<html><body><div class="m-read"><div class="top"><span class="chapter">Chapter 1: A</span></div>
<div class="txt" id="article"><h4>Chapter 1: A</h4><p>It was a <b>dark</b> &amp; stormy night.</p>
<div class="ads"><script>ads()</script><ins class="x"></ins></div>
<p>&ldquo;Hello,&rdquo; she said. 1 &lt; 2</p><p>&nbsp;</p><p>The end, and a rather long closing line to pass the size check.</p></div>
<div class="txt">short</div></div></body></html>]]
local paras = assert(Site.parseChapter(chapter_html, "Chapter 1: A"))
eq(#paras, 3, "paragraph count")
eq(paras[1], "It was a dark & stormy night.", "p1")
eq(paras[2], "“Hello,” she said. 1 < 2", "p2")
local br = assert(Site.parseChapter('<body><div id="chr-content">Line one of the text here.<br><br>Line two of the text is here, long enough to count as content.</div></body>', "X"))
eq(#br, 2, "br paragraphs")

-- epub
local epub = assert(Epub.new("tests/out.epub", { title = "First <Novel> & Co", author = "Jane", source = novel_url, description = "d" }))
assert(epub:setCover("\255\216\255\224" .. string.rep("x", 20)))
eq(epub:setCover("not an image at all"), false, "bad cover")
assert(epub:addChapter("Chapter 1: A & B", paras))
assert(epub:addChapter("Chapter 2 – ünïcödé", { "Text <with> markup & \1control" }))
assert(epub:finish())


-- main.lua smoke test with stubbed KOReader modules -----------------------------
local shown = {}
local function widget(kind)
    local W = { kind = kind }
    W.new = function(class, o) return setmetatable(o, { __index = class }) end
    W.extend = W.new
    return W
end
for _, m in ipairs({ "buttondialog", "confirmbox", "infomessage", "inputdialog", "menu", "multiinputdialog" }) do
    package.loaded["ui/widget/" .. m] = widget(m)
end
package.loaded["ui/widget/container/widgetcontainer"] = widget("container")
package.loaded["datastorage"] = { getDataDir = function() return "tests" end }
package.loaded["ui/network/manager"] = { runWhenOnline = function(_, f) f() end }
package.loaded["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
package.loaded["ui/trapper"] = {
    wrap = function(_, f) f() end, info = function() return true end,
    confirm = function() return true end, reset = function() end,
}
package.loaded["ui/uimanager"] = {
    show = function(_, w) shown[#shown + 1] = w end, close = function() end, forceRePaint = function() end,
}
package.loaded["ffi/util"] = {
    template = function(str, ...)
        local args = { ... }
        return (str:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
    usleep = function() end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        if path == "tests" then return "directory" end
        local fh = io.open(path, "rb")
        if fh then fh:close() return "file" end
    end,
}
package.loaded["logger"] = { warn = function() end, err = function() end }
package.loaded["gettext"] = function(str) return str end
package.loaded["apps/filemanager/filemanager"] = {}
local store = {}
G_reader_settings = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
}
local function size(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local n = fh:seek("end")
    fh:close()
    return n
end

local Plugin = dofile("webnoveldownloader.koplugin/main.lua")
local plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
plugin:init()
plugin.settings.download_dir = "tests"
plugin.settings.include_cover = false
local menu_items = {}
plugin:addToMainMenu(menu_items)
assert(#menu_items.webnoveldownloader.sub_item_table >= 5, "main menu")

responses["https://libread.com/api/chapterlist.php"] = nil
responses[novel_url .. "/chapter-1"] = chapter_html
-- chapter-2 is missing on purpose: it must become a placeholder, not abort the book
plugin:openNovel(novel_url)
local menu = shown[#shown]
eq(menu.kind, "menu", "novel screen")
eq(#menu.item_table, 3 + 2, "novel screen rows")

local target = "tests/First Novel.epub"
os.remove(target)
menu.item_table[1].callback() -- download all
eq(shown[#shown].kind, "confirmbox", "done dialog")
local full = assert(size(target), "epub was not written")
eq(size(target .. ".part"), nil, "temp file removed")

-- existing file + "ask": dialog offers overwrite / keep both / cancel
menu.item_table[1].callback()
local ask = shown[#shown]
eq(ask.kind, "buttondialog", "overwrite prompt")
eq(#ask.buttons, 3, "overwrite prompt buttons")
ask.buttons[2][1].callback() -- keep both
assert(size("tests/First Novel (2).epub"), "renamed copy missing")
os.remove("tests/First Novel (2).epub")

-- overwrite replaces the old file in place
local fh = io.open(target, "wb") fh:write("stale") fh:close()
menu.item_table[1].callback()
shown[#shown].buttons[1][1].callback() -- overwrite
eq(size(target), full, "overwritten in place")
fh = io.open(target, "wb") fh:write("stale") fh:close()
plugin.settings.overwrite_mode = "overwrite"
menu.item_table[1].callback()
eq(shown[#shown].kind, "confirmbox", "no prompt in always-overwrite mode")
eq(size(target), full, "always overwrite")
os.remove(target)

-- single chapter
menu.item_table[4].callback()
shown[#shown].buttons[1][1].callback()
local single = "tests/First Novel - Chapter 1 A.epub"
assert(size(single), "single chapter epub missing")
os.remove(single)

-- nothing downloadable: no file is left behind
responses[novel_url .. "/chapter-1"] = nil
menu.item_table[1].callback()
eq(size(target), nil, "failed download leaves no file")
eq(size(target .. ".part"), nil, "failed download leaves no temp file")

-- every plugin file must at least compile
for _, f in ipairs({ "main", "_meta", "httpclient", "libread", "htmlutil", "epubwriter" }) do
    assert(loadfile("webnoveldownloader.koplugin/" .. f .. ".lua"))
end
print("lua: all tests passed")
