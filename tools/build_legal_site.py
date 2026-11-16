#!/usr/bin/env python3
"""Render docs/legal/*.md into a static site the owner can upload anywhere.

WHY THIS EXISTS
---------------
`kLegalBaseUrl` points at `/privacy` and `/terms`, and both app stores require a
reachable privacy-policy URL. The documents were written and reviewed; the only
thing standing between them and a live URL was that they are Markdown and a host
serves HTML. This turns the owner's remaining task from "write, convert and host
a privacy policy" into "upload one directory".

Output is DIRECTORY-STYLE so the URLs the app already builds work unchanged:

    build/legal/index.html
    build/legal/privacy/index.html   -> served at /privacy
    build/legal/terms/index.html     -> served at /terms

GitHub Pages, Netlify, Cloudflare Pages and S3 static hosting all resolve
`/privacy` to `privacy/index.html` with no configuration and no build step.

NO DEPENDENCIES ON PURPOSE
--------------------------
A release artifact that needs `pip install` before it can be regenerated is one
more thing to go wrong at the worst moment. This uses only the standard library,
and renders exactly the Markdown subset these two documents use — headings,
bold, inline code, unordered and ordered lists, tables, rules, paragraphs and
links. Anything outside that subset raises rather than silently dropping text
from a legal document, which is the one failure mode that actually matters here.
"""

from __future__ import annotations

import html
import pathlib
import re
import os
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "legal"
OUT = ROOT / "build" / "legal"

# Brand assets. Pre-scaled from the canonical app art (`app/assets/qirsh/`) and
# committed, so this script stays standard-library-only: resizing at build time
# would mean a Pillow dependency for a file that never changes. Regenerate with
# tools/legal_site_assets/README.md if the app mark ever changes.
ASSETS = ROOT / "tools" / "legal_site_assets"
ASSET_FILES = (
    "qirsh-coin-gold.png",
    "qirsh-coin-blue.png",
    "apple-touch-icon.png",
    "favicon.png",
)

# Source document -> published path segment. The segments must match the paths
# `legal_urls.dart` builds; `test/core/legal_urls_test.dart` asserts they do.
PAGES = {
    "PRIVACY_POLICY.md": ("privacy", "Privacy Policy"),
    "TERMS.md": ("terms", "Terms of Use"),
}

# Cross-document links in the Markdown point at sibling files; on the site they
# must point at the published paths instead.
LINK_REWRITES = {
    "./PRIVACY_POLICY.md": "/privacy",
    "./TERMS.md": "/terms",
    "PRIVACY_POLICY.md": "/privacy",
    "TERMS.md": "/terms",
}

