import { NavLink } from "react-router-dom";
import { ThemeSelector } from "./ThemeSelector";

export interface SidebarSectionItem {
  id: string;
  navTitle: string;
}

export interface SidebarSectionGroup {
  label?: string;
  items: SidebarSectionItem[];
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
            </a>
          ))}
        </div>
      ))}

      <div className="foot">
        <ThemeSelector />
      </div>
    </nav>
  );
}
