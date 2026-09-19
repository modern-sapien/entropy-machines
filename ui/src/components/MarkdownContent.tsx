import type { Components } from "react-markdown";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

// ---- Markdown rendering with GFM admonitions and pill badges ---------------

const ADMONITION_TYPES: Record<string, { label: string; color: string }> = {
  NOTE: { label: "Note", color: "var(--accent)" },
  WARNING: { label: "Warning", color: "var(--notice)" },
  TIP: { label: "Tip", color: "var(--positive)" },
  CAUTION: { label: "Caution", color: "var(--negative)" },
  IMPORTANT: { label: "Important", color: "var(--accent)" },
};

const PILL_RE = /^\[([SML])\]$/;

/** Parse GFM-style admonition blockquotes (> [!TYPE]\n> body). Returns the
 *  admonition type and cleaned children, or null if the blockquote isn't one. */
function parseAdmonition(children: React.ReactNode): { type: string; label: string; color: string; bold: boolean; body: React.ReactNode[] } | null {
  const childArray = Array.isArray(children) ? children : [children];
  // The first child of a GFM admonition blockquote rendered by react-markdown
  // is a <p> whose text starts with [!TYPE]
  const first = childArray[0];
  if (!first || typeof first !== "object" || !("props" in first)) return null;
  const pChildren = first.props.children;
  const textParts: string[] = [];
  const walk = (node: React.ReactNode) => {
    if (typeof node === "string") textParts.push(node);
    else if (Array.isArray(node)) node.forEach(walk);
  };
  walk(pChildren);
  const fullText = textParts.join("");
  const match = fullText.match(/^\[!(\w+)\]\s*/);
  if (!match) return null;
  const typeName = match[1].toUpperCase();
  const info = ADMONITION_TYPES[typeName];
  if (!info) return null;

  // Strip the [!TYPE] prefix from the first paragraph's children
  const stripPrefix = (node: React.ReactNode): React.ReactNode => {
    if (typeof node === "string") {
      const idx = node.indexOf(match[0]);
      if (idx >= 0) return node.slice(idx + match[0].length);
      return node;
    }
    if (Array.isArray(node)) {
      let found = false;
      return node.map((child) => {
        if (found) return child;
        const result = stripPrefix(child);
        if (result !== child) found = true;
        return result;
      });
    }
    return node;
  };

  // Rebuild the first <p> without the [!TYPE] prefix
  const strippedFirst = { ...first, props: { ...first.props, children: stripPrefix(pChildren) } };
  const body = [strippedFirst, ...childArray.slice(1)];
  return { type: typeName, label: info.label, color: info.color, bold: typeName === "IMPORTANT", body };
}

/** Render inline pill badges for standalone [S], [M], [L] text. */
function renderPillText(text: string): React.ReactNode {
  const parts: React.ReactNode[] = [];
  let lastIndex = 0;
  // Match standalone [S], [M], [L] tokens
  const re = /(?:^|\s)\[([SML])\](?=\s|$)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const before = text.slice(lastIndex, m.index);
    if (before) parts.push(before);
    // Include any leading whitespace
    const leadingSpace = m[0].startsWith(" ") || m[0].startsWith("\t") ? m[0][0] : "";
    if (leadingSpace) parts.push(leadingSpace);
    parts.push(
      <span key={m.index} className="pill-badge">{m[1]}</span>
    );
    lastIndex = m.index + m[0].length;
  }
  if (parts.length === 0) return text;
  const rest = text.slice(lastIndex);
  if (rest) parts.push(rest);
  return <>{parts}</>;
}

const markdownComponents: Components = {
  blockquote({ children, node: _node, ref: _ref, ...props }) {
    const admonition = parseAdmonition(children);
    if (admonition) {
      return (
        <div
          className="md-admonition"
          style={{ borderLeftColor: admonition.color }}
        >
          <div
            className="md-admonition-label"
            style={{
              color: admonition.color,
              fontWeight: admonition.bold ? 700 : 600,
            }}
          >
            {admonition.label}
          </div>
          <div className="md-admonition-body">{admonition.body}</div>
        </div>
      );
    }
    return <blockquote {...props}>{children}</blockquote>;
  },
  p({ children, node: _node, ...props }) {
    // Check for standalone pill badges
    if (typeof children === "string" && PILL_RE.test(children.trim())) {
      return (
        <p {...props}>
          <span className="pill-badge">{children.trim().slice(1, -1)}</span>
        </p>
      );
    }
    // Handle mixed text with pill badges
    if (typeof children === "string") {
      return <p {...props}>{renderPillText(children)}</p>;
    }
    // Process arrays of children
    if (Array.isArray(children)) {
      const processed = children.map((child, i) =>
        typeof child === "string" ? <span key={i}>{renderPillText(child)}</span> : child
      );
      return <p {...props}>{processed}</p>;
    }
    return <p {...props}>{children}</p>;
  },
};

export function MarkdownContent({ content }: { content: string }) {
  return (
    <div className="md-content">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
        {content}
      </ReactMarkdown>
    </div>
  );
}
