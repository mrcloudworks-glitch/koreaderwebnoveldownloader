#!/usr/bin/env python3
"""Runs tests/test.lua under LuaJIT (via `pip install lupa`), then checks the EPUB."""
import os, sys, zipfile
import lupa.luajit21 as lupa

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute(open("tests/test.lua").read())

z = zipfile.ZipFile("tests/out.epub")
assert z.testzip() is None, "corrupt zip"
names = z.namelist()
assert names[0] == "mimetype" and z.read("mimetype") == b"application/epub+zip"
import xml.dom.minidom as md
for n in names:
    if n.endswith((".xhtml", ".opf", ".ncx", ".xml")):
        md.parseString(z.read(n))
ch = z.read("OEBPS/chapters/ch00001.xhtml").decode()
assert ch.index('<h1 class="chapter-title">') < ch.index("<p>")
os.remove("tests/out.epub")
print("python: epub container OK (%d entries)" % len(names))
