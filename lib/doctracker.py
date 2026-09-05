#!/usr/bin/env python3
"""Render DOCS.html — a browsable PRD/doc tracker over manifest.json.

Answers, per doc: whose turn is it (ball), which questions are still
unanswered, which answers are waiting on my reply, and which issues are gated
behind the doc. An empty box that the reader answered PAST is 'superseded',
not 'unanswered' — see qstate/mark_superseded. TRACKER.html is issue-level; this is doc-level. INDEX.html
(question-level flat queue) stays for cross-doc triage.

Read-only over its sources; DOCS.html inlines everything at build time (same
reasoning as tracker.py — the page is usually opened over file:// where
fetching a sibling is blocked). Freshness comes from three hooks:
docstate.set_status/on_save, issues.py's render_tracker, and serve.py's
staleness check on GET (which uses sources() so the list can't drift).

    python3 doctracker.py            # write DOCS.html
    python3 doctracker.py --open     # write it and open in the browser
"""
import json
import re
import os
import subprocess
import sys

import docstate as ds

DIR = None  # set by init()
ISSUES = None
OUT = None

# Path to the unified base template — ONE source of truth for the sidebar nav.
_TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              'doc-template.html')

_NAV_CATEGORIES_CACHE = None

_DEFAULT_NAV_CATEGORIES = (
    '  <div class="grp">Categories</div>\n'
    '  <a href="TRACKER.html">issues</a>\n'
    '  <a href="PRDS.html">PRDs</a>\n'
    '  <a href="REPORTS.html">reports</a>\n'
    '  <a href="DOCS.html">docs</a>')


def _read_nav_categories():
    """Read the category links from doc-template.html — the ONE base template.

    The sidebar nav's category links are defined in doc-template.html and
    extracted here so doctracker.py does not duplicate them.  Falls back to
    a built-in constant if the template file is missing or unparseable.
    """
    global _NAV_CATEGORIES_CACHE
    if _NAV_CATEGORIES_CACHE is not None:
        return _NAV_CATEGORIES_CACHE
    try:
        with open(_TEMPLATE_PATH, encoding='utf-8') as f:
            src = f.read()
        m = re.search(
            r'(<div class="grp">Categories</div>'
            r'(?:\s*<a href="[^"]*">[^<]*</a>)+)',
            src)
        _NAV_CATEGORIES_CACHE = m.group(1).strip() if m else _DEFAULT_NAV_CATEGORIES
    except OSError:
        _NAV_CATEGORIES_CACHE = _DEFAULT_NAV_CATEGORIES
    return _NAV_CATEGORIES_CACHE


def _base_nav(brand):
    """Build the standard sidebar <nav> with the given brand text."""
    cats = _read_nav_categories()
    return ('<nav>\n'
            '  <div class="brand"><span class="logo"></span> %s</div>\n'
            '  %s\n'
            '</nav>' % (brand, cats))


def init(docs_dir=None):
    global DIR, ISSUES, OUT
    if docs_dir:
        DIR = os.path.abspath(docs_dir)
    elif DIR is None:
        if ds.DIR is None:
            ds.init()
        DIR = ds.DIR
    ISSUES = os.path.join(DIR, "issues.json")
    OUT = os.path.join(DIR, "DOCS.html")


def sources():
    """Every file render() reads whose change should invalidate DOCS.html.
    A function, not a constant: the manifest's doc files are part of the set
    (answers + review asides live inside them), and that set changes."""
    srcs = [ds.MANIFEST, ISSUES, _TEMPLATE_PATH]
    try:
        m = ds.load()
        srcs += [os.path.join(DIR, e["file"]) for e in m["docs"].values() if e.get("file")]
    except Exception:
        pass
    return srcs


