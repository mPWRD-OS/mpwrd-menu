#!/usr/bin/env python3
from pathlib import Path
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: set-debian-version.py <version> <changelog>")

version = sys.argv[1]
changelog_path = Path(sys.argv[2])
text = changelog_path.read_text(encoding="utf-8")
pattern = re.compile(r"^(mpwrd-menu \()[^)]+(\).*)$", flags=re.MULTILINE)
if not pattern.search(text):
    raise SystemExit("failed to update debian/changelog version")
updated = pattern.sub(rf"\g<1>{version}\2", text, count=1)
changelog_path.write_text(updated, encoding="utf-8")
