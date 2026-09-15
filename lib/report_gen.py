"""lib/report_gen.py — Generate sprint report and dialogue doc HTML files.

Produces HTML matching the project's template conventions: theme vars, sidebar
nav with category links, multi-page sections, response boxes with save bar,
disk-save and live-reload scripts.  The generated file is the BASE template;
lib/enhance.py adds further patches (navmarks, collapse, autosave, etc.) at
serve time.

Used by the create_report MCP tool.  Stdlib only — no external dependencies.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime

# ---------------------------------------------------------------------------
# CSS — extracted from the production sprint report template.  Every generated
# doc starts with the same sheet; enhance.py's versioned patches upgrade it at
# serve time.
# ---------------------------------------------------------------------------

_CSS = """\
  :root{
    --bg:#0a0a0d; --fg:#fafafa; --accent:#a78bfa; --positive:#23D18B; --negative:#ef4444;
    --notice:#f59e0b;
    --fs-sm:14px; --fs-base:17px; --fs-head:21px; --fs-title:30px;
    --measure:70ch;
    --font:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    --mono:"SF Mono",SFMono-Regular,Menlo,Consolas,monospace;
    --radius:0;
  }

  *{box-sizing:border-box}
  html{font-size:16px;}
  body{font-family:var(--font); font-size:var(--fs-base); line-height:1.65;
    color:var(--fg); background:var(--bg); margin:0; display:flex; min-height:100vh;}

  :focus-visible{outline:2px solid var(--accent); outline-offset:1px;}

  code{font-family:var(--mono); font-size:var(--fs-sm); background:none;
    border:1px solid var(--accent); padding:0 .25em;}
  pre{background:none; border:1px solid var(--accent); padding:12px 14px; overflow-x:auto;
    font-family:var(--mono); font-size:var(--fs-sm); line-height:1.55;}
  pre code{border:none; padding:0;}

  nav{width:296px; flex:none; border-right:1px solid var(--accent); background:var(--bg);
    padding:22px 14px; position:sticky; top:0; height:100vh; overflow-y:auto;}
  nav .brand{display:flex; align-items:center; gap:8px; font-weight:700;
    font-size:var(--fs-base); margin-bottom:16px; padding:0 6px;}
  nav .brand .logo{width:18px; height:18px; border:1px solid var(--accent); background:none;}
  nav a{display:block; padding:6px 10px; color:var(--fg); text-decoration:none;
    font-size:var(--fs-base); margin-bottom:2px; border:1px solid transparent;}
  nav a:hover{box-shadow:inset 0 0 0 2px var(--accent);}
  nav a.cur{border-color:var(--accent); font-weight:700;}
  nav .grp{font-size:var(--fs-sm); font-weight:700; text-transform:uppercase;
    letter-spacing:.06em; color:var(--fg); margin:16px 6px 6px;}
  nav .foot{font-size:var(--fs-sm); color:var(--fg); margin-top:20px; padding:0 6px;}

  main{flex:1; min-width:0; padding:38px 42px 120px; max-width:1060px;}
  .page{display:none;} .page.cur{display:block;}

  h1{font-size:var(--fs-title); font-weight:700; letter-spacing:-.015em;
    line-height:1.2; margin:2px 0 8px;}
  h2{font-size:var(--fs-head); font-weight:700; line-height:1.3; margin:34px 0 8px;}
  h3{font-size:var(--fs-head); font-weight:700; text-transform:uppercase;
    letter-spacing:.03em; line-height:1.3; margin:24px 0 6px;}
  .sub{font-size:var(--fs-base); margin:0 0 20px;}
  p{margin:11px 0;}
  main a{color:var(--accent); text-decoration:underline;}

  .page > p, .page > ul, .page > ol, .page > .sub, .callout, blockquote{
    max-width:var(--measure);}

  .callout{padding:12px 16px; margin:16px 0; border:1px solid var(--accent); background:none;}
  .callout.key{border-left:3px solid var(--accent);}
  .callout.good{border-left:3px solid var(--positive);}
  .callout.warn{border-left:3px solid var(--notice);}
  .callout.bad{border-left:3px solid var(--negative);}
  .callout .tag{font-size:var(--fs-sm); font-weight:700; text-transform:uppercase;
    letter-spacing:.05em; display:block; margin-bottom:4px;}
  .callout.key .tag{color:var(--accent);} .callout.good .tag{color:var(--positive);}
  .callout.warn .tag{color:var(--notice);} .callout.bad .tag{color:var(--negative);}

  .tbl-wrap{overflow-x:auto; margin:18px 0;}
  table{border-collapse:collapse; width:100%; font-size:var(--fs-base);}
  th,td{padding:10px 12px; text-align:left; border:1px solid var(--accent); vertical-align:top;}
  thead th{font-size:var(--fs-sm); font-weight:700; text-transform:uppercase;
    letter-spacing:.04em; color:var(--fg); white-space:nowrap;}
  td code{font-size:var(--fs-sm);}

  ul,ol{margin:10px 0; padding-left:24px;} li{margin:7px 0;}
  .foot{font-size:var(--fs-sm);}

  .pill{display:inline-block; font-size:var(--fs-sm); font-weight:700; padding:1px 8px;
    border:1px solid var(--accent); background:none; color:var(--fg); vertical-align:middle;}
  .pill.dec{color:var(--notice); border-color:var(--notice);}
  .pill.grn{color:var(--positive); border-color:var(--positive);}
  .pill.red{color:var(--negative); border-color:var(--negative);}

  .card{border:1px solid var(--accent); padding:12px 14px; margin:16px 0;}
  .card > :first-child{margin-top:0}
  .card > :last-child{margin-bottom:0}
  .card.flag{border-left:3px solid var(--notice);}
  .card .eyebrow{font-size:var(--fs-sm); font-weight:700; text-transform:uppercase;
    letter-spacing:.05em; display:block; margin-bottom:4px; color:var(--notice);}

  blockquote{border-left:3px solid var(--accent); margin:10px 0; padding-left:13px;
    font-size:var(--fs-base);}

  .response{margin:16px 0 6px; border:1px solid var(--accent);
    border-left:3px solid var(--notice); background:none; padding:9px 13px;}
  .response label{display:block; font-size:var(--fs-sm); font-weight:700;
    text-transform:uppercase; letter-spacing:.05em; color:var(--notice); margin-bottom:5px;}
  .response .discuss{margin:0 0 10px; padding:9px 12px; border:1px solid var(--accent);
    border-left:2px solid var(--accent); background:none;
    font-size:var(--fs-base); line-height:1.55; color:var(--fg);}
  .response .discuss code{font-size:var(--fs-sm);}
  .response textarea{width:100%; min-height:52px; resize:vertical; font-family:var(--font);
    font-size:var(--fs-base); color:var(--fg); background:var(--bg);
    border:1px solid var(--accent); padding:7px 10px; line-height:1.5; overflow:hidden;}
  .response textarea:focus{outline:none; box-shadow:inset 0 0 0 2px var(--accent);}
  .response.filled{border-left-color:var(--positive);}
  .response.filled label{color:var(--positive);}

  .savebar{position:fixed; bottom:14px; right:19px; display:flex; align-items:center;
    gap:11px; z-index:50; background:var(--bg); border:1px solid var(--accent);
    padding:7px 9px 7px 16px;}
  .savebar .stat{font-size:var(--fs-sm); color:var(--fg);}
  .savebar button{font-family:var(--font); font-size:var(--fs-base); font-weight:700;
    cursor:pointer; border:1px solid var(--accent); background:none; color:var(--fg);
    padding:6px 14px;}
  .savebar button:hover{box-shadow:inset 0 0 0 2px var(--accent);}
  .savebar button.ghost{border-color:var(--accent); color:var(--fg); padding:6px 10px;}"""

_THEME_CSS = """\
:root[data-theme="daylight"]{
  --bg:#FAF8F4; --fg:#23262E; --accent:#6D4AA8; --positive:#0B6E5A;
  --negative:#8C1D18; --notice:#A06E12;
  --fs-sm:14px; --fs-base:17px; --fs-head:21px; --fs-title:30px;
}
:root[data-theme="high-contrast"]{
  --bg:#000; --fg:#fff; --accent:#D670D6; --positive:#23D18B;
  --negative:#F48771; --notice:#F5F543;
  --fs-sm:12px; --fs-base:14px; --fs-head:16px; --fs-title:20px;
}
:root[data-theme="janus"]{
  --bg:#0a0a0d; --fg:#fafafa; --accent:#c084fc; --positive:#23D18B;
  --negative:#ef4444; --notice:#fbbf24;
  --fs-sm:12px; --fs-base:14px; --fs-head:16px; --fs-title:20px;
}"""

_THEME_FLASH = (
    '<script id="__theme-flash-patch" data-tf="2">'
    "try{var t=localStorage.getItem('entropy-machines-theme');"
    "if(t)document.documentElement.setAttribute('data-theme',t);}"
    "catch(e){}</script>"
)

_DISK_SAVE_CSS = """\
<style id="__disk-save-css">
  .box-status{font-size:var(--fs-sm,12px); font-weight:700; text-transform:uppercase;
    letter-spacing:.04em; margin-top:6px; padding:0;}
  .box-status.awaiting{color:var(--notice);}
  .box-status.saved{color:var(--positive);}
