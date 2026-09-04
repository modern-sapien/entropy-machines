#!/usr/bin/env python3
"""Apply the review-doc enhancements to the dialogue-docs, idempotently.

Patches, each guarded by a marker so re-running is safe:
  1. disk-save   — 💾 POSTs responses to bin/serve (writes back in place).
  2. nav-marks   — live per-section review state in the sidebar.
  3. live-reload — polls for new reply folds and auto-reloads when clean.
  4. collapse    — collapses earlier rounds of long dialogue chains.
  5. theme-selector — named-theme selector (replaces the old dark/light toggle).
  6. readmark    — IntersectionObserver marks review blocks as read.
  7. docstatus   — shows doc-level status badge in the sidebar brand area.
  8. issue-agree — checkboxes on PRD issue tables for accept/reject (PRDs only).
  9. unsaved-cue — savebar border turns caution when edits are pending.
 10. doc-nav    — cross-doc navigation: 4 category links to landing pages.

Usage:
  python3 enhance.py            # patch every *.html in this folder
  python3 enhance.py <file>     # patch one file
"""
import glob
import json
import os
import re
import sys

DIR = None  # set by init() or docstate.init()

DISK_SAVE_MARK = 'id="__disk-save-patch"'
DISK_WINS_MARK = 'id="__disk-wins-patch"'
BOXSTATE_MARK = 'id="__boxstate-patch"'
BOXSTATE_RV = "1"
NAVMARK_MARK = 'id="__navmark-patch"'
NAVMARK_RV = "2"
TODOBANNER_MARK = 'id="__todobanner-patch"'
TODOBANNER_RV = "2"
TRACKERNAV_MARK = 'id="__trackernav-patch"'
TRACKERNAV_RV = "1"
REPORTNAV_MARK = 'id="__reportnav-patch"'
AUTOSAVE_MARK = 'id="__autosave-patch"'
COLLAPSE_MARK = 'id="__collapse-patch"'
COLLAPSE_RV = "1"
LOCKBOX_MARK = 'id="__lockbox-patch"'
LOCKBOX_RV = "1"
THEMEFLASH_MARK = 'id="__theme-flash-patch"'
THEMEFLASH_RV = "2"
THEMETOGGLE_MARK = 'id="__theme-toggle-patch"'
THEMETOGGLE_RV = "2"
THEME_OPTIONS_MARK = 'id="__theme-options-patch"'
READMARK_MARK = 'id="__readmark-patch"'
READMARK_RV = "1"
DOCSTATUS_MARK = 'id="__docstatus-patch"'
DOCSTATUS_RV = "1"
ISSUE_AGREE_MARK = 'id="__issue-agree-patch"'
ISSUE_AGREE_RV = "1"
UNSAVED_CUE_MARK = 'id="__unsaved-cue-patch"'
UNSAVED_CUE_RV = "1"
DOCNAV_MARK = 'id="__docnav-patch"'
DOCNAV_RV = "2"
LIVERELOAD_MARK = 'id="__livereload-patch"'
# VERSIONED, like review-css, and for the same reason: every doc already carries
# a copy of this patch stamped into its HTML, so a mark-only gate reads them all
# as fresh and a fix reaches nothing. That is precisely how the review-css v4 fix
# reached 2 of 21 docs (see test_enhance's header). Bump on every behaviour
# change to the patch body.
#   v1  version-bump trigger — announced "new reply" on the reader's own 💾
#   v2  review-signature trigger
#   v3  scroll-to-update — after live-reload, scroll to the first NEW reply block
LIVERELOAD_RV = "3"
# disk-save versions:
#   v1  did not re-baseline responses-data after a save, so every saved
#       answer read as an unsaved edit for the rest of the session
#   v2  syncs responses-data on a successful save
DISK_SAVE_RV = "3"

# The marks serve.py's freshness gate requires, in ONE place. It used to be a
# tuple written out in serve.py and a second copy in test_enhance.py, so adding
# a patch meant the test kept asserting against the old list and passed while
# testing nothing — the same duplicated-list failure the tracker.SOURCES
# comment in serve.py documents. Both now import this. PRDSTATUS_MARK is
# deliberately absent: it is applied only to PRD/SPINE docs, so requiring it
# would make every other doc read stale forever. ISSUE_AGREE_MARK is absent
# for the same reason: it is applied only to PRDs with issue tables.
GATE_MARKS = (DISK_SAVE_MARK, DISK_WINS_MARK, BOXSTATE_MARK, NAVMARK_MARK,
              TODOBANNER_MARK, TRACKERNAV_MARK, COLLAPSE_MARK,
              LOCKBOX_MARK, THEMEFLASH_MARK, THEMETOGGLE_MARK,
              THEME_OPTIONS_MARK,
              READMARK_MARK, DOCSTATUS_MARK, UNSAVED_CUE_MARK,
              DOCNAV_MARK,
              LIVERELOAD_MARK, AUTOSAVE_MARK)


# ---- versioned patches ----------------------------------------------------
# A patch stamped into every doc can be REVISED, and mark-presence is not
# freshness for anything revisable: the gate reads the old copy as current and
# the fix reaches nothing. This has now bitten three separate patches —
# review-css (v4 landed in 2 of 21 docs), live-reload (announced "new reply" on
# the reader's own 💾 and could not be corrected in place), and disk-save. So
# it is a mechanism rather than a third hand-rolled copy.
#
# id → attribute carrying the version. Bump the RV constant on any behaviour
# change to that patch body and every served doc upgrades itself on next GET.
VERSIONED = {
    "__livereload-patch": ("data-lr", lambda: LIVERELOAD_RV, lambda: LIVERELOAD),
    "__disk-save-patch": ("data-ds", lambda: DISK_SAVE_RV, lambda: DISK_SAVE),
    # The three that decide what a doc SAYS needs the reader. Versioned
    # together because they are one rule in three places: change the rule in
    # __boxstate-patch and the other two must be re-served with it, or a doc
    # keeps counting by the old one.
    "__boxstate-patch": ("data-bs", lambda: BOXSTATE_RV, lambda: BOXSTATE),
    "__navmark-patch": ("data-nm", lambda: NAVMARK_RV, lambda: _script_only(NAVMARK)),
    "__todobanner-patch": ("data-tb", lambda: TODOBANNER_RV, lambda: _script_only(TODOBANNER)),
    "__collapse-patch": ("data-cl", lambda: COLLAPSE_RV, lambda: _script_only(COLLAPSE)),
    "__theme-flash-patch": ("data-tf", lambda: THEMEFLASH_RV, lambda: THEMEFLASH),
    "__theme-toggle-patch": ("data-tt", lambda: THEMETOGGLE_RV, lambda: _themetoggle_body()),
    "__lockbox-patch": ("data-lb", lambda: LOCKBOX_RV, lambda: LOCKBOX),
    "__readmark-patch": ("data-rm", lambda: READMARK_RV, lambda: _script_only(READMARK)),
    "__docstatus-patch": ("data-dstatus", lambda: DOCSTATUS_RV, lambda: _script_only(DOCSTATUS)),
    "__issue-agree-patch": ("data-ia", lambda: ISSUE_AGREE_RV, lambda: _script_only(ISSUE_AGREE)),
    "__unsaved-cue-patch": ("data-uc", lambda: UNSAVED_CUE_RV, lambda: UNSAVED_CUE),
    "__trackernav-patch": ("data-tn", lambda: TRACKERNAV_RV, lambda: _script_only(TRACKERNAV)),
    "__docnav-patch": ("data-dn", lambda: DOCNAV_RV, lambda: _script_only(DOCNAV)),
}



def _script_only(block):
    """The <script> half of a css+script patch block.

    ensure_versioned() rewrites the <script id="…"> tag in place, so the body
    it upgrades to must not carry the block's <style> with it — that would add
    one more copy of the stylesheet per upgrade.
    """
    i = block.index("<script ")
    return block[i:]


def _versioned_tag(pid):
    return re.compile(r'<script id="%s"[^>]*>.*?</script>' % re.escape(pid), re.S)


def versioned_block(pid):
    """That patch's body with its current version substituted in."""
    attr, rv, body = VERSIONED[pid]
    return body().replace("__RV__", rv())


def versioned_fresh(src, pid):
    """True when this doc carries the CURRENT copy of that patch."""
    attr, rv, _ = VERSIONED[pid]
    return f'id="{pid}" {attr}="{rv()}"' in src


