# KOReader web novel downloader

A [KOReader](https://koreader.rocks) plugin that browses the
[libread.com](https://libread.com/) catalog and saves chapters as EPUB files
you can read directly in KOReader.

## Features

- Browse the catalog: latest releases, newest novels, completed novels, most
  popular, genres, and search. You can also open a novel by pasting its URL.
- Download a whole novel, a range of chapters, or a single chapter.
- Every chapter starts with its title as a bold, larger heading, and the EPUB
  has a table of contents, a title page and (optionally) the cover.
- If the EPUB already exists you can overwrite it, keep both, or cancel. The
  behaviour can be fixed in the settings (ask / always overwrite / never
  overwrite). The old file is only replaced once the new one is complete.
- A chapter that fails to download becomes a short placeholder instead of
  aborting the whole book, and you can stop a download and keep what you have.

## Install

1. Copy the `webnoveldownloader.koplugin` folder into KOReader's `plugins`
   folder on your device (for example `koreader/plugins/`).
2. Restart KOReader.
3. Open the top menu, go to the tools tab (wrench icon) and choose
   **Web novel downloader**.

## Use

1. **Browse LibRead catalog**, then pick a section, a genre, or search.
2. Tap a novel to load its chapter list.
3. Choose **Download all chapters** or **Download a range of chapters**, or
   tap a chapter to download just that one (or from there onwards).
4. When the download finishes, choose **Open** to start reading.

Settings in the same menu: download folder, what to do when the EPUB already
exists, whether to include the cover, and the pause between chapters.

## Files

| File | Purpose |
| --- | --- |
| `main.lua` | Menus, dialogs and the download flow |
| `libread.lua` | libread.com catalog, novel and chapter parsing |
| `epubwriter.lua` | EPUB writer (pure Lua, no extra libraries) |
| `httpclient.lua` | HTTP requests with retries |
| `htmlutil.lua` | HTML helpers |

## Tests

The tests run offline against sample markup, with KOReader's UI stubbed:

```
pip install lupa
python3 tests/run_tests.py
```

## Notes

- The site's markup can change. If a list or chapter comes up empty, the
  selectors in `libread.lua` are the place to adjust.
- Download only what you are allowed to, for personal reading, and keep the
  pause between chapters reasonable.
