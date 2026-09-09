import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

export type LandingKind = "prds" | "docs" | "reports";

const TITLES: Record<LandingKind, string> = {
  prds: "PRDs",
  docs: "Docs",
  reports: "Reports",
};

const TYPE_MAP: Record<LandingKind, string> = {
  prds: "prd",
  docs: "doc",
  reports: "report",
};

// ---------------------------------------------------------------------------
// Types — mirror the doc shape from GET /api/docs (lib/api.py).
// ---------------------------------------------------------------------------

interface DocEntry {
  id: string;
  title: string;
  short_name: string;
  type: string;
  status: string;
  foot: string;
  created_at: string | null;
  updated_at: string | null;
  counts: { total: number; answered: number };
}

// ---------------------------------------------------------------------------
// Presentational helpers
// ---------------------------------------------------------------------------

function statusClass(status: string): string {
  switch (status) {
    case "in-review":
      return "dash-accent";
    case "answered":
    case "closed":
      return "dash-positive";
    default:
      return "";
  }
}

function answeredClass(total: number, answered: number): string {
  if (total === 0) return "";
  if (answered >= total) return "dash-positive";
  if (answered > 0) return "dash-accent";
  return "";
}

function formatTimestamp(ts: string | null): string {
  if (!ts) return "";
  return ts.replace("T", " ").replace("Z", "");
}

// ---------------------------------------------------------------------------
// LandingPage
// ---------------------------------------------------------------------------

export function LandingPage({ kind }: { kind: LandingKind }) {
  const [entries, setEntries] = useState<DocEntry[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const title = TITLES[kind];
  const typeFilter = TYPE_MAP[kind];

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    fetch("/api/docs")
      .then((res) => {
        if (!res.ok) throw new Error(`${res.status}`);
        return res.json();
      })
      .then((data: DocEntry[]) => {
        if (!cancelled) {
          setEntries(data.filter((d) => d.type === typeFilter));
          setError(null);
          setLoading(false);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setError(
            "Could not reach the docs API. Is the server running? If the database does not exist yet, run bin/migrate-db to create it.",
          );
          setLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [typeFilter]);

  return (
    <section className="page">
      <h1>{title}</h1>

      {loading && <p className="sub">Loading...</p>}

      {error && (
        <section className="dash-error">
          <h2>API unreachable</h2>
          <p>{error}</p>
        </section>
      )}

      {!loading && !error && entries.length === 0 && (
        <p
          className="dash-empty"
          style={{
            border: "1px solid var(--accent)",
            padding: "24px 16px",
            textAlign: "center",
          }}
        >
          No {title.toLowerCase()} yet.
        </p>
      )}

      {!loading && !error && entries.length > 0 && (
        <div className="tbl-wrap">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Title</th>
                <th>Status</th>
                <th>Answered</th>
                <th>Updated</th>
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => {
                const { total, answered } = entry.counts;
                const linkPath =
                  kind === "reports"
                    ? `/reports/${encodeURIComponent(entry.id)}`
                    : `/${kind}/${encodeURIComponent(entry.id)}`;

                return (
                  <tr key={entry.id}>
                    <td className="mono">
                      <Link to={linkPath}>{entry.short_name}</Link>
                    </td>
                    <td>{entry.title}</td>
                    <td>
                      <span className={statusClass(entry.status)}>
                        {entry.status}
                      </span>
                    </td>
                    <td className={answeredClass(total, answered)}>
                      {total > 0 ? `${answered}/${total} answered` : ""}
                    </td>
                    <td className="mono">{formatTimestamp(entry.updated_at)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