def ensure_versioned(src, pid):
    """Upgrade a stale versioned block in place. No-op if absent or current."""
    if f'id="{pid}"' not in src or versioned_fresh(src, pid):
        return src
    return _versioned_tag(pid).sub(lambda _m: versioned_block(pid), src, count=1)


def all_versioned_fresh(src):
    """Every versioned patch this doc carries is the current one."""
    return all(versioned_fresh(src, pid) for pid in VERSIONED
               if f'id="{pid}"' in src)


# Kept as the names serve.py and the tests already call.
def livereload_fresh(src):
    return versioned_fresh(src, "__livereload-patch")


def ensure_livereload(src):
    return ensure_versioned(src, "__livereload-patch")


def livereload_block():
    return versioned_block("__livereload-patch")


def required_marks(name, src=None):
    """The marks THIS doc must carry to count as freshly patched."""
    marks = list(GATE_MARKS)
    if needs_reportnav(name, src):
        marks.append(REPORTNAV_MARK)
    return tuple(marks)

# Generated pages — docstate.py/doctracker.py overwrite these on every render,
# so stamping them does nothing but churn the diff.
GENERATED = {"DOCS.html", "INDEX.html", "PRDS.html", "REPORTS.html"}

_HAS_PAGE_NAV = re.compile(r"<nav[^>]*>.*?<a[^>]+data-page=", re.S)


def needs_reportnav(name, src=None):
    """True when this doc should get the DERIVED section nav.

    Any doc that has response boxes, a </main>, and no page nav of its own.
    """
    if src is None:
        return False
    if "</main>" not in src or 'data-resp="' not in src:
        return False
    return not _HAS_PAGE_NAV.search(src)

DISK_WINS = r'''
<script id="__disk-wins-patch">
/* Disk beats a stale localStorage for answers that are already SAVED.
 *
 * The template's load() does the opposite: it merges localStorage OVER the
 * on-disk responses-data, unconditionally. That cost us four answers on
 * 2026-08-05 — a1-goal-followup, a7-tools, a8-toolset and a9-render came back
 * holding the text of the LAST four boxes, and the next save wrote the shift
 * to disk as truth. Recovered from history/v015; the browser's localStorage
 * was later confirmed to still hold the corrupted values, so the tab stayed
 * armed to redo the damage on every subsequent save.
 *
 * localStorage exists to protect typing that has NOT been saved yet, and that
 * is all it should win. So: a key with a non-empty value on disk is restored
 * from disk; a key that is empty on disk keeps whatever the browser holds.
 * Then localStorage is rewritten from the corrected DOM, which HEALS the drift
 * instead of masking it — otherwise the bad map survives every reload.
 *
 * Runs after the template's own load() because it is appended at end-of-body.
 */
(function(){
  var dataEl=document.getElementById('responses-data');
  if(!dataEl) return;
  var disk={};
  try{ disk=JSON.parse(dataEl.textContent||'{}')||{}; }catch(e){ return; }
  var healed=[];
  document.querySelectorAll('.response[data-resp]').forEach(function(el){
    var t=el.querySelector('textarea'); if(!t) return;
    var k=el.getAttribute('data-resp'), v=disk[k];
    if(typeof v==='string' && v.trim() && t.value!==v){
      healed.push(k+' ('+t.value.length+'->'+v.length+' chars)');
      t.value=v;
    }
    if(t.value.trim()) el.classList.add('filled'); else el.classList.remove('filled');
    t.style.height='auto'; t.style.height=t.scrollHeight+'px';
  });
  if(healed.length){
    try{
      // Which stored map belongs to THIS doc. It used to be "the first key
      // starting with janus-", which was a guess: localStorage is per-ORIGIN,
      // so every doc served from 127.0.0.1:8787 shares one store, and the
      // first janus- key is usually some other document's answers — healing
      // would then overwrite THAT doc's unsaved typing with this doc's.
      // Ownership is now proved, not guessed: a map belongs to this doc if it
      // holds at least one of this doc's data-resp ids. __autosave-patch's own
      // key (janus-<file>) is always included.
      var mine={};
      document.querySelectorAll('.response[data-resp]').forEach(function(el){
        var t=el.querySelector('textarea');
        if(t) mine[el.getAttribute('data-resp')]=t.value;
      });
      var file=(location.pathname.split('/').pop()||'doc').split('?')[0];
      var targets=['janus-'+file];
      for(var i=0;i<localStorage.length;i++){
        var k2=localStorage.key(i);
        if(!k2 || k2.indexOf('janus-')!==0 || targets.indexOf(k2)>=0) continue;
        try{
          var m=JSON.parse(localStorage.getItem(k2)||'{}')||{};
          if(Object.keys(m).some(function(kk){ return kk in mine; })) targets.push(k2);
        }catch(_e){}
      }
      targets.forEach(function(k3){
        // Only rewrite ids the map already held, plus this doc's own key in
        // full — a shared-prefix map from another doc keeps its other entries.
        var out;
        if(k3==='janus-'+file){ out=mine; }
        else {
          try{ out=JSON.parse(localStorage.getItem(k3)||'{}')||{}; }catch(_e){ return; }
          Object.keys(out).forEach(function(kk){ if(kk in mine) out[kk]=mine[kk]; });
        }
        localStorage.setItem(k3,JSON.stringify(out));
      });
    }catch(e){}
    console.warn('[dialogue-doc] restored '+healed.length+
      ' answer(s) from disk over a stale localStorage: '+healed.join(', '));
  }
})();
</script>
'''.strip()

DISK_SAVE = r'''
<style id="__disk-save-css">
  .box-status{font-size:var(--fs-sm,12px); font-weight:700; text-transform:uppercase;
    letter-spacing:.04em; margin-top:6px; padding:0;}
  .box-status.awaiting{color:var(--caution,#f59e0b);}
  .box-status.saved{color:var(--positive,#23D18B);}
</style>
<script id="__disk-save-patch" data-ds="__RV__">
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
      var key=el.getAttribute('data-resp');
      var s=el.querySelector('.box-status');
      if(!t.value.trim()){ if(s) s.remove(); return; }
      var hasReply=!!document.querySelector('aside.review[data-review="'+key+'"]');
      if(!s){ s=document.createElement('div'); s.className='box-status'; el.appendChild(s); }
      if(hasReply){ s.textContent='saved'; s.className='box-status saved'; }
      else { s.textContent='awaiting agent review'; s.className='box-status awaiting'; }
    });
  }
  b.addEventListener('click', async function(){
    var data=collect();
    if(stat) stat.textContent='Saving to disk…';
    try{
      var res=await fetch('/__save?file='+encodeURIComponent(file),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
      if(res.ok){
        if(stat) stat.textContent='Saved to disk ✓';
        try{
          var el=document.getElementById('responses-data');
          if(el) el.textContent=JSON.stringify(data,null,2);
        }catch(_){}
        markBoxes();
        return;
      }
      if(stat) stat.textContent='Save failed ('+res.status+')';
    }catch(e){
      if(stat) stat.textContent='Server offline — downloaded a copy (start serve.py to save in place)';
      try{
        var dataEl=document.getElementById('responses-data');
        if(dataEl) dataEl.textContent=JSON.stringify(data,null,2);
        document.querySelectorAll('.response[data-resp] textarea').forEach(function(t){ t.textContent=t.value; });
        var htmlOut='<!doctype html>\n'+document.documentElement.outerHTML;
        var a=document.createElement('a');
        a.href=URL.createObjectURL(new Blob([htmlOut],{type:'text/html'}));
        a.download=file; document.body.appendChild(a); a.click(); a.remove();
      }catch(_){}
    }
  });
  markBoxes();
})();
</script>
'''.strip()

