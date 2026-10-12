#!/usr/bin/env python3
"""Build the GitHub Pages changelog site from plugins/*/CHANGELOG.md.

Usage: scripts/build-changelog-site.py [out_dir]   (default: _site)
Writes index.html and feed.xml. Standard library only.
"""
import datetime
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE_URL = "https://linear-b.github.io/agent-plugins/"
REPO_URL = "https://github.com/linear-b/agent-plugins"
MARKETPLACE = "linearb-ai"

VERSION_RE = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\d{4}-\d{2}-\d{2}))?\s*$")
SECTION_RE = re.compile(r"^### (.+?)\s*$")
ITEM_RE = re.compile(r"^[-*] (.*)$")


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


def inline(md):
    """Escape, then render `code`, [text](http...) and **bold**."""
    codes = []

    def keep_code(m):
        codes.append("<code>" + html.escape(m.group(1)) + "</code>")
        return "\x00%d\x00" % (len(codes) - 1)

    s = re.sub(r"`([^`]+)`", keep_code, md)
    s = html.escape(s)

    def link(m):
        text, url = m.group(1), html.unescape(m.group(2))
        if not re.match(r"^https?://", url):
            return m.group(0)
        cls = ' class="pr"' if re.fullmatch(r"#\d+", text) else ""
        return '<a%s href="%s">%s</a>' % (cls, html.escape(url, quote=True), text)

    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, s)
    s = re.sub(r"\(((?:<a class=\"pr\"[^>]*>[^<]*</a>(?:,\s*)?)+)\)", r"\1", s)  # "(#10)" -> pill
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], s)


def load_plugins():
    market = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
    short = {p["name"]: p.get("description", "") for p in market.get("plugins", [])}
    plugins = []
    for d in sorted((ROOT / "plugins").iterdir()):
        cl, manifest = d / "CHANGELOG.md", d / ".claude-plugin/plugin.json"
        if not cl.is_file() or not manifest.is_file():
            continue
        meta = json.loads(manifest.read_text())
        name = meta["name"]
        plugins.append({
            "name": name,
            "version": meta.get("version", ""),
            "description": short.get(name) or meta.get("description", ""),
            "releases": parse_changelog(cl.read_text()),
        })
    return plugins


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def render_release(p, r, latest):
    rid = "%s-v%s" % (slug(p["name"]), slug(r["version"]))
    kinds = " ".join(sorted({slug(s["name"]) for s in r["sections"]}))
    out = ['<article class="release" id="%s" data-kinds="%s">' % (rid, kinds)]
    out.append('<header class="rel-head">')
    out.append('<button class="fold" aria-expanded="true" aria-controls="%s-body" aria-label="Collapse %s"></button>'
               % (rid, html.escape(r["version"])))
    out.append('<h3><a class="anchor" href="#%s" aria-label="Link to %s">#</a>%s</h3>'
               % (rid, html.escape(r["version"]), html.escape(r["version"])))
    if latest:
        out.append('<span class="pill latest">Latest</span>')
    if r["date"]:
        out.append('<time datetime="%s">%s</time>' % (r["date"], r["date"]))
    tag = "%s--v%s" % (p["name"], r["version"])
    out.append('<a class="gh" href="%s/releases/tag/%s">Release notes</a>'
               % (REPO_URL, html.escape(tag, quote=True)))
    out.append("</header>")
    out.append('<div class="rel-body" id="%s-body">' % rid)
    for s in r["sections"]:
        k = slug(s["name"])
        out.append('<section class="kind" data-kind="%s">' % k)
        out.append('<h4><span class="chip chip-%s">%s</span></h4><ul>' % (k, html.escape(s["name"])))
        out.extend("<li>%s</li>" % inline(i) for i in s["items"])
        out.append("</ul></section>")
    out.append("</div></article>")
    return "\n".join(out)


