#!/usr/bin/env python3
"""Gate: every <lib> referenced by project/Build.xml must exist or be allowlisted.

Why this exists
---------------
Build.xml selects a prebuilt LuaJIT static library per platform/arch. When one of
those files is absent the failure only shows up at *link* time, minutes into a
release build, as "LNK1181: cannot open input file" or an undefined-symbol storm.
This turns that into a two-second, explicit report.

Strictness
----------
* a selection that is missing and NOT covered by project/known-missing-libs.txt -> exit 1
* an allowlist entry whose file now exists (stale entry)                         -> exit 1

Usage
-----
    python tools/check_prebuilt_libs.py                   # strict, uses the allowlist
    python tools/check_prebuilt_libs.py --json
    python tools/check_prebuilt_libs.py --no-allowlist    # every gap is fatal
    python tools/check_prebuilt_libs.py --allow-missing   # report only, exit 0
    python tools/check_prebuilt_libs.py --prune-allowlist # drop entries whose file
                                                          # now exists, then check

Exit codes: 0 = ok, 1 = gap or stale allowlist entry, 2 = Build.xml unreadable.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_XML = os.path.join(ROOT, "project", "Build.xml")
ALLOWLIST = os.path.join(ROOT, "project", "known-missing-libs.txt")

PLACEHOLDERS = [
    ("${haxelib:linc_luajit}", ROOT.replace(os.sep, "/")),
    ("${haxelib:linc_luajit-rewriten}", ROOT.replace(os.sep, "/")),
]


def resolve(value: str) -> str:
    out = value
    for needle, replacement in PLACEHOLDERS:
        out = out.replace(needle, replacement)
    out = out.replace("\\", "/")
    if not os.path.isabs(out):
        out = os.path.join(ROOT, out.lstrip("/\\"))
    return os.path.normpath(out)


def load_allowlist(path: str):
    entries = []
    if not os.path.isfile(path):
        return entries
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if line:
                entries.append(line.replace("\\", "/"))
    return entries


def collect(path: str):
    rows = []
    for lib in ET.parse(path).getroot().iter("lib"):
        name = lib.get("name")
        if not name:
            continue
        rows.append({
            "name": name,
            "if": lib.get("if") or "",
            "unless": lib.get("unless") or "",
            "exists": os.path.isfile(resolve(name)),
        })
    return rows


def prune_allowlist(path: str, rows) -> list:
    """Drop entries whose file exists now; return the dropped entries.

    A CI run that just produced a missing archive would otherwise be failed by the
    stale-entry rule, which is meant to catch rot, not a job doing its work. Pruning
    in the collect job keeps the committed file honest instead.
    """
    if not os.path.isfile(path):
        return []
    present = [r["name"].replace("\\", "/") for r in rows if r["exists"]]
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    dropped, kept = [], []
    for raw in lines:
        entry = raw.split("#", 1)[0].strip().replace("\\", "/")
        if entry and any(entry in name for name in present):
            dropped.append(entry)
            continue
        kept.append(raw)
    if dropped:
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(kept)
    return dropped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--allow-missing", action="store_true")
    ap.add_argument("--no-allowlist", action="store_true")
    ap.add_argument("--prune-allowlist", action="store_true")
    ap.add_argument("--allowlist", default=ALLOWLIST)
    args = ap.parse_args()

    if not os.path.isfile(BUILD_XML):
        print("::error::Build.xml not found at " + BUILD_XML, file=sys.stderr)
        return 2

    rows = collect(BUILD_XML)

    if args.prune_allowlist:
        for entry in prune_allowlist(args.allowlist, rows):
            print("pruned allowlist entry (the file exists now): " + entry)

    missing = [r for r in rows if not r["exists"]]
    allow = [] if args.no_allowlist else load_allowlist(args.allowlist)

    def covered(name: str) -> bool:
        return any(entry in name.replace("\\", "/") for entry in allow)

    unlisted = [r for r in missing if not covered(r["name"])]
    stale = [e for e in allow if not any(e in r["name"].replace("\\", "/") for r in missing)]

    if args.json:
        print(json.dumps({
            "total": len(rows),
            "missing": [r["name"] for r in missing],
            "unlisted_missing": [r["name"] for r in unlisted],
            "stale_allowlist": stale,
        }, indent=2))
    else:
        print("Build.xml references %d prebuilt library selections" % len(rows))
        width = max((len(r["name"]) for r in rows), default=0)
        for r in rows:
            if r["exists"]:
                mark = "ok     "
            elif covered(r["name"]):
                mark = "known  "
            else:
                mark = "MISSING"
            cond = ""
            if r["if"]:
                cond += ' if="%s"' % r["if"]
            if r["unless"]:
                cond += ' unless="%s"' % r["unless"]
            print("  %s  %-*s  %s" % (mark, width, r["name"], cond))
        print("")
        print("  %d present, %d missing (%d of them allowlisted in project/known-missing-libs.txt)"
              % (len(rows) - len(missing), len(missing), len(missing) - len(unlisted)))
        for name in unlisted:
            print("::error::missing prebuilt library not in the allowlist: " + name["name"])
        for entry in stale:
            print("::error::stale allowlist entry (the file exists now): " + entry)
        if unlisted:
            print("")
            print("Build it with tools/build_luajit.sh <target> (see")
            print(".github/workflows/prebuilt-luajit.yml), or add it to")
            print("project/known-missing-libs.txt with a reason.")

    if args.allow_missing:
        return 0
    return 0 if (not unlisted and not stale) else 1


if __name__ == "__main__":
    sys.exit(main())