def qstate(box, superseded=False):
    """One question's state, independent of the doc's own status.
    unanswered → needs the owner; awaiting-reply → owner answered, I owe a
    fold-in; replied → both sides in; superseded → empty, but the reader
    answered something FURTHER DOWN the same section, so they moved past it.

    The fourth state exists because the first three made this tool lie to the
    owner. TRACKER-SWEEP-2026-08-22 reported PRD-15 as having open questions;
    every real question in it was answered and the empties were tail follow-up
    boxes the conversation had already run past ("uh.. everything is checked
    off. what is open here?", 2026-08-23). An empty box is only a demand while
    nothing after it has been answered — see mark_superseded.
    """
    if not box["answer"]:
        return "superseded" if superseded else "unanswered"
    if not box["review"]:
        return "awaiting-reply"
    return "replied"


def chain_of(key):
    """The question a follow-up box belongs to.

    reply.py names a follow-up after the box it hangs under — `p4-pick`,
    `p4-pick-followup`, `p4-pick-followup-followup`, `p4-pick-followup2` — so
    the stem IS the conversation id. Anything else is its own chain.
    """
    stem = key
    while True:
        m = re.match(r"^(.*)-followup\d*$", stem)
        if not m:
            return stem
        stem = m.group(1)


def mark_superseded(boxes):
    """Per box, in document order: is a LATER box in the SAME CHAIN answered?

    Document order within one chain is the whole signal. A chain reads
    question → answer → my reply + follow-up → answer → … A gap in the MIDDLE
    of that is not a pending demand: the reader kept going and answered further
    down the same conversation. A gap at the END of a chain is a demand,
    because nothing came after it.

    Chain, not section: a sprint report is one long scroll with no <section>
    ids, so scoping by section made every box in the file one chain and let an
    answer anywhere silence a question anywhere above it — which would have
    hidden both of the asks folded into SPRINT-REPORT-2026-08-13 on 2026-08-23.
    """
    later = []
    seen = {}
    for b in reversed(boxes):
        ch = chain_of(b["key"])
        later.append(bool(seen.get(ch)))
        if b["answer"]:
            seen[ch] = True
    return list(reversed(later))


def summarize(boxes):
    """{unanswered: n, awaiting-reply: n, replied: n, superseded: n}."""
    out = {"unanswered": 0, "awaiting-reply": 0, "replied": 0, "superseded": 0}
    for b, sup in zip(boxes, mark_superseded(boxes)):
        out[qstate(b, sup)] += 1
    return out


def gated_issues(issues, handle, doc_status):
    """Issues whose decisionDoc is this handle. They are gated (blocked on the
    doc) while the doc is anything but resolved — same rule as issues.py's
    decision_gate, restated here only as a view."""
    rows = []
    for iid, it in issues.items():
        if it.get("decisionDoc") != handle:
            continue
        rows.append({"id": iid, "title": it.get("title", iid),
                     "status": it.get("status", "?"),
                     "gated": doc_status != "resolved" and it.get("status") != "done"})
    return rows


def collect():
    m = ds.load()
    issues = {}
    try:
        issues = json.load(open(ISSUES)).get("issues", {})
    except (OSError, ValueError):
        pass  # a missing issues.json degrades to no gating info, never breaks
    docs = []
    for did, e in m["docs"].items():
        file = e.get("file", "")
        boxes = ds.extract_boxes(os.path.join(DIR, file))
        status = e.get("status", "?")
        docs.append({
            "handle": did,
            "file": file,
            "title": e.get("title", file or did),
            "status": status,
            "ball": ds.STATUS.get(status, ("?", "?"))[1],
            "version": e.get("version", 0),
            "updatedAt": e.get("updatedAt", ""),
            "questions": [{"key": b["key"], "label": b["label"],
                           "section": b["section"], "state": qstate(b, sup)}
                          for b, sup in zip(boxes, mark_superseded(boxes))],
            "counts": summarize(boxes),
            "issues": gated_issues(issues, did, status),
        })
    return docs


