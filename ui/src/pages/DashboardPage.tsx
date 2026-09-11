import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

// ---------------------------------------------------------------------------
// Types — mirror the JSON shapes from lib/api.py.
// ---------------------------------------------------------------------------

interface Issue {
  id: string;
  title: string;
  status: string;
  effort?: string;
  blocked_by: string[];
  claimed_by?: string;
  claimed_at?: string;
}

interface Doc {
  id: string;
  counts: { total: number; answered: number };
}

interface IssueNote {
  id: number;
  issue_id: string;
  type: string;
  author: string | null;
  content: string;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Fetch helpers
// ---------------------------------------------------------------------------

async function fetchJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const msg = (body as { error?: string }).error ?? res.statusText;
    throw new Error(msg);
  }
  return res.json() as Promise<T>;
}

/** Fetch notes across all issues and merge/sort by created_at descending. */
async function fetchRecentEvents(issues: Issue[]): Promise<IssueNote[]> {
  if (issues.length === 0) return [];
  const batches = await Promise.all(
    issues.map((iss) =>
      fetchJson<IssueNote[]>(`/api/issues/${encodeURIComponent(iss.id)}/events`)
    )
  );
  const all = batches.flat();
  all.sort((a, b) => (b.created_at ?? "").localeCompare(a.created_at ?? ""));
  return all.slice(0, 30);
}

// ---------------------------------------------------------------------------
// Small presentational helpers
// ---------------------------------------------------------------------------

function EmptyRow({ cols, children }: { cols: number; children: React.ReactNode }) {
  return (
    <tr>
      <td colSpan={cols} className="dash-empty">
        {children}
      </td>
    </tr>
  );
}

function ErrorBanner({ message }: { message: string }) {
  const isMigrate = /no database|migrate-db/i.test(message);
  return (
    <section className="dash-error">
      <h2>API unreachable</h2>
      {isMigrate ? (
        <p>
          The database has not been created yet. Run{" "}
          <code>bin/migrate-db</code> to initialise it.
        </p>
      ) : (
        <p>{message}</p>
      )}
    </section>
  );
}

function formatTimestamp(ts: string): string {
  if (!ts) return "";
  // Show date + time, drop the trailing Z for display.
  return ts.replace("T", " ").replace("Z", "");
}

// ---------------------------------------------------------------------------
// DashboardPage
// ---------------------------------------------------------------------------

export function DashboardPage() {
  const [readyIssues, setReadyIssues] = useState<Issue[]>([]);
  const [claims, setClaims] = useState<Issue[]>([]);
  const [docs, setDocs] = useState<Doc[]>([]);
  const [events, setEvents] = useState<IssueNote[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        // Fetch issues (all) and docs in parallel.
        const [allIssues, docsResult] = await Promise.all([
          fetchJson<Issue[]>("/api/issues"),
          fetchJson<Doc[]>("/api/docs"),
        ]);

        if (cancelled) return;

        // Ready issues: open status with no blockers remaining.
        const ready = allIssues.filter(
          (i) => i.status === "open" && i.blocked_by.length === 0
        );

        // In-flight: status === "progress".
        const inFlight = allIssues.filter((i) => i.status === "progress");

        // Recent events: fetch notes across all issues.
        const notes = await fetchRecentEvents(allIssues);

        if (cancelled) return;

        setReadyIssues(ready);
        setClaims(inFlight);
        setDocs(docsResult);
        setEvents(notes);
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
  }, []);

  if (loading) {
    return (
      <section className="page">
        <h1>Dashboard</h1>
        <p className="sub">Loading...</p>
      </section>
    );
  }

  if (error) {
    return (
      <section className="page">
        <h1>Dashboard</h1>
        <ErrorBanner message={error} />
      </section>
    );
  }

  return (
    <section className="page">
      <h1>Dashboard</h1>

      {/* ---- Ready issues ---- */}
      <h2>Ready</h2>
      <div className="tbl-wrap">
        <table>
          <thead>
            <tr>
              <th>id</th>
              <th>title</th>
              <th>effort</th>
            </tr>
          </thead>
          <tbody>
            {readyIssues.length === 0 ? (
              <EmptyRow cols={3}>
                Nothing ready &mdash; every issue is done, blocked, held, or
                gated.
              </EmptyRow>
            ) : (
              readyIssues.map((iss) => (
                <tr key={iss.id}>
                  <td className="mono">{iss.id}</td>
                  <td>{iss.title}</td>
                  <td className="mono">{iss.effort ?? ""}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* ---- In-flight claims ---- */}
      <h2>In flight</h2>
      <div className="tbl-wrap">
        <table>
          <thead>
            <tr>
              <th>issue</th>
              <th>claimed by</th>
            </tr>
          </thead>
          <tbody>
            {claims.length === 0 ? (
              <EmptyRow cols={2}>
                Nothing dispatched right now (or every dispatch has been handed
                off).
              </EmptyRow>
            ) : (
              claims.map((iss) => (
                <tr key={iss.id}>
                  <td className="mono">
                    <Link to="/tracker">{iss.id}</Link>
                  </td>
                  <td className="mono">{iss.claimed_by ?? ""}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* ---- Docs with answered counts ---- */}
      <h2>Docs</h2>
      <div className="tbl-wrap">
        <table>
          <thead>
            <tr>
              <th>doc</th>
              <th>answered</th>
            </tr>
          </thead>
          <tbody>
            {docs.length === 0 ? (
              <EmptyRow cols={2}>No docs registered yet.</EmptyRow>
            ) : (
              docs.map((d) => {
                const { total, answered } = d.counts;
                let status: string;
                let statusClass = "";
                if (total === 0) {
                  status = "no questions";
                  statusClass = "dash-empty";
                } else if (answered >= total) {
                  status = `${answered}/${total} answered`;
                  statusClass = "dash-positive";
                } else {
                  status = `${answered}/${total} answered`;
                  statusClass = "dash-accent";
                }
                return (
                  <tr key={d.id}>
                    <td>
                      <Link to={`/docs/${encodeURIComponent(d.id)}`}>
                        {d.id}
                      </Link>
                    </td>
                    <td className={statusClass}>{status}</td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* ---- Recent events ---- */}
      <h2>Recent events</h2>
      <div className="tbl-wrap">
        <table>
          <thead>
            <tr>
              <th>timestamp</th>
              <th>type</th>
              <th>issue</th>
              <th>author</th>
            </tr>
          </thead>
          <tbody>
            {events.length === 0 ? (
              <EmptyRow cols={4}>No notes recorded yet.</EmptyRow>
            ) : (
              events.map((ev) => (
                <tr key={`${ev.issue_id}-${ev.id}`}>
                  <td className="mono">
                    {formatTimestamp(ev.created_at)}
                  </td>
                  <td className="mono">{ev.type}</td>
                  <td className="mono">{ev.issue_id}</td>
                  <td className="mono">{ev.author ?? ""}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
