#!/usr/bin/env python3
"""Builds Mercury's website into docs/ (served by GitHub Pages). Run: python3 tools/build_site.py

Plain HTML and CSS, system fonts, no cookies, no analytics and no outside requests, so visiting
the site shares nothing about the visitor.
"""
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
REPO = "https://github.com/HarryNGU/mercury"
SITE = "https://harryngu.github.io/mercury/"
UPDATED = "3 November 2026"

GLYPH = {
    "record": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><rect x="3" y="3.5" width="18" height="13.5" rx="3.5" stroke="var(--accent)"/><circle cx="7" cy="16.5" r="5.8" fill="var(--bg)" stroke="none"/><circle cx="7" cy="16.5" r="4.5" fill="var(--accent)" stroke="none"/><circle cx="7" cy="16.5" r="1.4" fill="#fff" stroke="none"/><circle cx="17" cy="8.2" r="1.6" fill="var(--accent)" stroke="none"/></svg>',
    "reels": '<svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.9" stroke-linejoin="round"><rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M10.5 9.2v5.6l4.6-2.8z" fill="var(--accent)" stroke="none"/></svg>',
    "dictate": '<svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 3h9a5 5 0 0 1 5 5v4a5 5 0 0 1-5 5H11l-5.5 4 1.5-4h.5a5 5 0 0 1-5-5V8a5 5 0 0 1 5-5z"/><path d="M7.5 8.5v3M10.5 6.5v7M13.5 7.5v5M16.5 8.8v2.4" stroke-width="2.1"/></svg>',
    "assist": '<svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.9"><circle cx="11" cy="13" r="8"/><circle cx="11" cy="13" r="3.4" fill="var(--accent)" stroke="none"/><circle cx="18.5" cy="5.5" r="4.2" fill="var(--bg)" stroke="none"/><circle cx="18.5" cy="5.5" r="2.9" fill="var(--accent)" stroke="none"/></svg>',
}

NAV = [("index.html#features", "Features"), ("get-started.html", "Get started"), ("security.html", "Safety"), ("faq.html", "FAQ")]
V = "20"  # bump to refresh cached CSS and JS

# Mercury for Windows (early test). The installer is attached to a GitHub release of its own,
# tagged windows-vX.Y.Z and marked as a pre release so the Mac "latest" link never changes.
WIN_VERSION = "0.1.3"
WIN_FILE = f"Mercury-Setup-{WIN_VERSION}.exe"
WIN_URL = f"{REPO}/releases/download/windows-v{WIN_VERSION}/{WIN_FILE}"
WIN_SIZE = "118 MB"
WIN_SHA = "78b704cef052be37c1bae86dd9964c2408e71a80fd88a56a83c4454f68f4e000"

ICON = {
    "lock": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="10.5" width="15" height="10" rx="3"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/></svg>',
    "hand": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4.5a1.5 1.5 0 0 1 3 0V12M14 11.5V6a1.5 1.5 0 0 1 3 0v8.5a6.5 6.5 0 0 1-6.5 6.5c-2.4 0-3.9-1-5.1-2.9L3.6 15a1.5 1.5 0 0 1 2.4-1.8L8 15.5"/></svg>',
    "send": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M21 3 10 14M21 3l-7 18-4-7-7-4z"/></svg>',
    "code": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="m8 7-5 5 5 5M16 7l5 5-5 5M13.5 4l-3 16"/></svg>',
    "apple": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M16.4 12.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9-1.7 0-3.3 1-4.2 2.6-1.8 3.1-.5 7.7 1.3 10.2.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8 1.6 0 2 .8 3.4.8 1.4 0 2.3-1.3 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9-.1 0-2.7-1-2.7-4.1zM13.9 5c.7-.9 1.2-2 1-3.2-1 0-2.3.7-3 1.6-.7.8-1.3 2-1.1 3.1 1.1.1 2.3-.6 3.1-1.5z"/></svg>',
    "windows": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 5.2 10.4 4v7.4H3zM11.6 3.8 21 2.4v9H11.6zM3 12.6h7.4V20L3 18.8zM11.6 12.6H21v9l-9.4-1.4z"/></svg>',
    "play": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.5v13l11-6.5z"/></svg>',
    "speaker": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>',
}


def page(name, title, desc, body, home=False):
    def link(href, label):
        cur = ' aria-current="page"' if href == name else ""
        return f'<a href="{href}"{cur}>{label}</a>'
    nav = "".join(link(h, l) for h, l in NAV)
    canon = SITE + ("" if name == "index.html" else name)
    html = f"""<!doctype html>
<html lang="en" data-tone="{'dark' if home else 'light'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<meta name="referrer" content="no-referrer">
<meta name="theme-color" content="#04050a">
<link rel="canonical" href="{canon}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Mercury">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{canon}">
<meta property="og:image" content="{SITE}assets/og.png?v=3">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Mercury, a personal assistant for the Mac, shown as a blue and gold planet">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{desc}">
<meta name="twitter:image" content="{SITE}assets/og.png?v=3">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; base-uri 'self'; form-action 'none'">
<link rel="icon" href="assets/favicon.png?v=2">
<link rel="apple-touch-icon" href="assets/icon.png?v=2">
<link rel="stylesheet" href="assets/style.css?v={V}">
</head>
<body class="{'home' if home else 'inner'}">
<header class="nav-shell">
<nav class="bar" aria-label="Main">
<a class="brand" href="index.html"><img class="mark" src="assets/favicon.png?v=2" alt="" width="22" height="22">Mercury</a>
<div class="links">{nav}</div>
<a href="index.html#download" class="btn primary small nav-cta">Download</a>
<button class="menu-btn" aria-label="Menu" aria-expanded="false"><span></span><span></span></button>
</nav>
<div class="drawer">{nav}<a href="index.html#download" class="btn primary">Download</a></div>
</header>
<main>
{body}
</main>
<footer class="site" data-tone="dark"><div class="wrap">
<div class="foot-mark"><img src="assets/planet.png" alt="" width="1024" height="1024" loading="lazy"></div>
<div class="cols">
<div><a class="brand" href="index.html"><img class="mark" src="assets/favicon.png?v=2" alt="" width="22" height="22">Mercury</a><p class="about">Mercury, the messenger. A personal assistant for your Mac or Windows PC. Free and open source, with no account, no tracking and no ads.</p></div>
<div><h4>Product</h4><ul><li><a href="index.html#download">Download</a></li><li><a href="index.html#features">Features</a></li><li><a href="get-started.html">Get started</a></li><li><a href="windows.html">Mercury for Windows</a></li><li><a href="faq.html">FAQ</a></li><li><a href="{REPO}">Source code</a></li></ul></div>
<div><h4>Trust</h4><ul><li><a href="security.html">Safety and security</a></li><li><a href="privacy.html">Privacy policy</a></li><li><a href="terms.html">Terms of use</a></li><li><a href="notices.html">Open source notices</a></li></ul></div>
<div><h4>Help</h4><ul><li><a href="{REPO}/issues">Report a problem</a></li><li><a href="{REPO}/security/advisories/new">Report a security issue</a></li><li><a href="get-started.html#uninstall">Uninstall</a></li></ul></div>
</div>
<p class="fine-print">Mercury is an independent open source project for Mac and Windows. It isn't connected to any bank, company or other product called Mercury. This site doesn't use cookies or analytics, and it's hosted on GitHub Pages.</p>
</div></footer>
<script src="assets/site.js?v={V}"></script>
</body>
</html>
"""
    (DOCS / name).write_text(html)


def head(kicker, title, lede):
    return f'<section class="page-head" data-tone="dark"><div class="glow"></div><div class="wrap narrow"><span class="kicker rise">{ORBIT}{kicker}</span><h1 class="rise" style="--d:.05s">{title}</h1><p class="rise" style="--d:.1s">{lede}</p></div></section>'


def doc(name, title, desc, inner, kicker="Trust"):
    page(name, f"{title} · Mercury", desc, head(kicker, title, desc) + f'<div class="wrap narrow doc"><p class="updated">Last updated {UPDATED}</p>{inner}</div>')


