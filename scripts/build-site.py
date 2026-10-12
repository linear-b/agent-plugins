#!/usr/bin/env python3
"""Build the GitHub Pages site: home, one page per plugin, changelog, Atom feed.

Usage: scripts/build-site.py [out_dir] [repo_root]   (defaults: _site, this repo)
Every plugins/<name>/ with a .claude-plugin/plugin.json gets a page from its README.md;
its CHANGELOG.md feeds the changelog. Standard library only.
"""
import html
import json
import re
import sys
from pathlib import Path

SITE_URL = "https://linear-b.github.io/agent-plugins/"
REPO_URL = "https://github.com/linear-b/agent-plugins"
MARKETPLACE = "linearb-ai"
# Diagrams: plugin READMEs hold ```mermaid blocks (GitHub renders them too); the site draws them hand-drawn.
MERMAID_JS = ("https://cdn.jsdelivr.net/npm/mermaid@12.1.0/dist/mermaid.min.js",
              "sha384-EbBpjO7rlR6eqZEcG7GaPpyk9H9WrMyPWX4d3KvPYltgt8Z8l0z6R56B1qP40pR4")

VERSION_RE = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\d{4}-\d{2}-\d{2}))?\s*$")
SECTION_RE = re.compile(r"^### (.+?)\s*$")
ITEM_RE = re.compile(r"^[-*] (.*)$")


# ---------- parsing ----------

def parse_changelog(text):
    """Keep-a-Changelog subset -> [{version, date, sections: [{name, items}]}]."""
    releases, rel, sec = [], None, None
    for line in text.splitlines():
        m = VERSION_RE.match(line)
        if m:
            rel = {"version": m.group(1), "date": m.group(2) or "", "sections": []}
            releases.append(rel)
            sec = None
            continue
        if rel is None or re.match(r"^\[[^\]]+\]: ", line):
            continue
        m = SECTION_RE.match(line)
        if m:
            sec = {"name": m.group(1), "items": []}
            rel["sections"].append(sec)
            continue
        m = ITEM_RE.match(line)
        if m:
            if sec is None:  # bullet without a ### heading
                sec = {"name": "Changed", "items": []}
                rel["sections"].append(sec)
            sec["items"].append(m.group(1).strip())
        elif line.startswith("  ") and line.strip() and sec and sec["items"]:
            sec["items"][-1] += " " + line.strip()  # wrapped bullet
    return releases


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def gh_slug(s):
    """GitHub's heading anchor, so README #links keep working on the site."""
    s = re.sub(r"<[^>]+>", "", s).lower()
    return re.sub(r"[^\w\- ]", "", s).replace(" ", "-")


def inline(md, link_base=None):
    """Escape, then render `code`, [text](url) and **bold**. Relative links resolve against link_base."""
    codes = []

    def keep_code(m):
        codes.append("<code>" + html.escape(m.group(1)) + "</code>")
        return "\x00%d\x00" % (len(codes) - 1)

    s = re.sub(r"`([^`]+)`", keep_code, md)
    s = html.escape(s)

    def link(m):
        text, url = m.group(1), html.unescape(m.group(2))
        if url.startswith("#"):
            pass
        elif link_base and not re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I):
            url = link_base + url.lstrip("./")
        elif not re.match(r"^https?://", url):
            return m.group(0)
        cls = ' class="pr"' if re.fullmatch(r"#\d+", text) else ""
        return '<a%s href="%s">%s</a>' % (cls, html.escape(url, quote=True), text)

    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, s)
    s = re.sub(r"\(((?:<a class=\"pr\"[^>]*>[^<]*</a>(?:,\s*)?)+)\)", r"\1", s)  # "(#10)" -> pill
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], s)


