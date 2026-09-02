#!/usr/bin/env python3
"""Fold my review INTO a dialogue-doc, next to the user's answers.

The docs are the alignment surface — my read belongs in them, not the terminal.
This inserts an idempotent `.review` block (an <aside data-review="KEY">) right
after the matching `.response` box for each key I'm answering. Re-running
replaces the prior review for that key (so I can revise), never touches the
user's <textarea> or responses-data.

Usage:
  python3 reply.py <handle> replies.json     # replies.json = { "key": "html", ... }
  python3 reply.py <handle> -                 # read the JSON map from stdin
It resolves the handle via manifest.json, patches the file, snapshots a version,
and flips the doc to 'responded' (ball → user). Then just open the doc.
"""
import json
import os
import re
import sys

import docstate

DIR = None  # set by docstate.init()

REVIEW_CSS = """
<style id="__review-css" data-rv="6">
  /* Flat dialogue: agent and user blocks alternate at the same visual level.
     The follow-up .response stays inside <aside> for the re-fold regex, but
     CSS breaks it out of the aside's tint so it reads as a peer block. */
  aside.review{
    border:1px solid var(--border,#6FC3DF); border-left:3px solid var(--border,#6FC3DF);
    padding:.7rem .9rem; margin:.6rem 0 .3rem; font-size:var(--fs-base,14px);
    color:inherit; background:var(--bg,#000); }
  aside.review .who{ font-weight:700; color:var(--border,#6FC3DF); font-size:var(--fs-sm,12px);
    letter-spacing:.04em; text-transform:uppercase; display:block; margin-bottom:.35rem; }
  aside.review p{ margin:.4rem 0; } aside.review ul{ margin:.4rem 0 .4rem 1.1rem; }
  aside.review li{ margin:.2rem 0; }
  aside.review code{ background:transparent; color:inherit; padding:.02rem .3rem;
    border:1px solid color-mix(in srgb, currentColor 35%, transparent); }
  aside.review strong{ color:inherit; }
  /* Follow-up box — visually a PEER of the aside, not a child. Pulls out of
     the aside's padding with negative margin so it reads as a separate block. */
  aside.review .response{ margin:.7rem -.9rem -.7rem; padding:.7rem .9rem;
    background:var(--bg,#000); border:none; border-top:1px solid var(--border,#6FC3DF); }
  aside.review .response label{ font-weight:700; font-size:var(--fs-sm,12px);
    letter-spacing:.04em; text-transform:uppercase; color:var(--focus,#F38518);
    display:block; margin-bottom:.35rem; }
  aside.review .response .discuss{ display:none; }
  aside.review .response textarea{ background:var(--bg,#000); color:inherit;
    border:1px solid var(--border,#6FC3DF); }
</style>
""".strip()

def who():
    return "Agent response"


RV = re.search(r'data-rv="(\d+)"', REVIEW_CSS).group(1)


def ensure_css(src):
    """Insert the review CSS, or upgrade a stale copy in place.

    v1 was inserted once and never revisited, so a styling bug shipped in it
    lived on in every doc already folded. Version the block and replace on
    mismatch.
    """
    m = re.search(r'<style id="__review-css"[^>]*>.*?</style>', src, re.S)
    if m:
        if f'data-rv="{RV}"' in m.group(0):
            return src
        return src[:m.start()] + REVIEW_CSS + src[m.end():]
    if "</head>" in src:
        return src.replace("</head>", REVIEW_CSS + "\n</head>", 1)
    return src.replace("<body>", "<body>\n" + REVIEW_CSS, 1) if "<body>" in src else REVIEW_CSS + src


def followup_key(key, answers):
    """The data-resp for THIS round's follow-up box.

    `<key>-followup` for the first question, then `-followup2`, `-followup3`…
    once the previous one holds an answer. Reusing one key across rounds means
    the new question renders into a box that re-fills with the OLD answer — so
    the box counts as answered, the nav shows the page done, and the question
    is invisible. That is what happened to c1-confidence on DESIGN-BACKLOG,
    which is the same complaint ("you keep not highlighting what I need to look
    at in the UI") arriving by a second route.
    """
    base = f"{key}-followup"
    if not str(answers.get(base, "")).strip():
        return base
    n = 2
    while str(answers.get(f"{base}{n}", "")).strip():
        n += 1
    return f"{base}{n}"