def ring(words):
    """A key phrase with a thin orbit drawn around it, and a small moon travelling the orbit."""
    path = "M4,30 a96,26 0 1,0 192,0 a96,26 0 1,0 -192,0"
    return (f'<span class="ringed">{words}<svg class="ring" viewBox="0 0 200 60" preserveAspectRatio="none" aria-hidden="true">'
            f'<path d="{path}" pathLength="1"/>'
            f'<circle class="moon" r="3.4"><animateMotion dur="11s" repeatCount="indefinite" path="{path}"/></circle></svg></span>')


# A heading's full stop drawn as a tiny planet (the real "." is still there for copying and screen readers).
DOT = '<span class="pdot">.</span>'
ORBIT = '<svg class="orb" viewBox="0 0 20 20" aria-hidden="true"><ellipse cx="10" cy="10" rx="8.5" ry="4.2" transform="rotate(-18 10 10)"/><circle cx="10" cy="10" r="2.6"/></svg>'


# ─────────────────────────────── Home ───────────────────────────────
PLANET = '<img class="pl" src="assets/favicon.png?v=2" alt="" width="64" height="64">'


def you(text):
    return f'<div class="m you">{text}</div>'


def me(text):
    return f'<div class="m me">{text}</div>'


def panel(body, context="", extra=""):
    ctx = f'<div class="ctx"><span class="eye"></span>{context}</div>' if context else ""
    return f'''<div class="panel{extra}"><div class="ph">{PLANET}<b>Mercury</b><span class="dots"><i></i><i></i></span></div>
{ctx}<div class="pbody">{body}</div><div class="pin"><span>Ask anything</span><i class="mic"></i></div></div>'''


APPROVAL = '''<div class="approve"><small>To: Sam Lee · Re: Study group</small><p>Hi Sam, I'll be there at 6. See you then!</p>
<div class="ask"><span>✋ Send this email?</span><div class="btns"><span>Deny</span><span class="yes">Allow once</span></div></div></div>'''

WAVE = '<div class="wave">' + "".join(f'<i style="--h:{h}"></i>' for h in (3, 6, 9, 5, 11, 7, 4, 10, 6, 8, 3, 7, 12, 5, 8, 4, 9, 6, 3, 5)) + "</div>"

MOCKS = [
    panel(you("Why is caffeine so bitter?") + me("It's the shape. Caffeine fits the bitter taste receptors on your tongue, so they fire as if it were a warning. Here's the molecule from your notes:")
          + '<div class="card mol"><svg viewBox="0 0 120 70" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="2"><path d="M30 15l17 10v20l-17 10-17-10V25z"/><path d="M47 25l16-6 10 14-10 14-16-2"/><path d="M30 15V4M13 55l-9 5M73 33h12"/></g><g font-size="7" fill="currentColor" font-family="-apple-system,sans-serif"><text x="2" y="64">O</text><text x="86" y="36">N</text><text x="27" y="3">O</text></g></svg><span>Caffeine · C₈H₁₀N₄O₂</span></div>',
          "Looking at Notion · Chemistry notes"),
    panel(you("Plan my revision week around work") + me("Here's a plan that fits your shifts:")
          + '<div class="card plan"><div><b>Mon</b><span>Chemistry practice exam</span></div><div><b>Tue</b><span>Shift 4 to 9, light review only</span></div><div><b>Wed</b><span>Methods, chapter 6 questions</span></div><div><b>Thu</b><span>Go over Monday\'s mistakes</span></div></div>'
          + '<div class="chips"><span>From your calendar</span><span>From your notes</span></div>'),
    panel(you("Reply to Sam and say I'll be there at 6") + me("Here's the reply. I'll wait for you.") + APPROVAL, "Looking at Gmail"),
    '<div class="field"><div class="fh"><i></i><i></i><i></i><span>Messages · Mia</span></div><div class="bub them">Are you still coming tonight?</div>'
    '<div class="typing"><span class="t">Yes! Running about ten minutes late, save me a seat</span><span class="caret"></span></div>'
    f'<div class="dict">{WAVE}<span>Listening</span><kbd>⌥</kbd><kbd>⌥</kbd></div></div>',
    panel('<div class="live"><span class="rec"></span>Listening to Zoom</div>'
          + '<div class="tx"><p><b>Priya</b> So what do you think the main risk is?</p><p><b>Tom</b> I\'d say the timeline, honestly.</p></div>'
          + you("What should I say?") + me("Agree on the timeline, then add that the budget review lands the same week. Suggest moving it back by a week."), ""),
    '<div class="reels"><div class="phone"><div class="cap">Pauses are cut out</div></div><div class="phone mid"><div class="cap">Captions timed to you</div></div><div class="phone"><div class="cap">One click, every size</div></div>'
    '<div class="pill"><span class="rec"></span>02:14<i class="stop"></i></div><div class="cam"></div></div>',
]

FEATURES = [
    ("Ask", "Ask about anything on your screen", "If you're stuck on something in your notes, a chart in Excel or a paragraph in a PDF, press ⌥\\ and ask. Mercury looks at your screen and answers the way a friend would over text, with pictures, videos and links when they help.",
     ["It only looks at your screen when you ask", "Diagrams, molecules and videos show up in the chat", "It works over any app, so there's nothing to copy"], "<kbd>⌥</kbd><kbd>\\</kbd> to open it"),
    ("Knows you", "It already knows you", "Mercury works with the AI you already use. Connect Claude and it knows your notes, your calendar and your inbox. If you use ChatGPT, you can bring over what it remembers about you with one paste.",
     ["Uses your Claude memory and connected apps", "Brings in what ChatGPT knows about you", "Kept on your Mac, and you can delete it any time"], ""),
    ("Do", "It writes, you send", "Say “reply to Sam and tell him I'll be there at 6” and Mercury writes the reply in Gmail or Outlook, shows it to you, and waits. It only sends once you tap Allow or say “yes”.",
     ["Drafts in Gmail, Outlook, Messages, Instagram and Messenger", "Shows an Allow or Deny card before anything is sent", "Chat messages are typed in for you to send yourself"], ""),
    ("Dictate", "Talk instead of typing", "Double tap Option in iMessage, Slack, Word or anywhere else and start talking. Mercury types a tidy version where your cursor is, and stops on its own when you pause.",
     ["Works in any text box on your Mac", "Takes out the ums and applies your corrections", "Your speech is turned into text on your Mac"], "<kbd>⌥</kbd><kbd>⌥</kbd> double tap"),
    ("Listen", "Help during calls", "Turn on Listen during a Zoom or Google Meet call, a lecture or a video. Mercury hears your Mac's sound (never your microphone) and can suggest what to say, or sum up what you missed.",
     ["Ask “what should I say?” with one tap", "Summaries and to do lists from long calls", "A red dot shows whenever it's listening"], ""),
    ("Record", "Record once, post anywhere", "Hover over any window and click to record. Your face sits in a round bubble and the background noise is gone. Then edit it properly in Mercury, or make captioned versions for Reels, TikTok, Shorts and YouTube in one click.",
     ["Pauses are cut out for you", "Big captions timed to what you say", "A full editor with sound clean up, text, zooms and music"], "<kbd>⌘</kbd><kbd>\\</kbd> to record"),
]

FEAT_HTML = "".join(
    f'''<article class="feat" data-i="{i}"><div class="num">{k}</div><h3>{t}</h3><p>{d}</p>
<ul class="ticks">{"".join(f"<li>{x}</li>" for x in ticks)}</ul>{f'<div class="keys">{keys}</div>' if keys else ""}
<div class="inline-mock">{MOCKS[i]}</div></article>'''
    for i, (k, t, d, ticks, keys) in enumerate(FEATURES)
)
STAGE_HTML = "".join(f'<div class="mock{" on" if i == 0 else ""}" data-i="{i}">{m}</div>' for i, m in enumerate(MOCKS))

APPS = [("Gmail", "#ea4335"), ("Zoom", "#2d8cff"), ("Notion", "#e8e6e1"), ("Slack", "#e01e5a"), ("Messages", "#34c759"),
        ("Excel", "#21a366"), ("Instagram", "#d62976"), ("GoodNotes", "#4e8cf6"), ("Outlook", "#0a64d6"), ("Google Meet", "#00ac47"),
        ("Word", "#2b7cd3"), ("Safari", "#1e9bf0")]