BOXSTATE = r'''
<script id="__boxstate-patch" data-bs="__RV__">
// WHICH BOXES ACTUALLY WANT THE READER. One definition, used by the nav marks
// and the todo bar, because they used to each count "every .response[data-resp]
// with an empty textarea" and that count lied twice over:
//
//   1. A .mini row-note ("note on this row") is an INVITATION, never a demand.
//      Counting them left pages reading 0/7 forever.
//   2. A follow-up box the conversation already ran PAST is not pending. Chains
//      read question -> answer -> my reply + follow-up -> answer -> ...; a gap
//      in the middle means the reader kept going, a gap at the END means they
//      have not answered yet.
//
// Both were reported by the owner against a doc that claimed four open
// questions when every real question in it was answered ("uh.. everything is
// checked off. what is open here?", 2026-08-23). Same rule as doctracker.py's
// qstate/mark_superseded — if you change one, change the other.
(function(){
  function chainOf(key){
    var stem=key, m;
    while((m=/^(.*)-followup\d*$/.exec(stem))) stem=m[1];
    return stem;
  }
  function all(){
    return [].slice.call(document.querySelectorAll('.response[data-resp]'));
  }
  // A box counts at all only if it is a real question box, not a row-note.
  function countable(box){ return !box.classList.contains('mini'); }
  function filled(box){
    var t=box.querySelector('textarea');
    return !!(t && t.value.trim());
  }
  // Answered later in the SAME chain, anywhere in the doc, in document order.
  function supersededMap(){
    var boxes=all(), seen={}, out={};
    for(var i=boxes.length-1;i>=0;i--){
      var key=boxes[i].getAttribute('data-resp'), ch=chainOf(key);
      out[key]=!!seen[ch];
      if(filled(boxes[i])) seen[ch]=true;
    }
    return out;
  }
  function pendingIn(page){
    var sup=supersededMap();
    return [].slice.call(page.querySelectorAll('.response[data-resp]'))
      .filter(function(b){
        return countable(b) && !filled(b) && !sup[b.getAttribute('data-resp')];
      });
  }
  function countsIn(page){
    var boxes=[].slice.call(page.querySelectorAll('.response[data-resp]')).filter(countable);
    return {total:boxes.length, filled:boxes.filter(filled).length,
            pending:pendingIn(page).length};
  }
  window.__janusBoxes={chainOf:chainOf, pendingIn:pendingIn, countsIn:countsIn};
})();
</script>
'''.strip()


NAVMARK = r'''
<style id="__navmark-css">
  nav a[data-page]{ overflow:hidden; }
  nav a .navmark{ float:right; font-size:var(--fs-sm,12px); font-weight:700; line-height:1.5; margin-left:.4rem; }
  nav a .navmark.done{ color:var(--good); }
  nav a .navmark.todo{ color:var(--warn-deep); background:#fdf6e3; padding:.02rem .34rem; border-radius:99px; }
  @media (prefers-color-scheme:dark){ nav a .navmark.todo{ background:#241d10; } }
  nav .navsummary{ font-size:var(--fs-sm,12px); font-weight:700; color:var(--muted); margin:.5rem .4rem .2rem; padding:.3rem .55rem; border-radius:6px; background:var(--code-bg); }
  nav .navsummary .all-done{ color:var(--good); }
</style>
<script id="__navmark-patch" data-nm="__RV__">
// Live per-section review state in the sidebar. Independent of the main doc
// script — listens to input/save/clear.
//
// v2: counts come from __janusBoxes (see __boxstate-patch), so a row-note and
// a follow-up the conversation ran past no longer read as an unanswered
// question. v1 counted every empty textarea and told the owner a finished doc
// still needed him.
(function(){
  var links=[].slice.call(document.querySelectorAll('nav a[data-page]'));
  function ensure(link){ var m=link.querySelector('.navmark'); if(!m){ m=document.createElement('span'); m.className='navmark'; link.insertBefore(m, link.firstChild); } return m; }
  var summary=null;
  var foot=document.querySelector('nav .foot');
  if(foot){ summary=document.createElement('div'); summary.className='navsummary'; foot.parentNode.insertBefore(summary, foot); }
  function refresh(){
    var done=0, withBoxes=0;
    links.forEach(function(link){
      var page=document.getElementById(link.dataset.page);
      if(!page) return;
      var c=(window.__janusBoxes ? window.__janusBoxes.countsIn(page) : null);
      if(!c){ return; }  // helper not loaded yet — the deferred pass will run
      var m=link.querySelector('.navmark');
      if(c.total===0){ if(m) m.parentNode.removeChild(m); return; }
      withBoxes++;
      m=ensure(link);
      // A page with nothing PENDING is done even when a tail follow-up sits
      // empty — that box is answered-past, not owed.
      if(c.pending===0){ m.textContent='✓'; m.className='navmark done'; done++; }
      else { m.textContent=c.filled+'/'+c.total; m.className='navmark todo'; }
    });
    if(summary){
      if(!withBoxes){ summary.textContent=''; }
      else if(done===withBoxes){ summary.innerHTML='<span class="all-done">✓ all '+withBoxes+' sections answered</span>'; }
      else { summary.textContent='Answered '+done+'/'+withBoxes+' sections'; }
    }
  }
  document.querySelectorAll('.response[data-resp] textarea').forEach(function(t){ t.addEventListener('input', refresh); });
  document.addEventListener('click', function(e){ var id=e.target && e.target.id; if(id==='saveBtn'||id==='clearBtn'){ setTimeout(refresh,60); } });
  refresh();
  // An ALREADY-PATCHED doc gets __boxstate-patch appended after this block, so
  // the helper does not exist during the parse-time pass above. Both hooks are
  // cheap and idempotent.
  document.addEventListener('DOMContentLoaded', refresh);
  setTimeout(refresh, 0);
})();
</script>
'''.strip()



TODOBANNER = r'''
<style id="__todobanner-css">
  /* Palette-aware. The first version hardcoded #fdf6e3 and pill radii, which
     the 2026-08-07 doc standard forbids (rule 1: separate with BORDERS, never
     background tints; no filled badges). Vars fall back for docs still on the
     old sheet. */
  #__todobar{ position:sticky; top:0; z-index:40; margin:0 0 1.1rem;
    border:2px solid var(--caution,#a16207); background:var(--bg,#fff);
    color:var(--caution,#a16207); padding:.6rem .85rem; font-size:var(--fs-base,.9rem); }
  #__todobar[hidden]{ display:none; }
  #__todobar .hd{ font-weight:700; text-transform:uppercase; letter-spacing:.04em;
    font-size:var(--fs-sm,.72rem); display:block; margin-bottom:.35rem; }
  #__todobar a{ display:inline-block; font-weight:700; color:var(--caution,#a16207);
    background:none; border:1px solid currentColor; padding:.14rem .6rem;
    margin:.16rem .3rem .16rem 0; text-decoration:none; }
  #__todobar a:hover{ outline:2px solid var(--focus,#006BBD); outline-offset:1px; }
</style>
<script id="__todobanner-patch" data-tb="__RV__">
// An in-page "these need you" bar. Same source of truth as the nav marks —
// __janusBoxes.pendingIn (see __boxstate-patch). Clicking a chip switches to
// that page via the existing nav link, so it works with the doc's own router.
//
// v2: a row-note and a follow-up the conversation ran past are no longer
// "answers needed". v1 counted every empty textarea, so a doc with per-row
// note slots showed a permanent demand the owner could never clear.
(function(){
  var main=document.querySelector('main'); if(!main) return;
  var bar=document.createElement('div'); bar.id='__todobar'; bar.hidden=true;
  main.insertBefore(bar, main.firstChild);
  function label(link){
    // Clone and drop the navmark counter first — reading link.textContent raw
    // concatenates "0/1" onto the title and no amount of regex untangles
    // "0/10 · What is actually open" reliably.
    var c=link.cloneNode(true);
    var m=c.querySelector('.navmark'); if(m) m.remove();
    var t=(c.textContent||'').replace(/\s+/g,' ').trim();
    return t.replace(/^\d+\s*·\s*/,'').replace(/\s*⚑\s*$/,'').trim() || link.dataset.page;
  }
  function refresh(){
    var pending=[];
    [].slice.call(document.querySelectorAll('nav a[data-page]')).forEach(function(link){
      var page=document.getElementById(link.dataset.page); if(!page) return;
      if(!window.__janusBoxes) return;  // helper not loaded yet — deferred pass runs
      var n=window.__janusBoxes.pendingIn(page).length;
      if(n) pending.push({id:link.dataset.page, n:n, text:label(link)});
    });
    if(!pending.length){ bar.hidden=true; bar.innerHTML=''; return; }
    var total=pending.reduce(function(a,p){ return a+p.n; },0);
    bar.hidden=false;
    bar.innerHTML='<span class="hd">'+total+(total===1?' answer needed':' answers needed')+'</span>'+
      pending.map(function(p){
        return '<a href="#'+p.id+'" data-goto="'+p.id+'">'+p.text+(p.n>1?' ('+p.n+')':'')+'</a>';
      }).join('');
  }
  bar.addEventListener('click', function(e){
    var a=e.target.closest('a[data-goto]'); if(!a) return;
    e.preventDefault();
    var nav=document.querySelector('nav a[data-page="'+a.dataset.goto+'"]');
    if(nav) nav.click();
    // Focus the first box that actually WANTS an answer — not merely the first
    // empty one, which on a doc with row-notes is a note slot nobody owes.
    var page=document.getElementById(a.dataset.goto);
    var want=(page && window.__janusBoxes) ? window.__janusBoxes.pendingIn(page) : [];
    var target=(want[0] && want[0].querySelector('textarea')) ||
      document.querySelector('#'+a.dataset.goto+' .response[data-resp] textarea');
    if(target){ target.scrollIntoView({block:'center'}); target.focus(); }
  });
  document.querySelectorAll('.response[data-resp] textarea').forEach(function(t){
    t.addEventListener('input', refresh);
  });
  document.addEventListener('click', function(e){
    var id=e.target && e.target.id;
    if(id==='saveBtn'||id==='clearBtn') setTimeout(refresh,60);
  });
  refresh();
  // See the same two hooks in __navmark-patch: on an already-patched doc the
  // boxstate helper is appended AFTER this block, so the parse-time pass above
  // finds nothing and the deferred passes do the work.
  document.addEventListener('DOMContentLoaded', refresh);
  setTimeout(refresh, 0);
})();
</script>
'''.strip()




