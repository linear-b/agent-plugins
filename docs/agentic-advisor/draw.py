#!/usr/bin/env python3
"""Draw the agentic-advisor context diagram as hand-drawn SVGs. Usage: docs/agentic-advisor/draw.py docs/agentic-advisor"""
import math
import random
import sys
from html import escape

OUT = sys.argv[1]

# Fill/stroke per kind; var() picks up the site's theme, the fallback is used when shown as <img> (GitHub).
KINDS = {
    "lb": ("var(--brand-soft,#eef0ff)", "var(--brand,#5467ff)", "var(--brand-strong,#1831f4)"),
    "git": ("var(--success-soft,#e7f6ec)", "var(--success,#16a34a)", "var(--success,#15803d)"),
    "req": ("var(--dg-purple-soft,#f1ecff)", "var(--dg-purple,#7c5cff)", "var(--dg-purple,#6d28d9)"),
    "warn": ("var(--attention-soft,#fef3e2)", "var(--attention,#b45309)", "var(--attention,#b45309)"),
    "ok": ("var(--success-soft,#e7f6ec)", "var(--success,#16a34a)", "var(--success,#15803d)"),
    "bad": ("var(--destructive-soft,#fce8ee)", "var(--destructive,#bf1245)", "var(--destructive,#bf1245)"),
}
FG, MUTED = "var(--fg,#0a0a0a)", "var(--muted,#61656c)"


class Pen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.out = []

    def j(self, a=1.6):
        return self.r.uniform(-a, a)

    def rough_rect(self, x, y, w, h, fill, stroke, sw=1.8, opacity=None):
        if fill:
            op = ' fill-opacity="%s"' % opacity if opacity else ""
            self.out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="10" style="fill:%s"%s/>'
                            % (x, y, w, h, fill, op))
        for _ in range(2):  # two loose passes, Excalidraw-style
            p = [(x + self.j(), y + self.j()), (x + w + self.j(), y + self.j()),
                 (x + w + self.j(), y + h + self.j()), (x + self.j(), y + h + self.j())]
            d = "M%.1f %.1f " % (p[0][0] + 8, p[0][1])
            for a, b in zip(p, p[1:] + p[:1]):
                mx, my = (a[0] + b[0]) / 2 + self.j(1.2), (a[1] + b[1]) / 2 + self.j(1.2)
                d += "L%.1f %.1f " % (mx, my)
                d += "L%.1f %.1f " % (b[0] + self.j(0.8), b[1] + self.j(0.8))
            self.out.append('<path d="%s" style="fill:none;stroke:%s" stroke-width="%s" stroke-linecap="round" '
                            'stroke-linejoin="round"/>' % (d, stroke or MUTED, sw))

    def text(self, x, y, lines, size, color=FG, anchor="start", weight=None):
        if isinstance(lines, str):
            lines = [lines]
        lh = size * 1.25
        wt = ' font-weight="%s"' % weight if weight else ""
        spans = "".join('<tspan x="%.1f" dy="%s">%s</tspan>' % (x, 0 if i == 0 else lh, escape(l))
                        for i, l in enumerate(lines))
        self.out.append('<text x="%.1f" y="%.1f" font-size="%s" text-anchor="%s" style="fill:%s"%s>%s</text>'
                        % (x, y, size, anchor, color, wt, spans))

    def box(self, x, y, w, h, kind, lines, size=19):
        fill, stroke, _ = KINDS[kind]
        self.rough_rect(x, y, w, h, fill, stroke)
        lines = lines if isinstance(lines, list) else [lines]
        lh = size * 1.25
        top = y + h / 2 - (len(lines) - 1) * lh / 2 + size * 0.35
        self.text(x + w / 2, top, lines[:1], size + 1, anchor="middle", weight="700")
        if len(lines) > 1:
            self.text(x + w / 2, top + lh, lines[1:], size, color=FG, anchor="middle")

    def card(self, x, y, w, h, kind, lines, size=19):
        _, stroke, _ = KINDS[kind]
        self.rough_rect(x, y, w, h, "var(--card,#ffffff)", stroke)
        lines = lines if isinstance(lines, list) else [lines]
        lh = size * 1.25
        top = y + h / 2 - (len(lines) - 1) * lh / 2 + size * 0.35
        self.text(x + w / 2, top, lines[:1], size + 1, anchor="middle", weight="700")
        if len(lines) > 1:
            self.text(x + w / 2, top + lh, lines[1:], size, color=MUTED, anchor="middle")

    def zone(self, x, y, w, h, kind, title, note=None):
        fill, stroke, ink = KINDS[kind]
        self.rough_rect(x, y, w, h, fill, stroke, sw=1.4)
        self.text(x + 18, y + 32, title, 22, color=ink, weight="700")
        if note:
            self.text(x + 18, y + h - 14, note, 17, color=ink)

    def arrow(self, pts, color=MUTED, dashed=False):
        d = "M%.1f %.1f " % pts[0]
        for p in pts[1:]:
            d += "L%.1f %.1f " % (p[0] + self.j(0.6), p[1] + self.j(0.6))
        dash = ' stroke-dasharray="7 7"' if dashed else ""
        self.out.append('<path d="%s" style="fill:none;stroke:%s" stroke-width="2" stroke-linecap="round"%s/>'
                        % (d, color, dash))
        (x1, y1), (x2, y2) = pts[-2], pts[-1]
        a = math.atan2(y2 - y1, x2 - x1)
        for s in (2.6, -2.6):
            hx, hy = x2 - 13 * math.cos(a + s / 6), y2 - 13 * math.sin(a + s / 6)
            self.out.append('<path d="M%.1f %.1f L%.1f %.1f" style="fill:none;stroke:%s" stroke-width="2" '
                            'stroke-linecap="round"/>' % (hx, hy, x2, y2, color))

    def svg(self, w, h, title, cls):
        return ('<svg xmlns="http://www.w3.org/2000/svg" class="%s" viewBox="0 0 %d %d" role="img" '
                'aria-label="%s" font-family="Kalam, \'Comic Sans MS\', cursive">\n<title>%s</title>\n'
                # White card on GitHub (readable in its dark mode); transparent on the site.
                '<rect width="100%%" height="100%%" rx="16" style="fill:var(--dg-canvas,#ffffff)"/>\n%s\n</svg>\n'
                % (cls, w, h, escape(title, quote=True), escape(title), "\n".join(self.out)))


