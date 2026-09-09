import { useEffect, useRef } from "react";
import { ThemeSelector } from "./ThemeSelector";

interface SettingsModalProps {
  open: boolean;
  onClose: () => void;
}

export function SettingsModal({ open, onClose }: SettingsModalProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  // Close on Escape key
  useEffect(() => {
    if (!open) return;
    function handleKey(ev: KeyboardEvent) {
      if (ev.key === "Escape") onClose();
    }
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [open, onClose]);

  if (!open) return null;

  function handleBackdropClick(ev: React.MouseEvent) {
    // Close only when clicking the backdrop, not the panel itself
    if (panelRef.current && !panelRef.current.contains(ev.target as Node)) {
      onClose();
    }
  }

  return (
    <div className="settings-backdrop" onClick={handleBackdropClick}>
      <div className="settings-modal" ref={panelRef}>
        <div className="settings-header">
          <h2>Settings</h2>
          <button
            type="button"
            className="settings-close"
            onClick={onClose}
            title="Close settings"
          >
            &times;
          </button>
        </div>
        <div className="settings-body">
          <label className="settings-label">Theme</label>
          <ThemeSelector />
        </div>
      </div>
    </div>
  );
}