def categorize(docs):
    """Group docs by category using the handle-prefix convention.

    Returns a dict: {category: [doc, ...]} where category is one of
    'prd', 'report', 'doc', 'other'.  Same grouping the old DOCNAV JS
    used — prd-* handles, SPRINT-REPORT-* files or sprint-* handles,
    doc-* handles, and everything else.
    """
    cats = {"prd": [], "report": [], "doc": [], "other": []}
    for d in docs:
        h = d["handle"]
        f = d["file"]
        if re.match(r"^prd-", h, re.I):
            cats["prd"].append(d)
        elif re.match(r"^SPRINT-REPORT-", f, re.I) or re.match(r"^sprint-", h, re.I):
            cats["report"].append(d)
        elif re.match(r"^doc-", h, re.I):
            cats["doc"].append(d)
        else:
            cats["other"].append(d)
    return cats


def render_category(cat_docs, title, out_path, statuses):
    """Write a category landing page listing the given docs."""
    payload = {"docs": cat_docs, "statuses": statuses}
    blob = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    page = (CATEGORY_TEMPLATE
            .replace("__NAV__", _base_nav(title))
            .replace("__TITLE__", title)
            .replace("__DATA__", blob))
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(page)
    os.replace(tmp, out_path)
    return out_path


def render():
    """Rebuild DOCS.html and the category landing pages. Returns the
    DOCS.html output path (the main doc tracker)."""
    if DIR is None:
        init()
    all_docs = collect()
    statuses = {k: v[0] for k, v in ds.STATUS.items()}
    payload = {"docs": all_docs, "statuses": statuses}
    blob = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    html = (TEMPLATE
            .replace("__NAV__", _base_nav("Doc tracker"))
            .replace("__DATA__", blob))
    with open(OUT, "w") as f:
        f.write(html)

    # Category landing pages — PRDS.html and REPORTS.html.
    cats = categorize(all_docs)
    render_category(cats["prd"], "PRDs", os.path.join(DIR, "PRDS.html"), statuses)
    render_category(cats["report"], "Reports", os.path.join(DIR, "REPORTS.html"), statuses)

    return OUT


def main():
    init()
    all_docs = collect()
    out = render()
    cats = categorize(all_docs)
    print(f"wrote {out} ({len(all_docs)} docs)")
    print(f"  PRDS.html ({len(cats['prd'])} docs), REPORTS.html ({len(cats['report'])} docs)")
    if "--open" in sys.argv:
        subprocess.run(["open", out])


TEMPLATE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Doc tracker</title>
<style>
/* Palette + rules follow VS Code's High Contrast themes (hc-black / hc-light):
   separation by border, never by background tint; a distinct focus/active
   border hue; no fading to convey state. Same sheet as TRACKER.html. */
:root{                        /* hc-black */
  --bg:#000; --panel:#000;
  --ink:#fff; --dim:rgba(255,255,255,.7);
  --line:#6FC3DF;             /* contrastBorder */
  --focus:#F38518;            /* focusBorder / activeContrastBorder */
  --accent:#21A6FF;           /* textLink.foreground */
  --you:#F5F543; --me:#21A6FF; --done:#23D18B; --held:#D670D6; --warn:#F48771;
  --fs-sm:12px; --fs-base:14px; --fs-head:16px; --fs-title:20px;
  --mono:ui-monospace,SFMono-Regular,Menlo,monospace;
}
:root[data-theme=light]{      /* 5-color palette */
  --bg:#fff; --panel:#fff;
  --ink:#18181b; --dim:rgba(24,24,27,.7);
  --line:#7c3aed;
  --focus:#7c3aed;
  --accent:#7c3aed;
  --you:#7c3aed; --me:#7c3aed; --done:#0A5C21; --held:#7c3aed; --warn:#b91c1c;
}
*{box-sizing:border-box}
body{margin:0;display:flex;min-height:100vh;background:var(--bg);color:var(--ink);
  font:var(--fs-base)/1.5 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
body>nav{width:296px;flex:none;border-right:1px solid var(--line);background:var(--panel);
  padding:22px 14px;position:sticky;top:0;height:100vh;overflow-y:auto}
body>nav .brand{display:flex;align-items:center;gap:8px;font-weight:700;
  font-size:var(--fs-base);margin-bottom:16px;padding:0 6px}
body>nav .brand .logo{width:18px;height:18px;border:1px solid var(--line);background:none}
body>nav a{display:block;padding:6px 10px;color:var(--ink);text-decoration:none;
  font-size:var(--fs-base);margin-bottom:2px;border:1px solid transparent}
body>nav a:hover{box-shadow:inset 0 0 0 2px var(--focus)}
body>nav a.cur{border-color:var(--line);font-weight:700}
body>nav .grp{font-size:var(--fs-sm);font-weight:700;text-transform:uppercase;
  letter-spacing:.06em;color:var(--ink);margin:16px 6px 6px}
.content{flex:1;min-width:0}
a{color:var(--accent)}
:focus-visible{outline:2px solid var(--focus);outline-offset:1px}

header{position:sticky;top:0;z-index:20;background:var(--panel);
  border-bottom:1px solid var(--line);padding:10px 16px;
  display:flex;gap:14px;align-items:center;flex-wrap:wrap}
header h1{font-size:var(--fs-head);margin:0;font-weight:700;color:var(--ink)}
header h1 span{color:var(--dim);font-weight:400}
#q{flex:1;min-width:200px;background:var(--panel);border:1px solid var(--line);
  color:var(--ink);border-radius:4px;padding:7px 10px;font-size:var(--fs-base)}