ORBIT_HTML = "".join(
    f'<div class="sat" style="--a:{i * 360 / len(APPS):.1f}deg;--r:{(1 if i % 2 else 0.72)}"><span><i style="background:{c}"></i>{n}</span></div>'
    for i, (n, c) in enumerate(APPS)
)

DAY = [
    ("8:30", "Gmail", "#ea4335", "Replying before class", "Reply to Ms Lee: I'll hand the lab report in on Friday.", "Written in Gmail. You read it and press Send yourself."),
    ("10:00", "Zoom", "#2d8cff", "Lost in a lecture", "What did she mean by activation energy?", "A plain answer with a diagram while the lecture keeps going."),
    ("13:15", "Notion", "#e8e6e1", "Writing up notes", "Double tap ⌥ and talk through what you learned.", "Tidy notes, typed where your cursor is."),
    ("17:40", "Instagram", "#d62976", "Running late", "Tell Mia I'm 10 minutes away.", "Typed into her chat, and you press send."),
    ("21:00", "GoodNotes", "#4e8cf6", "Checking homework", "Is my working for question 4 right?", "Spots the mistake in step 2 and explains it."),
]
DAY_HTML = "".join(
    f'''<div class="moment reveal" style="--d:{i * 0.07:.2f}s"><div class="when">{t}<span class="app"><i style="background:{c}"></i>{app}</span></div>
<h3>{title}</h3><div class="said">{said}</div><div class="then">{then}</div></div>'''
    for i, (t, app, c, title, said, then) in enumerate(DAY)
)

CONTROL = [
    ("Looks at your screen", "Only when you ask a question, and only one screenshot each time.", '<span class="tag">You can turn it off</span>'),
    ("Hears your Mac's sound", "Only while you've turned Listen on.", '<span class="tag"><span class="dot"></span>Red dot while on</span>'),
    ("Hears your voice", "Only while you're dictating or talking to it.", '<span class="tag">You start it</span>'),
    ("Sends an email or message", "Only after you tap Allow or say “yes”. Chat messages are typed in for you to send.", '<span class="tag">Your OK first</span>'),
    ("Changes files or apps", "Only after you see exactly what it will do, and allow it.", '<span class="tag">Your OK first</span>'),
    ("Works in the background", "Never. Nothing happens unless you ask for it.", '<span class="tag never">Never</span>'),
    ("Collects or sells your data", "Never. No account, no tracking, no analytics.", '<span class="tag never">Never</span>'),
]
CONTROL_HTML = "".join(f'<div class="row reveal" style="--d:{i * 0.05:.2f}s"><b>{a}</b><span>{b}</span>{c}</div>' for i, (a, b, c) in enumerate(CONTROL))

WIN_DEMO = """<div class="win-demo" aria-hidden="true">
<figure><div class="ss"><b>Windows protected your PC</b><p>Microsoft Defender SmartScreen prevented an unrecognised app from starting.</p><span class="hl">More info</span><div class="ss-btns"><i>Don't run</i></div></div><figcaption>First, click <strong>More info</strong>.</figcaption></figure>
<figure><div class="ss"><b>Windows protected your PC</b><p>App: Mercury-Setup-""" + WIN_VERSION + """.exe<br>Publisher: Unknown publisher</p><div class="ss-btns"><i class="hl">Run anyway</i><i>Don't run</i></div></div><figcaption>Then click <strong>Run anyway</strong>.</figcaption></figure>
</div>"""

# People rarely read install guides, so clicking any "Download for Windows" button starts the
# download and opens these steps on top of the page, right when they're needed.
WIN_STEPS = f"""<dialog class="wsteps" id="winSteps" aria-labelledby="winStepsTitle">
<div class="ws-head"><h2 id="winStepsTitle">Your download has started</h2><button class="ws-x" data-close aria-label="Close">×</button></div>
<p class="ws-lead">Three quick steps and Mercury is ready. Keep this open while you go.</p>
<ol class="ws-list">
<li><strong>If your browser asks, keep the file.</strong><span>Mercury is new, so browsers may say it isn't commonly downloaded. In <b>Edge</b>, click the three dots next to the file, then <b>Keep</b>, <b>Show more</b> and <b>Keep anyway</b>. In <b>Chrome</b>, click <b>Keep</b>.</span></li>
<li><strong>Open <code>{WIN_FILE}</code></strong><span>Click it in your browser's downloads, or find it in your Downloads folder.</span></li>
<li><strong>Windows shows a blue box. Click More info, then Run anyway.</strong><span>Windows does this for any app it hasn't seen many times before.</span>{WIN_DEMO}</li>
</ol>
<p class="ws-done">Mercury then installs itself in seconds and opens. Pick the free AI and you're done. No account, no password.</p>
<div class="ws-foot"><a href="{WIN_URL}">Download didn't start? Try again</a><button class="btn primary small" data-close>Got it</button></div>
</dialog>"""

MAC_FIG_DONE = """<figure><div class="md-alert"><img src="assets/icon.png?v=2" alt=""><b>“Mercury” Not Opened</b><p>Apple could not verify “Mercury” is free of malware that may harm your Mac or compromise your privacy.</p><div class="md-btns"><i class="hl">Done</i><i>Move to Bin</i></div></div><figcaption>Click <strong>Done</strong>. Not Move to Bin.</figcaption></figure>"""
MAC_FIG_OPEN = """<figure><div class="md-set"><div class="md-side"><i></i><i></i><i class="on">Privacy &amp; Security</i><i></i></div><div class="md-main"><b>Security</b><p>“Mercury” was blocked to protect your Mac.</p><span class="hl">Open Anyway</span></div></div><figcaption>In <strong>Privacy &amp; Security</strong>, scroll down and click <strong>Open Anyway</strong>.</figcaption></figure>"""
MAC_DEMO = f'<div class="mac-demo" aria-hidden="true">{MAC_FIG_DONE}{MAC_FIG_OPEN}</div>'

MAC_STEPS = f"""<dialog class="wsteps" id="macSteps" aria-labelledby="macStepsTitle">
<div class="ws-head"><h2 id="macStepsTitle">Your download has started</h2><button class="ws-x" data-close aria-label="Close">×</button></div>
<p class="ws-lead">Mercury is free and made by one person, so Apple hasn't checked it yet and your Mac will stop it the first time. Here's the one minute way past that. Keep this open while you go.</p>
<ol class="ws-list">
<li><strong>Open the download and drag Mercury into Applications.</strong><span>Click the Mercury file in your Downloads (it ends in <code>.dmg</code>), then drag the planet onto the Applications folder.</span></li>
<li><strong>Open Mercury. Your Mac says it can't be opened. Click Done.</strong><span>That's normal for any app Apple hasn't checked. Nothing is wrong with your Mac.</span><div class="mac-demo one" aria-hidden="true">{MAC_FIG_DONE}</div></li>
<li><strong>Open System Settings, then Privacy &amp; Security. Scroll down and click Open Anyway.</strong><span>It's next to “Mercury was blocked”. Click <b>Open Anyway</b> once more and type your Mac password. You only do this once.</span><div class="mac-demo one" aria-hidden="true">{MAC_FIG_OPEN}</div><a class="ws-open" href="x-apple.systempreferences:com.apple.preference.security?Security">Take me to Privacy &amp; Security</a></li>
</ol>
<p class="ws-done">Mercury then opens and introduces itself. After this first time it opens like any other app.</p>
<div class="ws-foot"><a data-release="url" href="{REPO}/releases/latest">Download didn't start? Try again</a><button class="btn primary small" data-close>Got it</button></div>
</dialog>"""

MAC_BTN = f'<a class="btn primary" data-release="url" data-mac-download data-first="mac" href="{REPO}/releases/latest">{ICON["apple"]}Download for Mac</a>'
WIN_BTN = f'<a class="btn primary" href="{WIN_URL}" data-win-download data-first="windows">{ICON["windows"]}Download for Windows</a>'

