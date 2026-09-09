import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router-dom";

// ============================================================================
// DocPage — full document renderer with multi-page nav, response boxes,
// reply threads, autosave to API, nav marks, and scrollspy.
//
// Route: /docs/:slug (see App.tsx). Rendered inside Layout, which provides
// a TopNav. Page-level navigation uses inline tabs below the heading.
// ============================================================================

// ---- API types -------------------------------------------------------------

interface DocCounts {
  total: number;
  answered: number;
}

interface Doc {
  id: string;
  title: string;
  short_name: string;
  type: string;
  status: string;
  foot: string | null;
  counts: DocCounts;
}

interface Page {
  id: string;
  doc_id: string;
  position: number;
  nav_group: string | null;
  nav_title: string;
  heading: string;
  subtitle: string | null;
  content: string;
}

interface Reply {
  id: number;
  response_id: number;
  author: string;
  content: string;
  created_at: string;
}

interface Response {
  id: number;
  doc_id: string;
  page_id: string | null;
  resp_key: string;
  label: string | null;
  discuss: string | null;
  value: string;
  updated_at: string | null;
  replies: Reply[];
}

interface DocPayload {
  doc: Doc;
  pages: Page[];
  responses: Response[];
}

// ---- types for inline page tabs -------------------------------------------

interface PageTabItem {
  id: string;
  navTitle: string;
  answered?: number;
  total?: number;
}

interface PageTabGroup {
  label?: string;
  items: PageTabItem[];
}

// ---- autogrow hook (same as KitchenSinkPage) --------------------------------

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

// ---- navmark badge for inline tabs ----------------------------------------

function navMark(item: PageTabItem) {
  if (!item.total) return null;
  const done = item.answered === item.total;
  return (
    <span className={`navmark ${done ? "done" : "todo"}`}>{done ? "✓" : `${item.answered ?? 0}/${item.total}`}</span>
  );
}

// ---- sections summary line ------------------------------------------------

function sectionsSummary(groups: PageTabGroup[]) {
  const scored = groups.flatMap((g) => g.items).filter((it) => (it.total ?? 0) > 0);
  if (scored.length === 0) return null;
  const done = scored.filter((it) => it.answered === it.total).length;
  return (
    <div className="doc-tabs-summary">
      {done === scored.length ? (
        <span className="all-done">{"✓"} all {scored.length} sections answered</span>
      ) : (
        `Answered ${done}/${scored.length} sections`
      )}
    </div>
  );
}

// ---- ResponseBox ------------------------------------------------------------

interface ResponseBoxProps {
  respKey: string;
  label: string | null;
  discuss: string | null;
  value: string;
  onChange: (value: string) => void;
  locked?: boolean;
}

function ResponseBox({ respKey, label, discuss, value, onChange, locked }: ResponseBoxProps) {
  const ref = useAutoGrow(value, false);
  const filled = value.trim().length > 0;
  const className = ["response", filled && "filled"].filter(Boolean).join(" ");

  return (
    <div className={className} data-resp={respKey}>
      {label && <label>{label}</label>}
      {discuss && (
        <div className="discuss" dangerouslySetInnerHTML={{ __html: discuss }} />
      )}
      <textarea
        ref={ref}
        value={value}
        readOnly={locked}
        placeholder="Type your answer..."
        onChange={(ev) => !locked && onChange(ev.target.value)}
      />
    </div>
  );
}

// ---- Review block (agent reply) ---------------------------------------------

function Review({ reply }: { reply: Reply }) {
  return (
    <aside className="review" data-review={reply.id}>
      <span className="who">
        {reply.author} &middot; <time>{reply.created_at}</time>
      </span>
      {reply.content.split("\n").filter(Boolean).map((para, i) => (
        <p key={i}>{para}</p>
      ))}
    </aside>
  );
}

// ---- Reply thread with collapse --------------------------------------------

function snippetFor(resp: Response) {
  const text = resp.value.trim() || resp.discuss || "";
  return text.length > 80 ? `${text.slice(0, 80)}...` : text || "(empty)";
}

