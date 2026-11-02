"""Checks the landing page's search and answer-engine basics before Pages deploys it.

Every JSON-LD block parses, the canonical URL, og:url and the sitemap agree,
every FAQPage question appears on the page, and llms.txt links the page.
"""
import json
import re
import sys
from pathlib import Path

site = Path(sys.argv[1] if len(sys.argv) > 1 else "site")
html = (site / "index.html").read_text(encoding="utf-8")
errors = []

def meta(pattern):
    m = re.search(pattern, html)
    return m.group(1) if m else None

canonical = meta(r'<link rel="canonical" href="([^"]+)"')
og_url = meta(r'<meta property="og:url" content="([^"]+)"')
title = meta(r"<title>([^<]+)</title>")
desc = meta(r'<meta name="description" content="([^"]+)"')

if not canonical:
    errors.append("no canonical link")
if canonical != og_url:
    errors.append(f"canonical {canonical} != og:url {og_url}")
if not title or len(title) > 70:
    errors.append(f"title missing or over 70 chars: {title!r}")
if not desc or len(desc) > 170:
    errors.append(f"description missing or over 170 chars ({len(desc or '')})")

for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
    try:
        data = json.loads(block)
    except json.JSONDecodeError as e:
        errors.append(f"JSON-LD does not parse: {e}")
        continue
    if data.get("@type") == "FAQPage":
        for q in data["mainEntity"]:
            if f"<summary>{q['name']}</summary>" not in html:
                errors.append(f"FAQPage question not on the page: {q['name']}")

sitemap = (site / "sitemap.xml").read_text(encoding="utf-8")
if f"<loc>{canonical}</loc>" not in sitemap:
    errors.append("canonical URL missing from sitemap.xml")
if canonical and canonical not in (site / "llms.txt").read_text(encoding="utf-8"):
    errors.append("llms.txt does not link the canonical URL")

for e in errors:
    print(f"::error::{e}")
sys.exit(1 if errors else 0)