HOME = f"""
<section class="scene" data-tone="dark" aria-label="Introduction">
<div class="scene-pin">
<canvas class="space" aria-hidden="true"></canvas>
<img class="space-fallback" src="assets/planet.png" alt="" width="1024" height="1024">
<div class="intro">
<span class="kicker">{ORBIT}Mercury, the messenger</span>
<h1>The personal assistant <br>that lives on {ring("your desktop")}{DOT}</h1>
<p class="lede">In the old stories, Mercury carried messages for the gods. Now it runs errands on your Mac or Windows PC, and checks with you before anything goes out.</p>
<div class="actions dl2">{MAC_BTN}{WIN_BTN}</div>
<p class="meta">Free and open source. For macOS 15 or later, and Windows 10 and 11 (early test).</p>
</div>
<div class="meet" aria-hidden="true"><span class="kicker">{ORBIT}Meet Mercury</span><p>Small enough to stay out of your way.<br>Clever enough to help with anything on your screen.</p></div>
<div class="laptop" aria-hidden="true"><div class="bezel"><i class="notch"></i></div><div class="base"><i></i></div></div>
<div class="screen-ui" aria-hidden="true"><div class="screen-inner">
<div class="menubar"><b></b><strong>Preview</strong><span>File</span><span>Edit</span><span>View</span><span>Window</span><em><img src="assets/favicon.png?v=2" alt="">Wed 9:41</em></div>
<div class="win-title">Mercury in colour.png</div>
<div class="panel live-panel"><div class="ph">{PLANET}<b>Mercury</b><span class="dots"><i></i><i></i></span></div>
<div class="ctx"><span class="eye"></span>Looking at Preview</div>
<div class="pbody"><div class="m you q">What am I looking at?</div><div class="m me a" data-type="That's the planet Mercury in enhanced colour. The tan patches are old volcanic plains, the deep blue is darker rock, and the bright streaks are fresh material thrown out by a young crater."></div></div>
<div class="pin"><span>Ask anything</span><i class="mic"></i></div></div>
</div></div>
<p class="caption">It lives on your screen, over whatever you're doing.</p>
<div class="scroll-hint" aria-hidden="true"><i></i></div>
</div>
</section>

<section class="orbit-sec" data-tone="dark"><div class="wrap">
<div class="head reveal"><span class="kicker">{ORBIT}Works everywhere</span><h2>The apps you already use, {ring("with help")}{DOT}</h2><p>There's nothing new to learn. Mercury shows up over any app on your computer whenever you need a hand, and gets out of the way when you don't.</p></div>
<div class="orbit reveal" aria-hidden="true"><div class="ring r1"></div><div class="ring r2"></div><div class="core"><img src="assets/planet.png" alt="" width="1024" height="1024" loading="lazy"></div><div class="sats">{ORBIT_HTML}</div></div>
<div class="day">{DAY_HTML}</div>
</div></section>

<section class="features" id="features" data-tone="dark"><div class="wrap">
<div class="head reveal"><span class="kicker">{ORBIT}What it does</span><h2>One messenger for {ring("everything")} you do{DOT}</h2></div>
<div class="feat-grid">
<div class="feat-list">{FEAT_HTML}</div>
<div class="feat-stage"><div class="stage-inner"><div class="halo"></div>{STAGE_HTML}</div></div>
</div>
</div></section>

<section class="control-sec" id="control" data-tone="light"><div class="wrap">
<div class="head reveal"><span class="kicker">{ORBIT}You're in control</span><h2>Nothing happens {ring("without you")}{DOT}</h2><p>Mercury can see, hear and do things on your Mac, so here's exactly when it does each of them.</p></div>
<div class="control">
<div><div class="ledger">{CONTROL_HTML}</div>
<p class="ledger-foot reveal">Mercury is open source, so anyone can check it does what this page says. <a href="security.html">Read the full safety details</a></p></div>
</div>
<div class="film reveal">
<video src="assets/mercury-film.mp4?v=5" poster="assets/film-poster.jpg?v=6" preload="none" playsinline width="1600" height="900" aria-label="A short film: six people around the world on a Monday morning, and Mercury helping each of them get something done"></video>
<button class="play" type="button" aria-label="Play the film with sound">{ICON['play']}<span>Play the film</span></button>
</div>
<p class="film-cap reveal">54 seconds, best with sound on.</p>
</div></section>

<section class="steps-sec" data-tone="light"><div class="wrap">
<div class="head reveal"><span class="kicker">{ORBIT}Getting started</span><h2>Set up in about {ring("two minutes")}{DOT}</h2><p>Mercury introduces itself and asks before each step, and you can skip anything you like.</p></div>
<div class="steps3">
<div class="step reveal"><b class="n">Step 1</b><h3>Download</h3><p>A small download for any Mac on macOS 15 or later. Drag it into Applications.</p><div class="art"><img src="assets/icon.png?v=2" alt="" width="512" height="512" loading="lazy"></div></div>
<div class="step reveal" style="--d:.1s"><b class="n">Step 2</b><h3>Say hello</h3><p>A short chat sets things up and explains each permission before macOS asks for it.</p><div class="art chat"><div class="m me">Hi! I'm Mercury. What should I call you?</div><div class="m you">Alex is fine</div></div></div>
<div class="step reveal" style="--d:.2s"><b class="n">Step 3</b><h3>Press and ask</h3><p>In any app, press the shortcut and ask your first question.</p><div class="art keys-big"><kbd>⌥</kbd><kbd>\\</kbd></div></div>
</div>
</div></section>

<section class="faq-sec" data-tone="dark"><div class="wrap narrow">
<div class="head reveal"><span class="kicker">{ORBIT}Questions</span><h2>Common questions</h2></div>
<div class="faq reveal">
<details><summary>Is Mercury really free?</summary><p>Yes. It's open source, with no paid version and no ads. The assistant uses an AI you bring yourself (your Claude plan or your own API key).</p></details>
<details><summary>Can Mercury do anything without me knowing?</summary><p>No. It only looks, listens or does something when you ask. A red dot shows while it's listening, and anything that sends or changes something waits for you to press Allow.</p></details>
<details><summary>I use ChatGPT. Does Mercury know what it knows about me?</summary><p>You can bring it over. Mercury gives you a short prompt to paste into ChatGPT, and you paste the answer back. It's saved on your Mac and you can delete it any time. Mercury's answers themselves come from Claude.</p></details>
<details><summary>Which Macs does it work on?</summary><p>Any Mac on macOS 15 Sequoia or later, with Apple silicon or Intel. There's also an <a href=\"windows.html\">early test version for Windows 10 and 11</a>, and no phone version yet.</p></details>
<details><summary>Is this the Mercury bank?</summary><p>No. This Mercury is a free, open source assistant app for Mac and Windows, made by one person. It has nothing to do with any bank or company of the same name.</p></details>
</div>
<p class="more reveal"><a href="faq.html">More questions and answers</a></p>
</div></section>

{WIN_STEPS}
{MAC_STEPS}
<section class="download" id="download" data-tone="dark">
<div class="horizon" aria-hidden="true"><img src="assets/planet.png" alt="" width="1024" height="1024" loading="lazy"></div>
<div class="wrap narrow cta reveal">
<img class="cta-icon" src="assets/icon.png?v=2" alt="" width="512" height="512" loading="lazy">
<h2>Get Mercury</h2>
<div data-available="false"><p>Mercury is in a small private beta at the moment. The public download is coming soon.</p>
<a class="btn primary" href="{REPO}">Follow on GitHub</a>
<p class="fine">On GitHub, choose Watch, then Custom, then Releases, and you'll hear as soon as it's out.</p></div>
<div data-available="true" hidden>
<p>Free, for Mac and Windows. Pick your computer.</p>
<div class="dl2">
<div class="dlcard" data-first="mac"><b>{ICON['apple']}Mac</b><a class="btn primary" data-release="url" data-mac-download href="{REPO}/releases/latest">Download for Mac</a><p class="fine">macOS 15 or later · Version <span data-release="version">1.4.3</span> · <span data-release="size">13.4 MB</span> · <a href="get-started.html">Install guide</a></p></div>
<div class="dlcard" data-first="windows"><b>{ICON['windows']}Windows</b><a class="btn primary" href="{WIN_URL}" data-win-download>Download for Windows</a><p class="fine">Windows 10 and 11 · Early test, version {WIN_VERSION} · {WIN_SIZE} · <a href="windows.html">Install guide</a></p></div>
</div>
</div>
<div data-os="ios android" class="elsewhere" hidden><p>Mercury runs on a Mac or a Windows PC, not on phones. Open this page on your computer to download it.</p></div>
<div data-os="linux chromeos other" class="elsewhere" hidden><p>There's no Linux or ChromeOS version yet. Follow it on <a href="{REPO}">GitHub</a> to hear if that changes.</p></div>
</div>
</section>
"""

