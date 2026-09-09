import { useState, useCallback } from "react";
import { Link, NavLink } from "react-router-dom";
import { SettingsModal } from "./SettingsModal";

const NAV_LINKS = [
  { to: "/tracker", label: "Issues" },
  { to: "/prds", label: "PRDs" },
  { to: "/docs", label: "Docs" },
  { to: "/reports", label: "Reports" },
];

function navLinkClass({ isActive }: { isActive: boolean }): string {
  return "topnav-link" + (isActive ? " cur" : "");
}

export function TopNav() {
  const [settingsOpen, setSettingsOpen] = useState(false);
  const closeSettings = useCallback(() => setSettingsOpen(false), []);

  return (
    <>
      <nav className="topnav">
        <Link to="/" className="topnav-brand">
          <span className="logo" />
          entropy machines
        </Link>
        <div className="topnav-links">
          {NAV_LINKS.map((link) => (
            <NavLink key={link.to} to={link.to} className={navLinkClass}>
              {link.label}
            </NavLink>
          ))}
        </div>
        <button
          type="button"
          className="topnav-gear"
          title="Settings"
          onClick={() => setSettingsOpen(true)}
        >
          &#9881;
        </button>
      </nav>
      <SettingsModal open={settingsOpen} onClose={closeSettings} />
    </>
  );
}
