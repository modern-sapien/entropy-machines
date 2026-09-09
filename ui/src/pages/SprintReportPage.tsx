import { useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router-dom";

// ============================================================================
// SprintReportPage — standalone report renderer at /reports/:slug.
//
// Reports are doc-type records with type="report". They use the same API as
// docs (GET /api/docs/:slug), same multi-page content with response boxes and
// reply threads, same save endpoint (PUT /api/docs/:slug/responses/:key).
//
// Built standalone (Option B from the issue brief) because DocPage has not
// landed yet (i-react-doc-renderer is still in progress). Can be deduplicated
// later once DocPage is parameterisable.
//
// Page navigation uses .tracker-filters CSS (already in index.css) for inline
// tabs since the component is rendered inside Layout and cannot pass sections
// to the Sidebar. Sidebar nav marks require changes to App.tsx routing or
// Sidebar.tsx context, both outside this issue's scope.
// ============================================================================

// ---------------------------------------------------------------------------
// Types — mirror GET /api/docs/:slug response shape from lib/api.py
// ---------------------------------------------------------------------------

interface DocData {
  id: string;
  title: string;
  short_name: string;
  type: string;
  status: string;
  foot: string | null;
  counts: { total: number; answered: number };
}

interface PageData {
  id: string;
  doc_id: string;
  position: number;
  nav_group: string | null;
  nav_title: string;
  heading: string;
  subtitle: string | null;
  content: string;
}

interface ReplyData {
  id: number;
  response_id: number;
  author: string;
  content: string;
  created_at: string;
}

interface ResponseData {
  id: number;
  doc_id: string;
  page_id: string;
  resp_key: string;
  label: string | null;
  discuss: string | null;
  value: string;
  updated_at: string | null;
  replies: ReplyData[];
}

interface DocApiResponse {
  doc: DocData;
  pages: PageData[];
  responses: ResponseData[];
}

// ---------------------------------------------------------------------------
// Autogrow textarea — same pattern as KitchenSinkPage. Reset height then
// read scrollHeight so the textarea tracks its content. Skipped for .mini
// row-notes which stay a fixed single line by CSS.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// ResponseBox — uses existing CSS classes from index.css (.response,
// .response.filled, .discuss, .response.mini). Three-state colouring:
//   unanswered = --notice (amber)
//   agent voice (discuss/review) = --accent
//   answered (.filled) = --positive (green)
// ---------------------------------------------------------------------------

function ResponseBox({
  respKey,
  label,
  discuss,
  value,
  onChange,
  mini,
  locked,
}: {
  respKey: string;
  label?: string;
  discuss?: string;
  value: string;
  onChange: (value: string) => void;
  mini?: boolean;
  locked?: boolean;
}) {
  const ref = useAutoGrow(value, !!mini);
  const filled = value.trim().length > 0;
  const cls = ["response", filled && "filled", mini && "mini"]
    .filter(Boolean)
    .join(" ");

  return (
    <div className={cls} data-resp={respKey}>
      {label && <label>{label}</label>}
      {discuss && (
        <div
          className="discuss"
          dangerouslySetInnerHTML={{ __html: discuss }}
        />
      )}
      <textarea
        ref={ref}
        value={value}
        readOnly={locked}
        placeholder={mini ? "Add a note..." : "Type your answer..."}
        onChange={(ev) => !locked && onChange(ev.target.value)}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// ResponseThread — a response box + its reply thread. When a response has
// replies, they render as aside.review blocks below the (locked) answer box.
// 3+ replies fold older ones behind a __chain-toggle, same rule as the
// kitchen sink's ReplyThread.
// ---------------------------------------------------------------------------

function ResponseThread({
  response,
  value,
  onChange,
}: {
  response: ResponseData;
  value: string;
  onChange: (value: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const replies = response.replies;

  // No replies: plain response box, editable.
  if (replies.length === 0) {
    return (
      <ResponseBox
        respKey={response.resp_key}
        label={response.label ?? undefined}
        discuss={response.discuss ?? undefined}
        value={value}
        onChange={onChange}
      />
    );
  }

  // Lock the answer box once the agent has replied (the answer is settled
  // for this round).
  const locked =
    replies.length > 0 && replies[replies.length - 1].author === "agent";

  // Collapse: 3+ replies folds everything but the newest 2 behind a toggle.
  const cut = replies.length >= 3 ? replies.length - 2 : 0;
  const older = replies.slice(0, cut);
  const recent = replies.slice(cut);

  function renderReply(reply: ReplyData) {
    return (
      <aside className="review" key={reply.id} data-review={reply.id}>
        <span className="who">
          {reply.author} · <time>{reply.created_at}</time>
        </span>
        {reply.content.split("\n").map((para, i) => (
          <p key={i}>{para}</p>
        ))}
      </aside>
    );
  }

  return (
    <div className="thread">
      <ResponseBox
        respKey={response.resp_key}
        label={response.label ?? undefined}
        discuss={response.discuss ?? undefined}
        value={value}
        onChange={onChange}
        locked={locked}
      />
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
          {expanded
            ? older.map(renderReply)
            : older.map((reply) => (
                <div key={reply.id} className="response __chain-collapsed">
                  <div className="__chain-summary">
                    {reply.content.length > 80
                      ? `${reply.content.slice(0, 80)}...`
                      : reply.content}
                  </div>
                </div>
              ))}
        </>
      )}
      {recent.map(renderReply)}
    </div>
  );
}

// ---------------------------------------------------------------------------
// SprintReportPage
// ---------------------------------------------------------------------------

export function SprintReportPage() {
  const { slug } = useParams<{ slug: string }>();
  const [data, setData] = useState<DocApiResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [responses, setResponses] = useState<Record<string, string>>({});
  const [savedValues, setSavedValues] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [currentPageId, setCurrentPageId] = useState<string>("");

  // -- data fetch -----------------------------------------------------------

  useEffect(() => {
    if (!slug) return;
    let cancelled = false;

    async function load() {
      try {
        const res = await fetch(`/api/docs/${encodeURIComponent(slug!)}`);
        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(
            (body as { error?: string }).error ?? res.statusText
          );
        }
        const result = (await res.json()) as DocApiResponse;
        if (cancelled) return;
        setData(result);

        const vals: Record<string, string> = {};
        for (const r of result.responses) {
          vals[r.resp_key] = r.value ?? "";
        }
        setResponses(vals);
        setSavedValues({ ...vals });

        if (result.pages.length > 0) {
          setCurrentPageId(result.pages[0].id);
        }
        setError(null);
      } catch (err) {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    return () => {
      cancelled = true;
    };
  }, [slug]);

  // -- dirty tracking -------------------------------------------------------

  const dirty = useMemo(() => {
    return Object.keys(responses).some(
      (key) => responses[key] !== savedValues[key]
    );
  }, [responses, savedValues]);

  function updateResponse(key: string, value: string) {
    setResponses((prev) => ({ ...prev, [key]: value }));
  }

  // -- save -----------------------------------------------------------------

  async function handleSave() {
    if (!data || !slug || saving) return;
    setSaving(true);
    try {
      const changed = Object.keys(responses).filter(
        (key) => responses[key] !== savedValues[key]
      );
      for (const key of changed) {
        const res = await fetch(
          `/api/docs/${encodeURIComponent(slug)}/responses/${encodeURIComponent(key)}`,
          {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ value: responses[key] }),
          }
        );
        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(
            (body as { error?: string }).error ?? res.statusText
          );
        }
      }
      setSavedValues({ ...responses });
    } catch {
      // Save failed; dirty state remains so the user sees "unsaved" and can
      // retry. A per-response error UI is out of scope for this first pass.
    } finally {
      setSaving(false);
    }
  }

  // -- scrollspy: track which page section is visible -----------------------

  useEffect(() => {
    if (!data) return;
    const ids = data.pages.map((p) => p.id);
    const els = ids
      .map((id) => document.getElementById(id))
      .filter((el): el is HTMLElement => !!el);
    if (els.length === 0) return;
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((e) => e.isIntersecting);
        if (visible.length === 0) return;
        const top = visible.reduce((a, b) =>
          a.boundingClientRect.top < b.boundingClientRect.top ? a : b
        );
        setCurrentPageId(top.target.id);
      },
      { rootMargin: "-10% 0px -70% 0px", threshold: 0 }
    );
    els.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, [data]);

  function selectPage(id: string) {
    setCurrentPageId(id);
    document
      .getElementById(id)
      ?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  // -- early returns --------------------------------------------------------

  if (loading) {
    return (
      <section className="page">
        <h1>Loading...</h1>
        <p className="sub">Fetching report data.</p>
      </section>
    );
  }

  if (error) {
    const isMigrate = /no database|migrate-db/i.test(error);
    return (
      <section className="page">
        <h1>{slug}</h1>
        <section className="dash-error">
          <h2>API unreachable</h2>
          {isMigrate ? (
            <p>
              The database has not been created yet. Run{" "}
              <code>bin/migrate-db</code> to initialise it.
            </p>
          ) : (
            <p>{error}</p>
          )}
        </section>
      </section>
    );
  }

  if (!data) return null;

  // -- derived data ---------------------------------------------------------

  const { doc, pages } = data;

  // Group responses by page_id for rendering under each page section.
  const responsesByPage: Record<string, ResponseData[]> = {};
  for (const resp of data.responses) {
    const pid = resp.page_id ?? "";
    if (!responsesByPage[pid]) responsesByPage[pid] = [];
    responsesByPage[pid].push(resp);
  }

  // Per-page answered/total counts for the inline nav badges.
  function pageCounts(pageId: string) {
    const resps = responsesByPage[pageId] ?? [];
    const total = resps.length;
    const answered = resps.filter(
      (r) => (responses[r.resp_key] ?? "").trim().length > 0
    ).length;
    return { total, answered };
  }

  const hasResponses = data.responses.length > 0;

  // -- render ---------------------------------------------------------------

  return (
    <>
      <section className="page">
        <h1>{doc.title}</h1>
        <p className="sub">
          {doc.short_name} — Sprint Report
          {doc.status && doc.status !== "open" ? ` — ${doc.status}` : ""}
        </p>

        {/* Inline page navigation using existing tracker-filter CSS. Each
            page tab shows its nav_title and an answered/total count when the
            page has response boxes. Scrollspy highlights the visible page. */}
        {pages.length > 1 && (
          <div className="tracker-filters">
            {pages.map((page) => {
              const counts = pageCounts(page.id);
              const countText =
                counts.total > 0
                  ? ` (${counts.answered}/${counts.total})`
                  : "";
              return (
                <button
                  key={page.id}
                  type="button"
                  className={`tracker-filter${page.id === currentPageId ? " cur" : ""}`}
                  onClick={() => selectPage(page.id)}
                >
                  {page.nav_title}
                  {countText}
                </button>
              );
            })}
          </div>
        )}

        {/* Render all pages sequentially. Each page is a section with its
            heading, subtitle, content HTML, and response boxes. */}
        {pages.map((page) => {
          const pageResps = responsesByPage[page.id] ?? [];
          return (
            <section key={page.id} id={page.id}>
              <h2>{page.heading}</h2>
              {page.subtitle && <p className="sub">{page.subtitle}</p>}
              {page.content && (
                <div
                  dangerouslySetInnerHTML={{ __html: page.content }}
                />
              )}
              {pageResps.map((resp) => (
                <ResponseThread
                  key={resp.resp_key}
                  response={resp}
                  value={responses[resp.resp_key] ?? ""}
                  onChange={(v) => updateResponse(resp.resp_key, v)}
                />
              ))}
            </section>
          );
        })}

        {doc.foot && <p className="sub">{doc.foot}</p>}
      </section>

      {/* Save bar — fixed bottom-right, same as KitchenSinkPage. Only shown
          when the report has response boxes (nothing to save otherwise). */}
      {hasResponses && (
        <div className="savebar">
          <span className={`stat ${dirty ? "unsaved" : "saved"}`}>
            {saving
              ? "Saving..."
              : dirty
                ? "Unsaved changes..."
                : "Saved"}
          </span>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving || !dirty}
          >
            Save
          </button>
        </div>
      )}
    </>
  );
}
