#!/usr/bin/env python3
"""Reports what the string catalogue still needs.

    python3 scripts/check-strings.py [Resources/Localization/Localizable.xcstrings]

Exits non-zero when a string the app uses has no translation in a supported
language, or a translation's format specifiers do not match the source, so it
can gate a release. Strings marked "shouldTranslate": false
(URLs, symbols, bare numbers) are skipped, and stale ones — no longer in the
source — are listed separately so they can be deleted.
"""
import json
import pathlib
import re
import sys

# Must match ContentLanguage in Sources/VibeScrollCore/ContentLanguage.swift.
LANGUAGES = ["tr"]

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                    else pathlib.Path(__file__).resolve().parent.parent
                    / "Resources/Localization/Localizable.xcstrings")
catalog = json.loads(path.read_text())

# `%@`, `%lld`, `%1$@`… — positions may move in a translation, but the set of
# arguments and their types may not: a `%@` where the code passes an integer
# reads garbage at runtime, and a dropped one silently loses a number.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaAF])")


def specifiers(text):
    found, implicit = [], 0
    for position, spec in SPECIFIER.findall(text.replace("%%", "")):
        if position:
            index = int(position)
        else:
            implicit += 1
            index = implicit
        found.append((index, spec))
    return sorted(found)


mismatched = []
missing, stale = {lang: [] for lang in LANGUAGES}, []
for key, entry in sorted(catalog["strings"].items()):
    if entry.get("extractionState") == "stale":
        stale.append(key)
        continue
    if entry.get("shouldTranslate") is False:
        continue
    for lang in LANGUAGES:
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value"):
            missing[lang].append(key)
        elif specifiers(unit["value"]) != specifiers(key):
            mismatched.append((lang, key, unit["value"]))

total = sum(len(v) for v in missing.values())
for lang, keys in missing.items():
    for key in keys:
        print(f"untranslated [{lang}]: {key!r}")
for key in stale:
    print(f"stale (no longer in source): {key!r}")
for lang, key, value in mismatched:
    print(f"format mismatch [{lang}]: {key!r} -> {value!r}")
print(f"{len(catalog['strings'])} strings, {total} untranslated, "
      f"{len(mismatched)} format mismatches, {len(stale)} stale")
sys.exit(1 if total or mismatched else 0)