def block(key, value, answers=None, prior=None, fk=None):
    """value is either an HTML string, or {"html": ..., "ask": ..., "label": ...}.

    EVERY REPLY CARRIES A FOLLOW-UP BOX. When `ask` is present the box includes
    a .discuss block with the directed question and a labelled textarea. When
    `ask` is absent the box is a minimal generic textarea ("Your response") so
    the owner can always respond back -- a reply without a box is a reply the
    owner cannot talk back to.

    The data-resp is allocated by followup_key() against the answers already on
    disk, so a second question on the same key gets a fresh, empty box rather
    than inheriting the first one's answer. Replacing a review does NOT lose
    their text: values live in localStorage and responses-data keyed by
    data-resp, and load() re-fills.
    """
    answers = answers or {}
    ask = label = after = None
    if isinstance(value, dict):
        html, ask = value.get("html", ""), value.get("ask")
        label, after = value.get("label"), value.get("after")
    else:
        html = value
    tail = ""
    fk = fk or (value.get("followup_key") if isinstance(value, dict) else None) or followup_key(key, answers)
    if ask:
        tail = (f'<div class="response" data-resp="{fk}">'
                f'<label>{label or "User response"}</label>'
                f'<div class="discuss">{ask}</div>'
                f'<textarea placeholder="Type your answer…"></textarea></div>')
    else:
        tail = (f'<div class="response" data-resp="{fk}">'
                f'<label>Your response</label>'
                f'<textarea placeholder="Type your answer…"></textarea></div>')
    # `after` renders BELOW the follow-up box so a thread reads in order:
    # my reply -> their answer -> my response. Never nest a second <aside
    # class="review"> inside this one: the replace regex below is non-greedy on
    # </aside> and would truncate the block on the next re-fold.
    return (f'<aside class="review" data-review="{key}">'
            f'<span class="who">{who()}</span>{html}{prior or ""}{tail}{after or ""}</aside>')


def prior_boxes(aside_html, exclude=None):
    """Follow-up boxes from earlier rounds, lifted out of the aside being replaced.

    A re-fold rewrites the whole <aside>, so without this every previous round's
    box (and the answer in it) vanishes from the page. They render above the new
    question, so a thread reads oldest-first.
    """
    boxes = [b for b in re.findall(
        r'<div class="response" data-resp="[^"]*-followup\d*">.*?</textarea>\s*</div>',
        aside_html, re.S)
        # The key being re-asked is rebuilt by block(); carrying the old copy
        # across too emits the same data-resp twice, and the live one ends up
        # buried inside the collapsed <details>. Caught 2026-08-06.
        if f'data-resp="{exclude}"' not in b]
    if not boxes:
        return ""
    # Collapsed. Four rounds on one key turned the C1 page into a wall of green
    # the reader had to scroll past to reach the live question (2026-08-06).
    # <details> keeps every answer in the DOM — so it still saves, still counts
    # in navmark, still never orphans — while showing one thread by default.
    n = len(boxes)
    return ('<details class="build"><summary>Earlier rounds ('
            + str(n) + ')</summary>' + "".join(boxes) + '</details>')