LIVERELOAD = r'''
<style id="__livereload-css">
  /* Borders, never tints (2026-08-07 doc standard). */
  #__replybar{ position:fixed; left:50%; transform:translateX(-50%); bottom:14px; z-index:60;
    display:flex; align-items:center; gap:.7rem; background:var(--bg,#fff);
    border:2px solid var(--positive,#0A5C21); color:var(--positive,#0A5C21);
    padding:.5rem .8rem; font-size:var(--fs-base,.95rem); font-weight:700; }
  #__replybar[hidden]{ display:none; }
  #__replybar button{ font: inherit; font-weight:700; cursor:pointer; color:inherit;
    background:none; border:1px solid currentColor; padding:.2rem .7rem; }
  #__replybar button:hover{ outline:2px solid var(--focus,#006BBD); outline-offset:1px; }
  #__replybar .dismiss{ border:none; font-weight:400; }
</style>
<script id="__livereload-patch" data-lr="__RV__">
// "I replied" signal. Without it the reader has no way to learn that a fold
// landed except being told in chat — which was the last manual link in the
// loop (owner, 2026-08-09: "otherwise I won't know that you've responded").
//
// Polls /__docversion for THIS file and watches the REVIEW SIGNATURE — a hash
// of the folded <aside class="review"> blocks — not the version.
//
// v3: scroll-to-update — after a live-reload, scroll to the first NEW reply
// block so the owner lands on the content that changed, not at the top.
// Pre-reload snapshot of review ids is stored in sessionStorage.
(function(){
  // --- v3: scroll-to-update after live-reload ---
  try{
    var pre=JSON.parse(sessionStorage.getItem('__lr-pre')||'null');
    if(pre){
      sessionStorage.removeItem('__lr-pre');
      var first=null;
      document.querySelectorAll('aside.review[data-review]').forEach(function(el){
        if(!first && pre.indexOf(el.getAttribute('data-review'))<0) first=el;
      });
      if(first) setTimeout(function(){
        first.scrollIntoView({behavior:'smooth',block:'start'});
      },200);
    }
  }catch(e){}

  var file=(location.pathname.split('/').pop()||'').split('?')[0];
  if(!file) return;
  var seen=null, stopped=false;
  var bar=document.createElement('div');
  bar.id='__replybar'; bar.hidden=true;
  bar.innerHTML='<span id="__replytext">New reply — reload to read it</span>'+
    '<button id="__replygo">Reload</button>'+
    '<button class="dismiss" id="__replyx" title="Dismiss">✕</button>';
  document.body.appendChild(bar);

  // Snapshot current review ids into sessionStorage before any reload so
  // the post-reload pass (above) can diff and scroll to the new one.
  function snapshot(){
    var ids=[];
    document.querySelectorAll('aside.review[data-review]').forEach(function(el){
      ids.push(el.getAttribute('data-review'));
    });
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
        seen=d.reviews;   // announce a given reply once, not every 5s
        if(!dirty()){ snapshot(); location.reload(); return; }
        document.getElementById('__replytext').textContent=
          'New reply on disk — you have unsaved edits. 💾 first, then reload.';
        bar.hidden=false;
      })
      .catch(function(){ /* server gone: stay quiet, the doc still works */ });
  }
  setInterval(tick, 5000); tick();
})();
</script>
'''.strip()


TRACKERNAV = r'''
<style id="__trackernav-css">
  nav .tracknav{ display:flex; flex-wrap:wrap; gap:.35rem; margin:.45rem .4rem .6rem; }
  nav .tracknav a{ font-size:var(--fs-sm,12px); font-weight:700; text-decoration:none;
    color:var(--muted,#71717a); border:1px solid var(--border,#ddd6fe);
    padding:.1rem .5rem; }
  nav .tracknav a:hover{ color:var(--accent,#7c3aed); border-color:currentColor; }
</style>
<script id="__trackernav-patch" data-tn="__RV__">
/* Replaced by __docnav-patch category links. No-op — kept for the gate mark. */
</script>
'''.strip()


DOCNAV = r'''
<style id="__docnav-css">
  nav .__docnav{border-top:1px solid var(--border,#ccc);margin-top:.6rem;padding-top:.3rem;}
  nav .__dn-cats{display:flex;flex-wrap:wrap;gap:.3rem;margin:.3rem .4rem .5rem;}
  nav .__dn-cats a{font-size:var(--fs-sm,12px);font-weight:700;text-decoration:none;
    color:var(--muted,#71717a);border:1px solid var(--border,#ddd6fe);padding:.1rem .5rem;}
  nav .__dn-cats a:hover{color:var(--accent,#7c3aed);border-color:currentColor;}
</style>
<script id="__docnav-patch" data-dn="__RV__">
// Cross-doc navigation: 4 category links, each to its own landing page.
// No manifest.json fetch needed — the landing pages handle browsing.
(function(){
  var nav=document.querySelector('nav');
  if(!nav) return;
  var el=document.createElement('div');
  el.className='__docnav';
  el.innerHTML='<div class="__dn-cats">'
    +'<a href="TRACKER.html">issues</a>'
    +'<a href="PRDS.html">PRDs</a>'
    +'<a href="REPORTS.html">reports</a>'
    +'<a href="DOCS.html">docs</a>'
    +'</div>';
  var foot=nav.querySelector('.foot');
  if(foot) nav.insertBefore(el, foot);
  else nav.appendChild(el);
})();
</script>
'''.strip()


