# -*- coding: utf-8 -*-
"""
Moon+ .po reader -- decode a `<book>.epub.po` progress file against the real EPUB.

Established mapping (see research report):
    <T>*<SPINE>@<B>#<OFF>[:<PCT>%]
      T     = leading number, identical across a batch of books (semantics unresolved)
      SPINE = 0-based EPUB spine index
      B     = unknown, 0 in every sample so far
      OFF   = character offset inside spine[SPINE]
      PCT   = overall book progress, = text share (chars before spine + OFF) / total chars

Usage:
    python moonpo.py <epub> <po-file> [--clip CHARS]
    python moonpo.py --self-test
"""
import os, re, sys, zipfile, posixpath
from lxml import etree

NS = {"opf": "http://www.idpf.org/2007/opf",
      "dc": "http://purl.org/dc/elements/1.1/",
      "cnt": "urn:oasis:names:tc:opendocument:xmlns:container"}
PO_RE = re.compile(r"^(\d+)\*(\d+)@(\d+)#(\d+)(?::([\d.]+)%)?$")


def load_epub(path):
    """Return {'title','spine':[{'href','text'}], 'total_chars'}."""
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
            root = etree.fromstring(z.read(full))
            text = "".join(root.itertext())
        except Exception:
            text = ""
        spine.append({"href": full, "text": text})
    z.close()
    return {"title": title, "spine": spine,
            "total_chars": sum(len(s["text"]) for s in spine)}


def parse_po(text):
    m = PO_RE.match(text.strip())
    if not m:
        raise ValueError("not a Moon+ .po progress string: %r" % text[:80])
    ts, spine, b, off, pct = m.groups()
    return {"ts": int(ts), "spine": int(spine), "b": int(b),
            "off": int(off), "pct": float(pct) if pct else None}


def resolve(book, rec, clip=90):
    """Map a parsed record to a concrete location + surrounding text."""
    spine = book["spine"]
    i = rec["spine"]
    out = {"ok": False, "reason": None}
    if not (0 <= i < len(spine)):
        out["reason"] = "spine index %d out of range (book has %d items)" % (i, len(spine))
        return out
    item = spine[i]
    text = item["text"]
    off = rec["off"]
    if off > len(text):
        out["reason"] = ("offset %d exceeds spine[%d] length %d -> record probably from a "
                         "different edition of the book" % (off, i, len(text)))
        out["ok"] = True   # index valid, offset inconsistent
    prefix = sum(len(s["text"]) for s in spine[:i])
    share = 100.0 * (prefix + min(off, len(text))) / book["total_chars"]
    out.update({
        "ok": True,
        "spine_href": item["href"],
        "chapter_chars": len(text),
        "chars_before": prefix,
        "pct_from_text": share,
        "pct_reported": rec["pct"],
        "before": text[max(0, off - clip):off],
        "at": text[off:off + clip],
        "chapter_head": "".join(text.split())[:40],
    })
    return out


def report(book, rec, clip=90):
    r = resolve(book, rec, clip)
    L = []
    L.append("book      : %s" % book["title"])
    L.append("spine     : %d items, %d chars total" % (len(book["spine"]), book["total_chars"]))
    L.append("po record : T=%d spine=%d b=%d off=%d pct=%s"
             % (rec["ts"], rec["spine"], rec["b"], rec["off"], rec["pct"]))
    if not r["ok"]:
        L.append("!! %s" % r["reason"])
        return "\n".join(L)
    L.append("location  : spine[%d] = %s" % (rec["spine"], r["spine_href"]))
    L.append("chapter   : %d chars, starts near %r" % (r["chapter_chars"], r["chapter_head"]))
    L.append("offset    : %d chars into the chapter" % rec["off"])
    if r["pct_reported"] is None:
        L.append("text share: %.2f%%  (no pct field in this record)" % r["pct_from_text"])
    else:
        L.append("text share: %.2f%%  (reported %.2f%%, delta %+.2f)"
                 % (r["pct_from_text"], r["pct_reported"],
                    r["pct_from_text"] - r["pct_reported"]))
    L.append("   ...%s[[[%s]]]%s..." % (r["before"], r["at"][:clip], ""))
    if r["reason"]:
        L.append("!! %s" % r["reason"])
    return "\n".join(L)


def self_test():
    """Offline test on a synthetic EPUB so the parser/structure is verified without devices."""
    import io
    ok = 0
    fail = []

    def check(cond, label):
        nonlocal ok
        if cond:
            ok += 1
        else:
            fail.append(label)

    # build a tiny EPUB in memory
    buf = io.BytesIO()
    z = zipfile.ZipFile(buf, "w")
    z.writestr("META-INF/container.xml",
               '<?xml version="1.0"?><container version="1.0" '
               'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
               '<rootfile full-path="OEBPS/content.opf" '
               'media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr("OEBPS/content.opf",
               '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
               'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
               '<dc:title>T</dc:title></metadata><manifest>'
               '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>'
               '<item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>'
               '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>')
    z.writestr("OEBPS/c1.xhtml", "<html><body><p>" + "a" * 100 + "</p></body></html>")
    z.writestr("OEBPS/c2.xhtml", "<html><body><p>" + "b" * 300 + "</p></body></html>")
    z.close()

    tmpdir = os.environ.get("TEMP", ".")
    tmp = os.path.join(tmpdir, "ib-selftest.epub")
    open(tmp, "wb").write(buf.getvalue())
    book = load_epub(tmp)
    check(len(book["spine"]) == 2, "spine has 2 items (got %d)" % len(book["spine"]))
    check(book["total_chars"] == 400, "total chars 400 (got %d)" % book["total_chars"])

    # parse
    rec = parse_po("1785683827794*1@0#150:100.0%")
    check(rec["spine"] == 1 and rec["off"] == 150 and rec["b"] == 0, "parse fields")
    # text share: 100 chars of c1 + 150 into c2 = 250/400 = 62.5%
    r = resolve(book, rec)
    check(r["ok"], "resolve ok")
    check(abs(r["pct_from_text"] - 62.5) < 1e-9,
          "text share 62.5%% (got %.4f)" % r["pct_from_text"])
    # out-of-range spine
    r2 = resolve(book, parse_po("1*9@0#0:0%"))
    check(not r2["ok"] and "out of range" in (r2["reason"] or ""), "out-of-range spine rejected")
    # offset beyond chapter
    r3 = resolve(book, parse_po("1*0@0#999:0%"))
    check(r3["ok"] and "different edition" in (r3["reason"] or ""), "overlong offset flagged")
    # malformed
    try:
        parse_po("garbage")
        check(False, "malformed rejected")
    except ValueError:
        check(True, "")
    # no-pct form is accepted
    check(parse_po("1*2@0#3")["pct"] is None, "pct optional")

    os.remove(tmp)
    print("self-test: %d passed, %d failed" % (ok, len(fail)))
    for f in fail:
        print("  FAIL:", f)
    return 1 if fail else 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) < 3:
        print(__doc__)
        return 2
    epub, po = argv[1], argv[2]
    clip = 90
    if "--clip" in argv:
        clip = int(argv[argv.index("--clip") + 1])
    raw = open(po, "rb").read().decode("utf-8", "replace").strip()
    print(report(load_epub(epub), parse_po(raw), clip))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