def markdown(text, link_base=None):
    """README subset -> (html, [(id, h2 text)]). Raw HTML lines are dropped, never passed through."""
    lines, out, toc, i = text.splitlines(), [], [], 0
    il = lambda s: inline(s, link_base)  # noqa: E731

    def is_block_start(l):
        return (not l.strip() or l.startswith(("#", ">", "|", "```", "<"))
                or re.match(r"^\s*([-*]|\d+\.) ", l) is not None)

    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("<"):
            i += 1
            continue
        if line.startswith("```"):
            lang, body = line[3:].strip(), []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            src = html.escape("\n".join(body))
            if lang == "mermaid":
                out.append('<figure class="diagram"><pre class="mermaid">%s</pre></figure>' % src)
            else:
                out.append(code_block("\n".join(body)))
            continue
        m = re.match(r"^(#{1,6}) (.+?)\s*#*$", line)
        if m:
            level, title = len(m.group(1)), m.group(2)
            hid = gh_slug(title)
            if level == 2:
                toc.append((hid, re.sub(r"<[^>]+>", "", il(title))))
            out.append('<h%d id="%s">%s</h%d>' % (level, hid, il(title), level))
            i += 1
            continue
        if line.startswith(">"):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].strip())
                i += 1
            out.append("<blockquote><p>%s</p></blockquote>" % il(" ".join(quote)))
            continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|?\s*$", lines[i + 1]):
            cells = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]  # noqa: E731
            head = cells(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(cells(lines[i]))
                i += 1
            out.append('<div class="table"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>' % (
                "".join("<th>%s</th>" % il(c) for c in head),
                "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % il(c) for c in r) for r in rows)))
            continue
        m = re.match(r"^([-*]|\d+\.) ", line)
        if m:
            ordered = m.group(1)[0].isdigit()
            items = []
            while i < len(lines):
                m2 = re.match(r"^([-*]|\d+\.) (.*)$", lines[i])
                if m2 and m2.group(1)[0].isdigit() == ordered:
                    items.append(m2.group(2))
                elif lines[i].startswith("  ") and lines[i].strip() and items:
                    items[-1] += " " + lines[i].strip()
                elif not lines[i].strip() and i + 1 < len(lines) and re.match(
                        r"^\d+\. " if ordered else r"^[-*] ", lines[i + 1]):
                    pass  # blank line between items of the same list
                else:
                    break
                i += 1
            tag = "ol" if ordered else "ul"
            out.append("<%s>%s</%s>" % (tag, "".join("<li>%s</li>" % il(x) for x in items), tag))
            continue
        para = []
        while i < len(lines) and not (para and is_block_start(lines[i])):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>%s</p>" % il(" ".join(para)))
    return "\n".join(out), toc


def split_readme(text):
    """README -> (lede markdown, rest markdown): drop the H1, take the first paragraph as the lede."""
    lines = text.splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    while lines and not lines[0].strip():
        lines = lines[1:]
    lede = []
    while lines and lines[0].strip() and not lines[0].startswith(("#", "```", ">", "|", "-")):
        lede.append(lines.pop(0).strip())
    return " ".join(lede), "\n".join(lines)


def load_plugins(root):
    market = json.loads((root / ".claude-plugin/marketplace.json").read_text())
    short = {p["name"]: p.get("description", "") for p in market.get("plugins", [])}
    plugins = []
    for d in sorted((root / "plugins").iterdir()):
        manifest = d / ".claude-plugin/plugin.json"
        if not manifest.is_file():
            continue
        meta = json.loads(manifest.read_text())
        name = meta["name"]
        cl, readme = d / "CHANGELOG.md", d / "README.md"
        plugins.append({
            "name": name,
            "dir": d.name,
            "version": meta.get("version", ""),
            "description": short.get(name) or meta.get("description", ""),
            "readme": readme.read_text() if readme.is_file() else "",
            "releases": parse_changelog(cl.read_text()) if cl.is_file() else [],
        })
    return market, plugins


# ---------- rendering ----------

def managed_settings(names):
    """Claude.ai admin console > Claude Code > Managed settings: installs and enables for the whole org."""
    return json.dumps({
        "env": {"LINEARB_API_TOKEN": "<token from LinearB > Settings > API Tokens>"},
        "extraKnownMarketplaces": {MARKETPLACE: {
            "source": {"source": "github", "repo": REPO_URL.split("github.com/")[1]}, "autoUpdate": True}},
        "enabledPlugins": {"%s@%s" % (n, MARKETPLACE): True for n in names},
    }, indent=2)


def code_block(src):
    return ('<div class="codeblock"><pre><code>%s</code></pre><button class="copy ghost" data-copy="%s">Copy</button></div>'
            % (html.escape(src), html.escape(src, quote=True)))


def rollout(names):
    return """<div class="rollout">
  <div><h3>Roll out to your whole org</h3>
  <p>Admins can install and enable this for every developer from <strong>Claude.ai admin console → Claude Code → Managed settings</strong>. Paste this, then replace the token placeholder.</p>
  <p class="note">The token in managed settings is pushed to every developer's machine. Use a token created for this purpose, so you can rotate it on its own.</p></div>
  %s</div>""" % code_block(managed_settings(names))


def rel_id(p, r):
    return "%s-v%s" % (slug(p["name"]), slug(r["version"]))


def install_box(cmd):
    return ('<div class="install"><code>%s</code><button class="copy" data-copy="%s">Copy</button></div>'
            % (html.escape(cmd), html.escape(cmd, quote=True)))


def render_release(p, r, latest, base):
    rid = rel_id(p, r)
    out = ['<article class="release" id="%s">' % rid, '<header class="rel-head">',
           '<button class="fold" aria-expanded="true" aria-controls="%s-body" aria-label="Collapse %s"></button>'
           % (rid, html.escape(r["version"])),
           '<h3><a class="anchor" href="#%s" aria-label="Link to %s">#</a>%s</h3>'
           % (rid, html.escape(r["version"]), html.escape(r["version"]))]
    if latest:
        out.append('<span class="pill latest">Latest</span>')
    if r["date"]:
        out.append('<time datetime="%s">%s</time>' % (r["date"], r["date"]))
    tag = "%s--v%s" % (p["name"], r["version"])
    out.append('<a class="gh" href="%s/releases/tag/%s">Release notes</a>'
               % (REPO_URL, html.escape(tag, quote=True)))
    out.append('</header><div class="rel-body" id="%s-body">' % rid)
    for s in r["sections"]:
        k = slug(s["name"])
        out.append('<section class="kind" data-kind="%s"><h4><span class="chip chip-%s">%s</span></h4><ul>'
                   % (k, k, html.escape(s["name"])))
        out.extend("<li>%s</li>" % inline(i) for i in s["items"])
        out.append("</ul></section>")
    out.append("</div></article>")
    return "\n".join(out)


def logo(root):
    svg = (root / "site/assets/linearb-logo.svg").read_text()
    return re.sub(r'\s(width|height)="[^"]*"', "", svg, count=2).replace("<svg ", '<svg aria-hidden="true" ', 1)


def page(root, title, desc, body, base, active, extra_head="", scripts=""):
    nav = [("Plugins", base + "#plugins", "plugins"), ("Changelog", base + "changelog/", "changelog")]
    links = "".join('<a href="%s"%s>%s</a>' % (h, ' aria-current="page"' if k == active else "", t)
                    for t, h, k in nav)
    return (SHELL.replace("{{TITLE}}", html.escape(title))
            .replace("{{DESC}}", html.escape(desc, quote=True))
            .replace("{{BASE}}", base)
            .replace("{{LOGO}}", logo(root))
            .replace("{{NAV}}", links)
            .replace("{{HEAD}}", extra_head)
            .replace("{{BODY}}", body)
            .replace("{{SCRIPTS}}", scripts)
            .replace("{{REPO}}", REPO_URL)
            .replace("{{CSS}}", CSS)
            .replace("{{JS}}", JS))


def render_home(root, market, plugins):
    desc = market.get("metadata", {}).get("description", "")
    first = plugins[0]["name"] if plugins else "<plugin>"
    cards = []
    for p in plugins:
        latest = p["releases"][0] if p["releases"] else None
        meta = ('<span class="muted">Updated <time datetime="%s">%s</time></span>' % (latest["date"], latest["date"])
                if latest and latest["date"] else "")
        cards.append(
            '<article class="card"><div class="card-top"><h3><a href="%s/">%s</a></h3><span class="pill ver">v%s</span></div>'
            '<p>%s</p>%s%s<div class="card-actions"><a class="btn" href="%s/">Read the docs</a>'
            '<a class="btn ghost" href="changelog/#%s">Changelog</a></div></article>'
            % (p["dir"], html.escape(p["name"]), html.escape(p["version"]), html.escape(p["description"]), meta,
               install_box("/plugin install %s@%s" % (p["name"], MARKETPLACE)), p["dir"], slug(p["name"])))
    news = []
    for p, r in sorted(((p, r) for p in plugins for r in p["releases"][:3]),
                       key=lambda x: (x[1]["date"], x[1]["version"]), reverse=True)[:4]:
        first_item = next((s["items"][0] for s in r["sections"] if s["items"]), "")
        summary = re.sub(r"\s*\(\[#\d+\]\([^)]*\)\)", "", first_item)
        news.append('<li><a class="news-ver" href="changelog/#%s">%s %s</a><time datetime="%s">%s</time><p>%s</p></li>'
                    % (rel_id(p, r), html.escape(p["name"]), html.escape(r["version"]),
                       r["date"], r["date"], inline(summary)))
    body = """
<section class="hero">
  <p class="eyebrow">Claude Code plugins</p>
  <h1>Engineering context from LinearB, right inside your AI coding agent.</h1>
  <p class="lede">Plugins that give your agent the context a senior engineer would have: how healthy the repo is, how fragile the files are, and how much care the change deserves.</p>
  {box}
  <div class="hero-actions"><a class="btn" href="#plugins">Browse plugins</a><a class="btn ghost" href="changelog/">What's new</a></div>
</section>
<section class="steps" aria-labelledby="qs"><h2 id="qs">Quick start</h2><ol>
  <li><h3>Add the marketplace</h3><p>In Claude Code, run <code>/plugin marketplace add linear-b/agent-plugins</code>.</p></li>
  <li><h3>Install a plugin</h3><p>For example <code>/plugin install {first}@{mk}</code>.</p></li>
  <li><h3>Connect LinearB</h3><p>Create a token in <strong>LinearB → Settings → API Tokens</strong>, <code>export LINEARB_API_TOKEN=…</code>, then restart Claude Code.</p></li>
</ol>{rollout}</section>
<section id="plugins" aria-labelledby="pl"><h2 id="pl">Plugins</h2><div class="cards">{cards}</div></section>
<section class="split">
  <div><h2>What's new</h2><ul class="news">{news}</ul><a href="changelog/">Full changelog →</a></div>
  <div class="trust"><h2>Built to stay out of the way</h2>
    <dl>
      <dt>Your data stays in your org</dt><dd>Usage is reported only to the LinearB org your token belongs to. Source code and full prompts are never sent.</dd>
      <dt>Never blocks</dt><dd>If LinearB can't be reached, plugins fall back to safe defaults and your agent keeps working.</dd>
      <dt>Open source</dt><dd>Apache-2.0. Report vulnerabilities to <code>security@linearb.io</code>, per <a href="{repo}/blob/main/SECURITY.md">SECURITY.md</a>.</dd>
    </dl>
  </div>
</section>
""".format(box=install_box("/plugin marketplace add linear-b/agent-plugins"),
           first=html.escape(first), mk=MARKETPLACE, rollout=rollout([p["name"] for p in plugins]), cards="".join(cards), news="".join(news), repo=REPO_URL)
    return page(root, "LinearB Agent Plugins", desc, body, "", "home")


def render_plugin(root, p):
    base = "../"
    lede, rest = split_readme(p["readme"])
    link_base = "%s/blob/main/plugins/%s/" % (REPO_URL, p["dir"])
    body_html, toc = markdown(rest, link_base)
    toc_html = "".join('<li><a href="#%s">%s</a></li>' % (h, t) for h, t in toc)
    recent = "".join(render_release(p, r, i == 0, base) for i, r in enumerate(p["releases"][:3]))
    body = """
<div class="doc">
<aside class="side"><p class="side-label">On this page</p><ol class="toc">{toc}<li><a href="#recent-releases">Recent releases</a></li></ol></aside>
<article class="doc-main">
  <p class="crumb"><a href="../#plugins">Plugins</a> / {name}</p>
  <header class="doc-hero"><div class="hero-top"><h1>{name}</h1><span class="pill ver">v{ver}</span></div>
  <p class="lede">{lede}</p>
  {install}
  <details class="team"><summary>Rolling out to a team?</summary>{rollout}</details>
  <div class="hero-actions"><a class="btn ghost" href="../changelog/#{pslug}">Changelog</a><a class="btn ghost" href="{repo}/tree/main/plugins/{dir}">Source</a></div></header>
  <div class="prose">{body}</div>
  <section class="recent"><h2 id="recent-releases">Recent releases</h2><div class="timeline">{recent}</div>
  <a href="../changelog/#{pslug}">All releases →</a></section>
</article></div>
""".format(toc=toc_html, name=html.escape(p["name"]), ver=html.escape(p["version"]), lede=inline(lede),
           install=install_box("/plugin install %s@%s" % (p["name"], MARKETPLACE)), rollout=rollout([p["name"]]),
           pslug=slug(p["name"]), repo=REPO_URL, dir=p["dir"], body=body_html, recent=recent)
    head, scripts = "", ""
    if 'class="mermaid"' in body_html:
        head = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Kalam:wght@400;700&display=swap">'
        scripts = '<script src="%s" integrity="%s" crossorigin="anonymous"></script><script>%s</script>' % (
            MERMAID_JS[0], MERMAID_JS[1], DIAGRAM_JS)
    return page(root, "%s · LinearB Agent Plugins" % p["name"], p["description"], body, base, "plugin", head, scripts)


def render_changelog(root, plugins):
    base = "../"
    kinds = []
    for p in plugins:
        for r in p["releases"]:
            for s in r["sections"]:
                if s["name"] not in kinds:
                    kinds.append(s["name"])
    chips = "".join('<button class="chip chip-%s filter" data-kind="%s" aria-pressed="false">%s</button>'
                    % (slug(k), slug(k), html.escape(k)) for k in kinds)
    nav, main = [], []
    for p in plugins:
        if not p["releases"]:
            continue
        nav.append('<p class="side-label">%s</p><ol class="vers">' % html.escape(p["name"]))
        nav.extend('<li><a href="#%s"><span>%s</span><small>%s</small></a></li>'
                   % (rel_id(p, r), html.escape(r["version"]), html.escape(r["date"])) for r in p["releases"])
        nav.append("</ol>")
        main.append('<section class="cl-plugin" id="%s"><div class="cl-head"><h2><a href="%s%s/">%s</a></h2>'
                    '<span class="pill ver">v%s</span></div><div class="timeline">%s</div></section>'
                    % (slug(p["name"]), base, p["dir"], html.escape(p["name"]), html.escape(p["version"]),
                       "".join(render_release(p, r, i == 0, base) for i, r in enumerate(p["releases"]))))
    body = """
<div class="doc">
<nav class="side" aria-label="Versions">{nav}</nav>
<div class="doc-main">
<div class="intro"><h1>Changelog</h1><p class="lede">What changed in each release, newest first. Subscribe with the <a href="../feed.xml">Atom feed</a>.</p></div>
<div class="toolbar"><input class="search" id="q" type="search" placeholder="Search changes (press /)" aria-label="Search changes">{chips}<button class="btn ghost small" id="foldall">Collapse all</button></div>
{main}
<p class="empty" id="empty">No changes match. <a href="#" id="clear">Clear filters</a></p>
</div></div>
""".format(nav="\n".join(nav), chips=chips, main="\n".join(main))
    return page(root, "Changelog · LinearB Agent Plugins", "What changed in each release of LinearB's Claude Code plugins.",
                body, base, "changelog", "", "<script>%s</script>" % CHANGELOG_JS)


def render_feed(plugins):
    entries, newest = [], "1970-01-01"
    for p in plugins:
        for r in p["releases"]:
            date = r["date"] or "1970-01-01"
            newest = max(newest, date)
            url = "%schangelog/#%s" % (SITE_URL, rel_id(p, r))
            content = "".join("<h4>%s</h4><ul>%s</ul>" % (html.escape(s["name"]),
                              "".join("<li>%s</li>" % inline(i) for i in s["items"]))
                              for s in r["sections"])
            entries.append((date, "<entry><title>%s %s</title><id>%s</id>"
                            '<link href="%s"/><updated>%sT00:00:00Z</updated>'
                            '<content type="html">%s</content></entry>'
                            % (html.escape(p["name"]), html.escape(r["version"]), url, url, date,
                               html.escape(content))))
    entries.sort(key=lambda e: e[0], reverse=True)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<feed xmlns="http://www.w3.org/2005/Atom"><title>LinearB Agent Plugins changelog</title>'
            '<id>%s</id><author><name>LinearB</name></author><link href="%schangelog/"/><link rel="self" href="%sfeed.xml"/>'
            '<updated>%sT00:00:00Z</updated>%s</feed>\n'
            % (SITE_URL, SITE_URL, SITE_URL, newest, "".join(e[1] for e in entries)))


# ---------- assets ----------

# LinearB "Buzz" design system (linweb): Outfit, slate primary, bright-blue brand, Buzz status colors.
CSS = r"""
:root{--bg:#ffffff;--surface:#f5f6fa;--card:#ffffff;--fg:#0a0a0a;--primary:#383f48;--muted:#61656c;--line:#e4e4e7;
--brand:#5467ff;--brand-strong:#1831f4;--brand-soft:#eef0ff;--on-brand:#ffffff;--code:#f1f2f6;
--success:#16a34a;--success-soft:#e7f6ec;--attention:#b45309;--attention-soft:#fef3e2;--destructive:#bf1245;--destructive-soft:#fce8ee;
--font:"Outfit",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
--radius:12px;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0a0a0a;--surface:#111113;--card:#161618;--fg:#fafafa;--primary:#e4e4e7;--muted:#a1a1aa;--line:#262626;
--brand:#7c88ff;--brand-strong:#9aa3ff;--brand-soft:#1c1f45;--on-brand:#0a0a0a;--code:#1d1d21;
--success:#4ade80;--success-soft:#11281a;--attention:#fbbf24;--attention-soft:#2e2209;--destructive:#fb7194;--destructive-soft:#331520;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0a0a0a;--surface:#111113;--card:#161618;--fg:#fafafa;--primary:#e4e4e7;--muted:#a1a1aa;--line:#262626;
--brand:#7c88ff;--brand-strong:#9aa3ff;--brand-soft:#1c1f45;--on-brand:#0a0a0a;--code:#1d1d21;
--success:#4ade80;--success-soft:#11281a;--attention:#fbbf24;--attention-soft:#2e2209;--destructive:#fb7194;--destructive-soft:#331520;color-scheme:dark}
*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:84px}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition:none!important}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 var(--font);-webkit-font-smoothing:antialiased}
a{color:var(--brand-strong);text-decoration:none}a:hover{text-decoration:underline}
:focus-visible{outline:2px solid var(--brand);outline-offset:2px;border-radius:4px}
h1,h2,h3{color:var(--fg);text-wrap:balance;letter-spacing:-.015em;line-height:1.2}
code{font:.85em var(--mono);background:var(--code);padding:1px 6px;border-radius:6px;word-break:break-word}
.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.top-in{max-width:1160px;margin:0 auto;padding-inline:20px;height:64px;display:flex;align-items:center;gap:20px}
.brand{display:flex;align-items:center;gap:12px;color:var(--fg);font-weight:500}
.brand svg{height:22px;width:auto;display:block}
.brand span{padding-left:12px;border-left:1px solid var(--line);color:var(--muted)}
.brand:hover{text-decoration:none}
.top nav{display:flex;gap:4px;margin-left:auto;align-items:center}
.top nav a{color:var(--muted);padding:6px 12px;border-radius:8px;font-size:15px}
.top nav a:hover,.top nav a[aria-current]{color:var(--fg);background:var(--surface);text-decoration:none}
.icon-btn{border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;width:34px;height:34px;cursor:pointer;font:inherit}
.wrap{max-width:1160px;margin:0 auto;padding:40px 20px 72px}
.btn{display:inline-flex;align-items:center;border-radius:9px;padding:9px 16px;font:500 15px var(--font);background:var(--primary);color:var(--bg);border:1px solid transparent;cursor:pointer}
.btn:hover{text-decoration:none;filter:brightness(1.15)}
.btn.ghost{background:transparent;color:var(--fg);border-color:var(--line)}
.btn.ghost:hover{border-color:var(--brand);filter:none}
.btn.small{padding:6px 12px;font-size:13px}
.pill{font-size:12px;font-weight:600;border-radius:999px;padding:2px 10px;white-space:nowrap}
.ver{background:var(--brand-soft);color:var(--brand-strong)}
.latest{background:var(--success-soft);color:var(--success)}
.muted{color:var(--muted);font-size:14px}
.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:13px;font-weight:600;color:var(--brand-strong);margin:0 0 14px}
.lede{color:var(--muted);font-size:18px;max-width:62ch;margin:0 0 22px}
.install{display:flex;align-items:center;gap:8px;background:var(--code);border:1px solid var(--line);border-radius:10px;padding:6px 6px 6px 14px;max-width:560px}
.install code{background:none;padding:0;flex:1;min-width:0;overflow-x:auto;white-space:nowrap;font-size:14px}
.copy{border:0;background:var(--brand);color:var(--on-brand);border-radius:7px;padding:7px 14px;font:600 13px var(--font);cursor:pointer}
.copy.ghost{background:var(--card);color:var(--muted);border:1px solid var(--line)}
.hero-actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:20px}
/* home */
.hero{padding-block:36px 56px;max-width:820px}
.hero h1{font-size:clamp(34px,5vw,54px);font-weight:600;margin:0 0 18px}
section+section{margin-top:56px}
.wrap>section>h2,.split h2{font-size:26px;margin:0 0 20px}
.steps ol{list-style:none;counter-reset:s;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}
.steps li{counter-increment:s;background:var(--surface);border-radius:var(--radius);padding:22px;min-width:0}
.steps li:before{content:counter(s);display:grid;place-items:center;width:30px;height:30px;border-radius:50%;background:var(--brand);color:var(--on-brand);font-weight:600;margin-bottom:12px}
.steps h3{margin:0 0 6px;font-size:18px}.steps p{margin:0;color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,420px),1fr));gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:24px;display:flex;flex-direction:column;gap:14px;min-width:0}
.card-top{display:flex;align-items:center;gap:10px}
.card h3{margin:0;font-size:22px}.card h3 a{color:var(--fg)}
.card p{margin:0;color:var(--muted)}
.card-actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:auto}
.split{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr);gap:40px}
.news{list-style:none;padding:0;margin:0 0 14px}
.news li{padding:14px 0;border-bottom:1px solid var(--line);display:grid;grid-template-columns:auto 1fr;gap:2px 12px}
.news-ver{font-weight:600}.news time{color:var(--muted);font-size:14px;justify-self:end}
.news p{grid-column:1/-1;margin:0;color:var(--muted);font-size:15px}
.trust{align-self:start;background:var(--surface);border-radius:var(--radius);padding:24px 26px}
.trust dl{margin:0}.trust dt{font-weight:600;margin-top:16px}.trust dt:first-child{margin-top:0}.trust dd{margin:2px 0 0;color:var(--muted)}
/* docs + changelog layout */
.doc{display:grid;grid-template-columns:210px minmax(0,1fr);gap:48px}
.side{position:sticky;top:88px;align-self:start;max-height:calc(100vh - 110px);overflow:auto}
.side-label{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 10px;font-weight:600}
.toc,.vers{list-style:none;margin:0 0 22px;padding:0;border-left:2px solid var(--line)}
.toc a,.vers a{display:flex;justify-content:space-between;gap:8px;padding:5px 12px;margin-left:-2px;border-left:2px solid transparent;color:var(--muted);font-size:14px}
.toc a:hover,.vers a:hover{color:var(--fg);text-decoration:none}
.toc a.active,.vers a.active{color:var(--brand-strong);border-left-color:var(--brand);font-weight:600}
.vers a.dim{opacity:.35}.vers small{font-size:12px}
.crumb{font-size:14px;color:var(--muted);margin:0 0 10px}
.doc-hero{padding-bottom:28px;border-bottom:1px solid var(--line);margin-bottom:8px}
.hero-top{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.doc-hero h1,.intro h1{font-size:clamp(32px,4vw,44px);margin:0;font-weight:600}
.doc-hero .lede{margin-top:12px}
.intro .lede{margin-top:8px}
.prose>*{max-width:76ch}.prose>.diagram,.prose>.table{max-width:none}
.prose h2{font-size:26px;margin:44px 0 12px;padding-top:4px}
.prose h3{font-size:19px;margin:28px 0 8px}
.prose p,.prose li{color:var(--fg)}
.prose ul,.prose ol{padding-left:22px}.prose li{margin:6px 0}
.prose blockquote{margin:14px 0;padding:12px 16px;background:var(--surface);border-radius:10px;font-family:var(--mono);font-size:14px;color:var(--primary)}
.prose blockquote p{margin:0}
.codeblock{position:relative;margin:16px 0}
.codeblock pre{margin:0;background:var(--code);border:1px solid var(--line);border-radius:10px;padding:14px 16px;overflow-x:auto}
.codeblock pre code{background:none;padding:0;font-size:14px;white-space:pre;word-break:normal}
.codeblock .copy{position:absolute;top:8px;right:8px;opacity:0;transition:opacity .15s}
.codeblock:hover .copy,.codeblock .copy:focus-visible{opacity:1}
.table{overflow-x:auto;margin:16px 0;border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:14.5px}
th,td{text-align:left;padding:10px 14px;border-bottom:1px solid var(--line);vertical-align:top}
th{background:var(--surface);font-weight:600}tr:last-child td{border-bottom:0}
.diagram{margin:22px 0;background:var(--surface);border-radius:var(--radius);padding:20px;overflow-x:auto;text-align:center}
.diagram pre.mermaid{margin:0;font-family:var(--mono);font-size:13px;text-align:left;white-space:pre;color:var(--muted)}
.diagram pre.mermaid[data-processed]{text-align:center;white-space:normal}
.diagram svg{max-width:min(100%,720px);height:auto}
.rollout{margin-top:18px;display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.1fr);gap:24px;align-items:start;background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:22px}
.rollout h3{margin:0 0 8px;font-size:18px}.rollout p{margin:0 0 10px;color:var(--muted)}
.rollout .codeblock{margin:0}
.note{font-size:14px;border-left:3px solid var(--attention);padding-left:10px}
details.team{margin-top:14px;max-width:760px}
details.team summary{cursor:pointer;color:var(--brand-strong);font-weight:500;width:max-content}
details.team .rollout{grid-template-columns:minmax(0,1fr)}
.recent{margin-top:56px}.recent h2{font-size:26px;margin:0 0 18px}
/* changelog */
.toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:24px 0}
.search{flex:1 1 240px;min-width:0;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:10px;padding:10px 14px;font:inherit;font-size:15px}
.search:focus{outline:2px solid var(--brand);outline-offset:-1px;border-color:transparent}
.cl-plugin+.cl-plugin{margin-top:48px}
.cl-head{display:flex;align-items:center;gap:10px;margin-bottom:16px}.cl-head h2{margin:0;font-size:24px}.cl-head h2 a{color:var(--fg)}
.chip{display:inline-block;font-size:12px;font-weight:600;border-radius:999px;padding:3px 11px;border:1px solid transparent;background:var(--surface);color:var(--muted)}
.chip-added{background:var(--success-soft);color:var(--success)}.chip-changed{background:var(--brand-soft);color:var(--brand-strong)}
.chip-fixed{background:var(--attention-soft);color:var(--attention)}.chip-removed,.chip-security,.chip-deprecated{background:var(--destructive-soft);color:var(--destructive)}
button.filter{cursor:pointer;font-family:inherit}
button.filter[aria-pressed="true"]{border-color:currentColor;box-shadow:0 0 0 1px currentColor inset}
.timeline{position:relative;padding-left:24px}
.timeline:before{content:"";position:absolute;left:5px;top:8px;bottom:8px;width:2px;background:var(--line)}
.release{position:relative;background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:16px 22px;margin-bottom:14px}
.release:before{content:"";position:absolute;left:-24px;top:23px;width:12px;height:12px;border-radius:50%;background:var(--bg);border:2px solid var(--brand)}
.release:target{border-color:var(--brand);box-shadow:0 0 0 3px var(--brand-soft)}
.rel-head{display:flex;flex-wrap:wrap;align-items:center;gap:10px;cursor:pointer}
.rel-head h3{margin:0;font-size:19px}
.rel-head time{color:var(--muted);font-size:14px}
.rel-head .gh{margin-left:auto;font-size:14px}
.anchor{opacity:0;margin-left:-14px;width:14px;display:inline-block;color:var(--muted)}
.rel-head h3:hover .anchor{opacity:1}
.fold{border:0;background:none;color:var(--muted);width:24px;height:24px;margin-left:-6px;border-radius:6px;cursor:pointer;display:grid;place-items:center;padding:0}
.fold:before{content:"";width:7px;height:7px;border-right:2px solid currentColor;border-bottom:2px solid currentColor;transform:rotate(45deg);margin-top:-3px;transition:transform .15s}
.fold:hover{background:var(--surface);color:var(--fg)}
.release.collapsed .fold:before{transform:rotate(-45deg);margin-top:0;margin-left:-3px}
.release.collapsed .rel-body{display:none}
.kind h4{margin:14px 0 6px}.kind ul{margin:0;padding-left:20px}.kind li{margin:5px 0}.kind li::marker{color:var(--muted)}
a.pr{font-size:12px;font-weight:600;background:var(--brand-soft);border-radius:999px;padding:1px 8px}
mark{background:#ffe58a;color:#0a0a0a;border-radius:3px;padding:0 1px}
.empty{display:none;text-align:center;color:var(--muted);padding:40px 0}
.hidden{display:none!important}
footer{border-top:1px solid var(--line);color:var(--muted);font-size:14px}
.foot{max-width:1160px;margin:0 auto;padding:24px 20px;display:flex;flex-wrap:wrap;gap:8px 20px;align-items:center}
.foot .spacer{flex:1}
@media (max-width:860px){.doc{grid-template-columns:minmax(0,1fr);gap:0}.side{display:none}.split,.rollout{grid-template-columns:minmax(0,1fr)}
.brand span{display:none}.wrap{padding-top:24px}.release{padding:14px 16px}.rel-head .gh{margin-left:0}.search{flex-basis:100%}.top nav a{padding:6px 8px}}
@media (max-width:480px){.top-in{gap:8px}.top nav .gh-link{display:none}.top nav{gap:0}}
"""

SHELL = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<meta name="description" content="{{DESC}}">
<link rel="alternate" type="application/atom+xml" title="LinearB Agent Plugins changelog" href="{{BASE}}feed.xml">
<link rel="icon" href="{{BASE}}assets/linearb-mark.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Outfit:wght@300..700&display=swap">
{{HEAD}}
<script>try{var t=localStorage.getItem("theme");if(t)document.documentElement.setAttribute("data-theme",t)}catch(e){}</script>
<style>{{CSS}}</style>
</head>
<body>
<header class="top"><div class="top-in">
<a class="brand" href="{{BASE}}" aria-label="LinearB Agent Plugins home">{{LOGO}}<span>Agent Plugins</span></a>
<nav aria-label="Site">{{NAV}}<a class="gh-link" href="{{REPO}}">GitHub</a><button class="icon-btn" id="theme" aria-label="Toggle dark mode">◐</button></nav>
</div></header>
<main class="wrap">
{{BODY}}
</main>
<footer><div class="foot"><span>© LinearB · Apache-2.0</span><span class="spacer"></span>
<a href="{{REPO}}">GitHub</a><a href="{{BASE}}changelog/">Changelog</a><a href="{{BASE}}feed.xml">Feed</a><a href="{{REPO}}/issues">Report an issue</a><a href="{{REPO}}/blob/main/SECURITY.md">Security</a></div></footer>
<script>{{JS}}</script>
{{SCRIPTS}}
</body>
</html>
"""

JS = r"""
(function(){
  var root=document.documentElement;
  function save(k,v){try{localStorage.setItem(k,v)}catch(e){}}
  document.getElementById("theme").onclick=function(){
    var cur=root.getAttribute("data-theme"),dark=cur?cur==="dark":matchMedia("(prefers-color-scheme: dark)").matches;
    var next=dark?"light":"dark";root.setAttribute("data-theme",next);save("theme",next);
    document.dispatchEvent(new Event("themechange"))};
  document.querySelectorAll(".copy").forEach(function(b){b.onclick=function(e){
    e.stopPropagation();var label=b.textContent;
    var done=function(){b.textContent="Copied";setTimeout(function(){b.textContent=label},1500)};
    if(navigator.clipboard)navigator.clipboard.writeText(b.dataset.copy).then(done,function(){})}});
  // Relative dates, absolute on hover.
  var now=Date.now();document.querySelectorAll("time[datetime]").forEach(function(el){
    var d=Math.floor((now-new Date(el.dateTime+"T00:00:00Z"))/864e5);if(isNaN(d)||d<0)return;
    el.title=el.dateTime;el.textContent=d===0?"today":d===1?"yesterday":d<30?d+" days ago":el.dateTime});
  // Highlight the section in view in the sidebar.
  var links={};document.querySelectorAll(".side a[href^='#']").forEach(function(a){links[a.getAttribute("href").slice(1)]=a});
  var targets=Object.keys(links).map(function(id){return document.getElementById(id)}).filter(Boolean);
  if(targets.length&&"IntersectionObserver"in window){var io=new IntersectionObserver(function(es){es.forEach(function(e){
    if(e.isIntersecting){Object.keys(links).forEach(function(k){links[k].classList.remove("active")});links[e.target.id].classList.add("active")}})},{rootMargin:"-90px 0px -65% 0px"});
    targets.forEach(function(t){io.observe(t)})}
  // Collapsible releases.
  var rels=[].slice.call(document.querySelectorAll(".release")),foldAll=document.getElementById("foldall");
  window.setFold=function(r,closed){r.classList.toggle("collapsed",closed);var b=r.querySelector(".fold");
    b.setAttribute("aria-expanded",closed?"false":"true");b.setAttribute("aria-label",(closed?"Expand ":"Collapse ")+r.querySelector("h3").lastChild.textContent);syncAll()};
  function syncAll(){if(foldAll)foldAll.textContent=rels.every(function(r){return r.classList.contains("collapsed")})?"Expand all":"Collapse all"}
  rels.forEach(function(r){r.querySelector(".rel-head").addEventListener("click",function(e){
    if(e.target.closest("a"))return;setFold(r,!r.classList.contains("collapsed"))})});
  if(foldAll)foldAll.onclick=function(){var close=foldAll.textContent==="Collapse all";rels.forEach(function(r){setFold(r,close)})};
  function openHash(){var r=location.hash&&document.getElementById(location.hash.slice(1));if(r&&r.classList.contains("release"))setFold(r,false)}
  window.addEventListener("hashchange",openHash);openHash();
})();
"""

CHANGELOG_JS = r"""
(function(){
  var q=document.getElementById("q"),empty=document.getElementById("empty"),active={};
  var links={};document.querySelectorAll(".side a").forEach(function(a){links[a.getAttribute("href").slice(1)]=a});
  var items=[].slice.call(document.querySelectorAll(".kind li"));items.forEach(function(li){li._html=li.innerHTML});
  function esc(s){return s.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}
  // Wrap matches in <mark>, text nodes only, so links and code stay intact.
  function highlight(node,re){[].slice.call(node.childNodes).forEach(function(n){
    if(n.nodeType===1){highlight(n,re);return}
    if(n.nodeType!==3)return;
    var parts=n.data.split(re);if(parts.length<2)return;
    var frag=document.createDocumentFragment();
    parts.forEach(function(p,i){if(!p)return;if(i%2){var m=document.createElement("mark");m.textContent=p;frag.appendChild(m)}else frag.appendChild(document.createTextNode(p))});
    n.replaceWith(frag)})}
  function apply(){
    var term=q.value.trim(),kinds=Object.keys(active).filter(function(k){return active[k]}),re=term?new RegExp("("+esc(term)+")","i"):null,shown=0;
    items.forEach(function(li){
      var kindOk=!kinds.length||kinds.indexOf(li.closest(".kind").dataset.kind)>=0;
      var textOk=!re||li.textContent.toLowerCase().indexOf(term.toLowerCase())>=0;
      li.innerHTML=li._html;
      if(re&&textOk)highlight(li,re);
      li.classList.toggle("hidden",!(kindOk&&textOk))});
    document.querySelectorAll(".kind").forEach(function(s){s.classList.toggle("hidden",!s.querySelector("li:not(.hidden)"))});
    document.querySelectorAll(".release").forEach(function(r){var v=!!r.querySelector(".kind:not(.hidden)");
      r.classList.toggle("hidden",!v);if(links[r.id])links[r.id].classList.toggle("dim",!v);
      if(v&&(term||kinds.length))setFold(r,false);if(v)shown++});
    document.querySelectorAll(".cl-plugin").forEach(function(s){s.classList.toggle("hidden",!s.querySelector(".release:not(.hidden)"))});
    empty.style.display=shown?"none":"block"}
  q.addEventListener("input",apply);
  document.querySelectorAll("button.filter").forEach(function(b){b.onclick=function(){
    active[b.dataset.kind]=!active[b.dataset.kind];b.setAttribute("aria-pressed",active[b.dataset.kind]?"true":"false");apply()}});
  document.getElementById("clear").onclick=function(e){e.preventDefault();q.value="";active={};
    document.querySelectorAll("button.filter").forEach(function(b){b.setAttribute("aria-pressed","false")});apply()};
  document.addEventListener("keydown",function(e){if(e.key==="/"&&document.activeElement!==q){e.preventDefault();q.focus()}
    else if(e.key==="Escape"&&document.activeElement===q){q.value="";apply();q.blur()}});
})();
"""

# Hand-drawn (Excalidraw-style) diagrams in the site's colors; redrawn when the theme flips.
DIAGRAM_JS = r"""
(function(){
  if(!window.mermaid)return;  // CDN blocked: the diagram source stays readable as text
  var blocks=[].slice.call(document.querySelectorAll("pre.mermaid"));
  blocks.forEach(function(b){b.dataset.src=b.textContent});
  function css(v){return getComputedStyle(document.documentElement).getPropertyValue(v).trim()}
  function draw(){
    blocks.forEach(function(b){b.removeAttribute("data-processed");b.textContent=b.dataset.src});
    mermaid.initialize({startOnLoad:false,look:"handDrawn",theme:"base",securityLevel:"strict",
      fontFamily:"Kalam, var(--font)",flowchart:{curve:"basis"},
      themeVariables:{fontFamily:"Kalam, cursive",fontSize:"17px",background:css("--surface"),
        primaryColor:css("--card"),primaryBorderColor:css("--primary"),primaryTextColor:css("--fg"),
        secondaryColor:css("--brand-soft"),tertiaryColor:css("--surface"),
        lineColor:css("--muted"),textColor:css("--fg"),edgeLabelBackground:css("--surface")}});
    mermaid.run({nodes:blocks}).catch(function(){})}
  draw();document.addEventListener("themechange",draw);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change",draw);
})();
"""


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "_site")
    root = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent
    market, plugins = load_plugins(root)
    if not plugins:
        sys.exit("no plugins found under %s/plugins" % root)
    (out / "assets").mkdir(parents=True, exist_ok=True)
    (out / "changelog").mkdir(exist_ok=True)
    (out / "index.html").write_text(render_home(root, market, plugins), encoding="utf-8")
    for p in plugins:
        (out / p["dir"]).mkdir(exist_ok=True)
        (out / p["dir"] / "index.html").write_text(render_plugin(root, p), encoding="utf-8")
    (out / "changelog" / "index.html").write_text(render_changelog(root, plugins), encoding="utf-8")
    (out / "feed.xml").write_text(render_feed(plugins), encoding="utf-8")
    for a in (root / "site/assets").iterdir():
        (out / "assets" / a.name).write_bytes(a.read_bytes())
    (out / ".nojekyll").write_text("")
    print("wrote %s (%d plugin page(s), %d release(s))"
          % (out, len(plugins), sum(len(p["releases"]) for p in plugins)))


if __name__ == "__main__":
    main()
