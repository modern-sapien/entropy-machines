import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface Issue {
  id: string;
  title: string;
  status: string;
  source_doc: string | null;
  source_doc_type: string | null;
  source_doc_name: string | null;
  blocked_by: string[];
  claimed_by: string | null;
  claimed_at: string | null;
  effort?: string | null;
  held_why?: string | null;
  held_at?: string | null;
  gate?: string | null;
  gated_at?: string | null;
  created_at: string | null;
  updated_at: string | null;
}

interface Note {
  id: number;
  issue_id: string;
  type: string;
  author: string | null;
  content: string;
  created_at: string;
}

type Bucket = "ready" | "inflight" | "held" | "gated" | "blocked" | "done";
type ViewMode = "list" | "board";

interface DerivedIssue extends Issue {
  flags: Bucket[];
  bucket: Bucket;
  openBlockers: string[];
  doneBlockers: string[];
  blocks: string[];
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BUCKET_ORDER: Bucket[] = [
  "ready",
  "inflight",
  "held",
  "gated",
  "blocked",
  "done",
];

const BUCKET_META: Record<Bucket, { label: string; desc: string }> = {
  ready: { label: "Ready", desc: "claimable now" },
  inflight: { label: "In flight", desc: "claimed, being worked" },
  held: { label: "Held", desc: "a decision not to do it now" },
  gated: {
    label: "Gated",
    desc: "waiting on a ruling outside the issue graph",
  },
  blocked: { label: "Blocked", desc: "waiting on another issue" },
  done: { label: "Done", desc: "finished" },
};

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function day(ts: string | null | undefined): string {
  return (ts || "").slice(0, 10);
}

function tryParseJsonObj(s: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(s);
    if (v && typeof v === "object" && !Array.isArray(v))
      return v as Record<string, unknown>;
  } catch {
    /* not json */
  }
  return null;
}

// ---------------------------------------------------------------------------
// Process checkpoints — which note types represent process milestones
// ---------------------------------------------------------------------------

const CHECKPOINT_META: Record<string, { label: string; colorClass: string }> = {
  DISPATCH: { label: "isolated worker", colorClass: "accent" },
  HANDOFF: { label: "handed off", colorClass: "positive" },
  VERIFIED: { label: "verified", colorClass: "positive" },
  REVERIFY: { label: "re-verified", colorClass: "notice" },
  LANDED: { label: "landed", colorClass: "positive" },
};

/** Scan notes for the dispatch brief and earliest description NOTE. */
function extractContext(notes: Note[]): {
  brief: string | null;
  description: string | null;
} {
  let brief: string | null = null;
  let description: string | null = null;

  for (const note of notes) {
    const upperType = (note.type || "").toUpperCase();
    const fields = tryParseJsonObj(note.content);

    // Latest DISPATCH brief wins (loop overwrites earlier ones).
    if (upperType === "DISPATCH" && fields && typeof fields.brief === "string") {
      brief = fields.brief;
    }

    // First NOTE with text content becomes the description.
    if (upperType === "NOTE" && !description) {
      if (fields && typeof fields.text === "string") {
        description = fields.text;
      } else if (!fields && note.content) {
        description = note.content;
      }
    }
  }

  return { brief, description };
}

// ---------------------------------------------------------------------------
// Derivation — bucket grouping and dependency graph
// ---------------------------------------------------------------------------