</style>"""

_DISK_SAVE_JS = """\
<script id="__disk-save-patch" data-ds="3">
(function(){
  var btn=document.getElementById('saveBtn');
  var stat=document.getElementById('saveStat');
  if(!btn) return;
  var b=btn.cloneNode(true); btn.parentNode.replaceChild(b, btn);
  function collect(){ var o={}; document.querySelectorAll('.response[data-resp]').forEach(function(el){ var t=el.querySelector('textarea'); if(t) o[el.getAttribute('data-resp')]=t.value; }); return o; }
  var file=(location.pathname.split('/').pop()||'').split('?')[0];
  function markBoxes(){
    document.querySelectorAll('.response[data-resp]').forEach(function(el){
      if(el.classList.contains('mini')) return;
      var t=el.querySelector('textarea'); if(!t) return;
      var s=el.querySelector('.box-status');
      if(!t.value.trim()){ if(s) s.remove(); return; }
      var hasReply=!!document.querySelector('aside.review[data-review="'+el.getAttribute('data-resp')+'"]');
      if(!s){ s=document.createElement('div'); s.className='box-status'; el.appendChild(s); }
      if(hasReply){ s.textContent='saved'; s.className='box-status saved'; }
      else { s.textContent='awaiting agent review'; s.className='box-status awaiting'; }
    });
  }
  b.addEventListener('click', async function(){
    var data=collect();
    if(stat) stat.textContent='Saving to disk\\u2026';
    try{
      var res=await fetch('/__save?file='+encodeURIComponent(file),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
      if(res.ok){
        if(stat) stat.textContent='Saved to disk \\u2713';
        try{ var el=document.getElementById('responses-data'); if(el) el.textContent=JSON.stringify(data,null,2); }catch(_){}
        markBoxes();
        return;
      }
      if(stat) stat.textContent='Save failed ('+res.status+')';
    }catch(e){
      if(stat) stat.textContent='Server offline \\u2014 start bin/serve to save in place';
    }
  });
  markBoxes();
})();
</script>"""

_LIVERELOAD_JS = """\
<script id="__livereload-patch" data-lr="3">
(function(){
  try{
    var pre=JSON.parse(sessionStorage.getItem('__lr-pre')||'null');
    if(pre){
      sessionStorage.removeItem('__lr-pre');
      var first=null;
      document.querySelectorAll('aside.review[data-review]').forEach(function(el){
        if(!first && pre.indexOf(el.getAttribute('data-review'))<0) first=el;
      });
      if(first) setTimeout(function(){ first.scrollIntoView({behavior:'smooth',block:'start'}); },200);
    }
  }catch(e){}
  var file=(location.pathname.split('/').pop()||'').split('?')[0];
  if(!file) return;
  var seen=null, stopped=false;
  var bar=document.createElement('div');
  bar.id='__replybar'; bar.hidden=true;
  bar.innerHTML='<span id="__replytext">New reply \\u2014 reload to read it</span>'+
    '<button id="__replygo">Reload</button>'+
    '<button class="dismiss" id="__replyx" title="Dismiss">\\u2715</button>';
  document.body.appendChild(bar);
  function snapshot(){
    var ids=[];
    document.querySelectorAll('aside.review[data-review]').forEach(function(el){ ids.push(el.getAttribute('data-review')); });
    try{ sessionStorage.setItem('__lr-pre',JSON.stringify(ids)); }catch(e){}
  }
  bar.querySelector('#__replygo').addEventListener('click',function(){ snapshot(); location.reload(); });
  bar.querySelector('#__replyx').addEventListener('click',function(){ bar.hidden=true; stopped=true; });
  function baked(){
    var el=document.getElementById('responses-data');
    try{ return JSON.parse((el&&el.textContent)||'{}')||{}; }catch(e){ return {}; }
  }
  function dirty(){
    var disk=baked(), out=false;
    document.querySelectorAll('.response[data-resp]').forEach(function(el){
      var t=el.querySelector('textarea'); if(!t) return;
      if((t.value||'').trim() !== String(disk[el.getAttribute('data-resp')]||'').trim()) out=true;
    });
    return out;
  }
  function tick(){
    if(stopped) return;
    fetch('/__docversion?file='+encodeURIComponent(file),{cache:'no-store'})
      .then(function(r){ return r.ok ? r.json() : null; })
      .then(function(d){
        if(!d || typeof d.reviews!=='string') return;
        if(seen===null){ seen=d.reviews; return; }
        if(d.reviews===seen) return;
        seen=d.reviews;
        if(!dirty()){ snapshot(); location.reload(); return; }
        document.getElementById('__replytext').textContent=
          'New reply on disk \\u2014 you have unsaved edits. Save first, then reload.';
        bar.hidden=false;
      })
      .catch(function(){});
  }
  setInterval(tick, 5000); tick();
})();
</script>"""

# ---------------------------------------------------------------------------
# nav group labels by doc type
# ---------------------------------------------------------------------------

_NAV_GROUP = {
    "sprint-report": "Sprint Report",
    "dialogue": "Sections",
}

_NAV_FOOT = (
    "Answer each section's questions, then save. Your responses\n"
    "    are written back into this file on disk when served by "
    "<code>bin/serve</code>."
)


# ---------------------------------------------------------------------------
# public API
# ---------------------------------------------------------------------------

def _esc(s):
    """Minimal HTML escaping for attribute values and text content."""
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _make_slug(title):
    """Turn a title into a safe slug for filenames."""
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s or "untitled"


def generate_html(doc_type, title, slug, subtitle, sections):
    """Generate a complete HTML document following the project's template
    conventions.

    Args:
        doc_type: "sprint-report" or "dialogue"
        title: Document title (shown in <title> and <h1>)
        slug: URL-safe identifier for filename and nav brand
        subtitle: Subtitle text (date, description)
        sections: List of dicts, each with:
            nav_title: Nav sidebar link text
            heading: Section heading
            subtitle: Optional section subtitle
            content: HTML body content
            response: Optional dict with key, label, discuss

    Returns:
        The complete HTML string.
    """
    if doc_type == "sprint-report":
        filename = "SPRINT-REPORT-%s.html" % slug
    else:
        filename = "%s.html" % slug

    nav_group = _NAV_GROUP.get(doc_type, "Sections")
    ls_key = os.path.splitext(filename)[0]

    # Build nav links
    nav_links = []
    for i, sec in enumerate(sections):
        cur = ' class="cur"' if i == 0 else ""
        pid = "p%d" % i
        nav_links.append(
            '  <a href="#%s" data-page="%s"%s>%s</a>'
            % (pid, pid, cur, _esc(sec.get("nav_title", sec["heading"])))
        )

    # Build page sections
    page_sections = []
    for i, sec in enumerate(sections):
        pid = "p%d" % i
        cur = " cur" if i == 0 else ""
        parts = []
        parts.append('<section class="page%s" id="%s">' % (cur, pid))
        parts.append("  <h1>%s</h1>" % sec["heading"])
        if sec.get("subtitle"):
            parts.append('  <p class="sub">%s</p>' % sec["subtitle"])
        parts.append("")
        parts.append("  %s" % sec["content"])

        resp = sec.get("response")
        if resp:
            parts.append("")
            parts.append('  <div class="response" data-resp="%s">' % _esc(resp["key"]))
            parts.append("    <label>%s</label>" % _esc(resp["label"]))
            parts.append('    <div class="discuss">%s</div>' % resp["discuss"])
            parts.append('    <textarea placeholder="Type your answer..."></textarea>')
            parts.append("  </div>")

        parts.append("</section>")
        page_sections.append("\n".join(parts))

    # Build the page navigation + response box script
    page_nav_js = _build_page_nav_js(ls_key)

    # Assemble the full HTML
    lines = []
    lines.append("<!doctype html>")
    if doc_type == "sprint-report":
        lines.append(
            "<!-- =================== entropy-machines sprint report ====================\n"
            "  %s. Generated by the create_report MCP tool.\n"
            "  ======================================================================= -->" % _esc(title)
        )
    else:
        lines.append(
            "<!-- =================== entropy-machines dialogue doc ====================\n"
            "  %s. Generated by the create_report MCP tool.\n"
            "  ======================================================================= -->" % _esc(title)
        )
    lines.append('<html lang="en"><head>')
    lines.append('<meta charset="utf-8">')
    lines.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    lines.append("<title>%s</title>" % _esc(title))
    lines.append("<style>")
    lines.append(_CSS)
    lines.append("</style>")
    lines.append('<style id="__theme-options-patch">')
    lines.append(_THEME_CSS)
    lines.append("</style>")
    lines.append("</head><body>")
    lines.append(_THEME_FLASH)
    lines.append("")

    # Nav
    lines.append("<nav>")
    lines.append('  <div class="brand"><span class="logo"></span> %s</div>' % _esc(slug))
    lines.append('  <div class="grp">Categories</div>')
    lines.append('  <a href="TRACKER.html">issues</a>')
    lines.append('  <a href="PRDS.html">PRDs</a>')
    lines.append('  <a href="REPORTS.html">reports</a>')
    lines.append('  <a href="DOCS.html">docs</a>')
    lines.append('  <div class="grp">%s</div>' % _esc(nav_group))
    lines.extend(nav_links)
    lines.append('  <div class="foot">%s</div>' % _NAV_FOOT)
    lines.append("</nav>")
    lines.append("")

    # Main
    lines.append("<main>")
    lines.append("")
    lines.append("\n\n".join(page_sections))
    lines.append("")
    lines.append("</main>")
    lines.append("")

    # Save bar
    lines.append('<div class="savebar">')
    lines.append('  <span class="stat" id="saveStat">Unsaved changes...</span>')
    lines.append('  <button class="ghost" id="clearBtn" title="Clear all responses">&#10005;</button>')
    lines.append('  <button id="saveBtn">Save</button>')
    lines.append("</div>")

    # Scripts
    lines.append('<script type="application/json" id="responses-data">{}</script>')
    lines.append(page_nav_js)
    lines.append(_DISK_SAVE_CSS)
    lines.append(_DISK_SAVE_JS)
    lines.append(_LIVERELOAD_JS)
    lines.append("</body></html>")

    return "\n".join(lines) + "\n"


def _build_page_nav_js(ls_key):
    """Build the page navigation + response box script block."""
    return """\
<script>
(function(){
  var links=[].slice.call(document.querySelectorAll('nav a[data-page]'));
  function show(id){
    document.querySelectorAll('.page').forEach(function(p){ p.classList.toggle('cur', p.id===id); });
    links.forEach(function(l){ l.classList.toggle('cur', l.dataset.page===id); });
    try{ history.replaceState(null,'','#'+id); }catch(e){}
    window.scrollTo(0,0);
    document.querySelectorAll('#'+id+' .response textarea').forEach(function(t){ autoGrow(t); });
  }
  links.forEach(function(l){ l.addEventListener('click', function(ev){ ev.preventDefault(); show(l.dataset.page); }); });
  if (location.hash && document.getElementById(location.hash.slice(1))) show(location.hash.slice(1));
  window.addEventListener('hashchange', function(){ var h=location.hash.slice(1); if(h && document.getElementById(h)) show(h); });
  var KEY='%s';
  var boxes=[].slice.call(document.querySelectorAll('.response'));
  var stat=document.getElementById('saveStat');
  var dataEl=document.getElementById('responses-data');
  function ta(b){return b.querySelector('textarea');}
  function key(b){return b.getAttribute('data-resp');}
  function markFilled(b){ if(ta(b).value.trim()) b.classList.add('filled'); else b.classList.remove('filled'); }
  function autoGrow(el){ el.style.height='auto'; el.style.height=el.scrollHeight+'px'; }
  function load(){
    var saved={};
    try{ saved=JSON.parse(dataEl.textContent||'{}')||{}; }catch(e){}
    try{ var ls=JSON.parse(localStorage.getItem(KEY)||'{}'); Object.keys(ls).forEach(function(k){ if(ls[k]&&ls[k].trim()) saved[k]=ls[k]; }); }catch(e){}
    boxes.forEach(function(b){ var v=saved[key(b)]; if(typeof v==='string') ta(b).value=v; markFilled(b); autoGrow(ta(b)); });
  }
  function collect(){ var o={}; boxes.forEach(function(b){ o[key(b)]=ta(b).value; }); return o; }
  function autosave(){ try{ localStorage.setItem(KEY,JSON.stringify(collect())); }catch(e){} }
  boxes.forEach(function(b){ ta(b).addEventListener('input',function(){ markFilled(b); autoGrow(ta(b)); autosave(); stat.textContent='Unsaved changes...'; }); });
  load();
  window.addEventListener('resize',function(){ boxes.forEach(function(b){ autoGrow(ta(b)); }); });
})();
</script>""" % ls_key


def filename_for(doc_type, slug):
    """Return the conventional filename for a doc type and slug."""
    if doc_type == "sprint-report":
        return "SPRINT-REPORT-%s.html" % slug
    return "%s.html" % slug


def doc_id_for(doc_type, slug):
    """Return the manifest/db doc id for a doc type and slug."""
    if doc_type == "sprint-report":
        return "sprint-report-%s" % slug
    return slug


def db_type_for(doc_type):
    """Return the SQLite docs.type value."""
    if doc_type == "sprint-report":
        return "report"
    return "doc"