# ─────────────────────────────── Windows ───────────────────────────────


WINDOWS = f"""
{WIN_STEPS}
<div class="wrap narrow doc">
<div class="win-get">
<a class="btn primary" href="{WIN_URL}" data-win-download>{ICON['windows']}Download for Windows</a>
<p>Version {WIN_VERSION} · {WIN_SIZE} · Windows 10 or 11 (64 bit) · Free, no account</p>
</div>

<h2 id="install">Install in four steps</h2>
<ol class="steps">
<li><strong>Download Mercury</strong><p>Click <strong>Download for Windows</strong> above. Your browser saves <code>{WIN_FILE}</code> in your Downloads folder. It's {WIN_SIZE}, so give it a minute.</p>
<p><strong>If your browser warns you.</strong> Mercury is new and isn't signed with a paid certificate yet, so your browser may say the file isn't commonly downloaded. That's expected.</p>
<ul>
<li><strong>Edge:</strong> in the downloads box, click the three dots next to the file, then <strong>Keep</strong>, then <strong>Show more</strong>, then <strong>Keep anyway</strong>.</li>
<li><strong>Chrome:</strong> in the downloads box, click <strong>Keep</strong>.</li>
</ul></li>
<li><strong>Open the file</strong><p>Click the file in your browser's downloads, or open your Downloads folder and double click <code>{WIN_FILE}</code>.</p>
<p>Windows then shows a blue box saying <strong>Windows protected your PC</strong>. It shows this for any app it hasn't seen many times before.</p>
{WIN_DEMO}
<p>You don't need an admin password. Mercury installs in a few seconds and opens by itself.</p></li>
<li><strong>Choose how Mercury thinks</strong><p>On the welcome screen, keep <strong>Use Mercury's free AI</strong> selected and click <strong>Start using Mercury</strong>. There's no account to make. You get 40 messages a day. If you have an Anthropic API key, you can use that instead.</p></li>
<li><strong>Find Mercury any time</strong><p>The chat opens in the bottom right corner. When you hide it, Mercury keeps running by the clock in the taskbar. To bring it back:</p>
<ul>
<li>Press <kbd>Alt</kbd><kbd>\\</kbd> (the backslash key, usually just above Enter).</li>
<li>Or click the Mercury icon by the clock. If you can't see it, click the <strong>^</strong> arrow next to the clock. You can drag the icon onto the taskbar so it always shows.</li>
</ul>
<p>Mercury starts with Windows, so it's always ready. You can turn that off in its Settings.</p></li>
</ol>
<p class="note">Everything Mercury does on your PC, like saving a note or running a command, shows an <strong>Approve</strong> or <strong>Deny</strong> card first. Opening an app or setting a timer just happens, because you can see it straight away. Read more on the <a href="security.html">safety page</a>.</p>

<h2 id="shortcuts">Shortcuts</h2>
<table>
<tr><th>Keys</th><th>What it does</th></tr>
<tr><td><kbd>Alt</kbd><kbd>\\</kbd></td><td>Show or hide the chat</td></tr>
<tr><td><kbd>Alt</kbd><kbd>Shift</kbd><kbd>R</kbd></td><td>Record your screen, or finish a recording</td></tr>
<tr><td><kbd>Ctrl</kbd><kbd>Enter</kbd></td><td>Send your message with a look at your screen</td></tr>
<tr><td><kbd>Esc</kbd></td><td>Hide the chat</td></tr>
</table>
<p>If another app already uses <kbd>Alt</kbd><kbd>\\</kbd>, Mercury uses <kbd>Ctrl</kbd><kbd>Alt</kbd><kbd>M</kbd> instead (and <kbd>Ctrl</kbd><kbd>Alt</kbd><kbd>R</kbd> to record). Right click the Mercury icon by the clock to see which keys it's using.</p>

<h2 id="early">What's in this early version</h2>
<p>The Windows version is new, so it does less than the Mac app for now.</p>
<table>
<tr><th>Works now</th><th>Coming later</th></tr>
<tr><td>Chat about anything, with a look at your screen when you turn on the eye</td><td>Talking instead of typing (dictation)</td></tr>
<tr><td>Small jobs on your PC: open apps and websites, set timers, save notes, prepare emails and messages, run simple commands</td><td>The reel editor and drawing on recordings</td></tr>
<tr><td>Screen recording with your camera in a bubble, your microphone and your PC's sound</td><td>Automatic updates</td></tr>
</table>
<p>Something not working, or confusing? Tell the person who sent you here, or <a href="{REPO}/issues">report it on GitHub</a>. A screenshot helps a lot.</p>

<details class="note" style="margin-top:28px"><summary style="cursor:pointer;font-weight:600;color:var(--ink)">Want to check your download is genuine?</summary>
<p>Open PowerShell from the Start menu and run <code>Get-FileHash $HOME\\Downloads\\{WIN_FILE}</code>. The long code it prints should match this fingerprint exactly:</p>
<div class="checksum" id="winsha">{WIN_SHA.upper()}</div>
<p style="margin-top:8px"><button class="btn ghost small" data-copy="#winsha">Copy fingerprint</button></p></details>

<h2 id="privacy">Privacy</h2>
<p>With the free AI, your messages pass through a small Mercury server to Anthropic and aren't stored. The server only keeps daily counts so everyone gets a fair share. The full details are in the <a href="privacy.html#windows">privacy policy</a>.</p>

<h2 id="uninstall">Uninstall</h2>
<ol>
<li>Right click the Mercury icon by the clock and choose <strong>Quit Mercury</strong>.</li>
<li>Open <strong>Settings</strong>, then <strong>Apps</strong>, then <strong>Installed apps</strong>. Find Mercury, click the three dots, then <strong>Uninstall</strong>.</li>
<li>Optional: delete Mercury's settings folder by typing <code>%APPDATA%\\Mercury</code> into the File Explorer address bar. Your recordings (in Videos, Mercury Recordings) and notes (in Documents, Mercury) are yours to keep or delete.</li>
</ol>
</div>
"""

