import { NavLink } from "react-router-dom";
import { ThemeSelector } from "./ThemeSelector";

export interface SidebarSectionItem {
  id: string;
  navTitle: string;
  /** Answered/total question counts for this section, if it carries response
   * boxes. Omit (or leave total 0) for sections with nothing to answer —
   * they render with no badge, same as a page with zero .response boxes. */
  answered?: number;
  total?: number;
}

export interface SidebarSectionGroup {
  label?: string;
  items: SidebarSectionItem[];
}

function navMark(item: SidebarSectionItem) {
  if (!item.total) return null;
  const done = item.answered === item.total;
  return (
    <span className={`navmark ${done ? "done" : "todo"}`}>{done ? "✓" : `${item.answered ?? 0}/${item.total}`}</span>
  );
}

// One line at the foot of the section list: "Answered N/M sections", or a
// done variant once every scored section has no pending questions left.
// Sections with no .total (nothing to answer, e.g. a table-of-contents-only
// entry) don't count toward the denominator.
function sectionsSummary(sections: SidebarSectionGroup[]) {
  const scored = sections.flatMap((g) => g.items).filter((it) => (it.total ?? 0) > 0);
  if (scored.length === 0) return null;
  const done = scored.filter((it) => it.answered === it.total).length;
  return (
    <div className="navsummary">
      {done === scored.length ? (
        <span className="all-done">✓ all {scored.length} sections answered</span>
      ) : (
        `Answered ${done}/${scored.length} sections`
      )}
    </div>
  );
}

export interface SidebarProps {
  /** The current doc/report's own page sections (e.g. p0, p1, ...). Pages
   * that aren't a multi-page doc (dashboard, tracker, landings) omit this. */
  sections?: SidebarSectionGroup[];
  currentSectionId?: string;
  onSelectSection?: (id: string) => void;
}

const CATEGORIES = [
  { to: "/", label: "Dashboard", end: true },
  { to: "/tracker", label: "Tracker" },
  { to: "/prds", label: "PRDs" },
  { to: "/reports", label: "Reports" },
  { to: "/docs", label: "Docs" },
];

function navLinkClass({ isActive }: { isActive: boolean }): string {
  return isActive ? "cur" : "";
}

export function Sidebar({ sections, currentSectionId, onSelectSection }: SidebarProps) {
  return (
    <nav className="sidebar">
      <div className="brand">
        <span className="logo" />
        entropy-machines
      </div>

      <div className="grp">Categories</div>
      {CATEGORIES.map((cat) => (
        <NavLink key={cat.to} to={cat.to} end={cat.end} className={navLinkClass}>
          {cat.label}
        </NavLink>
      ))}

      {sections?.map((group, i) => (
        <div key={group.label ?? i}>
          {group.label && <div className="grp">{group.label}</div>}
          {group.items.map((item) => (
            <a
              key={item.id}
              href={`#${item.id}`}
              className={item.id === currentSectionId ? "cur" : ""}
              onClick={(ev) => {
                if (!onSelectSection) return;
                ev.preventDefault();
                onSelectSection(item.id);
              }}
            >
              {item.navTitle}
              {navMark(item)}
            </a>
          ))}
        </div>
      ))}

      {sections && sectionsSummary(sections)}

      <div className="foot">
        <ThemeSelector />
      </div>
    </nav>
  );
}