REPORTNAV = r"""<style id="__reportnav-css">
  /* Sticky so the section list is reachable from anywhere in a long report;
     borders only, per the 2026-08-07 doc standard. */
  main nav{ position:sticky; top:0; z-index:45; background:var(--bg,#fff); }
  main nav .seclinks{ display:flex; flex-wrap:wrap; gap:.3rem;
    margin:.35rem 0 0; flex-basis:100%; }
  main nav .seclinks a{ font-size:var(--fs-sm,12px); font-weight:700;
    text-decoration:none; color:var(--dim,#666);
    border:1px solid var(--border,#ccc); padding:2px 8px; }
  main nav .seclinks a:hover{ color:var(--accent,#0F4A85); border-color:currentColor; }
  main nav .seclinks a:target,
  main nav .seclinks a.here{ color:var(--focus,#F38518); border-color:currentColor; }
  main section{ scroll-margin-top:4.5rem; }
  /* Both this nav and __todobar are sticky at top:0 and __todobar is inserted
     ABOVE the nav, so they would overlap. The nav carries the same per-section
     counts (navmark), so the banner gives up stickiness here. */
  #__todobar{ position:static; }
</style>
<script id="__reportnav-patch">
// Section nav for a sprint report, derived from the <h2>s at view time.
//
// WHY DERIVED, NOT AUTHORED: the one thing this has to survive is a report
// written in a hurry. SPRINT-REPORT-2026-08-17-trace-record.html dropped the
// <nav> element out of the template body while keeping its CSS and the comment
// telling you not to — which cost the owner BOTH the section nav and the
// sprint-close checkbox (__prdready-patch bails at `if(!file||!nav) return`).
// Nothing warned either of us. Deriving the bar means the author cannot
// forget it, and an already-served report picks it up on its next GET.
//
// Runs before </main>, i.e. before every end-of-body patch, because navmark,
// todobanner and prdready all read `nav a[data-page]` / `nav .brand` once at
// load and never look again.
(function(){
  var main=document.querySelector('main'); if(!main) return;
  var nav=main.querySelector('nav');
  if(!nav){
    nav=document.createElement('nav');
    nav.setAttribute('aria-label','document');
    main.insertBefore(nav, main.firstChild);
  }
  if(!nav.querySelector('.brand')){
    var h1=main.querySelector('h1');
    var b=document.createElement('div'); b.className='brand';
    b.textContent=((h1&&h1.textContent)||document.title||'Report').trim();
    nav.insertBefore(b, nav.firstChild);
  }
  if(nav.querySelector('a[data-page]')) return;   // author supplied one
  function slug(t){
    return (t||'').toLowerCase().replace(/[^a-z0-9]+/g,'-')
      .replace(/^-+|-+$/g,'').slice(0,32) || 'section';
  }
  var heads=[].slice.call(main.querySelectorAll('h2'));
  if(!heads.length) return;
  var links=document.createElement('div'); links.className='seclinks';
  heads.forEach(function(h, i){
    var sec=h.parentNode;
    if(sec.tagName!=='SECTION' || sec.firstElementChild!==h){
      // Adopt this heading and everything after it up to the next <h2>.
      sec=document.createElement('section');
      h.parentNode.insertBefore(sec, h);
      var node=h;
      while(node){
        var next=node.nextSibling;
        sec.appendChild(node);
        if(next && next.nodeType===1 && next.tagName==='H2') break;
        node=next;
      }
    }
    if(!sec.id) sec.id='s-'+(i+1)+'-'+slug(h.textContent);
    var a=document.createElement('a');
    a.href='#'+sec.id;
    a.setAttribute('data-page', sec.id);
    a.textContent=(i+1)+' · '+(h.textContent||'').replace(/\s+/g,' ').trim();
    links.appendChild(a);
  });
  nav.appendChild(links);
  // Mark the section you are in. Cheap, and the alternative is a reader who
  // cannot tell a 9-chip bar from a decoration.
  var obs=window.IntersectionObserver && new IntersectionObserver(function(entries){
    entries.forEach(function(e){
      if(!e.isIntersecting) return;
      links.querySelectorAll('a').forEach(function(a){
        a.classList.toggle('here', a.getAttribute('data-page')===e.target.id);
      });
    });
  }, {rootMargin:'-20% 0px -70% 0px'});
  if(obs) main.querySelectorAll('section[id]').forEach(function(s){ obs.observe(s); });
})();
</script>"""


AUTOSAVE = r"""<script id="__autosave-patch">
// Typing survives a closed tab. It did not.
//
// The dialogue template autosaves to localStorage as you type;
// REPORT-TEMPLATE.html never did, so a report collected answers only between
// the moment you typed them and the moment you pressed 💾 — close the tab
// first and they were gone with no trace anywhere. Injected rather than
// templated so every doc already written gets it too.
//
// It only ever FILLS AN EMPTY BOX. Disk is the truth for anything saved
// (__disk-wins-patch), and a stale browser copy overwriting a saved answer is
// a failure this folder has already had once — four answers on 2026-08-05 came
// back holding the text of four other boxes.
(function(){
  var boxes=[].slice.call(document.querySelectorAll('.response[data-resp] textarea'));
  if(!boxes.length) return;
  var file=(location.pathname.split('/').pop()||'doc').split('?')[0];
  // "janus-" prefix is load-bearing: __disk-wins-patch heals the stored map by
  // looking up the first key with it.
  var KEY='janus-'+file;
  function keyOf(t){ return t.closest('.response').getAttribute('data-resp'); }
  try{
    var saved=JSON.parse(localStorage.getItem(KEY)||'{}')||{};
    boxes.forEach(function(t){
      var v=saved[keyOf(t)];
      if(!t.value.trim() && typeof v==='string' && v.trim()){
        t.value=v;
        t.closest('.response').classList.add('filled');
        t.style.height='auto'; t.style.height=t.scrollHeight+'px';
      }
    });
  }catch(e){}
  function dump(){
    var o={}; boxes.forEach(function(t){ o[keyOf(t)]=t.value; });
    try{ localStorage.setItem(KEY, JSON.stringify(o)); }catch(e){}
  }
  boxes.forEach(function(t){ t.addEventListener('input', dump); });
  document.addEventListener('click', function(e){
    if(e.target && e.target.id==='clearBtn') setTimeout(dump, 60);
  });
})();
</script>"""


COLLAPSE = r'''
<style id="__collapse-css">
  .__chain-toggle{
    display:inline-block; font-family:var(--font); font-size:var(--fs-sm);
    font-weight:700; cursor:pointer; color:var(--dim); background:none;
    border:1px solid var(--border); padding:3px 10px; margin:8px 0;
  }
  .__chain-toggle:hover{ box-shadow:inset 0 0 0 2px var(--focus); }
  .__chain-summary{
    font-size:var(--fs-sm); color:var(--dim); white-space:nowrap;
    overflow:hidden; text-overflow:ellipsis; max-width:100%; padding:2px 0;
  }
  .response.__chain-collapsed{ padding:5px 13px; }
</style>
<script id="__collapse-patch" data-cl="__RV__">
(function(){
  var done=false;
  function init(){
    if(done) return;
    var jb=window.__janusBoxes;
    if(!jb||!jb.chainOf) return;
    done=true;

    document.querySelectorAll('.page').forEach(function(page){
      var all=[].slice.call(page.querySelectorAll(
        '.response[data-resp]:not(.mini), aside.review[data-review]'
      ));
      var stems={}, order=[];
      all.forEach(function(el){
        var key=el.getAttribute('data-resp')||el.getAttribute('data-review');
        if(!key) return;
        var stem=jb.chainOf(key);
        if(!stems[stem]){ stems[stem]=[]; order.push(stem); }
        stems[stem].push(el);
      });

      order.forEach(function(stem){
        var entries=stems[stem];
        if(entries.length<3) return;

        var cut=entries.length-2;
        var older=entries.slice(0,cut);

        function snippet(el){
          var t='';
          if(el.classList.contains('response')){
            var ta=el.querySelector('textarea');
            t=(ta&&ta.value.trim())||'';
            if(!t){ var d=el.querySelector('.discuss'); t=d?d.textContent.trim():''; }
          }else{
            for(var i=0;i<el.children.length;i++){
              var ch=el.children[i];
              if(ch.classList.contains('response')||ch.classList.contains('review')) continue;
              t+=(t?' ':'')+((ch.textContent||'').trim());
              if(t.length>=80) break;
            }
          }
          return t.length>80?t.substring(0,80)+'…':(t||'(empty)');
        }

        older.forEach(function(entry){
          var sum=document.createElement('div');
          sum.className='__chain-summary';
          sum.textContent=snippet(entry);

          if(entry.classList.contains('response')){
            var d=entry.querySelector('.discuss'); if(d) d.hidden=true;
            var ta=entry.querySelector('textarea'); if(ta) ta.hidden=true;
            entry.appendChild(sum);
          }else{
            for(var i=0;i<entry.children.length;i++){
              var ch=entry.children[i];
              if(ch.classList.contains('response')||ch.classList.contains('review')||
                 ch.classList.contains('__chain-summary')) continue;
              ch.hidden=true;
            }
            entry.insertBefore(sum,entry.firstChild);
          }
          entry.classList.add('__chain-collapsed');
        });

        var btn=document.createElement('button');
        btn.className='__chain-toggle';
        btn.textContent='Show '+cut+' earlier';
        btn.setAttribute('aria-expanded','false');
        older[0].parentNode.insertBefore(btn,older[0]);

        var open=false;
        btn.addEventListener('click',function(){
          open=!open;
          btn.setAttribute('aria-expanded',String(open));
          btn.textContent=open?'Collapse':'Show '+cut+' earlier';

          older.forEach(function(entry){
            entry.classList.toggle('__chain-collapsed',!open);
            if(entry.classList.contains('response')){
              var d=entry.querySelector('.discuss'); if(d) d.hidden=!open;
              var ta=entry.querySelector('textarea'); if(ta) ta.hidden=!open;
            }else{
              for(var i=0;i<entry.children.length;i++){
                var ch=entry.children[i];
                if(ch.classList.contains('response')||ch.classList.contains('review')||
                   ch.classList.contains('__chain-summary')) continue;
                ch.hidden=!open;
              }
            }
            for(var i=0;i<entry.children.length;i++){
              if(entry.children[i].classList.contains('__chain-summary')){
                entry.children[i].hidden=open; break;
              }
            }
          });
        });
      });
    });
  }
  init();
  document.addEventListener('DOMContentLoaded',init);
  setTimeout(init,0);
})();
</script>
'''.strip()


