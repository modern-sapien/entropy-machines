// ============================================================================
// ExportButton — snapshots the current page as a standalone .html file.
//
// Captures: page content, all response-box values (current textarea text),
// reply threads, and the active theme (CSS custom properties baked in).
// Output is a single self-contained HTML file with all CSS inlined.
//
// File save uses the File System Access API (showSaveFilePicker) when
// available, falling back to a blob-URL + temporary anchor click.
//
// Integration: place inside the .savebar div in DocPage or SprintReportPage:
//   import { ExportButton } from "../components/ExportButton";
//   ...
//   <div className="savebar">
//     ...
//     <ExportButton title={doc.title} />
//     <button ...>Save</button>
//   </div>
// ============================================================================

import "./ExportButton.css";

// ---- theme + CSS collection -------------------------------------------------

const THEME_PROPS = [
  "--bg", "--fg", "--accent", "--positive", "--negative", "--notice",
  "--font", "--mono",
];

function readThemeValues(): Record<string, string> {
  const computed = getComputedStyle(document.documentElement);
  const values: Record<string, string> = {};
  for (const prop of THEME_PROPS) {
    values[prop] = computed.getPropertyValue(prop).trim();
  }
  return values;
}

function collectStylesheetRules(): string {
  const parts: string[] = [];
  for (const sheet of Array.from(document.styleSheets)) {
    try {
      for (const rule of Array.from(sheet.cssRules)) {
        parts.push(rule.cssText);
      }
    } catch {
      // CORS-restricted or otherwise inaccessible — skip.
    }
  }
  return parts.join("\n");
}

// ---- DOM cloning ------------------------------------------------------------

function clonePageContent(): HTMLElement | null {
  const main = document.querySelector("main");
  if (!main) return null;

  const clone = main.cloneNode(true) as HTMLElement;

  // cloneNode does not sync the live .value of textareas. Set each
  // clone's textContent so the current answer persists in serialised HTML.
  const origTextareas = main.querySelectorAll("textarea");
  const cloneTextareas = clone.querySelectorAll("textarea");
  for (let i = 0; i < origTextareas.length; i++) {
    cloneTextareas[i].textContent = origTextareas[i].value;
    cloneTextareas[i].setAttribute("readonly", "");
  }

  // Strip interactive elements that are non-functional in a static snapshot.
  clone.querySelector(".savebar")?.remove();
  for (const toggle of Array.from(clone.querySelectorAll(".__chain-toggle"))) {
    toggle.remove();
  }

  return clone;
}

// ---- HTML generation --------------------------------------------------------

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function buildStandaloneHtml(content: HTMLElement, title: string): string {
  const themeValues = readThemeValues();
  const css = collectStylesheetRules();

  const rootVars = Object.entries(themeValues)
    .map(([prop, val]) => `  ${prop}: ${val};`)
    .join("\n");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
:root {
${rootVars}
}
${css}
/* Export snapshot overrides — no topnav in the standalone file */
main { padding-top: 14px !important; }
.doc-sidebar { top: 0; height: 100vh; }
</style>
</head>
<body>
${content.outerHTML}
</body>
</html>`;
}

// ---- file save --------------------------------------------------------------

async function saveHtmlFile(html: string, filename: string): Promise<void> {
  const blob = new Blob([html], { type: "text/html" });

  // Prefer the File System Access API when the browser supports it.
  if ("showSaveFilePicker" in window) {
    try {
      const handle = await (
        window as unknown as Record<string, Function>
      ).showSaveFilePicker({
        suggestedName: filename,
        types: [
          { description: "HTML files", accept: { "text/html": [".html"] } },
        ],
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      return;
    } catch (err) {
      if ((err as DOMException).name === "AbortError") return;
      // Fall through to the anchor-click fallback.
    }
  }

  // Fallback: create a blob URL and click a temporary anchor element.
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  URL.revokeObjectURL(url);
}

// ---- public export function (also usable outside the button) ----------------

export async function exportPageToHtml(title: string): Promise<void> {
  const content = clonePageContent();
  if (!content) return;

  const html = buildStandaloneHtml(content, title);
  const filename =
    title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/-+$/, "") + ".html";

  await saveHtmlFile(html, filename);
}

// ---- React component --------------------------------------------------------

interface ExportButtonProps {
  title: string;
}

export function ExportButton({ title }: ExportButtonProps) {
  async function handleClick() {
    await exportPageToHtml(title);
  }

  return (
    <button
      type="button"
      className="export-btn"
      title="Export to HTML"
      onClick={handleClick}
    >
      <svg
        width="14"
        height="14"
        viewBox="0 0 14 14"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        style={{ verticalAlign: "-2px", marginRight: "5px" }}
      >
        <path d="M7 1v9M3.5 7L7 10.5 10.5 7" />
        <path d="M2 12h10" />
      </svg>
      Export
    </button>
  );
}