function deriveAll(issues: Issue[]): DerivedIssue[] {
  const map = new Map(issues.map((i) => [i.id, i]));

  // Reverse deps: if Y.blocked_by includes X, then X blocks Y.
  const reverseMap = new Map<string, string[]>();
  for (const issue of issues) {
    for (const dep of issue.blocked_by || []) {
      let arr = reverseMap.get(dep);
      if (!arr) {
        arr = [];
        reverseMap.set(dep, arr);
      }
      if (!arr.includes(issue.id)) arr.push(issue.id);
    }
  }

  return issues.map((issue) => {
    const status = issue.status || "open";
    const held = !!((issue.held_why || "").trim());
    const gated = !!((issue.gate || "").trim());

    // Open blockers: deps that are not done (or that don't exist in the store).
    const openB = (issue.blocked_by || []).filter((dep) => {
      const d = map.get(dep);
      return !d || d.status !== "done";
    });
    const doneB = (issue.blocked_by || []).filter((b) => !openB.includes(b));

    const isDone = status === "done";
    const isInflight = status === "progress" || status === "review";
    const isReady =
      (status === "open" || status === "notstarted") &&
      !held &&
      !gated &&
      !openB.length;

    const flags: Bucket[] = [];
    if (isReady) flags.push("ready");
    if (isInflight) flags.push("inflight");
    if (held) flags.push("held");
    if (gated) flags.push("gated");
    if (openB.length) flags.push("blocked");
    if (isDone) flags.push("done");

    // Precedence: done > held > gated > blocked > inflight > ready.
    let bucket: Bucket;
    if (isDone) bucket = "done";
    else if (held) bucket = "held";
    else if (gated) bucket = "gated";
    else if (openB.length) bucket = "blocked";
    else if (isInflight) bucket = "inflight";
    else if (isReady) bucket = "ready";
    else bucket = "blocked"; // fallback: visible, not lost

    return {
      ...issue,
      flags,
      bucket,
      openBlockers: openB,
      doneBlockers: doneB,
      blocks: (reverseMap.get(issue.id) || []).sort(),
    };
  });
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

function buildHaystack(issue: DerivedIssue): string {
  return [
    issue.id,
    issue.title,
    issue.held_why || "",
    issue.gate || "",
    issue.claimed_by || "",
    ...(issue.blocked_by || []),
  ]
    .join(" ")
    .toLowerCase();
}

function matchesSearch(issue: DerivedIssue, terms: string[]): boolean {
  if (!terms.length) return true;
  const hay = buildHaystack(issue);
  return terms.every((t) => hay.includes(t));
}

// ---------------------------------------------------------------------------
// Filtering (cross-filter for faceted counts)
// ---------------------------------------------------------------------------

interface Filters {
  states: Set<Bucket>;
  efforts: Set<string>;
  search: string;
}

function passes(
  issue: DerivedIssue,
  filters: Filters,
  terms: string[],
  skip?: "states" | "efforts",
): boolean {
  if (!matchesSearch(issue, terms)) return false;
  if (skip !== "states" && filters.states.size > 0) {
    if (!issue.flags.some((f) => filters.states.has(f))) return false;
  }
  if (skip !== "efforts" && filters.efforts.size > 0) {
    if (!filters.efforts.has(issue.effort || "")) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// TrackerPage
// ---------------------------------------------------------------------------

export function TrackerPage() {
  const [issues, setIssues] = useState<Issue[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [view, setView] = useState<ViewMode>("list");
  const [filters, setFilters] = useState<Filters>({
    states: new Set(),
    efforts: new Set(),
    search: "",
  });
  const [detailId, setDetailId] = useState<string | null>(null);
  const [detailNotes, setDetailNotes] = useState<Note[]>([]);
  const [notesLoading, setNotesLoading] = useState(false);

  // Fetch all issues on mount.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetch("/api/issues")
      .then((r) => {
        if (!r.ok) throw new Error(`${r.status}`);
        return r.json();
      })
      .then((data: Issue[]) => {
        if (!cancelled) {
          setIssues(data);
          setError(null);
          setLoading(false);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setError(
            "Could not reach the issue API. Is the server running? " +
              "If the database does not exist yet, run bin/migrate-db to create it.",
          );
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Derive buckets, flags, deps.
  const derived = useMemo(() => deriveAll(issues), [issues]);
  const issueMap = useMemo(
    () => new Map(derived.map((i) => [i.id, i])),
    [derived],
  );

  // Search terms.
  const terms = useMemo(
    () =>
      filters.search
        .trim()
        .toLowerCase()
        .split(/\s+/)
        .filter(Boolean),
    [filters.search],
  );

  // Filtered set.
  const filtered = useMemo(
    () => derived.filter((i) => passes(i, filters, terms)),
    [derived, filters, terms],
  );

  // Available effort values (sorted S < M < L < everything else).
  const efforts = useMemo(() => {
    const set = new Set(
      derived.map((i) => i.effort).filter(Boolean) as string[],
    );
    const order: Record<string, number> = { S: 0, M: 1, L: 2 };
    return [...set].sort(
      (a, b) => (order[a] ?? 3) - (order[b] ?? 3) || a.localeCompare(b),
    );
  }, [derived]);

  // Cross-filter counts: each facet group counts against every OTHER active
  // filter so toggling a facet never zeroes itself out.
  const stateCounts = useMemo(() => {
    const pool = derived.filter((i) => passes(i, filters, terms, "states"));
    const c: Record<Bucket, number> = {
      ready: 0,
      inflight: 0,
      held: 0,
      gated: 0,
      blocked: 0,
      done: 0,
    };
    for (const i of pool) for (const f of i.flags) c[f]++;
    return c;
  }, [derived, filters, terms]);

  const effortCounts = useMemo(() => {
    const pool = derived.filter((i) => passes(i, filters, terms, "efforts"));
    const c: Record<string, number> = {};
    for (const i of pool) {
      const e = i.effort || "";
      if (e) c[e] = (c[e] || 0) + 1;
    }
    return c;
  }, [derived, filters, terms]);

  // Fetch notes when the detail panel opens.
  useEffect(() => {
    if (!detailId) return;
    let cancelled = false;
    setNotesLoading(true);
    setDetailNotes([]);
    fetch(`/api/issues/${encodeURIComponent(detailId)}/notes`)
      .then((r) => (r.ok ? r.json() : []))
      .then((data: Note[]) => {
        if (!cancelled) {
          setDetailNotes(data);
          setNotesLoading(false);
        }
      })
      .catch(() => {
        if (!cancelled) setNotesLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [detailId]);

  // Handlers.
  const toggleState = useCallback((b: Bucket) => {
    setFilters((prev) => {
      const s = new Set(prev.states);
      if (s.has(b)) s.delete(b);
      else s.add(b);
      return { ...prev, states: s };
    });
  }, []);

  const toggleEffort = useCallback((e: string) => {
    setFilters((prev) => {
      const s = new Set(prev.efforts);
      if (s.has(e)) s.delete(e);
      else s.add(e);
      return { ...prev, efforts: s };
    });
  }, []);

  const clearAll = useCallback(() => {
    setFilters({ states: new Set(), efforts: new Set(), search: "" });
  }, []);

  const openDetail = useCallback((id: string) => setDetailId(id), []);
  const closeDetail = useCallback(() => setDetailId(null), []);

  // Keyboard: Escape closes detail, / focuses search.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeDetail();
      if (
        e.key === "/" &&
        (e.target as HTMLElement)?.tagName !== "INPUT"
      ) {
        e.preventDefault();
        document.getElementById("tracker-search")?.focus();
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [closeDetail]);

  const hasFilters =
    filters.states.size > 0 ||
    filters.efforts.size > 0 ||
    filters.search.length > 0;
  const detailIssue = detailId ? (issueMap.get(detailId) ?? null) : null;

  // --- Loading / Error states ---

  if (loading) {
    return (
      <section className="page">
        <h1>Issues</h1>
        <p className="sub">Loading issues...</p>
      </section>
    );
  }

  if (error) {
    return (
      <section className="page">
        <h1>Issues</h1>
        <p className="tracker-error">{error}</p>
      </section>
    );
  }

  // --- Main view ---

  return (
    <>
      {/* Sticky header */}
      <div className="tracker-header">
        <h1 className="tracker-title">Issues</h1>
        <input
          id="tracker-search"
          className="tracker-search"
          type="text"
          placeholder="search id, title, reason...  (/ to focus)"
          value={filters.search}
          onChange={(e) =>
            setFilters((prev) => ({ ...prev, search: e.target.value }))
          }
        />
        <div className="tracker-seg">
          <button
            className={view === "list" ? "on" : ""}
            onClick={() => setView("list")}
          >
            List
          </button>
          <button
            className={view === "board" ? "on" : ""}
            onClick={() => setView("board")}
          >
            Board
          </button>
        </div>
        {hasFilters && (
          <button className="tracker-clear" onClick={clearAll}>
            clear filters
          </button>
        )}
        <span className="tracker-count">
          {filtered.length} of {derived.length} &middot;{" "}
          {filtered.filter((i) => i.status !== "done").length} open
        </span>
      </div>

      {/* Body: filter sidebar + content */}
      <div className="tracker-body">
        {/* Filter sidebar */}
        <div className="tracker-sidebar">
          <div className="tracker-sidebar-grp">State</div>
          {BUCKET_ORDER.map((b) => (
            <button
              key={b}
              className={
                "tracker-f" +
                (filters.states.has(b) ? " on" : "") +
                (stateCounts[b] === 0 ? " zero" : "")
              }
              onClick={() => toggleState(b)}
            >
              <span className={`tracker-dot ${b}`} />
              {BUCKET_META[b].label}
              <span className="tracker-f-n">{stateCounts[b]}</span>
            </button>
          ))}
          <div className="tracker-sidebar-grp">Effort</div>
          {efforts.length > 0 ? (
            efforts.map((e) => (
              <button
                key={e}
                className={
                  "tracker-f" +
                  (filters.efforts.has(e) ? " on" : "") +
                  ((effortCounts[e] || 0) === 0 ? " zero" : "")
                }
                onClick={() => toggleEffort(e)}
              >
                {e}
                <span className="tracker-f-n">{effortCounts[e] || 0}</span>
              </button>
            ))
          ) : (
            <div className="tracker-f-empty">no effort recorded yet</div>
          )}
        </div>

        {/* Main content */}
        <div className="tracker-main">
          {filtered.length === 0 ? (
            <div className="tracker-empty">
              {derived.length > 0
                ? "Nothing matches."
                : "No issues filed yet."}
            </div>
          ) : view === "board" ? (
            <BoardView
              issues={filtered}
              onSelect={openDetail}
            />
          ) : (
            <ListView
              issues={filtered}
              issueMap={issueMap}
              onSelect={openDetail}
            />
          )}
        </div>
      </div>

      {/* Detail panel */}
      {detailIssue && (
        <>
          <div className="tracker-scrim" onClick={closeDetail} />
          <DetailPanel
            issue={detailIssue}
            issueMap={issueMap}
            notes={detailNotes}
            notesLoading={notesLoading}
            onClose={closeDetail}
            onNavigate={openDetail}
          />
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// ListView
// ---------------------------------------------------------------------------

function ListView({
  issues,
  issueMap,
  onSelect,
}: {
  issues: DerivedIssue[];
  issueMap: Map<string, DerivedIssue>;
  onSelect: (id: string) => void;
}) {
  return (
    <>
      {BUCKET_ORDER.map((bucket) => {
        const items = issues.filter((i) => i.bucket === bucket);
        if (!items.length) return null;
        return (
          <div key={bucket}>
            <div className="tracker-bh" id={`b-${bucket}`}>
              <span className={`tracker-dot ${bucket}`} />
              <h2>{BUCKET_META[bucket].label}</h2>
              <span className="tracker-bh-meta">
                {items.length} &middot; {BUCKET_META[bucket].desc}
              </span>
            </div>
            <div className="tracker-rows">
              {items.map((issue) => (
                <IssueRow
                  key={issue.id}
                  issue={issue}
                  issueMap={issueMap}
                  onClick={() => onSelect(issue.id)}
                />
              ))}
            </div>
          </div>
        );
      })}
    </>
  );
}

// ---------------------------------------------------------------------------
// IssueRow
// ---------------------------------------------------------------------------

function IssueRow({
  issue,
  issueMap,
  onClick,
}: {
  issue: DerivedIssue;
  issueMap: Map<string, DerivedIssue>;
  onClick: () => void;
}) {
  return (
    <div className={`tracker-row ${issue.bucket}`} onClick={onClick}>
      <span className={`tracker-dot ${issue.bucket}`} />
      <span className="tracker-row-title">
        {issue.title || "(no title)"}
      </span>
      {/* Flag tags for non-primary conditions */}
      {issue.flags
        .filter((f) => f !== "done" && f !== "ready")
        .map((f) => (
          <span key={f} className={`tracker-tag ${f}`}>
            {BUCKET_META[f].label.toLowerCase()}
          </span>
        ))}
      {issue.flags.includes("ready") && (
        <span className="tracker-tag ready">ready</span>
      )}
      {issue.claimed_by && (
        <span className="tracker-tag">{issue.claimed_by}</span>
      )}
      {issue.blocks.length > 0 && (
        <span className="tracker-tag">blocks {issue.blocks.length}</span>
      )}
      <span className="tracker-tag tracker-tag-eff">
        {issue.effort || "·"}
      </span>
      <span className="tracker-row-id">{issue.id}</span>
      <ReasonLines issue={issue} issueMap={issueMap} />
    </div>
  );
}

// ---------------------------------------------------------------------------
// ReasonLines — why an issue is not claimable
// ---------------------------------------------------------------------------

function ReasonLines({
  issue,
  issueMap,
}: {
  issue: DerivedIssue;
  issueMap: Map<string, DerivedIssue>;
}) {
  return (
    <>
      {issue.held_why && (
        <div className="tracker-row-why held">
          <b>held</b> &mdash; {issue.held_why}
          {issue.held_at && (
            <span className="mono"> (since {day(issue.held_at)})</span>
          )}
        </div>
      )}
      {issue.gate && (
        <div className="tracker-row-why gated">
          <b>gated</b> on <code>{issue.gate}</code>
          {issue.gated_at && (
            <span className="mono"> (since {day(issue.gated_at)})</span>
          )}
        </div>
      )}
      {issue.openBlockers.length > 0 && (
        <div className="tracker-row-why blocked">
          <b>blocked by</b>{" "}
          {issue.openBlockers.map((b, i) => (
            <span key={b}>
              {i > 0 && ", "}
              <code>{b}</code>
              {!issueMap.has(b) && " (no such issue)"}
            </span>
          ))}
        </div>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// BoardView
// ---------------------------------------------------------------------------

function BoardView({
  issues,
  onSelect,
}: {
  issues: DerivedIssue[];
  onSelect: (id: string) => void;
}) {
  return (
    <div className="tracker-cols">
      {BUCKET_ORDER.map((bucket) => {
        const items = issues.filter((i) => i.bucket === bucket);
        return (
          <div key={bucket} className="tracker-col">
            <h3 className="tracker-col-head">
              <span className={`tracker-dot ${bucket}`} />
              {BUCKET_META[bucket].label}
              <span className="tracker-col-count">{items.length}</span>
            </h3>
            {items.map((issue) => (
              <div
                key={issue.id}
                className="tracker-card"
                onClick={() => onSelect(issue.id)}
              >
                <div className="tracker-card-title">
                  {issue.title || "(no title)"}
                </div>
                <div className="tracker-card-meta">
                  <span>{issue.id}</span>
                  <span className="tracker-card-eff">
                    {issue.effort || ""}
                  </span>
                </div>
              </div>
            ))}
          </div>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------
// DetailPanel
// ---------------------------------------------------------------------------

function DetailPanel({
  issue,
  issueMap,
  notes,
  notesLoading,
  onClose,
  onNavigate,
}: {
  issue: DerivedIssue;
  issueMap: Map<string, DerivedIssue>;
  notes: Note[];
  notesLoading: boolean;
  onClose: () => void;
  onNavigate: (id: string) => void;
}) {
  return (
    <div className="tracker-detail">
      <button
        className="tracker-detail-close"
        onClick={onClose}
        title="close"
      >
        &times;
      </button>
      <h2>{issue.title || "(no title)"}</h2>
      <div className="tracker-detail-sub">
        {issue.id} &middot; status {issue.status} &middot; effort{" "}
        {issue.effort || "—"}
        {issue.claimed_by && (
          <>
            {" "}
            &middot; claimed by {issue.claimed_by}
            {issue.claimed_at && ` ${day(issue.claimed_at)}`}
          </>
        )}
      </div>

      {/* Source document linkage */}
      <div className="tracker-origin">
        <h4>Origin</h4>
        {issue.source_doc ? (
          <Link
            to={`/${issue.source_doc_type === "prd" ? "prds" : issue.source_doc_type === "report" ? "reports" : "docs"}/${encodeURIComponent(issue.source_doc)}`}
            className="tracker-origin-link"
          >
            {issue.source_doc_name || issue.source_doc}
          </Link>
        ) : (
          <span className="tracker-origin-adhoc">ad-hoc</span>
        )}
      </div>

      {/* Issue context — dispatch brief and description */}
      {(() => {
        const ctx = extractContext(notes);
        if (!ctx.brief && !ctx.description) return null;
        return (
          <div className="tracker-context">
            <h4>Goal</h4>
            {ctx.brief && (
              <div className="tracker-context-brief">{ctx.brief}</div>
            )}
            {ctx.description && ctx.description !== ctx.brief && (
              <div className="tracker-context-desc">{ctx.description}</div>
            )}
          </div>
        );
      })()}

      {/* Held reason block */}
      {issue.held_why && (
        <div className="tracker-reason held">
          <h4>Held &mdash; why</h4>
          <div>{issue.held_why}</div>
          {issue.held_at && (
            <div className="tracker-detail-when">
              since {issue.held_at}
            </div>
          )}
        </div>
      )}

      {/* Gated reason block */}
      {issue.gate && (
        <div className="tracker-reason gated">
          <h4>Gated on an open question</h4>
          <div>
            <code>{issue.gate}</code>
          </div>
          {issue.gated_at && (
            <div className="tracker-detail-when">
              since {issue.gated_at}
            </div>
          )}
        </div>
      )}

      {/* Open blockers */}
      {issue.openBlockers.length > 0 && (
        <div className="tracker-reason blocked">
          <h4>Blocked by (still open)</h4>
          <div className="tracker-chips">
            {issue.openBlockers.map((b) => (
              <DepChip
                key={b}
                id={b}
                issueMap={issueMap}
                onClick={onNavigate}
              />
            ))}
          </div>
        </div>
      )}

      {/* Done blockers */}
      {issue.doneBlockers.length > 0 && (
        <div className="tracker-blk">
          <h4>Was blocked by (done)</h4>
          <div className="tracker-chips">
            {issue.doneBlockers.map((b) => (
              <DepChip
                key={b}
                id={b}
                issueMap={issueMap}
                onClick={onNavigate}
                done
              />
            ))}
          </div>
        </div>
      )}

      {/* Reverse deps */}
      {issue.blocks.length > 0 && (
        <div className="tracker-blk">
          <h4>Blocks</h4>
          <div className="tracker-chips">
            {issue.blocks.map((b) => (
              <DepChip
                key={b}
                id={b}
                issueMap={issueMap}
                onClick={onNavigate}
              />
            ))}
          </div>
        </div>
      )}

      {/* Claimable */}
      {issue.flags.includes("ready") && (
        <div className="tracker-blk">
          <h4>Claimable</h4>
          <div>
            Nothing is holding this: not held, not gated, no open blocker.
          </div>
        </div>
      )}

      {/* Audit Log */}
      <div className="tracker-blk">
        <h4>Audit Log</h4>
        {notesLoading && <div className="sub">Loading notes...</div>}
        {!notesLoading && notes.length === 0 && (
          <div>No entries in the audit log.</div>
        )}
        {notes.map((n) => (
          <NoteEntry key={n.id} note={n} />
        ))}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// DepChip — dependency chip (clickable, done, or dead)
// ---------------------------------------------------------------------------

function DepChip({
  id,
  issueMap,
  onClick,
  done: isDone,
}: {
  id: string;
  issueMap: Map<string, DerivedIssue>;
  onClick: (id: string) => void;
  done?: boolean;
}) {
  const dep = issueMap.get(id);
  if (!dep) {
    return (
      <span className="tracker-chip tracker-chip-dead">
        {id} &mdash; no such issue (counts as blocking)
      </span>
    );
  }
  return (
    <span
      className={`tracker-chip ${isDone ? "tracker-chip-done" : "tracker-chip-link"}`}
      onClick={(e) => {
        e.stopPropagation();
        onClick(id);
      }}
    >
      <span className={`tracker-dot ${dep.bucket}`} />
      {id} &mdash; {dep.title || "(no title)"}
    </span>
  );
}

// ---------------------------------------------------------------------------
// NoteEntry — one line in the audit trail
// ---------------------------------------------------------------------------

function NoteEntry({ note }: { note: Note }) {
  const verb = (note.type || "comment").toUpperCase();
  const fields = tryParseJsonObj(note.content);
  const checkpoint = CHECKPOINT_META[verb] ?? null;

  return (
    <div
      className={
        "tracker-note" +
        (checkpoint
          ? ` checkpoint checkpoint-${checkpoint.colorClass}`
          : "")
      }
    >
      <div className="tracker-note-hd">
        <span className={`tracker-note-verb ${verb}`}>{verb}</span>
        {checkpoint && (
          <span
            className={`tracker-checkpoint-label ${checkpoint.colorClass}`}
          >
            {checkpoint.label}
          </span>
        )}
        <span>{note.author || "unknown"}</span>
        <span className="tracker-note-when">{note.created_at}</span>
      </div>
      {fields ? (
        <dl className="tracker-note-fields">
          {Object.keys(fields)
            .sort()
            .map((k) => {
              const v = fields[k];
              const text = Array.isArray(v)
                ? v.join("\n")
                : v && typeof v === "object"
                  ? JSON.stringify(v, null, 2)
                  : String(v ?? "");
              return (
                <Fragment key={k}>
                  <dt>{k}</dt>
                  <dd>{text}</dd>
                </Fragment>
              );
            })}
        </dl>
      ) : note.content ? (
        <div className="tracker-note-body">{note.content}</div>
      ) : null}
    </div>
  );
}