STYLE = """
/* Qirsh legal surface. Navy + gold, taken from the app's coin mark: deep navy
   ground, gold as the accent, blue for interaction. Dark is the designed
   default; light is a full peer, not an afterthought. */
:root {
  --bg: #f6f8fc; --bg-2: #eef2f9;
  --surface: #ffffff; --surface-2: #f9fbff;
  --border: #dde4f0; --border-soft: #e8edf6;
  --fg: #101725; --fg-soft: #38445c; --muted: #5f6c85;
  --gold: #a97b12; --gold-ink: #6d4d05;
  --blue: #1d5fc4; --blue-soft: #e8f0fd;
  --code-bg: #eef2f9; --code-fg: #24406e;
  --shadow: 0 1px 2px rgba(16,23,37,.05), 0 8px 24px -12px rgba(16,23,37,.18);
  --ring: 0 0 0 3px rgba(29,95,196,.35);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #060a14; --bg-2: #0a1020;
    --surface: #0d1526; --surface-2: #111b30;
    --border: #1e2c47; --border-soft: #17233a;
    --fg: #eaf0fb; --fg-soft: #c3cee2; --muted: #8b9ab6;
    --gold: #e8be5e; --gold-ink: #f2d290;
    --blue: #6ea8f5; --blue-soft: #12233f;
    --code-bg: #101c30; --code-fg: #9fc3f2;
    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 18px 40px -20px rgba(0,0,0,.75);
    --ring: 0 0 0 3px rgba(110,168,245,.45);
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--bg);
  /* Two faint pools of brand colour instead of a flat field. */
  background-image:
    radial-gradient(1100px 520px at 82% -12%, rgba(29,95,196,.10), transparent 60%),
    radial-gradient(760px 420px at 6% 0%, rgba(169,123,18,.08), transparent 62%);
  background-attachment: fixed;
  color: var(--fg);
  font: 16px/1.68 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        "Helvetica Neue", "Noto Naskh Arabic", Arial, sans-serif;
  font-feature-settings: "kern" 1;
  overflow-wrap: break-word;
}
:where(a, button, summary):focus-visible {
  outline: none; box-shadow: var(--ring); border-radius: 6px;
}

/* ── brand bar ─────────────────────────────────────────────────────────── */
.topbar {
  position: sticky; top: 0; z-index: 20;
  background: color-mix(in srgb, var(--bg) 82%, transparent);
  -webkit-backdrop-filter: saturate(180%) blur(14px);
  backdrop-filter: saturate(180%) blur(14px);
  border-bottom: 1px solid var(--border-soft);
}
@supports not (backdrop-filter: blur(1px)) { .topbar { background: var(--bg); } }
.topbar-in {
  max-width: 48rem; margin: 0 auto;
  padding: .6rem 1.1rem;
  display: flex; align-items: center; gap: .7rem;
}
.brand {
  display: inline-flex; align-items: center; gap: .6rem;
  text-decoration: none; color: inherit; min-height: 44px;
}
.brand img { width: 34px; height: 34px; display: block; flex: none; }
.brand-name {
  font-size: 1.06rem; font-weight: 700; letter-spacing: -.01em;
  line-height: 1.1;
}
.brand-ar {
  font-size: .95rem; color: var(--gold); font-weight: 600;
  margin-inline-start: .1rem;
}
.brand-sub {
  display: block; font-size: .7rem; font-weight: 600; letter-spacing: .09em;
  text-transform: uppercase; color: var(--muted); margin-top: .1rem;
}
.topnav { margin-inline-start: auto; display: flex; gap: .3rem; }
.topnav a {
  display: inline-flex; align-items: center; min-height: 40px;
  padding: 0 .7rem; border-radius: 8px;
  font-size: .88rem; font-weight: 600; text-decoration: none;
  color: var(--fg-soft);
}
.topnav a:hover { background: var(--surface-2); color: var(--fg); }
.topnav a[aria-current="page"] { color: var(--blue); background: var(--blue-soft); }

/* ── layout ────────────────────────────────────────────────────────────── */
main { max-width: 48rem; margin: 0 auto; padding: 1.6rem 1.1rem 4rem; }
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 16px;
  box-shadow: var(--shadow);
  padding: 1.6rem 1.3rem 1.9rem;
}

/* ── typography ────────────────────────────────────────────────────────── */
h1 {
  font-size: clamp(1.55rem, 5.2vw, 2.05rem); line-height: 1.2;
  letter-spacing: -.02em; margin: 0 0 .9rem; font-weight: 700;
}
h2 {
  font-size: clamp(1.12rem, 3.6vw, 1.3rem); line-height: 1.3;
  letter-spacing: -.01em; font-weight: 700;
  margin: 2.3rem 0 .7rem; padding-top: 1.3rem;
  border-top: 1px solid var(--border-soft);
}
.card > h2:first-of-type { border-top: 0; padding-top: 0; margin-top: 1.6rem; }
h3 {
  font-size: 1.02rem; font-weight: 650; margin: 1.7rem 0 .45rem;
  color: var(--fg);
}
h3::before {
  content: ""; display: inline-block; vertical-align: .12em;
  width: 3px; height: .82em; margin-inline-end: .5rem;
  background: var(--gold); border-radius: 2px;
}
h4 { font-size: .95rem; margin: 1.4rem 0 .4rem; color: var(--muted); }
p, li { margin: 0 0 .8rem; color: var(--fg-soft); }
li::marker { color: var(--gold); }
ul, ol { padding-inline-start: 1.25rem; margin: 0 0 .9rem; }
li { padding-inline-start: .15rem; }
strong { color: var(--fg); font-weight: 650; }
a { color: var(--blue); text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { text-decoration-thickness: 2px; }
hr { border: 0; border-top: 1px solid var(--border-soft); margin: 2rem 0; }
code {
  background: var(--code-bg); color: var(--code-fg);
  padding: .13em .38em; border-radius: 5px;
  font-size: .88em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  overflow-wrap: anywhere;
}

/* The "Last updated" line each document opens with. Purely presentational —
   if a document ever stops leading with it, this rule simply stops matching. */
.card > h1 + p {
  display: inline-block; margin-bottom: 1.5rem;
  padding: .3rem .7rem; border-radius: 999px;
  background: var(--blue-soft); border: 1px solid var(--border);
  font-size: .82rem; color: var(--muted);
}
.card > h1 + p strong { color: var(--fg-soft); font-weight: 600; }

/* ── tables ────────────────────────────────────────────────────────────── */
.tablewrap {
  overflow-x: auto; -webkit-overflow-scrolling: touch;
  margin: 0 0 1.3rem; border: 1px solid var(--border);
  border-radius: 11px; background: var(--surface-2);
}
table { border-collapse: collapse; width: 100%; font-size: .9rem; min-width: 20rem; }
th, td {
  text-align: start; padding: .62rem .8rem; vertical-align: top;
  border-bottom: 1px solid var(--border-soft);
}
thead th {
  font-weight: 650; font-size: .76rem; letter-spacing: .05em;
  text-transform: uppercase; color: var(--muted);
  background: color-mix(in srgb, var(--surface) 60%, var(--bg-2));
  white-space: nowrap; position: sticky; top: 0;
}
tbody tr:last-child td { border-bottom: 0; }
td { color: var(--fg-soft); }

/* ── landing page cards ────────────────────────────────────────────────── */
.lede { font-size: 1.02rem; color: var(--muted); margin: 0 0 1.6rem; max-width: 34rem; }
.doclist { display: grid; gap: .9rem; grid-template-columns: 1fr; }
@media (min-width: 34rem) { .doclist { grid-template-columns: 1fr 1fr; } }
.doccard {
  display: flex; flex-direction: column; gap: .35rem;
  padding: 1.15rem 1.1rem; border-radius: 14px;
  background: var(--surface); border: 1px solid var(--border);
  box-shadow: var(--shadow); text-decoration: none; color: inherit;
  transition: transform .18s ease, border-color .18s ease;
}
.doccard:hover { transform: translateY(-2px); border-color: var(--blue); }
.doccard h2 {
  margin: 0; padding: 0; border: 0; font-size: 1.06rem; color: var(--fg);
}
.doccard p { margin: 0; font-size: .89rem; color: var(--muted); }
.doccard .go {
  margin-top: .5rem; font-size: .83rem; font-weight: 650; color: var(--blue);
}
.stamp {
  font-size: .74rem; color: var(--muted);
  font-variant-numeric: tabular-nums;
}

/* ── footer ────────────────────────────────────────────────────────────── */
footer {
  max-width: 48rem; margin: 0 auto; padding: 1.5rem 1.1rem 3rem;
  border-top: 1px solid var(--border-soft); color: var(--muted); font-size: .85rem;
}
.footnav { display: flex; flex-wrap: wrap; gap: .3rem 1.1rem; margin-bottom: .7rem; }
.footnav a { font-weight: 600; text-decoration: none; }
.footnav a:hover { text-decoration: underline; }
.footmark { display: flex; align-items: center; gap: .5rem; }
.footmark img { width: 20px; height: 20px; opacity: .85; }

/* ── motion / a11y ─────────────────────────────────────────────────────── */
@media (prefers-reduced-motion: reduce) {
  * { animation: none !important; transition: none !important;
      scroll-behavior: auto !important; }
  .doccard:hover { transform: none; }
}
@media (prefers-contrast: more) {
  :root { --border: currentColor; }
}
.skip {
  position: absolute; left: -9999px; top: 0;
  background: var(--surface); color: var(--fg);
  padding: .7rem 1rem; border-radius: 0 0 8px 0; z-index: 40;
}
.skip:focus { left: 0; }

/* Very small phones: reclaim horizontal space. The brand subtitle is the first
   thing to go — at 320px it wraps to two lines and doubles the header height
   for text that is already implied by the nav next to it. */
@media (max-width: 23rem) {
  main { padding-inline: .7rem; }
  .card { padding: 1.2rem .95rem 1.5rem; border-radius: 14px; }
  .topbar-in { padding-inline: .7rem; gap: .5rem; }
  .brand-name { font-size: 1rem; }
  .brand-sub { display: none; }
  .brand img { width: 30px; height: 30px; }
  .topnav a { padding: 0 .55rem; font-size: .85rem; }
}
""".strip()


