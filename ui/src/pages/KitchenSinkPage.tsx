import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { THEME_NAMES } from "../data/themes";
import { useTheme } from "../hooks/useTheme";

// ============================================================================
// Kitchen sink — every major UX component the doc-renderer will need, wired
// to mock/hardcoded state so the owner can QA the look and feel before any of
// it talks to a real API. No fetch() anywhere on this page, on purpose.
//
// Route: /kitchen-sink (see App.tsx). Wrapped in Layout like other pages.
// Page-level navigation uses inline tabs (same pattern as DocPage).
// ============================================================================

const SECTION_IDS = {
  theme: "ks-theme",
  responseBox: "ks-response-box",
  rowNotes: "ks-row-notes",
  replyThread: "ks-reply-thread",
  saveBar: "ks-save-bar",
} as const;

// ---- page tab types -------------------------------------------------------

interface PageTabItem {
  id: string;
  navTitle: string;
  answered?: number;
  total?: number;
}

// ---- navmark badge for inline tabs ----------------------------------------

function navMark(item: PageTabItem) {
  if (!item.total) return null;
  const done = item.answered === item.total;
  return (
    <span className={`navmark ${done ? "done" : "todo"}`}>{done ? "✓" : `${item.answered ?? 0}/${item.total}`}</span>
  );
}

// ---- response box: reusable across the plain examples, the row-notes
// table, and the reply thread below. --------------------------------------

interface ResponseBoxProps {
  id: string;
  label?: string;
  discuss?: ReactNode;
  value: string;
  onChange: (value: string) => void;
  mini?: boolean;
  locked?: boolean;
}

// Autogrow: the textarea's height tracks its content, same trick the old HTML
// templates used (reset height, then read scrollHeight). Skipped for .mini
// row-notes, which stay a fixed single line by CSS instead.
function useAutoGrow(value: string, skip: boolean) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    if (skip) return;
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }, [value, skip]);
  return ref;
}

function ResponseBox({ id, label, discuss, value, onChange, mini, locked }: ResponseBoxProps) {
  const ref = useAutoGrow(value, !!mini);
  const filled = value.trim().length > 0;
  const className = ["response", filled && "filled", mini && "mini"].filter(Boolean).join(" ");

  return (
    <div className={className} data-resp={id}>
      {label && <label>{label}</label>}
      {discuss && <div className="discuss">{discuss}</div>}
      <textarea
        ref={ref}
        value={value}
        readOnly={locked}
        placeholder={mini ? "Add a note…" : "Type your answer…"}
        onChange={(ev) => !locked && onChange(ev.target.value)}
      />
    </div>
  );
}

// ---- reply thread: agent/owner conversation with a collapse round --------

interface ThreadRound {
  id: string;
  label: string;
  discuss: string;
  /** Present once the agent has answered this round — locks the owner's box
   * read-only, same as a real doc where a replied-to answer is settled. */
  reply?: { author: string; date: string; body: string[] };
}

function Review({ id, reply }: { id: string; reply: NonNullable<ThreadRound["reply"]> }) {
  return (
    <aside className="review" data-review={id}>
      <span className="who">
        {reply.author} · <time>{reply.date}</time>
      </span>
      {reply.body.map((para, i) => (
        <p key={i}>{para}</p>
      ))}
    </aside>
  );
}

function snippetFor(round: ThreadRound, value: string) {
  const text = value.trim() || round.discuss;
  return text.length > 80 ? `${text.slice(0, 80)}…` : text || "(empty)";
}

