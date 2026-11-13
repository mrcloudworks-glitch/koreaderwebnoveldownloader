--[[--
Dependency-free EPUB 2 writer.

Files are streamed into a ZIP container (stored, no compression) as they are
added, so memory usage stays low even for novels with thousands of chapters.
@module epubwriter
]]

local bit = require("bit")
local H = require("htmlutil")

local band, bxor, rshift = bit.band, bit.bxor, bit.rshift

-- CRC-32 ---------------------------------------------------------------------

local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if band(c, 1) ~= 0 then
            c = bxor(rshift(c, 1), 0xEDB88320)
        else
            c = rshift(c, 1)
        end
    end
    crc_table[i] = c
end

local function crc32(s)
    local crc = 0xFFFFFFFF
    local byte = string.byte
    local len = #s
    local i = 1
    while i <= len do
        local j = math.min(i + 255, len)
        local bytes = { byte(s, i, j) }
        for k = 1, #bytes do
            crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, bytes[k]), 0xFF)])
        end
        i = j + 1
    end
    crc = bxor(crc, 0xFFFFFFFF)
    if crc < 0 then crc = crc + 4294967296 end
    return crc
end

local function u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
                       math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- ZIP ------------------------------------------------------------------------

local Zip = {}
Zip.__index = Zip

function Zip.open(path)
    local fh, err = io.open(path, "wb")
    if not fh then return nil, err end
    local t = os.date("*t")
    local self = setmetatable({
        fh = fh,
        offset = 0,
        entries = {},
        dos_time = t.hour * 2048 + t.min * 32 + math.floor(t.sec / 2),
        dos_date = (math.max(t.year, 1980) - 1980) * 512 + t.month * 32 + t.day,
    }, Zip)
    return self
end