def build(src, replies):
    """Pure: source in, (new source, missing keys) out. No file touched."""
    src = ensure_css(src)
    m_data = re.search(r'id="responses-data">(.*?)</script>', src, re.S)
    answers = json.loads(m_data.group(1)) if m_data else {}
    missing = []
    for key, html in replies.items():
        # replace an existing review for this key, if present
        rx_existing = re.compile(r'<aside class="review" data-review="%s">.*?</aside>' % re.escape(key), re.S)
        m_ex = rx_existing.search(src)
        if m_ex:
            fk = (html.get("followup_key") if isinstance(html, dict) else None) \
                 or followup_key(key, answers)
            new = block(key, html, answers,
                        prior=prior_boxes(m_ex.group(0), exclude=fk), fk=fk)
            src = rx_existing.sub(lambda _m: new, src, count=1)
            continue
        new = block(key, html, answers)
        # else insert right after the matching response box (ends at </textarea></div>)
        # The class is matched loosely because per-ROW boxes are
        # `class="response mini"`. An exact `class="response"` silently reported
        # every row-note key as missing, so a reply to a specific table row had
        # nowhere to land (hit on UNATTENDED-OPS 2026-08-09).
        rx_resp = re.compile(
            r'(<div class="response[^"]*" data-resp="%s">.*?</textarea>\s*</div>)' % re.escape(key), re.S)
        m = rx_resp.search(src)
        if not m:
            missing.append(key)
            continue
        src = src[:m.end()] + "\n  " + new + src[m.end():]
    return src, missing


def boxes_of(src):
    return set(re.findall(r'data-resp="([^"]+)"', src))


def patch(path, replies):
    """Build, verify nothing answered lost its box, THEN write."""
    before = open(path, encoding="utf-8").read()
    after, missing = build(before, replies)
    m = re.search(r'id="responses-data">(.*?)</script>', before, re.S)
    answers = json.loads(m.group(1)) if m else {}
    lost = sorted(k for k in boxes_of(before) - boxes_of(after)
                  if str(answers.get(k, "")).strip() or "-followup" in k)
    if lost:
        sys.exit(
            "reply.py: refusing — this fold would remove answer boxes. Either they\n"
            "  hold saved answers, or they are open questions whose answer may be\n"
            "  sitting unsaved in the reader's browser under that exact data-resp:\n"
            + "".join(f"    {k}\n" for k in lost)
            + "  Nothing was written. This is a bug in the fold, not in your input."
        )
    with open(path, "w", encoding="utf-8") as f:
        f.write(after)
    return missing


def strip_tags(s):
    return re.sub(r"<[^>]+>", " ", s or "")


def preflight(replies, informational):
    """Warn when replies ask questions without highlighting them.

    Every reply now carries a follow-up box (generic if no `ask`, directed if
    `ask` is present), so the owner can always respond. A question mark in prose
    that lacks an explicit `ask` is no longer fatal -- the generic box gives the
    owner a place to answer -- but directed questions deserve directed labels.
    This warns so the caller can upgrade to {"html":…, "ask":…} when the prose
    genuinely asks something.

    `--informational` silences the warning for folds that genuinely only report
    outcomes.
    """
    if informational:
        return
    asked = [k for k, v in replies.items() if isinstance(v, dict) and v.get("ask")]
    qs = [k for k, v in replies.items()
          if k not in asked and "?" in strip_tags(v if isinstance(v, str) else v.get("html", ""))]
    if qs:
        print(
            "  WARN: these replies contain a question but no explicit `ask`.\n"
            "  A generic follow-up box will be added, but directed questions\n"
            '  should use {"html": …, "ask": "…"} so the question appears in\n'
            "  the .discuss block with a specific label:\n"
            + "".join(f"    {k}\n" for k in qs),
            file=sys.stderr,
        )


if __name__ == "__main__":
    argv = [a for a in sys.argv[1:] if a != "--informational"]
    informational = "--informational" in sys.argv
    if len(argv) < 2:
        sys.exit("usage: reply.py [--informational] <handle> <replies.json|->")
    handle, jsrc = argv[0], argv[1]
    docstate.init()
    m = docstate.load()
    did = docstate.resolve(m, handle)
    if not did or did.startswith("AMBIGUOUS"):
        sys.exit(f"could not resolve handle {handle!r}: {did}")
    replies = json.load(sys.stdin if jsrc == "-" else open(jsrc, encoding="utf-8"))
    path = os.path.join(docstate.DIR, m["docs"][did]["file"])
    preflight(replies, informational)          # both before patching — never half-write
    missing = patch(path, replies)
    if missing:
        print("  WARN no response box for keys:", ", ".join(missing))
    docstate.set_status(m, did, "open", "review-folded")
    print(f"  {did}: folded {len(replies)-len(missing)} review(s) → open "
          f"(v{m['docs'][did].get('version',0)})")