THEMEFLASH = r'''<script id="__theme-flash-patch" data-tf="__RV__">try{var t=localStorage.getItem('entropy-machines-theme');if(t)document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>'''

# ---- theme infrastructure ---------------------------------------------------
# A THEME FILE IS TOKENS ONLY — :root blocks with CSS custom properties.
# _theme_options() reads the .css files, extracts the bare :root tokens, and
# scopes each under :root[data-theme="<name>"] so that setting data-theme
# to the theme name activates those tokens.

_theme_cache = None


def _theme_options():
    """Read all theme CSS files, return (scoped_css, theme_list)."""
    global _theme_cache
    if _theme_cache is not None:
        return _theme_cache
    themes_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'themes')
    if not os.path.isdir(themes_dir):
        _theme_cache = ('', [])
        return _theme_cache
    blocks = []
    themes = []
    for fname in sorted(os.listdir(themes_dir)):
        if not fname.endswith('.css'):
            continue
        name = fname[:-4]
        path = os.path.join(themes_dir, fname)
        try:
            css = open(path, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError):
            continue
        m = re.search(r':root\s*\{([^}]+)\}', css)
        if not m:
            continue
        tokens = m.group(1)
        blocks.append(':root[data-theme="%s"]{%s}' % (name, tokens))
        label = name.replace('-', ' ').title()
        themes.append({'name': name, 'label': label})
    _theme_cache = ('\n'.join(blocks), themes)
    return _theme_cache


def _themetoggle_body():
    """Build the theme-selector patch body with embedded theme names."""
    _, themes = _theme_options()
    themes_json = json.dumps(themes)
    return _THEMETOGGLE_TEMPLATE.replace('__THEMES_JSON__', themes_json)


_THEMETOGGLE_TEMPLATE = r'''
<style id="__theme-toggle-css">
  .savebar select#themeBtn{
    font:inherit; font-size:var(--fs-sm,12px);
    background:var(--bg,#000); border:1px solid var(--border,#ddd);
    color:inherit; padding:2px 6px; cursor:pointer;
  }
  .savebar select#themeBtn:hover{box-shadow:inset 0 0 0 2px var(--focus);}
</style>
<script id="__theme-toggle-patch" data-tt="__RV__">
(function(){
  var KEY='entropy-machines-theme';
  var THEMES=__THEMES_JSON__;
  var el=document.getElementById('themeBtn');
  var sel;
  if(el && el.tagName==='SELECT'){
    sel=el;
  }else{
    var bar=document.querySelector('.savebar');
    if(!bar) return;
    sel=document.createElement('select');
    sel.id='themeBtn'; sel.title='Theme';
    if(el) el.parentNode.removeChild(el);
    var save=document.getElementById('saveBtn');
    if(save) bar.insertBefore(sel, save);
    else bar.appendChild(sel);
  }
  if(!sel.options.length){
    var d=document.createElement('option');
    d.value=''; d.textContent='Default theme';
    sel.appendChild(d);
    THEMES.forEach(function(t){
      var o=document.createElement('option');
      o.value=t.name; o.textContent=t.label;
      sel.appendChild(o);
    });
  }
  var stored='';
  try{ stored=localStorage.getItem(KEY)||''; }catch(e){}
  sel.value=stored;
  sel.addEventListener('change', function(){
    var v=sel.value;
    if(v){
      document.documentElement.setAttribute('data-theme', v);
      try{ localStorage.setItem(KEY, v); }catch(e){}
    }else{
      document.documentElement.removeAttribute('data-theme');
      try{ localStorage.removeItem(KEY); }catch(e){}
    }
  });
})();
</script>
'''.strip()

THEMETOGGLE = _THEMETOGGLE_TEMPLATE


LOCKBOX = r'''
<style id="__lockbox-css">
  .response.locked textarea{background:var(--bg); color:var(--fg);
    border:1px solid var(--border); cursor:default;}
  .response.locked label{color:var(--positive);}
</style>
<script id="__lockbox-patch" data-lb="__RV__">
(function(){
  function lock(){
    document.querySelectorAll('.response[data-resp]').forEach(function(el){
      if(el.classList.contains('mini')) return;
      var t=el.querySelector('textarea'); if(!t) return;
      var key=el.getAttribute('data-resp');
      if(!t.value.trim()) return;
      var hasReply=!!document.querySelector('aside.review[data-review="'+key+'"]');
      if(!hasReply) return;
      t.readOnly=true;
      el.classList.add('locked');
      var lbl=el.querySelector('label');
      if(lbl && lbl.textContent.indexOf('USER RESPONSE')===-1) lbl.textContent='USER RESPONSE';
    });
  }
  lock();
  document.addEventListener('DOMContentLoaded', lock);
  setTimeout(lock, 0);
})();
</script>
'''.strip()


READMARK = r'''
<style id="__readmark-css">
  .__readmark{ font-size:var(--fs-sm,12px); color:var(--dim,#666);
    font-weight:400; margin-left:.5rem; letter-spacing:.02em; }
</style>
<script id="__readmark-patch" data-rm="__RV__">
// Mark review blocks as read once the owner has scrolled past them.
// Uses IntersectionObserver: after 2 seconds in view, a small checkmark
// appears and the data-review key is stored in localStorage per doc.
// On reload, previously seen reviews are pre-marked.
(function(){
  var file=(location.pathname.split('/').pop()||'doc').split('?')[0];
  var KEY='__readmarks-'+file;
  var seen={};
  try{ seen=JSON.parse(localStorage.getItem(KEY)||'{}')||{}; }catch(e){}

  function mark(el){
    if(el.querySelector('.__readmark')) return;
    var m=document.createElement('span');
    m.className='__readmark';
    m.textContent='✓ read';
    var who=el.querySelector('.who');
    if(who) who.parentNode.insertBefore(m, who.nextSibling);
    else el.insertBefore(m, el.firstChild);
  }

  var reviews=[].slice.call(document.querySelectorAll('aside.review[data-review]'));
  if(!reviews.length) return;
  var timers={};

  // Pre-mark previously seen reviews.
  reviews.forEach(function(el){
    var key=el.getAttribute('data-review');
    if(seen[key]) mark(el);
  });

  if(!window.IntersectionObserver) return;
  var obs=new IntersectionObserver(function(entries){
    entries.forEach(function(e){
      var key=e.target.getAttribute('data-review');
      if(e.isIntersecting){
        if(!seen[key] && !timers[key]){
          timers[key]=setTimeout(function(){
            seen[key]=1;
            mark(e.target);
            try{ localStorage.setItem(KEY, JSON.stringify(seen)); }catch(ex){}
            obs.unobserve(e.target);
          }, 2000);
        }
      }else{
        if(timers[key]){ clearTimeout(timers[key]); delete timers[key]; }
      }
    });
  }, {threshold:0.3});

  reviews.forEach(function(el){
    var key=el.getAttribute('data-review');
    if(!seen[key]) obs.observe(el);
  });
})();
</script>
'''.strip()