def inline(text: str) -> str:
    """Escape, then apply the inline Markdown these documents use."""
    out = html.escape(text, quote=False)
    # Code first: its contents must not then be read as bold or a link.
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)

    def link(m: re.Match) -> str:
        label, href = m.group(1), m.group(2)
        href = LINK_REWRITES.get(href, href)
        return f'<a href="{html.escape(href, quote=True)}">{label}</a>'

    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, out)


def render(md: str) -> str:
    """Render the Markdown subset used by docs/legal/. Unknown syntax raises."""
    # HTML comments are maintainer notes ("DEPLOYMENT NOTE — not part of the
    # published text"). They used to be escaped into visible paragraphs, so the
    # live policy showed its own to-do list.
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    # A placeholder in the published text is worse than a failed build.
    for marker in ("<CONTACT_EMAIL>", "[OWNER MUST CONFIRM", "<!--"):
        if marker in md:
            raise ValueError(f"unresolved placeholder in legal text: {marker}")
    lines = md.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()

        if not line.strip():
            i += 1
            continue

        # Horizontal rule. Checked before tables so `---|---` is not mistaken.
        if re.fullmatch(r"-{3,}", line.strip()):
            out.append("<hr>")
            i += 1
            continue

        heading = re.match(r"^(#{1,4})\s+(.*)$", line)
        if heading:
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            i += 1
            continue

        # Table: a header row, a separator row, then body rows.
        if line.lstrip().startswith("|"):
            if i + 1 >= len(lines) or not re.match(
                r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]
            ):
                raise ValueError(f"line {i+1}: table header without separator")

            def cells(row: str) -> list[str]:
                return [c.strip() for c in row.strip().strip("|").split("|")]

            head = cells(line)
            i += 2
            body: list[list[str]] = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                body.append(cells(lines[i]))
                i += 1
            parts = ["<div class=\"tablewrap\"><table><thead><tr>"]
            parts += [f"<th>{inline(c)}</th>" for c in head]
            parts.append("</tr></thead><tbody>")
            for row in body:
                parts.append("<tr>")
                parts += [f"<td>{inline(c)}</td>" for c in row]
                parts.append("</tr>")
            parts.append("</tbody></table></div>")
            out.append("".join(parts))
            continue

        # Unordered list.
        if re.match(r"^[-*]\s+", line):
            items = []
            while i < len(lines) and re.match(r"^[-*]\s+", lines[i].rstrip()):
                items.append(re.sub(r"^[-*]\s+", "", lines[i].rstrip()))
                i += 1
                # Continuation lines are indented under the bullet.
                while i < len(lines) and re.match(r"^\s{2,}\S", lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            out.append(
                "<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>"
            )
            continue

        # Ordered list.
        if re.match(r"^\d+\.\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\d+\.\s+", lines[i].rstrip()):
                items.append(re.sub(r"^\d+\.\s+", "", lines[i].rstrip()))
                i += 1
                while i < len(lines) and re.match(r"^\s{3,}\S", lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            out.append(
                "<ol>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ol>"
            )
            continue

        # Paragraph: consume until a blank line or the start of another block.
        para = [line]
        i += 1
        while i < len(lines):
            nxt = lines[i].rstrip()
            if not nxt.strip():
                break
            if re.match(r"^(#{1,4}\s|[-*]\s|\d+\.\s)", nxt) or nxt.lstrip().startswith(
                "|"
            ) or re.fullmatch(r"-{3,}", nxt.strip()):
                break
            para.append(nxt)
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>")

    return "\n".join(out)


def _mark(cls: str = "") -> str:
    """The coin mark, gold on dark and blue on light, as one <picture>.

    `<picture>` swaps the source without JavaScript and without downloading
    both files, so the mark matches the theme even with scripting disabled.
    """
    c = f' class="{cls}"' if cls else ""
    return (
        "<picture>"
        '<source srcset="/qirsh-coin-gold.png" media="(prefers-color-scheme: dark)">'
        f'<img src="/qirsh-coin-blue.png" alt="Qirsh" width="34" height="34"{c}>'
        "</picture>"
    )


def page(title: str, body: str, *, current: str = "", wrap: bool = True) -> str:
    """Shell every page shares: brand bar, content, footer.

    `current` is the path of the page being rendered, used only to mark the
    active nav item with aria-current.
    """

    def nav(href: str, label: str) -> str:
        cur = ' aria-current="page"' if href == current else ""
        return f'<a href="{href}"{cur}>{label}</a>'

    content = f'<article class="card">\n{body}\n</article>' if wrap else body
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(title)} — Qirsh</title>
<meta name="description" content="{html.escape(title)} for the Qirsh (قِرش) app.">
<meta name="robots" content="index, follow">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#060a14" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#f6f8fc" media="(prefers-color-scheme: light)">
<link rel="icon" href="/favicon.png" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>{STYLE}</style>
</head>
<body>
<a class="skip" href="#content">Skip to content</a>
<header class="topbar">
  <div class="topbar-in">
    <a class="brand" href="/">
      {_mark()}
      <span>
        <span class="brand-name">Qirsh <span class="brand-ar" lang="ar" dir="rtl">قِرش</span></span>
        <span class="brand-sub">Privacy &amp; Terms</span>
      </span>
    </a>
    <nav class="topnav" aria-label="Legal documents">
      {nav("/privacy", "Privacy")}
      {nav("/terms", "Terms")}
    </nav>
  </div>
</header>
<main id="content">
{content}
</main>
<footer>
  <nav class="footnav" aria-label="Footer">
    <a href="/">Legal home</a><a href="/privacy">Privacy Policy</a><a href="/terms">Terms of Use</a>
  </nav>
  <div class="footmark">
    {_mark()}
    <span>Qirsh <span lang="ar" dir="rtl">قِرش</span></span>
  </div>
</footer>
</body>
</html>
"""


def stamp(md: str) -> str:
    """The document's own 'Last updated' line, or '' if it has none.

    Read from the source rather than generated, so the landing page can never
    claim a date the document itself does not carry.
    """
    m = re.search(r"^\*\*Last updated:\s*([^*]+)\*\*\s*$", md, flags=re.M)
    return m.group(1).strip() if m else ""


def index_body(stamps: dict[str, str]) -> str:
    """Landing page. Descriptions are neutral routing text, not legal claims."""

    def card(href: str, title: str, blurb: str) -> str:
        when = stamps.get(href, "")
        dated = (
            f'<p class="stamp">Last updated {html.escape(when)}</p>' if when else ""
        )
        return f"""<a class="doccard" href="{href}">
<h2>{html.escape(title)}</h2>
<p>{html.escape(blurb)}</p>
{dated}
<span class="go" aria-hidden="true">Read &rarr;</span>
</a>"""

    return f"""<h1>Legal</h1>
<p class="lede">The documents below describe how Qirsh (<span lang="ar" dir="rtl">قِرش</span>)
handles your data and the terms under which it is offered.</p>
<div class="doclist">
{card("/privacy", "Privacy Policy", "What the app processes on your device, what is sent to the cloud, and how to delete your data.")}
{card("/terms", "Terms of Use", "The terms you agree to when using Qirsh, including accuracy, responsibilities and availability.")}
</div>"""


def emit_app_ads_txt(out_dir):
    """Write app-ads.txt into `out_dir` from ADMOB_PUBLISHER_ID.

    AdMob has required app-ads.txt verification for newly configured apps since
    January 2025; without it, serving to the app is restricted. The file must be
    plain text at the DOMAIN ROOT (https://qirsh.site/app-ads.txt), which is why
    it is emitted as a bare file rather than a page route.

    It needs the real AdMob publisher id, and a WRONG one is worse than none: it
    authorises the wrong seller to sell your inventory. So this writes the file
    only when ADMOB_PUBLISHER_ID is supplied, and otherwise says loudly that it
    skipped. It never writes a placeholder.

    Lives here and is imported by build_site.py rather than copied, for the same
    reason `render` is: TWO site builders exist, only build_site.py produces the
    tree that is actually deployed, and a second copy of this logic would be a
    second thing to forget. app-ads.txt shipped in build_legal_site.py alone for
    a while, which meant setting the publisher id wrote the file into a directory
    nothing deploys.

    Returns the filename if written, None if skipped. Raises ValueError if the
    publisher id is malformed.
    """
    publisher = os.environ.get("ADMOB_PUBLISHER_ID", "").strip()
    if not publisher:
        print(
            "note: ADMOB_PUBLISHER_ID not set — app-ads.txt NOT written.\n"
            "      AdMob restricts serving to newly configured apps without it.\n"
            "      Re-run with ADMOB_PUBLISHER_ID=pub-XXXXXXXXXXXXXXXX once the\n"
            "      AdMob account exists. A placeholder is worse than absence.",
            file=sys.stderr,
        )
        return None
    if not re.fullmatch(r"pub-\d{16}", publisher):
        raise ValueError(
            f"ADMOB_PUBLISHER_ID must look like pub-<16 digits>, "
            f"got a value of length {len(publisher)}"
        )
    (out_dir / "app-ads.txt").write_text(
        f"google.com, {publisher}, DIRECT, f08c47fec0942fa0\n",
        encoding="utf-8",
    )
    return "app-ads.txt"


def main() -> int:
    if not SRC.is_dir():
        print(f"error: {SRC} not found", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    stamps: dict[str, str] = {}

    for name, (segment, title) in PAGES.items():
        src = SRC / name
        if not src.is_file():
            print(f"error: {src} missing", file=sys.stderr)
            return 1
        md = src.read_text(encoding="utf-8")
        body = render(md)
        # A silently-empty legal page is worse than a build failure.
        if len(body) < 500:
            print(f"error: {name} rendered to {len(body)} bytes", file=sys.stderr)
            return 1
        stamps[f"/{segment}"] = stamp(md)
        dest = OUT / segment
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(
            page(title, body, current=f"/{segment}"), encoding="utf-8"
        )
        written.append(f"{segment}/index.html")

    # Landing page last: it reports each document's own 'Last updated' line.
    (OUT / "index.html").write_text(
        page("Legal", index_body(stamps), current="/", wrap=False), encoding="utf-8"
    )
    written.insert(0, "index.html")

    for asset in ASSET_FILES:
        srcfile = ASSETS / asset
        if not srcfile.is_file():
            print(f"error: brand asset {srcfile} missing", file=sys.stderr)
            return 1
        shutil.copyfile(srcfile, OUT / asset)
        written.append(asset)

    # ── app-ads.txt ─────────────────────────────────────────────────────────
    # Shared with build_site.py — see emit_app_ads_txt().
    try:
        name = emit_app_ads_txt(OUT)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if name:
        written.append(name)

    print(f"wrote {len(written)} files to {OUT}:")
    for w in written:
        print(f"  {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