# ─────────────────────────────── Get started ───────────────────────────────
STARTED = f"""
<div class="wrap narrow doc">

<h2 id="install">1. Install</h2>
<ol class="steps">
<li><strong>Download Mercury</strong><p>From the <a href="index.html#download">download button</a>. Your browser saves a file called <code>Mercury-<span data-release="version">1.1.0</span>.dmg</code>.</p></li>
<li><strong>Drag Mercury into Applications</strong><p>Open the downloaded file and drag the Mercury icon onto the Applications folder.</p></li>
<li><strong>Open it</strong><p>Open Mercury from Applications.</p>
<div data-notarized="true" hidden><p>Mercury is signed and notarised by Apple, so it opens like any other app.</p></div>
<div data-notarized="false"><p>The first time, your Mac says Mercury can't be opened, because Apple hasn't checked this free app yet. Click <strong>Done</strong>, then open System Settings → Privacy &amp; Security, scroll down and click <strong>Open Anyway</strong> next to Mercury. Click Open Anyway once more and type your password. You only do this once.</p>{MAC_DEMO}</div>
</li>
</ol>
<details class="note" style="margin-top:16px"><summary style="cursor:pointer;font-weight:600;color:var(--ink)">Want to check your download is genuine?</summary>
<p>Open Terminal and run <code>shasum -a 256 ~/Downloads/Mercury-*.dmg</code>. It should match this fingerprint exactly:</p>
<div class="checksum" id="sha" data-release="sha256">Loading…</div>
<p style="margin-top:8px"><button class="btn ghost small" data-copy="#sha">Copy fingerprint</button></p></details>

<h2 id="welcome">2. The welcome tour</h2>
<p>The first time you open Mercury, it introduces itself in a short chat. It asks what to call you (that's optional, and stays on your Mac), lets you pick what you'd like help with, then asks for each permission one at a time, explaining why before macOS shows its own prompt. You can skip any of them. Mercury only asks again when you use that feature.</p>
<table>
<tr><th>Permission</th><th>Why Mercury asks</th><th>Needed for</th></tr>
<tr><td>Screen Recording</td><td>To record your screen, to take a screenshot when you ask Mercury about it, and to hear your Mac's sound when you turn on Listen.</td><td>Record, Ask, Listen</td></tr>
<tr><td>Camera</td><td>For the round camera bubble in recordings. Never used otherwise.</td><td>Record (optional)</td></tr>
<tr><td>Microphone</td><td>For your voice in recordings, dictation and when you talk to Mercury.</td><td>Record, Dictate, Talk</td></tr>
<tr><td>Speech Recognition</td><td>To turn speech into text on your Mac.</td><td>Dictate, Ask Mercury, captions</td></tr>
<tr><td>Accessibility</td><td>To notice the ⌥⌥ double tap in other apps and type text where your cursor is.</td><td>Dictate, Ask Mercury messages</td></tr>
<tr><td>Automation</td><td>Asked only if you have Ask Mercury use an app such as Mail or Messages for you.</td><td>Ask Mercury actions</td></tr>
</table>
<p class="note">After allowing Screen Recording, macOS may ask you to quit and reopen Mercury. Your choices are saved. You can review or remove any permission later in System Settings → Privacy &amp; Security.</p>

<h2 id="connect">3. Connect your AI (optional)</h2>
<p>Ask Mercury needs an AI to answer your questions. The tour asks which one you'd like to use, or you can skip it:</p>
<ul>
<li><strong>Claude Code on your Mac (recommended).</strong> If you already use <a href="https://claude.com/claude-code">Claude Code</a>, Ask Mercury uses it with your own Claude plan. It brings your memory notes and your connected apps (like Gmail and Calendar). Sign in once by opening Terminal, running <code>claude</code> and typing <code>/login</code>.</li>
<li><strong>An Anthropic API key.</strong> Create one at console.anthropic.com and paste it into Mercury. It's stored in your Mac's Keychain and billed to your Anthropic account.</li>
<li><strong>Not now.</strong> Recording and dictation work without any AI.</li>
</ul>
<p>Other assistants such as ChatGPT or Gemini can't be connected yet.</p>
<p>Before Ask Mercury can see or hear anything, it shows you its ground rules and asks you to agree. You can read them on the <a href="security.html#rules">safety page</a>.</p>

<h2 id="whisper">4. Sharper voice and captions (optional)</h2>
<p>Whisper is a free speech model that runs on your Mac and is much more accurate than the one built into macOS. To use it, install <a href="https://brew.sh">Homebrew</a>, run <code>brew install whisper-cpp</code> in Terminal, then download the model from Mercury's welcome tour or reel editor (574 MB, once). Nothing is uploaded.</p>

<h2 id="shortcuts">5. Shortcuts</h2>
<table>
<tr><th>Keys</th><th>What it does</th></tr>
<tr><td><kbd>⌥</kbd><kbd>⇧</kbd><kbd>R</kbd></td><td>Start a recording (pick what to record), or finish one</td></tr>
<tr><td><kbd>⌥</kbd><kbd>⇧</kbd><kbd>A</kbd></td><td>Draw an area, then record it</td></tr>
<tr><td><kbd>⌥</kbd> <kbd>⌥</kbd></td><td>Double tap to dictate. It finishes when you pause (or tap ⌥ once)</td></tr>
<tr><td><kbd>⌥</kbd><kbd>\\</kbd></td><td>Show or hide Ask Mercury</td></tr>
<tr><td><kbd>⌥</kbd><kbd>⇧</kbd><kbd>\\</kbd></td><td>Talk to Ask Mercury</td></tr>
<tr><td><kbd>Esc</kbd></td><td>Cancel picking, the countdown, dictation, or hide Ask Mercury</td></tr>
</table>
<p>Click any shortcut inside Mercury to change it.</p>

<h2 id="uninstall">Uninstall</h2>
<p>Mercury doesn't keep anything outside your Mac, so this removes it completely:</p>
<ol>
<li>Quit Mercury and drag it from Applications to the Bin.</li>
<li>Optional: delete its data folder, <code>~/Library/Application Support/Bubble</code>, and its log, <code>~/Library/Logs/Bubble.log</code>. Your recordings in <code>~/Desktop/Mercury Recordings</code> are yours to keep or delete.</li>
<li>Optional: if you saved an API key, open the Keychain Access app, search for "Bubble AI polish" and delete it.</li>
<li>Optional: remove Mercury from System Settings → Privacy &amp; Security lists (Screen Recording, Microphone and so on).</li>
</ol>
</div>
"""

# ─────────────────────────────── FAQ ───────────────────────────────
def q(question, answer):
    return f"<details><summary>{question}</summary>{answer}</details>"

FAQ = head("FAQ", "Questions people ask", "If yours isn't here, ask on GitHub and I'll help.") + '<div class="wrap narrow doc faq">' + "".join([
    q("Is Mercury really free?", "<p>Yes. It's open source under the MIT licence, with no paid version and no ads. Ask Mercury uses an AI you bring yourself (your Claude plan or your own API key), and that provider may charge you for it.</p>"),
    q("Which devices does it work on?", "<p>Macs running macOS 15 Sequoia or later, with Apple silicon or Intel. There's no Windows, Linux, iPhone or Android version.</p>"),
    q("Is it safe to download?", "<p>Mercury is open source, so anyone can read exactly what it does, and every release lists a SHA256 fingerprint so you can confirm the file hasn't been changed (see the <a href=\"get-started.html#install\">install guide</a>). Only download Mercury from this site or its GitHub page.</p>"),
    q("What does Mercury collect about me?", "<p>Nothing. There's no account, no analytics and no tracking. The only time anything leaves your Mac is when you use a feature that needs the internet, like asking Ask Mercury a question, and the <a href=\"privacy.html\">privacy policy</a> lists exactly what is sent and to whom.</p>"),
    q("Does Mercury record me all the time?", "<p>No. It records only when you start a recording, hears your voice only while you dictate or talk to it, hears your Mac's sound only while Listen is on (a red dot shows), and takes a screenshot only when you ask it something.</p>"),
    q("What does Listen hear?", "<p>Only the sound playing on your Mac: the other people on a call or meeting, or a video you're watching. It doesn't use your microphone. To talk to Mercury yourself, use Talk (⌥⇧\\) or dictation.</p>"),
    q("Can Ask Mercury send messages or emails for me?", "<p>It can prepare them, but it never sends anything on its own. Emails need you to approve them. For Messenger, Instagram, WhatsApp and Messages it opens the chat and types the message, and you press Enter.</p>"),
    q("Can I use it with ChatGPT or another AI?", "<p>Yes. With no AI account at all, Mercury's free AI gives you 40 messages a day. You can also use your own OpenAI key, or another service that works the same way, like Gemini, Grok, DeepSeek, OpenRouter or Ollama on your own computer. A ChatGPT Plus plan isn't a key: get one at platform.openai.com. With Claude Code on your Mac, Mercury can also do things for you, like drafting emails and saving files, always with your OK. Recording and dictation don't need any AI.</p>"),
    q("Does it know my previous Claude chats?", "<p>Through Claude Code it knows your Claude Code memory notes and connected apps. It can't read your chat history from the Claude app or website, because Claude doesn't let other apps do that.</p>"),
    q("Can people tell I'm using Ask Mercury on a call?", "<p>By default, yes: if you share your screen, Mercury's chat shows up in the share and in recordings like any other window. If your chat is private, one switch hides it from every recording and screen share, Mercury's own and Zoom, Meet or Teams alike. Please don't use that to cheat in exams or interviews, and don't record people without telling them.</p>"),
    q("Where are my recordings?", "<p>In <code>Mercury Recordings</code> on your Desktop, and in Mercury's library. Reels are saved in its <code>Reels</code> folder. Nothing is uploaded.</p>"),
    q("Dictation didn't type into my app. Why?", "<p>Mercury needs Accessibility permission to type into other apps (System Settings → Privacy &amp; Security → Accessibility). Without it, your words are copied so you can paste them. Some secure fields, like password boxes, block typing on purpose.</p>"),
    q("How do I remove Mercury completely?", "<p>See <a href=\"get-started.html#uninstall\">Uninstall</a>. Because Mercury has no servers, deleting it from your Mac removes it completely.</p>"),
    q("How do I report a bug or a security problem?", f"<p>Bugs: <a href=\"{REPO}/issues\">open an issue on GitHub</a>. Security problems: please report them privately through <a href=\"{REPO}/security/advisories/new\">GitHub's private security reporting</a>, not in a public issue.</p>"),
]) + "</div>"