DOCSTATUS = r'''
<style id="__docstatus-css">
  .__docstatus{ font-size:var(--fs-sm,12px); font-weight:700;
    text-transform:uppercase; letter-spacing:.04em;
    padding:2px 8px; margin-left:.5rem; border:1px solid currentColor;
    display:inline-block; vertical-align:middle; }
  .__docstatus.st-open{ color:var(--caution,#a16207); }
  .__docstatus.st-in-review{ color:var(--info,#006BBD); }
  .__docstatus.st-resolved{ color:var(--positive,#0A5C21); }
</style>
<script id="__docstatus-patch" data-dstatus="__RV__">
// Show the doc-level status in the sidebar brand area.
// Reads from data-doc-status on <html> if set; otherwise computes from page
// state: pending boxes -> open, all answered + some without reviews ->
// in-review, all answered + all with reviews -> resolved.
(function(){
  var done=false;
  function init(){
    if(done) return;
    var brand=document.querySelector('nav .brand');
    if(!brand) return;

    // Read explicit status from root attribute if present.
    var explicit=document.documentElement.dataset.docStatus;
    if(explicit){
      done=true;
      show(brand, explicit);
      return;
    }

    // Compute from page state — needs __janusBoxes.
    var jb=window.__janusBoxes;
    if(!jb||!jb.countsIn) return;
    done=true;

    var pages=[].slice.call(document.querySelectorAll('.page'));
    if(!pages.length) return;
    var totalBoxes=0, totalFilled=0, totalPending=0;
    pages.forEach(function(page){
      var c=jb.countsIn(page);
      totalBoxes+=c.total; totalFilled+=c.filled; totalPending+=c.pending;
    });
    if(!totalBoxes) return; // no response boxes — no status

    var status;
    if(totalPending>0) status='open';
    else {
      // All answered. Check if all have reviews.
      var unreplied=false;
      document.querySelectorAll('.response[data-resp]:not(.mini)').forEach(function(el){
        var t=el.querySelector('textarea');
        if(t && t.value.trim()){
          var key=el.getAttribute('data-resp');
          if(!document.querySelector('aside.review[data-review="'+key+'"]')) unreplied=true;
        }
      });
      status=unreplied?'in-review':'resolved';
    }
    show(brand, status);
  }

  function show(brand, status){
    var el=brand.querySelector('.__docstatus');
    if(!el){
      el=document.createElement('span');
      el.className='__docstatus';
      brand.appendChild(el);
    }
    var labels={'open':'open','in-review':'in review','resolved':'resolved'};
    el.textContent=labels[status]||status;
    el.className='__docstatus st-'+status;
  }

  init();
  document.addEventListener('DOMContentLoaded', init);
  setTimeout(init, 0);
})();
</script>
'''.strip()


ISSUE_AGREE = r'''
<style id="__issue-agree-css">
  /* Issue agreement checkboxes on the PRD output/issues page. */
  .issue-agree-th{ width:3.2rem; text-align:center; font-size:var(--fs-sm,12px);
    font-weight:700; text-transform:uppercase; letter-spacing:.03em;
    color:var(--dim,#666); }
  .issue-agree-td{ text-align:center; vertical-align:middle; }
  .issue-agree-td input[type="checkbox"]{ width:1.1rem; height:1.1rem;
    cursor:pointer; accent-color:var(--positive,#23D18B); }
</style>
<script id="__issue-agree-patch" data-ia="__RV__">
// Issue agreement checkboxes. On any page whose <h1> says "Issues this PRD
// creates", every <table> gets an "Accept" column of checkboxes. The owner
// checks the issues they agree to file, leaves the rest unchecked. State is
// stored per-file in localStorage so it survives reloads.
(function(){
  var KEY_PREFIX='janus-issue-agree-';
  var file=(location.pathname.split('/').pop()||'doc').split('?')[0];
  var KEY=KEY_PREFIX+file;
  function loadState(){
    try{ return JSON.parse(localStorage.getItem(KEY)||'{}')||{}; }catch(e){ return {}; }
  }
  function saveState(state){
    try{ localStorage.setItem(KEY, JSON.stringify(state)); }catch(e){}
  }
  function issueId(tr){
    // The first <td> holds the issue id in a <strong> tag.
    var td=tr.querySelector('td');
    if(!td) return null;
    var s=td.querySelector('strong');
    return s ? s.textContent.trim() : null;
  }
  function init(){
    // Find pages whose <h1> says "Issues this PRD creates".
    var pages=document.querySelectorAll('.page');
    var issueTables=[];
    pages.forEach(function(page){
      var h1=page.querySelector('h1');
      if(!h1 || h1.textContent.indexOf('Issues')===-1 ||
         h1.textContent.indexOf('PRD')===-1) return;
      var tables=page.querySelectorAll('table');
      tables.forEach(function(t){ issueTables.push(t); });
    });
    if(!issueTables.length) return;
    var state=loadState();
    issueTables.forEach(function(table){
      // Guard: do not add twice (idempotent).
      if(table.querySelector('.issue-agree-th')) return;
      // Add header.
      var thead=table.querySelector('thead');
      if(thead){
        var headerRow=thead.querySelector('tr');
        if(headerRow){
          var th=document.createElement('th');
          th.className='issue-agree-th';
          th.textContent='Accept';
          headerRow.insertBefore(th, headerRow.firstChild);
        }
      }
      // Add checkboxes to each body row.
      var tbody=table.querySelector('tbody');
      if(!tbody) return;
      var rows=tbody.querySelectorAll('tr');
      rows.forEach(function(tr){
        var id=issueId(tr);
        var td=document.createElement('td');
        td.className='issue-agree-td';
        var cb=document.createElement('input');
        cb.type='checkbox';
        cb.title=id ? 'Accept '+id : 'Accept this issue';
        if(id && state[id]) cb.checked=true;
        cb.addEventListener('change', function(){
          var st=loadState();
          var iid=issueId(tr);
          if(iid){ if(cb.checked) st[iid]=true; else delete st[iid]; }
          saveState(st);
        });
        td.appendChild(cb);
        tr.insertBefore(td, tr.firstChild);
      });
    });
  }
  init();
  document.addEventListener('DOMContentLoaded', init);
  setTimeout(init, 0);
})();
</script>
'''.strip()


def _has_issue_tables(src):
    """True when this doc has an issues-output page with tables."""
    return "Issues this PRD creates" in src and "<table" in src


UNSAVED_CUE = r'''
<script id="__unsaved-cue-patch" data-uc="__RV__">
// Visual cue on the savebar when edits are pending.
//
// The template's inline script already sets saveStat to "Unsaved changes…", but
// a text label is easy to miss in peripheral vision. This patch adds a
// caution-coloured border to the savebar while any textarea differs from the
// baked responses-data, so the reader has a persistent visual reminder that work
// will be lost if the tab closes without a save.
//
// Resets to the default border on save (listens for saveStat text changing to
// "Saved") and on clear. Runs after disk-save and disk-wins so responses-data
// reflects the true on-disk state.
(function(){
  var bar=document.querySelector('.savebar');
  if(!bar) return;
  var origBorder=bar.style.borderColor||'';
  var stat=document.getElementById('saveStat');
  function baked(){
    var el=document.getElementById('responses-data');
    try{ return JSON.parse((el&&el.textContent)||'{}')||{}; }catch(e){ return {}; }
  }
  function hasPendingEdits(){
    var disk=baked();
    var found=false;
    document.querySelectorAll('.response[data-resp]').forEach(function(el){
      var t=el.querySelector('textarea'); if(!t) return;
      var key=el.getAttribute('data-resp');
      if((t.value||'').trim()!==String(disk[key]||'').trim()) found=true;
    });
    return found;
  }
  function update(){
    if(hasPendingEdits()){
      bar.style.borderColor='var(--caution,#a16207)';
      bar.style.borderWidth='2px';
    }else{
      bar.style.borderColor=origBorder;
      bar.style.borderWidth='';
    }
  }
  document.querySelectorAll('.response[data-resp] textarea').forEach(function(t){
    t.addEventListener('input', update);
  });
  // Reset after save or clear.
  if(stat){
    new MutationObserver(function(){ update(); }).observe(stat,{childList:true,characterData:true,subtree:true});
  }
  document.addEventListener('click', function(e){
    var id=e.target&&e.target.id;
    if(id==='saveBtn'||id==='clearBtn') setTimeout(update, 100);
  });
  update();
})();
</script>
'''.strip()


