#!/usr/bin/env python3
"""Write the LuCI translation template (po/templates/wrthotspot.pot).

    scripts/i18n-scan.py

Collects _('...') / _("...") strings from the LuCI views and the menu titles,
like LuCI's build/i18n-scan.pl but without gettext tools. Translators copy the
template to po/<lang>/wrthotspot.po; luci.mk then builds a
luci-i18n-wrthotspot-<lang> package from it.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "feed/luci/luci-app-wrt-hotspot"
OUT = APP / "po/templates/wrthotspot.pot"

# _('text') or _("text"), with backslash escapes; not N_() / plural forms.
CALL = re.compile(r"""(?<![\w.])_\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")\s*[,)]""", re.S)


def unescape(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def po_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


strings = {}  # msgid -> [ "file:line" ]

for path in sorted((APP / "htdocs").rglob("*.js")):
    text = path.read_text(encoding="utf-8")
    for m in CALL.finditer(text):
        msgid = unescape(m.group(1) if m.group(1) is not None else m.group(2))
        line = text.count("\n", 0, m.start()) + 1
        strings.setdefault(msgid, []).append(f"{path.relative_to(APP).as_posix()}:{line}")

for path in sorted((APP / "root").rglob("*.json")):
    data = json.loads(path.read_text(encoding="utf-8"))
    for entry in data.values() if isinstance(data, dict) else []:
        if isinstance(entry, dict) and isinstance(entry.get("title"), str):
            strings.setdefault(entry["title"], []).append(path.relative_to(APP).as_posix())

lines = ['msgid ""', 'msgstr "Content-Type: text/plain; charset=UTF-8"', ""]
for msgid in sorted(strings, key=str.lower):
    if not msgid:
        continue
    lines.append("#: " + " ".join(strings[msgid][:4]))
    lines.append("msgid " + po_quote(msgid))
    lines.append('msgstr ""')
    lines.append("")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
print(f"{len(strings)} strings -> {OUT.relative_to(ROOT).as_posix()}")