#q::placeholder{color:var(--dim)}
#q:focus{outline:none;border-color:var(--focus);box-shadow:0 0 0 1px var(--focus)}
.seg{display:flex;border:1px solid var(--line);border-radius:4px;overflow:hidden}
.seg button{background:var(--panel);border:0;color:var(--ink);padding:7px 11px;
  font-size:var(--fs-sm);font-weight:600;cursor:pointer}
.seg button:hover{box-shadow:inset 0 0 0 1px var(--focus)}
.tot{color:var(--ink);font-size:var(--fs-sm);white-space:nowrap;font-variant-numeric:tabular-nums}

section.grp{padding:0 18px}
section.grp:last-of-type{padding-bottom:80px}
.gh{display:flex;align-items:baseline;gap:10px;margin:24px 0 8px}
.gh h2{font-size:var(--fs-head);margin:0;font-weight:700}
.gh .meta{color:var(--dim);font-size:var(--fs-sm)}
.dot{width:10px;height:10px;border-radius:50%;flex:none;display:inline-block;
  border:1px solid var(--bg);box-shadow:0 0 0 1px currentColor}
.dot.open{background:var(--you);color:var(--you)}
.dot.in-review{background:var(--me);color:var(--me)}
.dot.resolved{background:var(--done);color:var(--done)}
.dot.held{background:var(--held);color:var(--held)}
.dot.unanswered{background:var(--you);color:var(--you)}
.dot.awaiting-reply{background:var(--me);color:var(--me)}
.dot.replied{background:var(--done);color:var(--done)}
.dot.superseded{background:var(--done);color:var(--done)}

.rows{border:1px solid var(--line);border-radius:4px;overflow:hidden;background:var(--panel)}
.row{display:flex;gap:10px;align-items:center;padding:9px 12px;cursor:pointer;
  border-top:1px solid var(--line);color:var(--ink)}
.row:first-child{border-top:0}
.row:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.row .t{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  font-weight:700}
.row.resolved .t{font-weight:400}      /* weight, not opacity, marks settled docs */
.row .id{color:var(--ink);font-family:var(--mono);font-size:var(--fs-sm);flex:none}
.tag{font-size:var(--fs-sm);font-weight:700;padding:1px 8px;border-radius:10px;
  border:1px solid var(--line);color:var(--ink);flex:none;white-space:nowrap;
  background:transparent}
.tag.you{color:var(--you);border-color:var(--you)}
.tag.me{color:var(--me);border-color:var(--me)}
.tag.gate{color:var(--warn);border-color:var(--warn)}
.tag.v{font-variant-numeric:tabular-nums}
#empty{color:var(--ink);padding:40px 18px}

#scrim{position:fixed;inset:0;background:#000c;z-index:30;display:none}
#scrim.on{display:block}
#det{position:fixed;top:0;right:0;bottom:0;width:min(640px,94vw);z-index:31;
  background:var(--panel);border-left:2px solid var(--line);overflow:auto;
  transform:translateX(100%);transition:transform .16s ease;padding:18px 22px 60px}
