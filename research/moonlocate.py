# -*- coding: utf-8 -*-
"""
Verify the Moon+ spine/offset mapping WITHOUT relying on the .po numbers.

Two jobs:
  1) `locate` -- give a passage of text (e.g. copied from the device) and find where it
     sits in an EPUB: spine index, character offset, chapter title, and text-share %.
     This lets the user confirm "the .po said spine N offset M -- was it right?".
  2) `chapter` -- print what a given spine index actually is (title head + char count),
     to check the spine<->chapter relationship.

Usage:
    python moonlocate.py locate  <epub> --text "..."        [--clip N]
    python moonlocate.py chapter <epub> <spine-index>
    python moonlocate.py map     <epub> <spine-index>       # all indices whose head shows this number
"""
import os, re, sys, zipfile, posixpath
from lxml import etree

NS = {"opf": "http://www.idpf.org/2007/opf",
      "dc": "http://purl.org/dc/elements/1.1/",
      "cnt": "urn:oasis:names:tc:opendocument:xmlns:container"}


def load_epub(path):
    z = zipfile.ZipFile(path)
    cont = etree.fromstring(z.read("META-INF/container.xml"))
    opf_path = cont.find(".//cnt:rootfile", NS).get("full-path")
    opf_dir = posixpath.dirname(opf_path)
    opf = etree.fromstring(z.read(opf_path))
    t = opf.find(".//dc:title", NS)
    title = t.text if t is not None else os.path.basename(path)
    manifest = {i.get("id"): i.get("href")
                for i in opf.findall(".//opf:manifest/opf:item", NS)}
    spine = []
    for ref in opf.findall(".//opf:spine/opf:itemref", NS):
        href = manifest.get(ref.get("idref"))
        if not href:
            continue
        full = posixpath.normpath(posixpath.join(opf_dir, href)) if opf_dir else href
        try:
            text = "".join(etree.fromstring(z.read(full)).itertext())
        except Exception:
            text = ""
        spine.append({"href": full, "text": text})
    z.close()
    return {"title": title, "spine": spine,
            "total_chars": sum(len(s["text"]) for s in spine)}


def norm(s):
    """Whitespace-insensitive form plus a char->original index map."""
    out, idx = [], []
    for i, ch in enumerate(s):
        if ch.isspace():
            continue
        out.append(ch)
        idx.append(i)
    return "".join(out), idx


def locate(book, needle, clip=60):
    n, _ = norm(needle)
    if not n:
        return None
    spine = book["spine"]
    # build normalized spine texts once
    for i, item in enumerate(spine):
        nt, idx = norm(item["text"])
        pos = nt.find(n)
        if pos >= 0:
            off = idx[pos]
            prefix = sum(len(s["text"]) for s in spine[:i])
            head = "".join(item["text"].split())[:44]
            return {
                "spine": i, "offset": off, "chapter_head": head,
                "chapter_chars": len(item["text"]),
                "href": item["href"],
                "pct": 100.0 * (prefix + off) / book["total_chars"],
                "snippet": item["text"][max(0, off - clip):off + len(needle) + clip],
            }
    return None


def chapter_report(book, i):
    spine = book["spine"]
    if not (0 <= i < len(spine)):
        return "spine index %d out of range (book has %d)" % (i, len(spine))
    item = spine[i]
    prefix = sum(len(s["text"]) for s in spine[:i])
    head = "".join(item["text"].split())[:60]
    return ("spine[%d] = %s\n  chars=%d  starts at %d (%.2f%% of book)\n  head: %s"
            % (i, item["href"], len(item["text"]), prefix,
               100.0 * prefix / book["total_chars"], head))


def map_numbers(book, num):
    """Which spine indices have this chapter number at their head?"""
    hits = []
    for i, item in enumerate(book["spine"]):
        head = "".join(item["text"].split())[:30]
        if re.search(r"第\s*%d\s*[章回节]" % num, head):
            hits.append((i, head[:34]))
    return hits


def self_test():
    import io
    ok, fails = 0, []

    def check(c, label):
        nonlocal ok
        if c:
            ok += 1
        else:
            fails.append(label)

    buf = io.BytesIO()
    z = zipfile.ZipFile(buf, "w")
    z.writestr("META-INF/container.xml",
               '<?xml version="1.0"?><container version="1.0" '
               'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
               '<rootfile full-path="OEBPS/content.opf" '
               'media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr("OEBPS/content.opf",
               '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
               '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>'
               '<manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>'
               '<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest>'
               '<spine><itemref idref="a"/><itemref idref="b"/></spine></package>')
    z.writestr("OEBPS/a.xhtml", "<html><body><p>第1章 开端</p><p>" + "甲" * 98 + "</p></body></html>")
    z.writestr("OEBPS/b.xhtml", "<html><body><p>第2章 继续</p><p>" + "乙" * 298 + "</p></body></html>")
    z.close()
    tmp = os.path.join(os.environ.get("TEMP", "."), "ib-locate-selftest.epub")
    open(tmp, "wb").write(buf.getvalue())
    book = load_epub(tmp)
    check(len(book["spine"]) == 2, "spine count")
    r = locate(book, "乙乙乙乙乙")
    check(r is not None and r["spine"] == 1, "locate finds spine 1 (got %s)" % (r and r["spine"]))
    check(r and r["offset"] == 6, "offset lands on first 乙 (got %s)" % (r and r["offset"]))
    r2 = locate(book, "甲甲甲")
    check(r2 and r2["spine"] == 0, "locate finds spine 0")
    # whitespace-insensitive
    r3 = locate(book, "第2章   继续")
    check(r3 is not None and r3["spine"] == 1, "whitespace-insensitive locate")
    check(locate(book, "不存在的内容") is None, "absent text returns None")
    check("out of range" in chapter_report(book, 9), "chapter bounds")
    check(len(map_numbers(book, 2)) == 1 and map_numbers(book, 2)[0][0] == 1, "map_numbers")
    os.remove(tmp)
    print("self-test: %d passed, %d failed" % (ok, len(fails)))
    for f in fails:
        print("  FAIL:", f)
    return 1 if fails else 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd = argv[1]
    book = load_epub(argv[2])
    print("book: %s  (spine=%d, chars=%d)" % (book["title"], len(book["spine"]), book["total_chars"]))
    if cmd == "chapter":
        print(chapter_report(book, int(argv[3])))
    elif cmd == "map":
        for i, head in map_numbers(book, int(argv[3])):
            print("  spine[%d]  %s" % (i, head))
    elif cmd == "locate":
        if "--text" in argv:
            text = argv[argv.index("--text") + 1]
        elif "--text-file" in argv:
            text = open(argv[argv.index("--text-file") + 1], encoding="utf-8").read()
        else:
            print("need --text or --text-file")
            return 2
        clip = 60
        if "--clip" in argv:
            clip = int(argv[argv.index("--clip") + 1])
        r = locate(book, text.strip(), clip)
        if not r:
            print("!! passage NOT found in this EPUB (different edition?)")
            return 1
        print("spine[%d] = %s" % (r["spine"], r["href"]))
        print("  chapter head : %s" % r["chapter_head"])
        print("  chapter chars: %d" % r["chapter_chars"])
        print("  offset       : %d" % r["offset"])
        print("  text share   : %.2f%%" % r["pct"])
        print("  context      : ...%s..." % r["snippet"])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