# ─────────────────────────────── Privacy ───────────────────────────────
PRIVACY = f"""
<p>Mercury is a free, open source Mac app that I make. This policy explains what happens to your information when you use the app and this website. In short, I don't collect anything, and Mercury only sends information to other services when you use a feature that needs them.</p>

<h2>Who makes Mercury</h2>
<p>Mercury is an independent open source project published at <a href="{REPO}">github.com/HarryNGU/mercury</a>. There are no Mercury accounts. The Mac app uses no Mercury servers. The early Windows version can use one for its optional free AI (see <a href="#windows">below</a>). You can reach me through <a href="{REPO}/issues">GitHub issues</a>.</p>

<h2>What I collect</h2>
<p>Nothing. Mercury has no accounts, analytics, crash reporting, advertising or tracking. I don't receive your recordings, voice, screenshots, messages, contacts or settings, and I couldn't see them even if I wanted to.</p>

<h2>What stays on your Mac</h2>
<ul>
<li>Recordings and reels (<code>~/Desktop/Mercury Recordings</code>).</li>
<li>Your voice. Dictation, captions and Ask Mercury's listening are transcribed on your Mac, and audio is never uploaded.</li>
<li>The name you asked Mercury to call you, if you gave one. It is only shown to you.</li>
<li>Your chats with Mercury (in <code>~/Library/Application Support/Bubble/Chats</code>, readable only by your user account), so it picks up where you left off. Screenshots are never saved. They're kept for 30 days unless you choose otherwise in Settings, and you can delete any chat, or all of them, at any time.</li>
<li>What you brought over from another assistant about yourself, if you did (in <code>~/Library/Application Support/Bubble/about-me.md</code>, readable only by your user account). You can delete it in Mercury's settings.</li>
<li>Settings, snippets, transcripts of your recordings, and Ask Mercury's latest screenshot (in <code>~/Library/Application Support/Bubble</code>, readable only by your user account).</li>
<li>Your Anthropic API key, if you add one, in the macOS Keychain.</li>
<li>A log file for troubleshooting (<code>~/Library/Logs/Bubble.log</code>). It stays on your Mac unless you choose to share it.</li>
</ul>

<h2>When information leaves your Mac</h2>
<p>Only when you use these features, and only to these services:</p>
<table>
<tr><th>When you…</th><th>What is sent</th><th>To</th></tr>
<tr><td>Ask Mercury something</td><td>Your question, a screenshot of your screen (unless you turn the eye off), the recent transcript (only if Listen is on), and what you brought over about yourself (if you did)</td><td>Anthropic, through Claude Code on your Mac or your API key</td></tr>
<tr><td>Ask Ask Mercury to use a connected app (for example Gmail)</td><td>What's needed for that task</td><td>That app, through the connection you set up with your Claude account</td></tr>
<tr><td>Use AI polish for dictation, or the reel editor chat</td><td>The text of your dictation, or the video's transcript and edit settings. Never audio or video.</td><td>Anthropic, with your API key</td></tr>
<tr><td>See a picture, molecule or video in an answer</td><td>The search words or compound name</td><td>Wikimedia Commons, PubChem or YouTube (the video player)</td></tr>
<tr><td>Download the Whisper speech model</td><td>A normal download request</td><td>Hugging Face</td></tr>
<tr><td>Mercury checks for updates (once a day, if that's on)</td><td>A normal request for one small public file. Nothing about you is included.</td><td>GitHub Pages (this website)</td></tr>
</table>
<p>Those services handle the information under their own privacy policies, including <a href="https://www.anthropic.com/legal/privacy">Anthropic's</a>. Mercury never sells your information or shares it with anyone else.</p>

<h2 id="windows">Mercury for Windows and its free AI</h2>
<p>The early Windows version offers a free AI, so you can try it without an account or an API key. If you choose it, your question (and a screenshot, if you turn the eye on) goes through a small Mercury server on Cloudflare to Anthropic for the answer, then the answer comes straight back. The server doesn't store your messages, screenshots or anything else you send.</p>
<p>To keep the free AI fair and within its daily budget, the server keeps only daily counts: how many questions this PC has asked today (linked to a random ID made on your PC, not your name), and how many came from your internet address, which is scrambled (hashed) first so the real address is never saved. Cloudflare, like any host, may log requests for security (see <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare's privacy policy</a>).</p>
<p>If you'd rather nothing passes through Mercury's server, choose "Use my own Anthropic API key" in the welcome screen or in Settings. Mercury then talks to Anthropic directly. On Windows, settings live in <code>%APPDATA%\\Mercury</code>, and your key is encrypted with Windows' own protection.</p>

<h2>Other people's information</h2>
<p>If you turn on Listen during a call, what other people say is transcribed on your Mac and may be included when you ask a question. Tell people before you do this. In some places the law requires their consent.</p>

<h2>This website</h2>
<p>This site doesn't use cookies, analytics or outside scripts. It's hosted on GitHub Pages, which, like any web host, may log your IP address for security reasons (see <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">GitHub's privacy statement</a>). Downloads come from GitHub.</p>

<h2>Children</h2>
<p>Mercury isn't meant for children under 13. Features that use Anthropic require you to meet Anthropic's age requirements, which are 18 or older.</p>

<h2>Your choices and rights</h2>
<p>Because I don't hold any of your information, there's nothing for me to access, correct or delete. You control everything on your Mac: you can delete recordings, clear Mercury's data folder, remove your API key and revoke permissions in System Settings at any time (see <a href="get-started.html#uninstall">Uninstall</a>). For information you sent to Anthropic or another service, use that service's privacy tools.</p>

<h2>Changes</h2>
<p>If this policy changes, I'll update this page and the date above, and mention the change in the release notes. Mercury's code is public, so any change in what it does is visible.</p>
"""

# ─────────────────────────────── Terms ───────────────────────────────
TERMS = f"""
<p>These terms apply when you download or use Mercury or this website. By using Mercury you agree to them. If you don't agree, please don't use it.</p>

<h2>The licence</h2>
<p>Mercury is open source software under the <a href="{REPO}/blob/main/LICENSE">MIT licence</a>. You can use, copy, change and share it, including commercially, as long as you keep the licence notice. These terms add rules about how you use it; they don't take away rights the licence gives you.</p>

<h2>Who can use Mercury</h2>
<p>You must be at least 13, or older if the law where you live requires it. Ask Mercury's AI features use Anthropic's services, and you must meet <a href="https://www.anthropic.com/legal">Anthropic's terms</a> (including their age requirement) to use them.</p>

<h2 id="acceptable-use">Acceptable use</h2>
<p>You're responsible for how you use Mercury. Don't use it to:</p>
<ul>
<li>record, transcribe or listen to people without the consent the law where you are requires;</li>
<li>cheat in exams, assessments or job interviews, or get around rules you've agreed to;</li>
<li>harass, impersonate, threaten or spam anyone, including through messages it helps you prepare;</li>
<li>break the law, infringe others' rights, or capture content you're not allowed to copy;</li>
<li>break the terms of services you connect, such as Anthropic, Google or Meta.</li>
</ul>

<h2>Things it does for you</h2>
<p>Ask Mercury can prepare emails and messages and take actions in apps when you ask and approve it. AI can make mistakes: check what it prepares before you send or approve anything. You're responsible for messages you send and actions you approve.</p>

<h2>Other services</h2>
<p>Some features connect to services Mercury doesn't control: Anthropic (Claude), Claude Code, apps you connect through your Claude account, Wikimedia Commons, PubChem, YouTube and Hugging Face. Your use of them is governed by their own terms and policies, and you're responsible for any costs they charge, such as API usage.</p>

<h2>No warranty</h2>
<p>Mercury is provided "as is", without warranties of any kind, as the MIT licence says. I can't promise it will be free of errors, always available, or right for your purpose. Keep backups of recordings that matter.</p>

<h2>Limits of liability</h2>
<p>To the extent the law allows, the people who make Mercury aren't liable for any loss or damage from using or not being able to use it, including lost recordings, messages sent or actions approved, or costs from other services. Nothing in these terms limits rights you have under consumer law that can't be excluded, including the Australian Consumer Law.</p>

<h2>Changes</h2>
<p>I may update these terms. Changes take effect when they're posted here, and the date above will change. If you keep using Mercury after that, you accept the new terms.</p>

<h2>Law</h2>
<p>These terms are governed by the laws of Victoria, Australia.</p>

<h2>Contact</h2>
<p>Questions: <a href="{REPO}/issues">GitHub issues</a>.</p>
"""