#det.on{transform:none}
#det h2{margin:6px 0 4px;font-size:var(--fs-title);line-height:1.3}
#det .sub{color:var(--ink);font-family:var(--mono);font-size:var(--fs-sm);margin-bottom:14px}
#close{position:absolute;top:12px;right:16px;background:var(--panel);
  border:1px solid var(--line);border-radius:4px;width:30px;height:30px;
  color:var(--ink);font-size:var(--fs-title);cursor:pointer;line-height:1}
#close:hover{border-color:var(--focus);box-shadow:inset 0 0 0 1px var(--focus)}
.blk{margin:18px 0}
.blk h4{margin:0 0 6px;font-size:var(--fs-sm);letter-spacing:.09em;text-transform:uppercase;
  color:var(--ink);font-weight:700}
.qrow{display:flex;gap:9px;align-items:baseline;padding:5px 0;border-top:1px solid var(--line)}
.qrow:first-child{border-top:0}
.qrow .dot{position:relative;top:1px}
.qrow a{color:var(--ink);text-decoration:none;font-weight:600}
.qrow a:hover{color:var(--accent);text-decoration:underline}
.qrow .st{margin-left:auto;color:var(--dim);font-size:var(--fs-sm);white-space:nowrap;flex:none}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{display:inline-flex;align-items:center;gap:6px;background:var(--panel);
  border:1px solid var(--line);border-radius:4px;padding:3px 8px;font-size:var(--fs-sm);
  color:var(--ink);text-decoration:none;cursor:pointer}
.chip:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.chip.gated{border-color:var(--warn)}
button.act{font:inherit;font-weight:700;cursor:pointer;color:var(--ink);
  background:var(--bg);border:1px solid var(--line);padding:6px 14px;margin-right:8px}
button.act:hover{box-shadow:inset 0 0 0 2px var(--focus)}
button.act[disabled]{cursor:wait}
</style></head>
<body>
__NAV__
<div class="content">
<header>
  <h1>Doc tracker</h1>
  <input id="q" placeholder="search title, handle, question…  (/ to focus)">
  <div class="seg" id="theme"><button>◐</button></div>
  <div class="tot" id="tot"></div>
</header>
<div id="out"></div>
</div>
<div id="scrim"></div>
<div id="det"><button id="close">×</button><div id="detBody"></div></div>

<script id="data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const DOCS = D.docs;
const byHandle = Object.fromEntries(DOCS.map(d => [d.handle, d]));
// Groups are the ball, in the order the owner triages: their turn first.
const GROUPS = [
  ['open',      'Your turn',   'answers or a read needed from you'],
  ['in-review', 'My turn',     'you answered — a reply is owed'],
  ['held',      'Held',        'paused on purpose; nobody’s turn'],
  ['resolved',  'Resolved',    'settled — reopen from the detail panel'],
];
const QSTATE = { unanswered: 'needs your answer',
                 'awaiting-reply': 'awaiting my reply', replied: 'replied',
                 superseded: 'moved past' };
let q = '';

const esc = s => (s||'').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function hits(d){
  if (!q) return true;
  const hay = (d.handle+' '+d.title+' '+d.file+' '
    + d.questions.map(x=>x.label).join(' ')+' '
    + d.issues.map(x=>x.id+' '+x.title).join(' ')).toLowerCase();
  return q.split(/\s+/).every(w => hay.includes(w));
}

function tags(d){
  let t = '';
  if (d.counts.unanswered) t += `<span class="tag you">${d.counts.unanswered} to answer</span>`;
  if (d.counts['awaiting-reply']) t += `<span class="tag me">${d.counts['awaiting-reply']} awaiting reply</span>`;
  const g = d.issues.filter(i => i.gated).length;
  if (g) t += `<span class="tag gate">gates ${g} issue${g>1?'s':''}</span>`;
  return t;
}