TITLE = ("What agentic-advisor looks at: LinearB repo health, incidents and ticket; local git history on the files "
         "you touch; and your request. Effort is the highest of the three. Only the grade and its metadata are "
         "reported to your own LinearB org; never code, file contents or full prompts.")


def wide():
    p = Pen(7)
    p.text(590, 40, "What LinearB looks at before your agent writes code", 30, anchor="middle", weight="700")
    p.box(20, 330, 220, 130, "warn", ["You start a code task", "prompt, ticket key,", "or first file edit"], 18)
    p.zone(290, 80, 560, 250, "lb", "1. LinearB API (your org, read-only)", "repo health cached 24h · ticket only when a key is named")
    p.card(308, 130, 170, 145, "lb", ["Repo health", "rework % (30d)", "unreviewed", "merges"], 18)
    p.card(493, 130, 170, 145, "lb", ["Incidents", "recent + open,", "org-wide"], 18)
    p.card(678, 130, 155, 145, "lb", ["Ticket", "type, priority,", "points, labels"], 18)
    p.zone(290, 350, 560, 220, "git", "2. Local git (stays on your machine)", "only on fragile repos or sensitive files")
    p.card(308, 400, 255, 120, "git", ["Files you'll touch", "lines rewritten (90d)", "fix / revert hints"], 18)
    p.card(578, 400, 255, 120, "git", ["Ownership", "who owns the lines,", "is it your code?"], 18)
    p.zone(290, 590, 560, 125, "req", "3. Your request (no calls)")
    p.card(308, 638, 525, 58, "req", ["scope, breadth, tricky logic, blast radius"], 18)
    for (x, y) in ((290, 205), (290, 460), (290, 652)):
        p.arrow([(240, 395), (x, y)])
    p.box(905, 300, 255, 100, "warn", ["Effort =", "highest of 1, 2, 3"], 20)
    for (x, y) in ((850, 205), (850, 460), (850, 652)):
        p.arrow([(x, y), (905, 350)])
    p.arrow([(1032, 400), (1032, 440)])
    p.box(905, 440, 255, 56, "ok", ["LOW", "lean, small diff"], 17)
    p.box(905, 506, 255, 56, "warn", ["MEDIUM", "normal care"], 17)
    p.box(905, 572, 255, 66, "bad", ["HIGH", "guards, tests, questions"], 17)
    p.text(1032, 665, "printed as one verdict line", 17, color=MUTED, anchor="middle")
    p.zone(290, 740, 870, 150, "warn", "Reported to your own LinearB org (turn off: LINEARB_TELEMETRY=0)")
    p.card(308, 788, 500, 84, "ok", ["Sent", "grade + evidence, repo, branch, ticket key,", "your email, token counts"], 17)
    p.card(825, 788, 318, 84, "bad", ["Never sent", "source code, file contents,", "full prompts"], 17)
    p.arrow([(1160, 605), (1185, 605), (1185, 760), (1162, 760)], color="var(--attention,#b45309)", dashed=True)
    return p.svg(1200, 910, TITLE, "wide")