function ReplyThread({
  responses,
  values,
  onChange,
}: {
  responses: Response[];
  values: Record<string, string>;
  onChange: (key: string, value: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  // Same rule as KitchenSinkPage: 3+ rounds folds everything but newest 2.
  const cut = responses.length >= 3 ? responses.length - 2 : 0;
  const older = responses.slice(0, cut);
  const recent = responses.slice(cut);

  function renderRound(resp: Response) {
    const val = values[resp.resp_key] ?? resp.value;
    const hasReply = resp.replies.length > 0;
    return (
      <div key={resp.resp_key}>
        <ResponseBox
          respKey={resp.resp_key}
          label={resp.label}
          discuss={resp.discuss}
          value={val}
          onChange={(v) => onChange(resp.resp_key, v)}
          locked={hasReply}
        />
        {resp.replies.map((reply) => (
          <Review key={reply.id} reply={reply} />
        ))}
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
          {older.map((resp) =>
            expanded ? (
              renderRound(resp)
            ) : (
              <div key={resp.resp_key} className="response __chain-collapsed">
                <div className="__chain-summary">{snippetFor(resp)}</div>
              </div>
            ),
          )}
        </>
      )}
      {recent.map(renderRound)}
    </div>
  );
}

// ---- Page section (one page of the doc) ------------------------------------

function PageSection({
  page,
  responses,
  values,
  onChange,
}: {
  page: Page;
  responses: Response[];
  values: Record<string, string>;
  onChange: (key: string, value: string) => void;
}) {
  // Group responses that share the same base key prefix into threads.
  const groups = useMemo(() => {
    if (responses.length <= 1) {
      return responses.map((r) => [r]);
    }
    const hasThread = responses.some((r) => r.replies.length > 0) || responses.length > 1;
    if (hasThread) {
      return [responses];
    }
    return responses.map((r) => [r]);
  }, [responses]);

  return (
    <section className="page" id={page.id}>
      <h1>{page.heading}</h1>
      {page.subtitle && <p className="sub">{page.subtitle}</p>}
      <div dangerouslySetInnerHTML={{ __html: page.content }} />
      {groups.map((group) =>
        group.length === 1 ? (
          <div key={group[0].resp_key}>
            <ResponseBox
              respKey={group[0].resp_key}
              label={group[0].label}
              discuss={group[0].discuss}
              value={values[group[0].resp_key] ?? group[0].value}
              onChange={(v) => onChange(group[0].resp_key, v)}
              locked={group[0].replies.length > 0}
            />
            {group[0].replies.map((reply) => (
              <Review key={reply.id} reply={reply} />
            ))}
          </div>
        ) : (
          <ReplyThread
            key={group[0].resp_key}
            responses={group}
            values={values}
            onChange={onChange}
          />
        ),
      )}
    </section>
  );
}

// ---- DocPage (main export) -------------------------------------------------

export function DocPage() {
  const { slug } = useParams<{ slug: string }>();
  const [data, setData] = useState<DocPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  // Local edits keyed by resp_key
  const [values, setValues] = useState<Record<string, string>>({});
  // Track which keys are dirty (edited but not saved)
  const [dirty, setDirty] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);
  const [saveStatus, setSaveStatus] = useState<"idle" | "saved">("idle");

  // Current page for scrollspy
  const [currentPageId, setCurrentPageId] = useState<string>("");

  // ---- fetch doc data ----
  useEffect(() => {
    if (!slug) return;
    setLoading(true);
    setError(null);
    fetch(`/api/docs/${encodeURIComponent(slug)}`)
      .then((res) => {
        if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
        return res.json();
      })
      .then((payload: DocPayload) => {
        setData(payload);
        // Initialize values from server data
        const init: Record<string, string> = {};
        for (const resp of payload.responses) {
          init[resp.resp_key] = resp.value;
        }
        setValues(init);
        setDirty(new Set());
        setSaveStatus("idle");
        setLoading(false);
        // Set initial page
        if (payload.pages.length > 0) {
          setCurrentPageId(payload.pages[0].id);
        }
      })
      .catch((err) => {
        setError(err.message);
        setLoading(false);
      });
  }, [slug]);

  // ---- scrollspy ----
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
          a.boundingClientRect.top < b.boundingClientRect.top ? a : b,
        );
        setCurrentPageId(top.target.id);
      },
      { rootMargin: "-10% 0px -70% 0px", threshold: 0 },
    );
    els.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, [data]);

  // ---- build inline page tab data ----
  const selectSection = useCallback((id: string) => {
    setCurrentPageId(id);
    document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, []);

  const tabGroups = useMemo<PageTabGroup[]>(() => {
    if (!data) return [];
    // Group pages by nav_group
    const groupMap = new Map<string, Page[]>();
    const groupOrder: string[] = [];
    for (const page of data.pages) {
      const key = page.nav_group ?? "";
      if (!groupMap.has(key)) {
        groupMap.set(key, []);
        groupOrder.push(key);
      }
      groupMap.get(key)!.push(page);
    }

    // Build response lookup by page_id
    const respByPage = new Map<string, Response[]>();
    for (const resp of data.responses) {
      const pid = resp.page_id ?? "";
      if (!respByPage.has(pid)) respByPage.set(pid, []);
      respByPage.get(pid)!.push(resp);
    }

    return groupOrder.map((groupLabel) => {
      const pages = groupMap.get(groupLabel)!;
      return {
        label: groupLabel || undefined,
        items: pages.map((page) => {
          const pageResps = respByPage.get(page.id) ?? [];
          const total = pageResps.length;
          const answered = pageResps.filter((r) => {
            const val = values[r.resp_key] ?? r.value;
            return val.trim().length > 0;
          }).length;
          return {
            id: page.id,
            navTitle: page.nav_title,
            total: total > 0 ? total : undefined,
            answered: total > 0 ? answered : undefined,
          };
        }),
      };
    });
  }, [data, values]);

  // ---- response editing ----
  function handleChange(key: string, value: string) {
    setValues((prev) => ({ ...prev, [key]: value }));
    setDirty((prev) => new Set(prev).add(key));
    setSaveStatus("idle");
  }

  // ---- save to API ----
  async function handleSave() {
    if (!slug || dirty.size === 0) return;
    setSaving(true);
    const keys = Array.from(dirty);
    try {
      for (const key of keys) {
        const res = await fetch(
          `/api/docs/${encodeURIComponent(slug)}/responses/${encodeURIComponent(key)}`,
          {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ value: values[key] ?? "" }),
          },
        );
        if (!res.ok) throw new Error(`Save failed for ${key}: ${res.status}`);
      }
      setDirty(new Set());
      setSaveStatus("saved");
    } catch (err) {
      // On error, leave dirty set intact so user can retry
      console.error("Save error:", err);
    } finally {
      setSaving(false);
    }
  }

  // ---- render ----

  if (loading) {
    return (
      <section className="page">
        <h1>Loading...</h1>
      </section>
    );
  }

  if (error || !data) {
    return (
      <section className="page">
        <div className="dash-error">
          <h2>Failed to load document</h2>
          <p>{error ?? "Unknown error"}</p>
        </div>
      </section>
    );
  }

  // Build response lookup by page_id
  const respByPage = new Map<string, Response[]>();
  for (const resp of data.responses) {
    const pid = resp.page_id ?? "";
    if (!respByPage.has(pid)) respByPage.set(pid, []);
    respByPage.get(pid)!.push(resp);
  }

  const hasDirty = dirty.size > 0;

  return (
    <>
      {/* Inline page tabs — replaces sidebar page navigation */}
      {data.pages.length > 1 && (
        <div className="doc-tabs-wrap">
          {tabGroups.map((group, gi) => (
            <div key={group.label ?? gi} className="doc-tabs-group">
              {group.label && <span className="doc-tabs-label">{group.label}</span>}
              <div className="doc-tabs">
                {group.items.map((item) => (
                  <button
                    key={item.id}
                    type="button"
                    className={`doc-tab${item.id === currentPageId ? " cur" : ""}`}
                    onClick={() => selectSection(item.id)}
                  >
                    {item.navTitle}
                    {navMark(item)}
                  </button>
                ))}
              </div>
            </div>
          ))}
          {sectionsSummary(tabGroups)}
        </div>
      )}

      {data.pages.map((page) => (
        <PageSection
          key={page.id}
          page={page}
          responses={respByPage.get(page.id) ?? []}
          values={values}
          onChange={handleChange}
        />
      ))}
      <div className="savebar">
        {data.doc.foot && (
          <span className="stat">{data.doc.foot}</span>
        )}
        <span className={`stat ${hasDirty ? "unsaved" : saving ? "unsaved" : saveStatus === "saved" ? "saved" : ""}`}>
          {saving
            ? "Saving..."
            : hasDirty
              ? "Unsaved changes..."
              : saveStatus === "saved"
                ? "Saved"
                : `${data.doc.counts.answered}/${data.doc.counts.total} answered`}
        </span>
        <button type="button" onClick={handleSave} disabled={!hasDirty && !saving}>
          Save
        </button>
      </div>
    </>
  );
}