function render(){
  const sel = DOCS.filter(hits);
  const open = sel.filter(d => d.status !== 'resolved').length;
  document.getElementById('tot').textContent = `${sel.length} of ${DOCS.length} · ${open} not resolved`;
  let h = '';
  for (const [st, label, sub] of GROUPS){
    const items = sel.filter(d => d.status === st)
      .sort((a,b) => (b.updatedAt||'').localeCompare(a.updatedAt||''));
    if (!items.length) continue;
    h += `<section class="grp"><div class="gh"><span class="dot ${st}"></span>
      <h2>${label}</h2><span class="meta">${items.length} · ${sub}</span></div>
      <div class="rows">` + items.map(d => `
      <div class="row ${d.status}" data-h="${d.handle}">
        <span class="dot ${d.status}"></span>
        <span class="t">${esc(d.title)}</span>
        ${d.status === 'resolved' ? '' : tags(d)}
        <span class="tag v">v${d.version}</span>
        <span class="id">${d.handle}</span>
      </div>`).join('') + '</div></section>';
  }
  document.getElementById('out').innerHTML = h || '<div id="empty">Nothing matches.</div>';
}

function openDet(handle){
  const d = byHandle[handle]; if (!d) return;
  let h = `<h2>${esc(d.title)}</h2>
    <div class="sub">${d.handle} · <a href="${esc(d.file)}">${esc(d.file)}</a> ·
      <span class="dot ${d.status}" style="vertical-align:middle"></span>
      ${esc((D.statuses[d.status]||d.status).replace(/^[^ ]+ /,''))} · v${d.version}${d.updatedAt ? ' · updated '+esc(d.updatedAt) : ''}</div>`;
  if (d.questions.length){
    h += `<div class="blk"><h4>Questions — ${d.counts.unanswered} unanswered · ${d.counts['awaiting-reply']} awaiting my reply · ${d.counts.replied} replied${d.counts.superseded ? ` · ${d.counts.superseded} moved past` : ''}</h4>`
      + d.questions.map(x => `<div class="qrow"><span class="dot ${x.state}"></span>
        <a href="${esc(d.file)}${x.section ? '#'+esc(x.section) : ''}">${esc(x.label||x.key)}</a>
        <span class="st">${QSTATE[x.state]}</span></div>`).join('') + '</div>';
  } else h += `<div class="blk"><h4>Questions</h4><div>none in this doc</div></div>`;
  if (d.issues.length){
    h += `<div class="blk"><h4>Issues on this decision</h4><div class="chips">`
      + d.issues.map(i => `<span class="chip ${i.gated?'gated':''}">
          ${esc(i.title)}${i.gated ? ' · gated' : ''}</span>`).join('') + '</div></div>';
  }
  // Status controls — write path exists only when served by serve.py (POST
  // /__doc → docstate.set_status). A file:// open stays read-only.
  if (location.protocol.startsWith('http')){
    const btn = (st, label) => `<button class="act" data-st="${st}" data-h="${d.handle}">${label}</button>`;
    let acts = '';
    if (d.status !== 'resolved') acts += btn('resolved', 'Mark resolved');
    if (d.status !== 'open' && d.status !== 'resolved') acts += btn('open', 'Ball to me (open)');
    if (d.status !== 'held') acts += btn('held', 'Hold');
    if (d.status === 'resolved' || d.status === 'held') acts += btn('open', 'Reopen');
    h += `<div class="blk"><h4>Move it</h4>${acts}</div>`;
  }
  document.getElementById('detBody').innerHTML = h;
  document.getElementById('det').classList.add('on');
  document.getElementById('scrim').classList.add('on');
  location.hash = handle;
}
function closeDet(){
  document.getElementById('det').classList.remove('on');
  document.getElementById('scrim').classList.remove('on');
  if (location.hash) history.replaceState(null,'',location.pathname);
}

async function docOp(handle, status){
  document.querySelectorAll('button.act').forEach(b => { b.disabled = true; });
  let j;
  try {
    const r = await fetch('/__doc', { method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ handle, status }) });
    j = await r.json();
  } catch (err){ j = { ok:false, error:String(err) }; }
  if (!j.ok){ alert(j.error || 'failed');
    document.querySelectorAll('button.act').forEach(b => { b.disabled = false; }); return; }
  location.reload();  // server re-rendered this file inside the call
}