function Zip:add(name, data)
    local crc = crc32(data)
    local header = table.concat({
        "PK\3\4", u16(20), u16(0x0800), u16(0), -- version, UTF-8 names, stored
        u16(self.dos_time), u16(self.dos_date),
        u32(crc), u32(#data), u32(#data),
        u16(#name), u16(0), name,
    })
    local ok, err = self.fh:write(header, data)
    if not ok then return nil, err end
    self.entries[#self.entries + 1] = { name = name, crc = crc, size = #data, offset = self.offset }
    self.offset = self.offset + #header + #data
    return true
end

function Zip:close()
    local cd = {}
    for _, e in ipairs(self.entries) do
        cd[#cd + 1] = table.concat({
            "PK\1\2", u16(20), u16(20), u16(0x0800), u16(0),
            u16(self.dos_time), u16(self.dos_date),
            u32(e.crc), u32(e.size), u32(e.size),
            u16(#e.name), u16(0), u16(0), u16(0), u16(0), u32(0),
            u32(e.offset), e.name,
        })
    end
    local cd_data = table.concat(cd)
    local n = #self.entries
    local ok, err = self.fh:write(cd_data, "PK\5\6", u16(0), u16(0), u16(n), u16(n),
                                  u32(#cd_data), u32(self.offset), u16(0))
    self.fh:close()
    self.fh = nil
    if not ok then return nil, err end
    return true
end

function Zip:abort()
    if self.fh then
        self.fh:close()
        self.fh = nil
    end
end

-- EPUB -----------------------------------------------------------------------

local STYLESHEET = [[
body {
  margin: 0 3%;
  line-height: 1.5;
}
h1.chapter-title {
  font-size: 1.7em;
  font-weight: bold;
  text-align: center;
  line-height: 1.25;
  margin: 1.2em 0 1.4em 0;
  page-break-before: always;
  page-break-after: avoid;
}
p {
  margin: 0 0 0.7em 0;
  text-indent: 1.2em;
  text-align: justify;
}
p.note {
  text-indent: 0;
  font-style: italic;
}
div.titlepage {
  text-align: center;
  margin-top: 15%;
}
div.titlepage h1 {
  font-size: 2em;
  font-weight: bold;
}
div.titlepage p {
  text-indent: 0;
  text-align: center;
}
div.titlepage p.description {
  text-align: justify;
  margin-top: 2em;
}
div.cover {
  text-align: center;
}
div.cover img {
  max-width: 100%;
  height: auto;
}
]]

local XHTML_HEAD = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="%s">
<head>
<meta http-equiv="Content-Type" content="application/xhtml+xml; charset=utf-8"/>
<title>%s</title>
<link rel="stylesheet" type="text/css" href="%sstyle.css"/>
</head>
<body>
]]

local Epub = {}
Epub.__index = Epub

--- Detects an image type from its magic bytes.
local function imageType(data)
    if not data or #data < 12 then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "jpg", "image/jpeg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png", "image/png" end
    if data:sub(1, 4) == "GIF8" then return "gif", "image/gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp", "image/webp" end
    return nil
end
Epub.imageType = imageType

--- Starts a new EPUB at `path`.
-- meta: { title, author, description, source, language, identifier }
function Epub.new(path, meta)
    local zip, err = Zip.open(path)
    if not zip then return nil, err end
    local self = setmetatable({
        path = path,
        zip = zip,
        meta = meta or {},
        chapters = {},
        lang = (meta and meta.language) or "en",
    }, Epub)
    -- The mimetype entry must come first and be stored uncompressed.
    local ok
    ok, err = zip:add("mimetype", "application/epub+zip")
    if ok then
        ok, err = zip:add("META-INF/container.xml", [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]])
    end
    if ok then ok, err = zip:add("OEBPS/style.css", STYLESHEET) end
    if not ok then
        zip:abort()
        return nil, err
    end
    return self
end

--- Sets the cover image (raw bytes). Returns false if the format is unknown.
function Epub:setCover(data)
    local ext, mime = imageType(data)
    if not ext then return false end
    local ok = self.zip:add("OEBPS/cover." .. ext, data)
    if not ok then return false end
    self.cover = { file = "cover." .. ext, mime = mime }
    return true
end

--- Adds a chapter. `paragraphs` is a list of plain-text paragraphs.
-- The chapter title is always rendered first, as a bold, larger heading.
function Epub:addChapter(title, paragraphs, is_note)
    local n = #self.chapters + 1
    local file = string.format("chapters/ch%05d.xhtml", n)
    local buf = {
        string.format(XHTML_HEAD, self.lang, H.escape(title), "../"),
        '<h1 class="chapter-title"><b>', H.escape(title), "</b></h1>\n",
    }
    local class = is_note and ' class="note"' or ""
    for _, p in ipairs(paragraphs) do
        buf[#buf + 1] = "<p" .. class .. ">" .. H.escape(p) .. "</p>\n"
    end
    buf[#buf + 1] = "</body>\n</html>\n"
    local ok, err = self.zip:add("OEBPS/" .. file, table.concat(buf))
    if not ok then return nil, err end
    self.chapters[n] = { title = title, file = file, id = string.format("ch%05d", n) }
    return true
end

function Epub:chapterCount()
    return #self.chapters
end

local function titlePage(self)
    local m = self.meta
    local buf = { string.format(XHTML_HEAD, self.lang, H.escape(m.title), "") }
    if self.cover then
        buf[#buf + 1] = '<div class="cover"><img src="' .. self.cover.file .. '" alt="Cover"/></div>\n'
    end
    buf[#buf + 1] = '<div class="titlepage">\n<h1>' .. H.escape(m.title) .. "</h1>\n"
    if m.author and m.author ~= "" then
        buf[#buf + 1] = "<p>" .. H.escape(m.author) .. "</p>\n"
    end
    if m.source and m.source ~= "" then
        buf[#buf + 1] = "<p>" .. H.escape(m.source) .. "</p>\n"
    end
    if m.description and m.description ~= "" then
        buf[#buf + 1] = '<p class="description">' .. H.escape(m.description) .. "</p>\n"
    end
    buf[#buf + 1] = "</div>\n</body>\n</html>\n"
    return table.concat(buf)
end

local function contentOpf(self)
    local m = self.meta
    local buf = {
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n',
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n',
        "    <dc:title>", H.escape(m.title), "</dc:title>\n",
        '    <dc:creator opf:role="aut">', H.escape(m.author ~= "" and m.author or "Unknown"), "</dc:creator>\n",
        "    <dc:language>", H.escape(self.lang), "</dc:language>\n",
        '    <dc:identifier id="bookid">', H.escape(m.identifier or m.source or m.title), "</dc:identifier>\n",
        "    <dc:date>", os.date("!%Y-%m-%dT%H:%M:%SZ"), "</dc:date>\n",
    }
    if m.source and m.source ~= "" then
        buf[#buf + 1] = "    <dc:source>" .. H.escape(m.source) .. "</dc:source>\n"
    end
    if m.description and m.description ~= "" then
        buf[#buf + 1] = "    <dc:description>" .. H.escape(m.description) .. "</dc:description>\n"
    end
    if self.cover then
        buf[#buf + 1] = '    <meta name="cover" content="cover-image"/>\n'
    end
    buf[#buf + 1] = "  </metadata>\n  <manifest>\n"
    buf[#buf + 1] = '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
    buf[#buf + 1] = '    <item id="css" href="style.css" media-type="text/css"/>\n'
    buf[#buf + 1] = '    <item id="titlepage" href="title.xhtml" media-type="application/xhtml+xml"/>\n'
    if self.cover then
        buf[#buf + 1] = string.format('    <item id="cover-image" href="%s" media-type="%s"/>\n',
                                      self.cover.file, self.cover.mime)
    end
    for _, ch in ipairs(self.chapters) do
        buf[#buf + 1] = string.format('    <item id="%s" href="%s" media-type="application/xhtml+xml"/>\n',
                                      ch.id, ch.file)
    end
    buf[#buf + 1] = '  </manifest>\n  <spine toc="ncx">\n    <itemref idref="titlepage"/>\n'
    for _, ch in ipairs(self.chapters) do
        buf[#buf + 1] = string.format('    <itemref idref="%s"/>\n', ch.id)
    end
    buf[#buf + 1] = '  </spine>\n  <guide>\n    <reference type="title-page" title="Title page" href="title.xhtml"/>\n  </guide>\n</package>\n'
    return table.concat(buf)
end

local function tocNcx(self)
    local m = self.meta
    local buf = {
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n  <head>\n',
        '    <meta name="dtb:uid" content="', H.escape(m.identifier or m.source or m.title), '"/>\n',
        '    <meta name="dtb:depth" content="1"/>\n',
        '    <meta name="dtb:totalPageCount" content="0"/>\n',
        '    <meta name="dtb:maxPageNumber" content="0"/>\n',
        "  </head>\n  <docTitle><text>", H.escape(m.title), "</text></docTitle>\n  <navMap>\n",
    }
    for i, ch in ipairs(self.chapters) do
        buf[#buf + 1] = string.format(
            '    <navPoint id="nav%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/></navPoint>\n',
            i, i, H.escape(ch.title), ch.file)
    end
    buf[#buf + 1] = "  </navMap>\n</ncx>\n"
    return table.concat(buf)
end

--- Writes the book metadata/TOC and closes the file.
function Epub:finish()
    local zip = self.zip
    local ok, err = zip:add("OEBPS/title.xhtml", titlePage(self))
    if ok then ok, err = zip:add("OEBPS/toc.ncx", tocNcx(self)) end
    if ok then ok, err = zip:add("OEBPS/content.opf", contentOpf(self)) end
    if not ok then
        self:abort()
        return nil, err
    end
    return zip:close()
end

--- Discards the unfinished file.
function Epub:abort()
    self.zip:abort()
    os.remove(self.path)
end

return Epub