# ─────────────────────────────── Security ───────────────────────────────
SECURITY = f"""
<p>Mercury can see your screen, hear your voice and do things in your apps, so I've built it to be careful by default. This page explains how.</p>

<h2 id="rules">The ground rules</h2>
<p>Before Ask Mercury can see or hear anything, Mercury shows you these rules and asks you to agree:</p>
<ul>
<li><strong>It sees your screen only when you ask.</strong> Each question sends one screenshot to your AI. Turn the eye off for private screens, like banking.</li>
<li><strong>Listening is off until you turn it on,</strong> and a red dot shows while it's on.</li>
<li><strong>Nothing is sent without you.</strong> Emails need your Approve. Messages are typed in for you to send.</li>
<li><strong>Private files stay private.</strong> It asks before reading key, password or history files, and before opening links that carry data.</li>
<li><strong>It's visible.</strong> The chat shows up in screen shares unless you hide it for privacy, and it isn't for cheating or secret recording.</li>
</ul>

<h2>Actions need your approval</h2>
<p>Looking things up runs freely. Anything that writes files, runs commands, or sends, creates, edits or deletes in your apps shows an Approve or Deny card first. You can say "yes" or "no" out loud. "Always allow" applies to one tool only, and never overrides the protections below.</p>

<h2>Protection from tricks</h2>
<p>A web page, email or document could contain hidden text meant to trick an AI into doing something you didn't ask for (called prompt injection). Mercury always asks you before:</p>
<ul>
<li>reading files that hold keys, passwords or private history (for example <code>~/.ssh</code>, keychains, browser data, shell history, <code>.env</code> files);</li>
<li>searching your whole home folder;</li>
<li>opening a web address that carries data in it, which is a common way to leak information.</li>
</ul>

<h2>Your accounts and keys</h2>
<ul>
<li>Mercury never asks for or stores your passwords. It works with the apps and browser you're already signed into.</li>
<li>Claude Code keeps its own sign in details in your Keychain, and Mercury never sees them.</li>
<li>An API key you add is stored in the macOS Keychain, never in a file.</li>
</ul>

<h2>Inside the app</h2>
<ul>
<li>Mercury's helper for Ask Mercury listens only on your own Mac (127.0.0.1) and needs a random secret that changes every launch, so other devices and websites can't use it.</li>
<li>The app uses Apple's hardened runtime and asks only for the system permissions it needs: camera, microphone and automation.</li>
<li>Speech recognition and Whisper run on your Mac; audio is never uploaded.</li>
</ul>

<h2 id="verify">Check your download</h2>
<p>Every release publishes a SHA256 fingerprint on the <a href="index.html#download">download page</a> and on GitHub. In Terminal, run <code>shasum -a 256 ~/Downloads/Mercury-*.dmg</code> and compare. If they don't match, don't open the file. Only download Mercury from this site or <a href="{REPO}/releases">its GitHub releases</a>.</p>
<p class="note" data-notarized="false">Early versions are signed but not yet notarised by Apple, so macOS warns the first time you open them. Notarisation (Apple's malware check) is on the way. Until then, the fingerprint and the public source code are how you can check the download.</p>

<h2 id="report">Report a security problem</h2>
<p>Please report it privately through <a href="{REPO}/security/advisories/new">GitHub's private vulnerability reporting</a>, not in a public issue. Include what you found and how to reproduce it. I'll reply as soon as I can and credit you if you'd like.</p>
"""

# ─────────────────────────────── Notices ───────────────────────────────
NOTICES = f"""
<p>Mercury is under the MIT licence. It works with these projects and services, which have their own licences and terms:</p>
<table>
<tr><th>Project or service</th><th>Used for</th><th>Licence or terms</th></tr>
<tr><td><a href="https://github.com/ggml-org/whisper.cpp">whisper.cpp</a></td><td>Transcription on your Mac (installed separately)</td><td>MIT</td></tr>
<tr><td><a href="https://github.com/openai/whisper">Whisper models</a> (large-v3-turbo)</td><td>Speech model (downloaded separately)</td><td>MIT</td></tr>
<tr><td><a href="https://claude.com/claude-code">Claude Code</a> and the <a href="https://www.anthropic.com/api">Anthropic API</a></td><td>Ask Mercury, AI polish, reel editor chat</td><td><a href="https://www.anthropic.com/legal">Anthropic's terms</a></td></tr>
<tr><td><a href="https://commons.wikimedia.org">Wikimedia Commons</a></td><td>Pictures in answers</td><td>Each image has its own licence, shown on its page</td></tr>
<tr><td><a href="https://pubchem.ncbi.nlm.nih.gov">PubChem</a> (U.S. National Library of Medicine)</td><td>Molecule structures</td><td><a href="https://www.ncbi.nlm.nih.gov/home/about/policies/">NCBI policies</a></td></tr>
<tr><td><a href="https://www.youtube.com">YouTube</a></td><td>Videos played in answers</td><td><a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a></td></tr>
<tr><td>Apple frameworks</td><td>Screen capture, camera, speech recognition, Vision</td><td>Part of macOS</td></tr>
</table>
<p>Mercury isn't affiliated with or endorsed by Anthropic, Apple, Google, Meta, OpenAI, Wikimedia or the U.S. National Library of Medicine. Product names belong to their owners.</p>
"""

NOT_FOUND = head("404", "Page not found", "That page doesn't exist.") + '<div class="wrap narrow doc center"><p><a class="btn primary" href="index.html">Go to the home page</a></p></div>'

if __name__ == "__main__":
    DOCS.mkdir(exist_ok=True)
    page("index.html", "Mercury · The messenger for your Mac and Windows PC", "Hand Mercury the job and it runs it: it looks at your screen and tutors you, finds answers and videos, writes your messages and records your screen. Free, private and open source, for Mac and Windows.", HOME, home=True)
    page("get-started.html", "Get started · Mercury", "Install Mercury, set up permissions, connect your AI and learn the shortcuts.",
         head("Get started", "Set up Mercury in about two minutes", "Install it, say hello, and Mercury walks you through the rest. Everything after installing is optional.") + STARTED)
    page("windows.html", "Mercury for Windows · Mercury", "Download Mercury for Windows 10 and 11 and set it up in about a minute. Free, with no account.",
         head("Windows", "Mercury for Windows", "An early test version for Windows 10 and 11. Setting it up takes about a minute, with no account and no admin password.") + WINDOWS)
    page("faq.html", "FAQ · Mercury", "Answers to common questions about Mercury.", FAQ)
    doc("privacy.html", "Privacy policy", "What Mercury does with your information: nothing is collected.", PRIVACY)
    doc("terms.html", "Terms of use", "The terms for using Mercury, including acceptable use.", TERMS)
    doc("security.html", "Safety and security", "How Mercury keeps you safe: approvals, protections and how to check your download.", SECURITY)
    doc("notices.html", "Open source notices", "The projects and services Mercury works with.", NOTICES)
    page("404.html", "Not found · Mercury", "Page not found.", NOT_FOUND)
    (DOCS / ".nojekyll").write_text("")
    print("Built", len(list(DOCS.glob("*.html"))), "pages in", DOCS)