document.addEventListener('click', e => {
  const act = e.target.closest('button.act');
  if (act) return void docOp(act.dataset.h, act.dataset.st);
  if (e.target.closest('#theme')){
    const cur = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = cur; localStorage.bwTheme = cur; return; }
  const node = e.target.closest('.row[data-h]');
  if (node) return openDet(node.dataset.h);
  if (e.target.id === 'close' || e.target.id === 'scrim') closeDet();
});
document.getElementById('q').addEventListener('input', e => { q = e.target.value.trim().toLowerCase(); render(); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeDet();
  if (e.key === '/' && e.target.id !== 'q'){ e.preventDefault(); document.getElementById('q').focus(); }
});
if (localStorage.bwTheme) document.documentElement.dataset.theme = localStorage.bwTheme;
render();
if (location.hash && byHandle[location.hash.slice(1)]) openDet(location.hash.slice(1));
// Highlight current page in sidebar
(function(){
  var file=(location.pathname.split('/').pop()||'').split('?')[0];
  document.querySelectorAll('body>nav a[href]').forEach(function(a){
    if(a.getAttribute('href')===file) a.classList.add('cur');
  });
})();
</script>
</body></html>
"""

CATEGORY_TEMPLATE = r"""<!doctype html>
<html lang="en" data-generated="doctracker.py"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<!-- GENERATED FILE — written by doctracker.py. Hand edits are lost on
     the next render. This is a read-only category landing page. -->
