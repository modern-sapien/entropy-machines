import { useEffect, useState } from "react";

interface Issue {
  id: string;
  title: string;
  status: string;
  source_doc: string | null;
  blocked_by: string[];
  claimed_by: string | null;
  claimed_at: string | null;
  effort?: string | null;
  created_at: string | null;
  updated_at: string | null;
}

type Filter = "all" | "open" | "progress" | "review" | "done";

const FILTERS: { key: Filter; label: string }[] = [
  { key: "all", label: "All" },
  { key: "open", label: "Open" },
  { key: "progress", label: "In Progress" },
  { key: "review", label: "Review" },
  { key: "done", label: "Done" },
];

function statusClass(status: string): string {
  switch (status) {
    case "progress":
      return "tracker-status-progress";
    case "done":
      return "tracker-status-done";
    default:
      return "";
  }
}

export function TrackerPage() {
  const [issues, setIssues] = useState<Issue[]>([]);
  const [filter, setFilter] = useState<Filter>("all");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetch("/api/issues")
      .then((res) => {
        if (!res.ok) throw new Error(`${res.status}`);
        return res.json();
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
            "Could not reach the issue API. Is the server running? If the database does not exist yet, run bin/migrate-db to create it.",
          );
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const filtered =
    filter === "all" ? issues : issues.filter((i) => i.status === filter);

  return (
    <section className="page">
      <h1>Tracker</h1>

      {loading && <p className="sub">Loading issues...</p>}

      {error && <p className="tracker-error">{error}</p>}

      {!loading && !error && (
        <>
          <div className="tracker-bar">
            <div className="tracker-filters">
              {FILTERS.map((f) => (
                <button
                  key={f.key}
                  className={
                    "tracker-filter" + (filter === f.key ? " cur" : "")
                  }
                  onClick={() => setFilter(f.key)}
                >
                  {f.label}
                </button>
              ))}
            </div>
            <span className="tracker-count">
              Showing {filtered.length} of {issues.length} issues
            </span>
          </div>

          {filtered.length === 0 ? (
            <p className="tracker-empty">No issues match this filter.</p>
          ) : (
            <div className="tbl-wrap">
              <table className="tracker-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Title</th>
                    <th>Status</th>
                    {issues.some((i) => i.effort) && <th>Effort</th>}
                    <th>Claimed</th>
                    <th>Blocked By</th>
                  </tr>
                </thead>
                <tbody>
                  {filtered.map((issue) => (
                    <tr key={issue.id}>
                      <td>
                        <code className="tracker-id">{issue.id}</code>
                      </td>
                      <td>{issue.title}</td>
                      <td>
                        <span className={statusClass(issue.status)}>
                          {issue.status}
                        </span>
                      </td>
                      {issues.some((i) => i.effort) && (
                        <td>{issue.effort || ""}</td>
                      )}
                      <td>{issue.claimed_by || ""}</td>
                      <td>
                        {issue.blocked_by.length > 0 && (
                          <span className="tracker-blockers">
                            {issue.blocked_by.map((dep) => (
                              <span key={dep} className="tracker-chip">
                                {dep}
                              </span>
                            ))}
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </section>
  );
}
