--[[--
Web novel downloader plugin for KOReader.

Browse the libread.com catalog, then download a single chapter, a range of
chapters or a whole novel as an EPUB file readable by KOReader.
@module koplugin.webnoveldownloader
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

local Epub = require("epubwriter")
local Site = require("libread")

local SETTINGS_KEY = "webnovel_downloader"

local WebNovelDownloader = WidgetContainer:extend{
    name = "webnoveldownloader",
    is_doc_only = false,
}

-- Settings -------------------------------------------------------------------

function WebNovelDownloader:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    if self.settings.overwrite_mode == nil then self.settings.overwrite_mode = "ask" end
    if self.settings.include_cover == nil then self.settings.include_cover = true end
    -- Older versions defaulted to 500 ms, which the site tends to answer with
    -- "403 Forbidden"; move those installs to the gentler default once.
    if self.settings.delay_ms == nil or (self.settings.delay_ms < 1500 and not self.settings.delay_migrated) then
        self.settings.delay_ms = 1500
    end
    self.settings.delay_migrated = true
    self.novel_cache = {}
    Site.sleep = function(seconds) ffiUtil.usleep(seconds * 1000000) end
    self.menus = {}
    self.ui.menu:registerToMainMenu(self)
end

function WebNovelDownloader:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function WebNovelDownloader:getDownloadDir()
    local dir = self.settings.download_dir
    if dir and lfs.attributes(dir, "mode") == "directory" then
        return dir
    end
    dir = G_reader_settings:readSetting("home_dir")
        or G_reader_settings:readSetting("lastdir")
    if dir and lfs.attributes(dir, "mode") == "directory" then
        return dir
    end
    return DataStorage:getDataDir()
end

-- Main menu ------------------------------------------------------------------

function WebNovelDownloader:addToMainMenu(menu_items)
    local overwrite_modes = {
        { "ask", _("Ask every time") },
        { "overwrite", _("Always overwrite") },
        { "rename", _("Never overwrite (save under a new name)") },
    }
    local overwrite_items = {}
    for _i, mode in ipairs(overwrite_modes) do
        overwrite_items[#overwrite_items + 1] = {
            text = mode[2],
            radio = true,
            checked_func = function() return self.settings.overwrite_mode == mode[1] end,
            callback = function()
                self.settings.overwrite_mode = mode[1]
                self:saveSettings()
            end,
        }
    end

    menu_items.webnoveldownloader = {
        text = _("Web novel downloader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Browse LibRead catalog"),
                callback = function()
                    NetworkMgr:runWhenOnline(function() self:showHome() end)
                end,
            },
            {
                text = _("Open novel by URL"),
                callback = function() self:promptUrl() end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Download folder: %1"), self:getDownloadDir())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:chooseDownloadDir(touchmenu_instance)
                end,
            },
            {
                text = _("If the EPUB file already exists"),
                sub_item_table = overwrite_items,
            },
            {
                text = _("Include cover image"),
                checked_func = function() return self.settings.include_cover end,
                callback = function()
                    self.settings.include_cover = not self.settings.include_cover
                    self:saveSettings()
                end,
            },
            {
                text_func = function()
                    return T(_("Pause between chapters: %1 ms"), self.settings.delay_ms)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Pause between chapters"),
                        info_text = _("A short pause is kinder to the website and avoids being blocked."),
                        value = self.settings.delay_ms,
                        value_min = 0,
                        value_max = 10000,
                        value_step = 100,
                        value_hold_step = 500,
                        unit = "ms",
                        default_value = 1500,
                        callback = function(spin)
                            self.settings.delay_ms = spin.value
                            self:saveSettings()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

function WebNovelDownloader:chooseDownloadDir(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.settings.download_dir = path
            self:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }:chooseDir(self:getDownloadDir())
end

-- UI helpers -----------------------------------------------------------------

function WebNovelDownloader:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- Runs a blocking function while showing a "loading" message.
function WebNovelDownloader:withLoading(text, func)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, res, err = pcall(func)
    UIManager:close(msg)
    if not ok then
        logger.err("WebNovelDownloader:", res)
        return nil, tostring(res)
    end
    return res, err
end

--- Shows a full screen list. Items use { text, mandatory, callback }.
function WebNovelDownloader:showMenu(title, items)
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            if item.callback then item.callback() end
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            for i = #self.menus, 1, -1 do
                if self.menus[i] == menu then table.remove(self.menus, i) end
            end
        end,
    }
    table.insert(self.menus, menu)
    UIManager:show(menu)
    return menu
end

-- Catalog browsing -----------------------------------------------------------

function WebNovelDownloader:showHome()
    local items = {
        { text = _("Search…"), callback = function() self:promptSearch() end },
    }
    for _i, section in ipairs(Site.sections) do
        items[#items + 1] = {
            text = _(section.title),
            callback = function()
                self:showList(_(section.title), Site.absolute(section.path), 1)
            end,
        }
    end
    items[#items + 1] = { text = _("Genres"), callback = function() self:showGenres() end }
    items[#items + 1] = { text = _("Open novel by URL…"), callback = function() self:promptUrl() end }
    self:showMenu(T(_("%1 catalog"), Site.name), items)
end

function WebNovelDownloader:showGenres()
    local genres = self:withLoading(_("Loading genres…"), function()
        return Site.fetchGenres()
    end)
    if not genres then return end
    local items = {}
    for _i, genre in ipairs(genres) do
        items[#items + 1] = {
            text = genre.title,
            callback = function() self:showList(genre.title, genre.url, 1) end,
        }
    end
    self:showMenu(_("Genres"), items)
end

function WebNovelDownloader:novelItems(list)
    local items = {}
    for _i, novel in ipairs(list) do
        items[#items + 1] = {
            text = novel.title,
            callback = function() self:openNovel(novel.url) end,
        }
    end
    return items
end

function WebNovelDownloader:showList(title, url, page)
    local result, err = self:withLoading(_("Loading catalog…"), function()
        return Site.fetchList(url, page)
    end)
    if not result then
        self:notify(T(_("Could not load the catalog:\n%1"), err or _("unknown error")))
        return
    end
    if #result.items == 0 then
        self:notify(page > 1 and _("No more novels.") or _("No novels found on this page."))
        return
    end
    local items = self:novelItems(result.items)
    if result.next_url then
        items[#items + 1] = {
            text = T(_("Next page (%1) ▸"), page + 1),
            bold = true,
            callback = function() self:showList(title, result.next_url, page + 1) end,
        }
    end
    local menu_title = page > 1 and T(_("%1 – page %2"), title, page) or title
    self:showMenu(menu_title, items)
end

function WebNovelDownloader:promptSearch()
    local dialog
    local function doSearch()
        local query = dialog:getInputText()
        if not query or query:match("^%s*$") then return end
        UIManager:close(dialog)
        local result, err = self:withLoading(_("Searching…"), function()
            return Site.search(query)
        end)
        if not result then
            self:notify(T(_("Search failed:\n%1"), err or _("unknown error")))
        elseif #result.items == 0 then
            self:notify(_("No novels found."))
        else
            self:showMenu(T(_("Search: %1"), query), self:novelItems(result.items))
        end
    end
    dialog = InputDialog:new{
        title = T(_("Search %1"), Site.name),
        input_hint = _("Novel title"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = doSearch },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function WebNovelDownloader:promptUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("Open novel by URL"),
        input = Site.base_url .. "/",
        input_hint = Site.base_url .. "/libread/…",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Open"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText()
                    if not url or not Site.path(url) or Site.path(url) == "/" then
                        self:notify(T(_("Please enter the address of a novel on %1."), Site.base_url))
                        return
                    end
                    UIManager:close(dialog)
                    NetworkMgr:runWhenOnline(function() self:openNovel(url) end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Novel screen ---------------------------------------------------------------

function WebNovelDownloader:blockedAdvice()
    return _("The website is refusing requests from this device for now. This usually passes by itself: wait a while (from several minutes to a few hours) before trying again, and keep the pause between chapters at 1500 ms or more.")
end

function WebNovelDownloader:openNovel(url)
    -- Reuse the list loaded earlier in this session: fewer requests to the site.
    local novel, err = self.novel_cache[url], nil
    if not novel then
        novel, err = self:withLoading(_("Loading novel…"), function()
            return Site.fetchNovel(url)
        end)
        if novel then self.novel_cache[url] = novel end
    end
    if not novel then
        local text = T(_("Could not load the novel:\n%1"), err or _("unknown error"))
        if Site.isBlocked(err) then text = text .. "\n\n" .. self:blockedAdvice() end
        self:notify(text)
        return
    end
    local total = #novel.chapters
    local items = {
        {
            text = T(_("⇩ Download all chapters (%1)"), total),
            bold = true,
            callback = function() self:startDownload(novel, 1, total) end,
        },
        {
            text = _("⇩ Download a range of chapters…"),
            bold = true,
            callback = function() self:promptRange(novel) end,
        },
        {
            text = _("ⓘ About this novel"),
            bold = true,
            callback = function() self:showNovelInfo(novel) end,
        },
    }
    for i, chapter in ipairs(novel.chapters) do
        items[#items + 1] = {
            text = chapter.title,
            mandatory = tostring(i),
            callback = function() self:chapterActions(novel, i) end,
        }
    end
    self:showMenu(novel.title, items)
end

function WebNovelDownloader:showNovelInfo(novel)
    local lines = { novel.title }
    if novel.author ~= "" then lines[#lines + 1] = T(_("Author: %1"), novel.author) end
    lines[#lines + 1] = T(_("Chapters: %1"), #novel.chapters)
    if novel.chapters_guessed then
        lines[#lines + 1] = _("The site did not provide the full chapter list, so chapters were numbered up to the newest one. Their titles are read while downloading.")
    end
    lines[#lines + 1] = novel.url
    if novel.description ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = novel.description
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("About this novel"),
        text = table.concat(lines, "\n"),
    })
end

function WebNovelDownloader:chapterActions(novel, index)
    local total = #novel.chapters
    local dialog
    local function action(first, last)
        return function()
            UIManager:close(dialog)
            self:startDownload(novel, first, last)
        end
    end
    local buttons = {
        {{ text = _("Download this chapter only"), callback = action(index, index) }},
    }
    if index < total then
        buttons[#buttons + 1] = {{
            text = T(_("Download from here to the end (%1 chapters)"), total - index + 1),
            callback = action(index, total),
        }}
    end
    if index > 1 then
        buttons[#buttons + 1] = {{
            text = T(_("Download from the start to here (%1 chapters)"), index),
            callback = action(1, index),
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Download a range starting here…"),
        callback = function()
            UIManager:close(dialog)
            self:promptRange(novel, index)
        end,
    }}
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = novel.chapters[index].title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function WebNovelDownloader:promptRange(novel, first)
    local total = #novel.chapters
    local dialog
    dialog = MultiInputDialog:new{
        title = T(_("Download chapters (1 – %1)"), total),
        fields = {
            {
                description = _("First chapter"),
                text = tostring(first or 1),
                input_type = "number",
            },
            {
                description = _("Last chapter"),
                text = tostring(total),
                input_type = "number",
            },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Download"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local from, to = tonumber(fields[1]), tonumber(fields[2])
                    if not from or not to then
                        self:notify(_("Please enter chapter numbers."))
                        return
                    end
                    from, to = math.floor(from), math.floor(to)
                    if from > to then from, to = to, from end
                    from = math.max(1, from)
                    to = math.min(total, to)
                    if from > total then
                        self:notify(T(_("This novel only has %1 chapters."), total))
                        return
                    end
                    UIManager:close(dialog)
                    self:startDownload(novel, from, to)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Downloading ----------------------------------------------------------------

-- Seconds to wait before the single retry after the site refuses a request.
local BLOCK_WAIT = 30

local function safeFilename(name)
    name = name:gsub('[/\\:%*%?"<>|%c]', " "):gsub("%s+", " ")
    name = name:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #name > 120 then
        name = name:sub(1, 120):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", ""):gsub("%s+$", "")
    end
    if name == "" then name = "novel" end
    return name
end

local function fileExists(path)
    return lfs.attributes(path, "mode") ~= nil
end

function WebNovelDownloader:targetName(novel, first, last)
    local total = #novel.chapters
    local title = safeFilename(novel.title)
    if first == 1 and last == total then
        return title
    elseif first == last then
        return safeFilename(title .. " - " .. novel.chapters[first].title)
    end
    return string.format("%s (ch %d-%d)", title, first, last)
end

local function uniquePath(dir, name)
    local n = 2
    local path
    repeat
        path = string.format("%s/%s (%d).epub", dir, name, n)
        n = n + 1
    until not fileExists(path)
    return path
end

--- Decides where to save (handling existing files), then starts the download.
function WebNovelDownloader:startDownload(novel, first, last)
    local dir = self:getDownloadDir()
    local name = self:targetName(novel, first, last)
    local path = dir .. "/" .. name .. ".epub"

    local function go(target)
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
                self:download(novel, first, last, target)
            end)
        end)
    end

    if not fileExists(path) then
        return go(path)
    end
    if self.ui.document and self.ui.document.file == path then
        self:notify(_("This EPUB is currently open. Close the book before overwriting it."))
        return
    end

    local mode = self.settings.overwrite_mode
    if mode == "overwrite" then
        return go(path)
    elseif mode == "rename" then
        return go(uniquePath(dir, name))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(_("The file already exists:\n%1\n\nWhat do you want to do?"), path),
        buttons = {
            {{
                text = _("Overwrite existing EPUB"),
                callback = function()
                    UIManager:close(dialog)
                    go(path)
                end,
            }},
            {{
                text = _("Keep both (save under a new name)"),
                callback = function()
                    UIManager:close(dialog)
                    go(uniquePath(dir, name))
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- Downloads chapters first..last into an EPUB at `path`.
-- Must run inside Trapper:wrap().
function WebNovelDownloader:download(novel, first, last, path)
    local tmp_path = path .. ".part"
    local count = last - first + 1

    Trapper:info(_("Preparing EPUB…"))
    local epub, err = Epub.new(tmp_path, {
        title = novel.title,
        author = novel.author,
        description = novel.description,
        source = novel.url,
        identifier = novel.url,
        language = "en",
    })
    if not epub then
        Trapper:reset()
        self:notify(T(_("Could not create the file:\n%1\n%2"), tmp_path, tostring(err)))
        return
    end

    if self.settings.include_cover and novel.cover_url then
        local ok, data = pcall(Site.fetchCover, novel)
        if ok and data then epub:setCover(data) end
    end

    local failed = {}
    local blocked
    local cancelled = false
    local write_error
    for i = first, last do
        local chapter = novel.chapters[i]
        local done = i - first
        local go_on = Trapper:info(T(_("Downloading chapter %1 of %2\n%3\n\nTap the screen to stop."),
                                     done + 1, count, chapter.title))
        if not go_on then
            if Trapper:confirm(_("Stop downloading?"), _("Continue"), _("Stop")) then
                cancelled = true
                break
            end
            Trapper:info(T(_("Downloading chapter %1 of %2\n%3"), done + 1, count, chapter.title))
        end

        local ok, paragraphs, fetch_err, page_title = pcall(Site.fetchChapter, chapter, novel.url)
        if not ok then
            fetch_err, paragraphs = tostring(paragraphs), nil
        end
        if not paragraphs and Site.isBlocked(fetch_err) then
            -- The site is refusing us. Wait once and try again; if it still
            -- refuses, stop instead of sending more requests it will reject.
            Trapper:info(T(_("The website refused the request (%1).\nWaiting %2 seconds before one more try…"),
                           tostring(fetch_err), BLOCK_WAIT))
            ffiUtil.usleep(BLOCK_WAIT * 1000000)
            ok, paragraphs, fetch_err, page_title = pcall(Site.fetchChapter, chapter, novel.url)
            if not ok then
                fetch_err, paragraphs = tostring(paragraphs), nil
            end
            if not paragraphs and Site.isBlocked(fetch_err) then
                blocked = { error = tostring(fetch_err), index = i, title = chapter.title }
                break
            end
        end
        if paragraphs and page_title and chapter.title_guess then
            -- remember the real title read from the chapter page
            chapter.title = page_title
            chapter.title_guess = nil
        end
        local added, add_err
        if paragraphs then
            added, add_err = epub:addChapter(chapter.title, paragraphs)
        else
            logger.warn("WebNovelDownloader: chapter failed", chapter.url, fetch_err)
            failed[#failed + 1] = chapter.title
            if not failed.error then
                failed.error, failed.url = tostring(fetch_err), chapter.url
            end
            added, add_err = epub:addChapter(chapter.title, {
                T(_("This chapter could not be downloaded (%1)."), tostring(fetch_err)),
                chapter.url,
            }, true)
        end
        if not added then
            write_error = add_err or "write error"
            break
        end

        if i < last and self.settings.delay_ms > 0 then
            ffiUtil.usleep(self.settings.delay_ms * 1000)
        end
    end

    if write_error then
        epub:abort()
        Trapper:reset()
        self:notify(T(_("Could not write the EPUB (is the storage full?):\n%1"), tostring(write_error)))
        return
    end

    local saved = epub:chapterCount()
    if blocked then
        local text = T(_("Download stopped at chapter %1:\n%2\n\nError: %3\n\n%4"),
                       blocked.index, blocked.title, blocked.error, self:blockedAdvice())
        if saved - #failed <= 0 then
            epub:abort()
            Trapper:reset()
            self:notify(text)
            return
        end
        local keep = Trapper:confirm(
            text .. "\n\n" .. T(_("Save the %1 chapter(s) downloaded so far? Later you can continue from chapter %2 (tap it in the list, then \"Download from here to the end\")."),
                                saved, blocked.index),
            _("Discard"), _("Save"))
        if not keep then
            epub:abort()
            Trapper:reset()
            return
        end
    end
    if cancelled then
        local keep = saved > 0 and Trapper:confirm(
            T(_("Download stopped.\nSave the %1 chapter(s) downloaded so far?"), saved),
            _("Discard"), _("Save"))
        if not keep then
            epub:abort()
            Trapper:reset()
            return
        end
    end
    if saved == #failed then
        epub:abort()
        Trapper:reset()
        self:notify(T(_("Download failed: no chapter could be downloaded.\n\nError: %1\nAddress: %2\n\nIf the error is a timeout or 403/503, check your connection or wait a while (the site may be blocking requests). A 404 means the chapter address is wrong."),
                      failed.error or _("unknown"), failed.url or ""))
        return
    end

    local ok
    ok, err = epub:finish()
    if ok then
        -- Replace an existing EPUB only once the new one is complete.
        if fileExists(path) then os.remove(path) end
        ok, err = os.rename(tmp_path, path)
    end
    if not ok then
        os.remove(tmp_path)
        Trapper:reset()
        self:notify(T(_("Could not save the EPUB:\n%1"), tostring(err)))
        return
    end
    Trapper:reset()

    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end

    local text = T(_("Saved %1 chapter(s) to:\n%2"), saved, path)
    if #failed > 0 then
        text = text .. "\n\n" .. T(_("%1 chapter(s) could not be downloaded and contain a placeholder, e.g.:\n%2\n(%3)"),
                                   #failed, failed[1], failed.error or "")
    end
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Open it now?"),
        ok_text = _("Open"),
        cancel_text = _("Close"),
        ok_callback = function() self:openBook(path) end,
    })
end

function WebNovelDownloader:openBook(path)
    for i = #self.menus, 1, -1 do
        UIManager:close(self.menus[i])
    end
    self.menus = {}
    if self.ui.document and self.ui.switchDocument then
        self.ui:switchDocument(path)
    else
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end
end

return WebNovelDownloader