def render(plugins):
    built = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    kinds = []
    for p in plugins:
        for r in p["releases"]:
            for s in r["sections"]:
                if s["name"] not in kinds:
                    kinds.append(s["name"])
    chips = "".join('<button class="chip chip-%s filter" data-kind="%s" aria-pressed="false">%s</button>'
                    % (slug(k), slug(k), html.escape(k)) for k in kinds)

    nav, body = [], []
    for p in plugins:
        nav.append('<p class="nav-plugin">%s</p><ol>' % html.escape(p["name"]))
        for i, r in enumerate(p["releases"]):
            rid = "%s-v%s" % (slug(p["name"]), slug(r["version"]))
            nav.append('<li><a href="#%s"><span>%s</span><small>%s</small></a></li>'
                       % (rid, html.escape(r["version"]), html.escape(r["date"])))
        nav.append("</ol>")
        install = "/plugin install %s@%s" % (p["name"], MARKETPLACE)
        body.append('<section class="plugin" id="%s">' % slug(p["name"]))
        body.append('<div class="hero"><div class="hero-top"><h2>%s</h2><span class="pill ver">v%s</span></div>'
                    % (html.escape(p["name"]), html.escape(p["version"])))
        body.append('<p class="desc">%s</p>' % html.escape(p["description"]))
        body.append('<div class="install"><code>%s</code><button class="copy" data-copy="%s">Copy</button></div>'
                    % (html.escape(install), html.escape(install, quote=True)))
        body.append('<p class="hint">Already installed? <code>claude plugin update %s@%s</code>, then restart Claude Code.</p></div>'
                    % (html.escape(p["name"]), MARKETPLACE))
        body.append('<div class="timeline">')
        body.extend(render_release(p, r, i == 0) for i, r in enumerate(p["releases"]))
        body.append("</div></section>")

    return (TEMPLATE
            .replace("{{CHIPS}}", chips)
            .replace("{{NAV}}", "\n".join(nav))
            .replace("{{BODY}}", "\n".join(body))
            .replace("{{REPO}}", REPO_URL)
            .replace("{{BUILT}}", built))