def tall():
    p = Pen(11)
    p.text(300, 38, "What LinearB looks at", 30, anchor="middle", weight="700")
    p.text(300, 70, "before your agent writes code", 20, color=MUTED, anchor="middle")
    p.box(40, 95, 520, 80, "warn", ["You start a code task", "prompt, ticket key, or first file edit"], 19)
    p.arrow([(300, 175), (300, 205)])
    p.zone(20, 205, 560, 310, "lb", "1. LinearB API (your org, read-only)", "repo health is cached for 24 hours")
    p.card(40, 255, 250, 115, "lb", ["Repo health", "rework % (30d)", "unreviewed merges"], 19)
    p.card(310, 255, 250, 115, "lb", ["Incidents", "recent + open", "org-wide"], 19)
    p.card(40, 385, 520, 85, "lb", ["Ticket", "type, priority, points, labels", "(only when a key is named)"], 18)
    p.zone(20, 535, 560, 225, "git", "2. Local git (stays on your machine)", "only on fragile repos or sensitive files")
    p.card(40, 585, 250, 125, "git", ["Files you'll touch", "lines rewritten", "(90d), fix/revert"], 19)
    p.card(310, 585, 250, 125, "git", ["Ownership", "who owns the lines,", "is it your code?"], 19)
    p.zone(20, 780, 560, 130, "req", "3. Your request (no calls)")
    p.card(40, 830, 520, 60, "req", ["scope, breadth, tricky logic, blast radius"], 18)
    p.arrow([(300, 910), (300, 940)])
    p.box(130, 940, 340, 80, "warn", ["Effort =", "highest of 1, 2, 3"], 21)
    p.arrow([(300, 1020), (300, 1050)])
    p.box(20, 1050, 175, 80, "ok", ["LOW", "lean, small diff"], 18)
    p.box(212, 1050, 175, 80, "warn", ["MEDIUM", "normal care"], 18)
    p.box(404, 1050, 176, 80, "bad", ["HIGH", "guards + tests"], 18)
    p.text(300, 1160, "printed as one verdict line", 18, color=MUTED, anchor="middle")
    p.arrow([(300, 1172), (300, 1198)], color="var(--attention,#b45309)", dashed=True)
    p.zone(20, 1200, 560, 300, "warn", "Reported to your own LinearB org", "turn off: LINEARB_TELEMETRY=0")
    p.card(40, 1250, 520, 95, "ok", ["Sent", "grade + evidence, repo, branch,", "ticket key, your email, token counts"], 18)
    p.card(40, 1360, 520, 90, "bad", ["Never sent", "source code, file contents, full prompts"], 18)
    return p.svg(600, 1520, TITLE, "tall")


open(OUT + "/context.svg", "w").write(wide())
open(OUT + "/context.tall.svg", "w").write(tall())
print("ok")