function ReplyThread({
  rounds,
  responses,
  onChange,
}: {
  rounds: ThreadRound[];
  responses: Record<string, string>;
  onChange: (id: string, value: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  // Same rule as the old templates: a chain of 3+ rounds folds everything but
  // the newest 2 behind a toggle, so a long-settled conversation doesn't push
  // the live question off the screen.
  const cut = rounds.length >= 3 ? rounds.length - 2 : 0;
  const older = rounds.slice(0, cut);
  const recent = rounds.slice(cut);

  function renderRound(round: ThreadRound) {
    const value = responses[round.id] ?? "";
    return (
      <div key={round.id}>
        <ResponseBox
          id={round.id}
          label={round.label}
          discuss={round.discuss}
          value={value}
          onChange={(v) => onChange(round.id, v)}
          locked={!!round.reply}
        />
        {round.reply && <Review id={round.id} reply={round.reply} />}
      </div>
    );
  }

  return (
    <div className="thread">
      {older.length > 0 && (
        <>
          <button
            type="button"
            className="__chain-toggle"
            aria-expanded={expanded}
            onClick={() => setExpanded((v) => !v)}
          >
            {expanded ? "Collapse" : `Show ${older.length} earlier`}
          </button>
          {older.map((round) =>
            expanded ? (
              renderRound(round)
            ) : (
              <div key={round.id} className="response __chain-collapsed">
                <div className="__chain-summary">{snippetFor(round, responses[round.id] ?? "")}</div>
              </div>
            ),
          )}
        </>
      )}
      {recent.map(renderRound)}
    </div>
  );
}

// ---- mock data -------------------------------------------------------------

const INITIAL_RESPONSES: Record<string, string> = {
  "ks-basic-filled":
    "Ship the mock data inline in the component. It's a QA fixture, not the real doc renderer — a build-time fetch would just be one more thing to keep in sync with nothing.",
  "ks-basic-empty": "",
  "ks-row-sidebar": "",
  "ks-row-theme": "Looks right in all 5 — check hc-dark contrast once more before sign-off.",
  "ks-row-savebar": "",
  "ks-thread-q1": "Should the kitchen sink ship its own mock data, or read fixtures from a JSON file?",
  "ks-thread-q2": "Inline is fine for now — one file, easy to scan in review.",
  "ks-thread-q3": "Should locked (replied-to) boxes stay read-only on this page too?",
  "ks-thread-q4": "Yes — it's the real behavior the doc renderer will have, worth QAing here.",
  "ks-thread-q5": "",
};

const THREAD_ROUNDS: ThreadRound[] = [
  {
    id: "ks-thread-q1",
    label: "Question",
    discuss: "Should the kitchen sink page ship its own mock data, or read fixtures from a JSON file?",
    reply: {
      author: "Agent",
      date: "2026-09-05",
      body: ["Inline, hardcoded in the component. No fetch, no fixture file to keep in sync — the brief is explicit that this page never talks to an API."],
    },
  },
  {
    id: "ks-thread-q2",
    label: "Follow-up",
    discuss: "Inline is fine for now — one file, easy to scan in review.",
    reply: {
      author: "Agent",
      date: "2026-09-05",
      body: ["Agreed, keeping it to one page component plus the shared response-box CSS. Nothing exported for other pages to import yet."],
    },
  },
  {
    id: "ks-thread-q3",
    label: "Follow-up",
    discuss: "Should locked (replied-to) boxes stay read-only on this page too?",
    reply: {
      author: "Agent",
      date: "2026-09-06",
      body: ["Yes — it's real behavior the eventual doc renderer needs, so it's worth showing here rather than skipping it as \"just a demo\"."],
    },
  },
  {
    id: "ks-thread-q4",
    label: "Follow-up",
    discuss: "Yes — it's the real behavior the doc renderer will have, worth QAing here.",
    reply: {
      author: "Agent",
      date: "2026-09-06",
      body: ["Locked it. Once a round has a reply, its textarea goes read-only and the newest unanswered round below stays live so Save Bar has something to react to."],
    },
  },
  {
    id: "ks-thread-q5",
    label: "Follow-up",
    discuss:
      "One open thread left: does the kitchen sink need its own /kitchen-sink entry in the top nav, or is the route enough?",
  },
];

// resp keys that count toward a section's answered/total badge — mirrors the
// real doc convention: .mini row-notes are invitations, never counted.
const SECTION_RESP_KEYS: Record<string, string[]> = {
  [SECTION_IDS.responseBox]: ["ks-basic-filled", "ks-basic-empty"],
  [SECTION_IDS.replyThread]: THREAD_ROUNDS.map((r) => r.id),
};

export function KitchenSinkPage() {
  const { theme } = useTheme();
  const [responses, setResponses] = useState<Record<string, string>>(INITIAL_RESPONSES);
  const [dirty, setDirty] = useState(true);
  const [currentSectionId, setCurrentSectionId] = useState<string>(SECTION_IDS.theme);

  function updateResponse(id: string, value: string) {
    setResponses((prev) => ({ ...prev, [id]: value }));
    setDirty(true);
  }

  function handleSave() {
    setDirty(false);
  }

  function handleClear() {
    setResponses(INITIAL_RESPONSES);
    setDirty(true);
  }

  function selectSection(id: string) {
    setCurrentSectionId(id);
    document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  // Scrollspy: highlight whichever section is nearest the top of the viewport
  // as the reader scrolls, not just on click.
  useEffect(() => {
    const ids = Object.values(SECTION_IDS);
    const els = ids.map((id) => document.getElementById(id)).filter((el): el is HTMLElement => !!el);
    if (els.length === 0) return;
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((e) => e.isIntersecting);
        if (visible.length === 0) return;
        const top = visible.reduce((a, b) => (a.boundingClientRect.top < b.boundingClientRect.top ? a : b));
        setCurrentSectionId(top.target.id);
      },
      { rootMargin: "-10% 0px -70% 0px", threshold: 0 },
    );
    els.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, []);

  const tabItems = useMemo<PageTabItem[]>(() => {
    function countsFor(sectionId: string) {
      const keys = SECTION_RESP_KEYS[sectionId];
      if (!keys) return undefined;
      return { total: keys.length, answered: keys.filter((k) => (responses[k] ?? "").trim().length > 0).length };
    }
    return [
      { id: SECTION_IDS.theme, navTitle: "Theme" },
      { id: SECTION_IDS.responseBox, navTitle: "Response Box" },
      { id: SECTION_IDS.rowNotes, navTitle: "Row Notes" },
      { id: SECTION_IDS.replyThread, navTitle: "Reply Thread" },
      { id: SECTION_IDS.saveBar, navTitle: "Save Bar" },
    ].map((item) => ({ ...item, ...countsFor(item.id) }));
  }, [responses]);

  return (
    <>
      {/* Inline page tabs — replaces sidebar section navigation */}
      <div className="doc-tabs-wrap">
        <div className="doc-tabs">
          {tabItems.map((item) => (
            <button
              key={item.id}
              type="button"
              className={`doc-tab${item.id === currentSectionId ? " cur" : ""}`}
              onClick={() => selectSection(item.id)}
            >
              {item.navTitle}
              {navMark(item)}
            </button>
          ))}
        </div>
      </div>

      <section className="page">
        <h1>Kitchen Sink</h1>
        <p className="sub">
          Every major UX component with mock data — the owner's QA gate before any of this wires up to real
          data. No API calls happen on this page.
        </p>

        <h2 id={SECTION_IDS.theme}>Theme</h2>
        <p>
          Current theme: <code>{theme}</code>. Switch it from the settings gear in the top nav — every
          component on this page redraws from the same 6 custom properties, no per-component overrides.
        </p>
        <div className="swatches">
          {(["bg", "fg", "accent", "positive", "negative", "notice"] as const).map((name) => (
            <div className="swatch" key={name}>
              <div className="fill" style={{ background: `var(--${name})` }} />
              <span className="name">{name}</span>
            </div>
          ))}
        </div>
        <p className="sub">All {THEME_NAMES.length} themes: {THEME_NAMES.join(", ")}.</p>

        <h2 id={SECTION_IDS.responseBox}>Response Box</h2>
        <p>Autogrow tracks content height; the filled state is a colour + weight change, never a fill.</p>
        <ResponseBox
          id="ks-basic-filled"
          label="Filled example"
          discuss="A short question with an answer already in it, to show the filled/autogrow state."
          value={responses["ks-basic-filled"]}
          onChange={(v) => updateResponse("ks-basic-filled", v)}
        />
        <ResponseBox
          id="ks-basic-empty"
          label="Empty example"
          discuss="Same box, nothing typed yet — accent border only, no positive left edge."
          value={responses["ks-basic-empty"]}
          onChange={(v) => updateResponse("ks-basic-empty", v)}
        />

        <h2 id={SECTION_IDS.rowNotes}>Row Notes</h2>
        <p className="sub">
          A compact, single-line response box embedded in a table cell — an invitation to comment on a row, not
          a required question. It never counts toward a section's answered/total badge.
        </p>
        <div className="tbl-wrap">
          <table>
            <thead>
              <tr>
                <th>Component</th>
                <th>Owner's row note</th>
              </tr>
            </thead>
            <tbody>
              <tr className="row-note">
                <td>Top Nav</td>
                <td>
                  <ResponseBox
                    id="ks-row-sidebar"
                    mini
                    value={responses["ks-row-sidebar"]}
                    onChange={(v) => updateResponse("ks-row-sidebar", v)}
                  />
                </td>
              </tr>
              <tr className="row-note">
                <td>Theme switching</td>
                <td>
                  <ResponseBox
                    id="ks-row-theme"
                    mini
                    value={responses["ks-row-theme"]}
                    onChange={(v) => updateResponse("ks-row-theme", v)}
                  />
                </td>
              </tr>
              <tr className="row-note">
                <td>Save bar</td>
                <td>
                  <ResponseBox
                    id="ks-row-savebar"
                    mini
                    value={responses["ks-row-savebar"]}
                    onChange={(v) => updateResponse("ks-row-savebar", v)}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h2 id={SECTION_IDS.replyThread}>Reply Thread</h2>
        <p className="sub">
          Agent voice (the discuss text and reply) is accent-coloured; owner voice (the filled textarea) is
          positive-coloured. Once a round has a reply its box locks read-only. This thread has 5 rounds, so the
          oldest 3 fold behind "Show 3 earlier."
        </p>
        <ReplyThread rounds={THREAD_ROUNDS} responses={responses} onChange={updateResponse} />

        <h2 id={SECTION_IDS.saveBar}>Save Bar</h2>
        <p className="sub">
          Fixed bottom-right, always on screen. Type in any box above to see it flip to "Unsaved changes…";
          click Save to see it settle. Clear resets every box on this page back to its sample value.
        </p>
      </section>
      <div className="savebar">
        <span className={`stat ${dirty ? "unsaved" : "saved"}`}>{dirty ? "Unsaved changes…" : "Saved ✓"}</span>
        <button type="button" className="ghost" title="Reset to sample data" onClick={handleClear}>
          ✕
        </button>
        <button type="button" onClick={handleSave}>
          Save
        </button>
      </div>
    </>
  );
}
