-- entropy-machines SQLite schema.
--
-- Source of truth for this DDL is the "Database design" page of the React
-- migration PRD (entropy-machines-docs/PRD-006-react-migration.html, page
-- p3 — search that file for id="p3"). Column-for-column identical to the
-- <pre><code> block on that page; the only additions here are the indexes
-- at the bottom, which change nothing about the shape, only lookup speed.
--
-- Populated by lib/migrate_db.py (bin/migrate-db) from the pre-React data:
-- entropy-machines-docs/*.html (dialogue docs), .entropy-machines/issues.json
-- (issues + notes log), and entropy-machines-docs/manifest.json (per-doc
-- status/version bookkeeping). Output lives at
-- .entropy-machines/entropy-machines.db, alongside issues.json — see the
-- PRD page for why SQLite and why that path.

PRAGMA foreign_keys = ON;

-- Core content
CREATE TABLE IF NOT EXISTS docs (
  id          TEXT PRIMARY KEY,   -- "PRD-002-dialogue-workflow"
  title       TEXT NOT NULL,      -- "PRD-002 — How dialogue docs are worked through"
  short_name  TEXT NOT NULL,      -- "PRD-002"
  type        TEXT NOT NULL,      -- "prd" | "report" | "doc"
  status      TEXT DEFAULT 'open',-- "open" | "in-review" | "answered" | "closed"
  foot        TEXT,               -- footer guidance text
  created_at  TEXT,
  updated_at  TEXT
);

CREATE TABLE IF NOT EXISTS pages (
  id          TEXT NOT NULL,      -- "p0", "p1", ...
  doc_id      TEXT REFERENCES docs(id),
  position    INTEGER NOT NULL,   -- ordering
  nav_group   TEXT,               -- "Context", "Open questions", etc.
  nav_title   TEXT NOT NULL,      -- "What a dialogue doc is"
  heading     TEXT NOT NULL,
  subtitle    TEXT,
  content     TEXT NOT NULL,      -- HTML body of the page
  PRIMARY KEY (doc_id, id)
);

-- Response / conversation
CREATE TABLE IF NOT EXISTS responses (
  id          INTEGER PRIMARY KEY,
  doc_id      TEXT REFERENCES docs(id),
  page_id     TEXT,               -- matches pages.id
  resp_key    TEXT NOT NULL,      -- "p0-key-question" (stable identity)
  label       TEXT,               -- "Your overall read"
  discuss     TEXT,               -- the discussion prompt HTML
  value       TEXT DEFAULT '',    -- the owner's answer
  updated_at  TEXT,
  UNIQUE(doc_id, resp_key)
);

-- Agent replies (the conversation thread)
CREATE TABLE IF NOT EXISTS replies (
  id          INTEGER PRIMARY KEY,
  response_id INTEGER REFERENCES responses(id),
  author      TEXT NOT NULL,      -- "agent" | "owner"
  content     TEXT NOT NULL,
  created_at  TEXT
);

-- Issues (replaces issues.json)
CREATE TABLE IF NOT EXISTS issues (
  id          TEXT PRIMARY KEY,   -- "i-react-scaffold"
  title       TEXT NOT NULL,
  status      TEXT DEFAULT 'open',-- "open" | "progress" | "review" | "done"
  source_doc  TEXT REFERENCES docs(id),  -- PRD/report/doc that created this issue (optional)
  blocked_by  TEXT,               -- JSON array of issue ids
  claimed_by  TEXT,
  claimed_at  TEXT,
  created_at  TEXT,
  updated_at  TEXT
);

-- Issue notes (replaces the notes log)
CREATE TABLE IF NOT EXISTS issue_notes (
  id          INTEGER PRIMARY KEY,
  issue_id    TEXT REFERENCES issues(id),
  type        TEXT NOT NULL,      -- "dispatch" | "handoff" | "comment"
  author      TEXT,
  content     TEXT NOT NULL,
  created_at  TEXT
);

-- Settings (replaces localStorage for theme, replaces manifest.json)
CREATE TABLE IF NOT EXISTS settings (
  key         TEXT PRIMARY KEY,   -- "theme", "doc:PRD-002:version", etc.
  value       TEXT
);

-- Indexes — lookup speed only, no change to the shape above.
CREATE INDEX IF NOT EXISTS idx_pages_doc_id       ON pages(doc_id);
CREATE INDEX IF NOT EXISTS idx_responses_doc_id   ON responses(doc_id);
CREATE INDEX IF NOT EXISTS idx_replies_response   ON replies(response_id);
CREATE INDEX IF NOT EXISTS idx_issues_source_doc  ON issues(source_doc);
CREATE INDEX IF NOT EXISTS idx_issue_notes_issue  ON issue_notes(issue_id);