def render_feed(plugins):
    entries, newest = [], "1970-01-01"
    for p in plugins:
        for r in p["releases"]:
            date = r["date"] or "1970-01-01"
            newest = max(newest, date)
            rid = "%s-v%s" % (slug(p["name"]), slug(r["version"]))
            content = "".join("<h4>%s</h4><ul>%s</ul>" % (html.escape(s["name"]),
                              "".join("<li>%s</li>" % inline(i) for i in s["items"]))
                              for s in r["sections"])
            entries.append((date, "<entry><title>%s %s</title><id>%s#%s</id>"
                            '<link href="%s#%s"/><updated>%sT00:00:00Z</updated>'
                            '<content type="html">%s</content></entry>'
                            % (html.escape(p["name"]), html.escape(r["version"]), SITE_URL, rid,
                               SITE_URL, rid, date, html.escape(content))))
    entries.sort(key=lambda e: e[0], reverse=True)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<feed xmlns="http://www.w3.org/2005/Atom"><title>LinearB Agent Plugins changelog</title>'
            '<id>%s</id><author><name>LinearB</name></author><link href="%s"/><link rel="self" href="%sfeed.xml"/><updated>%sT00:00:00Z</updated>%s</feed>\n'
            % (SITE_URL, SITE_URL, SITE_URL, newest, "".join(e[1] for e in entries)))


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Changelog · LinearB Agent Plugins</title>
<meta name="description" content="What changed in each release of LinearB's Claude Code plugins.">
<link rel="alternate" type="application/atom+xml" title="Changelog feed" href="feed.xml">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%234F46E5'/%3E%3Cpath d='M9 22V10h3v9h7v3z' fill='white'/%3E%3C/svg%3E">
<style>
:root{--bg:#f7f7fb;--card:#fff;--text:#16161d;--muted:#5d5d6e;--line:#e4e4ee;--accent:#4f46e5;--on-accent:#fff;--accent-soft:#eef0ff;--code:#f1f1f7;
--added:#0f7b4b;--added-bg:#e3f6ec;--changed:#3b49c9;--changed-bg:#e9ecff;--fixed:#a6510b;--fixed-bg:#fff0e0;--removed:#b42335;--removed-bg:#fde8ea;--other:#5d5d6e;--other-bg:#ececf3}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0e0e14;--card:#17171f;--text:#ececf3;--muted:#9a9aad;--line:#2a2a36;--accent:#8b85ff;--on-accent:#0e0e14;--accent-soft:#23214a;--code:#22222c;
--added:#5fd39b;--added-bg:#123323;--changed:#9aa5ff;--changed-bg:#1e2350;--fixed:#ffb36b;--fixed-bg:#3a2510;--removed:#ff8b98;--removed-bg:#3d1820;--other:#b4b4c4;--other-bg:#26262f}}
:root[data-theme="dark"]{--bg:#0e0e14;--card:#17171f;--text:#ececf3;--muted:#9a9aad;--line:#2a2a36;--accent:#8b85ff;--on-accent:#0e0e14;--accent-soft:#23214a;--code:#22222c;
--added:#5fd39b;--added-bg:#123323;--changed:#9aa5ff;--changed-bg:#1e2350;--fixed:#ffb36b;--fixed-bg:#3a2510;--removed:#ff8b98;--removed-bg:#3d1820;--other:#b4b4c4;--other-bg:#26262f}
*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:80px}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:1px 6px;border-radius:5px;word-break:break-word}
.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 85%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.top-in{max-width:1100px;margin:0 auto;padding:12px 16px;display:flex;align-items:center;gap:12px}
.brand{display:flex;align-items:center;gap:10px;font-weight:650;color:var(--text)}
.logo{width:26px;height:26px;border-radius:7px;background:var(--accent);display:grid;place-items:center;color:#fff;font-weight:800;font-size:14px}
.spacer{flex:1}
.icon-btn{border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:8px;padding:6px 10px;font:inherit;font-size:13px;cursor:pointer}
.icon-btn:hover{border-color:var(--accent)}
.wrap{max-width:1100px;margin:0 auto;padding:28px 16px 64px;display:grid;grid-template-columns:200px minmax(0,1fr);gap:40px}
main{min-width:0}
.intro h1{font-size:32px;line-height:1.2;margin:0 0 6px;letter-spacing:-.02em}
.intro p{color:var(--muted);margin:0 0 20px}
nav.side{position:sticky;top:84px;align-self:start;max-height:calc(100vh - 100px);overflow:auto}
.nav-plugin{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 8px}
nav ol{list-style:none;margin:0 0 20px;padding:0;border-left:2px solid var(--line)}
nav li a{display:flex;justify-content:space-between;gap:8px;padding:5px 10px;margin-left:-2px;border-left:2px solid transparent;color:var(--muted);font-size:14px}
nav li a small{font-size:12px;opacity:.8}
nav li a:hover{color:var(--text);text-decoration:none}
nav li a.dim{opacity:.35}
nav li a.active{color:var(--accent);border-left-color:var(--accent);font-weight:600}
.hero{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px 22px;margin-bottom:22px}
.hero-top{display:flex;align-items:center;gap:10px}
.hero h2{margin:0;font-size:20px}
.desc{color:var(--muted);margin:8px 0 14px}
.install{display:flex;align-items:center;gap:8px;background:var(--code);border-radius:10px;padding:8px 8px 8px 12px}
.install code{background:none;padding:0;flex:1;overflow:auto;white-space:nowrap}
.copy{border:0;background:var(--accent);color:var(--on-accent);border-radius:7px;padding:6px 12px;font:inherit;font-size:13px;font-weight:600;cursor:pointer}
.hint{font-size:13px;color:var(--muted);margin:10px 0 0}
.pill{font-size:12px;font-weight:600;border-radius:999px;padding:2px 9px}
.ver{background:var(--accent-soft);color:var(--accent)}
.latest{background:var(--added-bg);color:var(--added)}
.toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:22px}
.search{flex:1 1 220px;min-width:0;border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:10px;padding:9px 12px;font:inherit}
.search:focus{outline:2px solid var(--accent);outline-offset:-1px;border-color:transparent}
.chip{display:inline-block;font-size:12px;font-weight:650;border-radius:999px;padding:3px 10px;border:1px solid transparent;background:var(--other-bg);color:var(--other)}
.chip-added{background:var(--added-bg);color:var(--added)}.chip-changed{background:var(--changed-bg);color:var(--changed)}
.chip-fixed{background:var(--fixed-bg);color:var(--fixed)}.chip-removed,.chip-security,.chip-deprecated{background:var(--removed-bg);color:var(--removed)}
button.filter{cursor:pointer;font-family:inherit}
button.filter[aria-pressed="true"]{border-color:currentColor;box-shadow:0 0 0 1px currentColor inset}
.timeline{position:relative;padding-left:22px}
.timeline:before{content:"";position:absolute;left:5px;top:6px;bottom:6px;width:2px;background:var(--line)}
.release{position:relative;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 22px;margin-bottom:16px;transition:border-color .15s}
.release:before{content:"";position:absolute;left:-22px;top:24px;width:12px;height:12px;border-radius:50%;background:var(--card);border:2px solid var(--accent)}
.release:target{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.rel-head{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-bottom:6px}
.fold{border:0;background:none;color:var(--muted);width:22px;height:22px;margin-left:-6px;border-radius:6px;cursor:pointer;display:grid;place-items:center;padding:0}
.fold:before{content:"";width:7px;height:7px;border-right:2px solid currentColor;border-bottom:2px solid currentColor;transform:rotate(45deg);margin-top:-3px;transition:transform .15s}
.fold:hover{background:var(--code);color:var(--text)}
.release.collapsed .fold:before{transform:rotate(-45deg);margin-top:0;margin-left:-3px}
.release.collapsed .rel-body{display:none}
.release.collapsed .rel-head{margin-bottom:0}
.rel-head{cursor:pointer}
.rel-head h3{margin:0;font-size:19px;letter-spacing:-.01em}
.rel-head time{color:var(--muted);font-size:13px}
.rel-head .gh{margin-left:auto;font-size:13px}
.anchor{opacity:0;margin-left:-16px;width:16px;display:inline-block;color:var(--muted)}
.rel-head h3:hover .anchor{opacity:1}
.kind h4{margin:14px 0 6px}
.kind ul{margin:0;padding-left:20px}
.kind li{margin:5px 0}
.kind li::marker{color:var(--muted)}
a.pr{font-size:12px;font-weight:600;background:var(--accent-soft);border-radius:999px;padding:1px 7px}
mark{background:#ffe58a;color:#16161d;border-radius:3px;padding:0 1px}
.empty{display:none;text-align:center;color:var(--muted);padding:40px 0}
footer{color:var(--muted);font-size:13px;border-top:1px solid var(--line);margin-top:30px;padding-top:16px}
.hidden{display:none!important}
@media (max-width:820px){.wrap{grid-template-columns:minmax(0,1fr);gap:0;padding-top:20px}nav.side{display:none}.intro h1{font-size:26px}.release{padding:16px}.rel-head .gh{margin-left:0}.search{flex-basis:100%}}
</style>
</head>
<body>
<header class="top"><div class="top-in">
<a class="brand" href="#"><span class="logo">L</span>LinearB Agent Plugins</a>
<span class="spacer"></span>
<a class="icon-btn" href="feed.xml" title="Atom feed">Feed</a>
<a class="icon-btn" href="{{REPO}}">GitHub</a>
<button class="icon-btn" id="theme" aria-label="Toggle dark mode">◐</button>
</div></header>
<div class="wrap">
<nav class="side" aria-label="Versions">{{NAV}}</nav>
<main>
<div class="intro"><h1>Changelog</h1><p>What changed in each release, newest first.</p></div>
<div class="toolbar"><input class="search" id="q" type="search" placeholder="Search changes…  (press / )" aria-label="Search changes">{{CHIPS}}<button class="icon-btn" id="foldall">Collapse all</button></div>
{{BODY}}
<p class="empty" id="empty">No changes match. <a href="#" id="clear">Clear filters</a></p>
<footer>Generated from each plugin's <code>CHANGELOG.md</code> on {{BUILT}} · <a href="{{REPO}}/releases">All releases</a></footer>
</main>
</div>
<script>
(function(){
  var root=document.documentElement,store={get:function(k){try{return localStorage.getItem(k)}catch(e){return null}},set:function(k,v){try{localStorage.setItem(k,v)}catch(e){}}};
  var t=store.get("theme");if(t)root.setAttribute("data-theme",t);
  document.getElementById("theme").onclick=function(){
    var dark=root.getAttribute("data-theme")?root.getAttribute("data-theme")==="dark":matchMedia("(prefers-color-scheme: dark)").matches;
    var next=dark?"light":"dark";root.setAttribute("data-theme",next);store.set("theme",next)};
  document.querySelectorAll(".copy").forEach(function(b){b.onclick=function(){
    var done=function(){b.textContent="Copied";setTimeout(function(){b.textContent="Copy"},1500)};
    if(navigator.clipboard)navigator.clipboard.writeText(b.dataset.copy).then(done,function(){});}});
  // Relative dates, absolute on hover.
  var now=Date.now();document.querySelectorAll("time").forEach(function(el){
    var d=Math.floor((now-new Date(el.dateTime+"T00:00:00Z"))/864e5);if(isNaN(d)||d<0)return;
    el.title=el.dateTime;el.textContent=d===0?"today":d===1?"yesterday":d<30?d+" days ago":el.dateTime});
  var links={};document.querySelectorAll("nav.side a").forEach(function(a){links[a.getAttribute("href").slice(1)]=a});
  // Search + kind filters.
  var q=document.getElementById("q"),empty=document.getElementById("empty"),active={};
  var items=[].slice.call(document.querySelectorAll(".kind li"));items.forEach(function(li){li._html=li.innerHTML});
  function esc(s){return s.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}
  function apply(){
    var term=q.value.trim(),kinds=Object.keys(active).filter(function(k){return active[k]}),re=term?new RegExp("("+esc(term)+")","i"):null,shown=0;
    items.forEach(function(li){
      var kindOk=!kinds.length||kinds.indexOf(li.closest(".kind").dataset.kind)>=0;
      var textOk=!re||li.textContent.toLowerCase().indexOf(term.toLowerCase())>=0;
      li.innerHTML=li._html;
      if(re&&textOk)highlight(li,re);
      li.classList.toggle("hidden",!(kindOk&&textOk))});
    document.querySelectorAll(".kind").forEach(function(s){s.classList.toggle("hidden",!s.querySelector("li:not(.hidden)"))});
    document.querySelectorAll(".release").forEach(function(r){var v=!!r.querySelector(".kind:not(.hidden)");r.classList.toggle("hidden",!v);if(v&&(term||kinds.length))setFold(r,false);if(links[r.id])links[r.id].classList.toggle("dim",!v);if(v)shown++});
    empty.style.display=shown?"none":"block"}
  // Wrap matches in <mark>, text nodes only, so links and code stay intact.
  function highlight(node,re){[].slice.call(node.childNodes).forEach(function(n){
    if(n.nodeType===1){highlight(n,re);return}
    if(n.nodeType!==3)return;
    var parts=n.data.split(re);if(parts.length<2)return;
    var frag=document.createDocumentFragment();
    parts.forEach(function(p,i){if(!p)return;if(i%2){var m=document.createElement("mark");m.textContent=p;frag.appendChild(m)}else frag.appendChild(document.createTextNode(p))});
    n.replaceWith(frag)})}
  // Collapse / expand releases.
  var rels=[].slice.call(document.querySelectorAll(".release")),foldAll=document.getElementById("foldall");
  function setFold(r,closed){r.classList.toggle("collapsed",closed);var b=r.querySelector(".fold");
    b.setAttribute("aria-expanded",closed?"false":"true");b.setAttribute("aria-label",(closed?"Expand ":"Collapse ")+r.querySelector("h3").lastChild.textContent)}
  function syncAll(){foldAll.textContent=rels.every(function(r){return r.classList.contains("collapsed")})?"Expand all":"Collapse all"}
  rels.forEach(function(r){r.querySelector(".rel-head").addEventListener("click",function(e){
    if(e.target.closest("a"))return;setFold(r,!r.classList.contains("collapsed"));syncAll()})});
  foldAll.onclick=function(){var close=foldAll.textContent==="Collapse all";rels.forEach(function(r){setFold(r,close)});syncAll()};
  // Opening a #version link expands it.
  function openHash(){var r=location.hash&&document.getElementById(location.hash.slice(1));if(r&&r.classList.contains("release")){setFold(r,false);syncAll()}}
  window.addEventListener("hashchange",openHash);openHash();
  q.addEventListener("input",apply);
  document.querySelectorAll("button.filter").forEach(function(b){b.onclick=function(){
    active[b.dataset.kind]=!active[b.dataset.kind];b.setAttribute("aria-pressed",active[b.dataset.kind]?"true":"false");apply()}});
  document.getElementById("clear").onclick=function(e){e.preventDefault();q.value="";active={};
    document.querySelectorAll("button.filter").forEach(function(b){b.setAttribute("aria-pressed","false")});apply()};
  document.addEventListener("keydown",function(e){if(e.key==="/"&&document.activeElement!==q){e.preventDefault();q.focus()}
    else if(e.key==="Escape"&&document.activeElement===q){q.value="";apply();q.blur()}});
  // Highlight the version in view.
  if("IntersectionObserver"in window){var io=new IntersectionObserver(function(es){es.forEach(function(e){
    if(e.isIntersecting){Object.keys(links).forEach(function(k){links[k].classList.remove("active")});var a=links[e.target.id];if(a)a.classList.add("active")}})},{rootMargin:"-90px 0px -65% 0px"});
    document.querySelectorAll(".release").forEach(function(r){io.observe(r)})}
})();
</script>
</body>
</html>
"""


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "_site")
    plugins = load_plugins()
    if not any(p["releases"] for p in plugins):
        sys.exit("no CHANGELOG releases found under plugins/")
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(render(plugins), encoding="utf-8")
    (out / "feed.xml").write_text(render_feed(plugins), encoding="utf-8")
    (out / ".nojekyll").write_text("")
    print("wrote %s (%d plugin(s), %d release(s))"
          % (out, len(plugins), sum(len(p["releases"]) for p in plugins)))


if __name__ == "__main__":
    main()