def apply(src, name="doc.html"):
    """Pure transform: apply all patches to src, return (new_src, changed).

    Same logic as patch() but no file I/O — for serve-time injection."""
    if "</body>" not in src:
        return src, []
    changed = []
    if DISK_SAVE_MARK not in src:
        src = src.replace("</body>", versioned_block("__disk-save-patch") + "\n</body>", 1)
        changed.append("disk-save v" + DISK_SAVE_RV)
    else:
        upgraded = ensure_versioned(src, "__disk-save-patch")
        if upgraded != src:
            src = upgraded
            changed.append("disk-save v" + DISK_SAVE_RV)
    if DISK_WINS_MARK not in src:
        src = src.replace("</body>", DISK_WINS + "\n</body>", 1)
        changed.append("disk-wins")
    if BOXSTATE_MARK not in src:
        src = src.replace("</body>", versioned_block("__boxstate-patch") + "\n</body>", 1)
        changed.append("box-state v" + BOXSTATE_RV)
    if NAVMARK_MARK not in src:
        src = src.replace("</body>", NAVMARK.replace("__RV__", NAVMARK_RV) + "\n</body>", 1)
        changed.append("nav-marks v" + NAVMARK_RV)
    if TODOBANNER_MARK not in src:
        src = src.replace("</body>", TODOBANNER.replace("__RV__", TODOBANNER_RV) + "\n</body>", 1)
        changed.append("todo-banner v" + TODOBANNER_RV)
    for pid, tag in (("__boxstate-patch", "box-state"),
                     ("__navmark-patch", "nav-marks"),
                     ("__todobanner-patch", "todo-banner")):
        up = ensure_versioned(src, pid)
        if up != src:
            src = up
            changed.append(tag + " upgraded")
    if needs_reportnav(name, src) and REPORTNAV_MARK not in src:
        src = src.replace("</main>", REPORTNAV + "\n</main>", 1)
        changed.append("report-nav")
    if TRACKERNAV_MARK not in src:
        src = src.replace("</body>", TRACKERNAV.replace("__RV__", TRACKERNAV_RV) + "\n</body>", 1)
        changed.append("tracker-nav v" + TRACKERNAV_RV)
    else:
        upgraded = ensure_versioned(src, "__trackernav-patch")
        if upgraded != src:
            src = upgraded
            changed.append("tracker-nav v" + TRACKERNAV_RV)
    if DOCNAV_MARK not in src:
        src = src.replace("</body>", DOCNAV.replace("__RV__", DOCNAV_RV) + "\n</body>", 1)
        changed.append("doc-nav v" + DOCNAV_RV)
    else:
        upgraded = ensure_versioned(src, "__docnav-patch")
        if upgraded != src:
            src = upgraded
            changed.append("doc-nav v" + DOCNAV_RV)
    if AUTOSAVE_MARK not in src:
        src = src.replace("</body>", AUTOSAVE + "\n</body>", 1)
        changed.append("autosave")
    if COLLAPSE_MARK not in src:
        src = src.replace("</body>", COLLAPSE.replace("__RV__", COLLAPSE_RV) + "\n</body>", 1)
        changed.append("collapse v" + COLLAPSE_RV)
    else:
        upgraded = ensure_versioned(src, "__collapse-patch")
        if upgraded != src:
            src = upgraded
            changed.append("collapse v" + COLLAPSE_RV)
    # Theme options CSS — scoped :root[data-theme="<name>"] blocks for every
    # theme in lib/themes/. Injected before </head> so the tokens are available
    # when __theme-flash-patch sets data-theme right after <body>.
    if THEME_OPTIONS_MARK not in src:
        options_css, _ = _theme_options()
        if options_css:
            block = '<style id="__theme-options-patch">\n' + options_css + '\n</style>'
            src = src.replace("</head>", block + "\n</head>", 1)
            changed.append("theme-options")
    # Theme flash prevention — right after <body> so it runs before paint.
    if THEMEFLASH_MARK not in src:
        src = src.replace("</head><body>", "</head><body>\n" + versioned_block("__theme-flash-patch"), 1)
        changed.append("theme-flash v" + THEMEFLASH_RV)
    else:
        upgraded = ensure_versioned(src, "__theme-flash-patch")
        if upgraded != src:
            src = upgraded
            changed.append("theme-flash v" + THEMEFLASH_RV)
    if THEMETOGGLE_MARK not in src:
        src = src.replace("</body>", versioned_block("__theme-toggle-patch") + "\n</body>", 1)
        changed.append("theme-selector v" + THEMETOGGLE_RV)
    else:
        upgraded = ensure_versioned(src, "__theme-toggle-patch")
        if upgraded != src:
            src = upgraded
            changed.append("theme-selector v" + THEMETOGGLE_RV)
    if LOCKBOX_MARK not in src:
        src = src.replace("</body>", versioned_block("__lockbox-patch") + "\n</body>", 1)
        changed.append("lockbox v" + LOCKBOX_RV)
    else:
        upgraded = ensure_versioned(src, "__lockbox-patch")
        if upgraded != src:
            src = upgraded
            changed.append("lockbox v" + LOCKBOX_RV)
    if READMARK_MARK not in src:
        src = src.replace("</body>", READMARK.replace("__RV__", READMARK_RV) + "\n</body>", 1)
        changed.append("readmark v" + READMARK_RV)
    else:
        upgraded = ensure_versioned(src, "__readmark-patch")
        if upgraded != src:
            src = upgraded
            changed.append("readmark v" + READMARK_RV)
    if DOCSTATUS_MARK not in src:
        src = src.replace("</body>", DOCSTATUS.replace("__RV__", DOCSTATUS_RV) + "\n</body>", 1)
        changed.append("docstatus v" + DOCSTATUS_RV)
    else:
        upgraded = ensure_versioned(src, "__docstatus-patch")
        if upgraded != src:
            src = upgraded
            changed.append("docstatus v" + DOCSTATUS_RV)
    # Issue agreement checkboxes — only on PRDs that have an issues-output page
    # with tables. Like PRDSTATUS_MARK, not in GATE_MARKS because requiring it
    # of all docs would make every non-PRD read stale.
    if _has_issue_tables(src):
        if ISSUE_AGREE_MARK not in src:
            src = src.replace("</body>", ISSUE_AGREE.replace("__RV__", ISSUE_AGREE_RV) + "\n</body>", 1)
            changed.append("issue-agree v" + ISSUE_AGREE_RV)
        else:
            upgraded = ensure_versioned(src, "__issue-agree-patch")
            if upgraded != src:
                src = upgraded
                changed.append("issue-agree v" + ISSUE_AGREE_RV)
    # Unsaved-cue — savebar border turns caution when edits are pending.
    # Applied to every doc that has a savebar.
    if UNSAVED_CUE_MARK not in src:
        src = src.replace("</body>", versioned_block("__unsaved-cue-patch") + "\n</body>", 1)
        changed.append("unsaved-cue v" + UNSAVED_CUE_RV)
    else:
        upgraded = ensure_versioned(src, "__unsaved-cue-patch")
        if upgraded != src:
            src = upgraded
            changed.append("unsaved-cue v" + UNSAVED_CUE_RV)
    if LIVERELOAD_MARK not in src:
        src = src.replace("</body>", livereload_block() + "\n</body>", 1)
        changed.append("live-reload v" + LIVERELOAD_RV)
    else:
        upgraded = ensure_livereload(src)
        if upgraded != src:
            src = upgraded
            changed.append("live-reload v" + LIVERELOAD_RV)
    if '<style id="__review-css"' in src:
        import reply
        upgraded = reply.ensure_css(src)
        if upgraded != src:
            src = upgraded
            changed.append("review-css v" + reply.RV)
    return src, changed


def patch(path):
    """Read a doc from disk, apply all patches, write back if anything changed."""
    src = open(path, encoding="utf-8").read()
    name = os.path.basename(path)
    src, changed = apply(src, name)
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
    return changed


def init(docs_dir=None):
    global DIR
    if docs_dir:
        DIR = os.path.abspath(docs_dir)
    elif DIR is None:
        import docstate
        if docstate.DIR is None:
            docstate.init()
        DIR = docstate.DIR


if __name__ == "__main__":
    init()
    targets = (
        [os.path.join(DIR, sys.argv[1])] if len(sys.argv) > 1
        else sorted(p for p in glob.glob(os.path.join(DIR, "*.html"))
                    if os.path.basename(p) not in GENERATED)
    )
    for p in targets:
        c = patch(p)
        print(f"  {os.path.basename(p):40} {'+ ' + ', '.join(c) if c else '(up to date)'}")