<style>
:root{
  --bg:#000; --panel:#000;
  --ink:#fff; --dim:rgba(255,255,255,.7);
  --line:#6FC3DF;
  --focus:#F38518;
  --accent:#21A6FF;
  --you:#F5F543; --me:#21A6FF; --done:#23D18B; --held:#D670D6; --warn:#F48771;
  --fs-sm:12px; --fs-base:14px; --fs-head:16px; --fs-title:20px;
  --mono:ui-monospace,SFMono-Regular,Menlo,monospace;
}
:root[data-theme=light]{
  --bg:#fff; --panel:#fff;
  --ink:#18181b; --dim:rgba(24,24,27,.7);
  --line:#7c3aed;
  --focus:#7c3aed;
  --accent:#7c3aed;
  --you:#7c3aed; --me:#7c3aed; --done:#0A5C21; --held:#7c3aed; --warn:#b91c1c;
}
*{box-sizing:border-box}
body{margin:0;display:flex;min-height:100vh;background:var(--bg);color:var(--ink);
  font:var(--fs-base)/1.5 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
body>nav{width:296px;flex:none;border-right:1px solid var(--line);background:var(--panel);
  padding:22px 14px;position:sticky;top:0;height:100vh;overflow-y:auto}
body>nav .brand{display:flex;align-items:center;gap:8px;font-weight:700;
  font-size:var(--fs-base);margin-bottom:16px;padding:0 6px}
body>nav .brand .logo{width:18px;height:18px;border:1px solid var(--line);background:none}
body>nav a{display:block;padding:6px 10px;color:var(--ink);text-decoration:none;
  font-size:var(--fs-base);margin-bottom:2px;border:1px solid transparent}
body>nav a:hover{box-shadow:inset 0 0 0 2px var(--focus)}
body>nav a.cur{border-color:var(--line);font-weight:700}
body>nav .grp{font-size:var(--fs-sm);font-weight:700;text-transform:uppercase;
  letter-spacing:.06em;color:var(--ink);margin:16px 6px 6px}
.content{flex:1;min-width:0}
a{color:var(--accent)}
:focus-visible{outline:2px solid var(--focus);outline-offset:1px}
header{position:sticky;top:0;z-index:20;background:var(--panel);
  border-bottom:1px solid var(--line);padding:10px 16px;
  display:flex;gap:14px;align-items:center;flex-wrap:wrap}
header h1{font-size:var(--fs-head);margin:0;font-weight:700}
.seg{display:flex;border:1px solid var(--line);border-radius:4px;overflow:hidden}
.seg button{background:var(--panel);border:0;color:var(--ink);padding:7px 11px;
  font-size:var(--fs-sm);font-weight:600;cursor:pointer}
.seg button:hover{box-shadow:inset 0 0 0 1px var(--focus)}
section{padding:0 18px 80px}
.dot{width:10px;height:10px;border-radius:50%;flex:none;display:inline-block;
  border:1px solid var(--bg);box-shadow:0 0 0 1px currentColor}
.dot.open{background:var(--you);color:var(--you)}
.dot.in-review{background:var(--me);color:var(--me)}
.dot.resolved{background:var(--done);color:var(--done)}
.dot.held{background:var(--held);color:var(--held)}
.rows{border:1px solid var(--line);border-radius:4px;overflow:hidden;background:var(--panel)}
.row{display:flex;gap:10px;align-items:center;padding:9px 12px;
  border-top:1px solid var(--line);color:var(--ink);text-decoration:none}
.row:first-child{border-top:0}
.row:hover{box-shadow:inset 0 0 0 2px var(--focus)}
.row .t{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  font-weight:700}
.row.resolved .t{font-weight:400}
.row .id{color:var(--ink);font-family:var(--mono);font-size:var(--fs-sm);flex:none}
.tag{font-size:var(--fs-sm);font-weight:700;padding:1px 8px;border-radius:10px;
  border:1px solid var(--line);color:var(--ink);flex:none;white-space:nowrap;
  background:transparent}
.tag.you{color:var(--you);border-color:var(--you)}
.tag.me{color:var(--me);border-color:var(--me)}
.tag.gate{color:var(--warn);border-color:var(--warn)}
.tag.v{font-variant-numeric:tabular-nums}
#empty{color:var(--ink);padding:40px 18px}
</style></head>
<body>
__NAV__
<div class="content">
<header>
  <h1>__TITLE__</h1>
  <div class="seg" id="theme"><button>&#9680;</button></div>
</header>
<section id="out"></section>
</div>

<script id="data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const DOCS = D.docs;
const esc = s => (s||'').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

function tags(d){
  let t = '';
  if (d.counts.unanswered) t += '<span class="tag you">' + d.counts.unanswered + ' to answer</span>';
  if (d.counts['awaiting-reply']) t += '<span class="tag me">' + d.counts['awaiting-reply'] + ' awaiting reply</span>';
  const g = d.issues.filter(i => i.gated).length;
  if (g) t += '<span class="tag gate">gates ' + g + ' issue' + (g>1?'s':'') + '</span>';
  return t;
}

function render(){
  const out = document.getElementById('out');
  if (!DOCS.length){
    out.innerHTML = '<div id="empty">No documents in this category yet.</div>';
    return;
  }
  const sorted = DOCS.slice().sort((a,b) => (b.updatedAt||'').localeCompare(a.updatedAt||''));
  out.innerHTML = '<div class="rows">' + sorted.map(d =>
    '<a class="row ' + d.status + '" href="' + esc(d.file) + '">' +
    '<span class="dot ' + d.status + '"></span>' +
    '<span class="t">' + esc(d.title) + '</span>' +
    (d.status !== 'resolved' ? tags(d) : '') +
    '<span class="tag v">v' + d.version + '</span>' +
    '<span class="id">' + esc(d.handle) + '</span>' +
    '</a>').join('') + '</div>';
}

document.addEventListener('click', e => {
  if (e.target.closest('#theme')){
    const cur = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = cur;
    try { localStorage.bwTheme = cur; } catch(err) {}
    return;
  }
});
try { if (localStorage.bwTheme) document.documentElement.dataset.theme = localStorage.bwTheme; }
catch(err) {}
render();
// Highlight current page in sidebar
(function(){
  var file=(location.pathname.split('/').pop()||'').split('?')[0];
  document.querySelectorAll('body>nav a[href]').forEach(function(a){
    if(a.getAttribute('href')===file) a.classList.add('cur');
  });
})();
</script>
</body></html>
"""

if __name__ == "__main__":
    main()
