// The 6-color system: every theme is exactly these six colors, each used
// at 100% opacity. No rgba(), no tints derived by lowering opacity — a
// different mood is a different hex value, not the same hex value made
// translucent.
//
// These are the SAME theme configs the old HTML templates carried inline
// in <script id="__theme-selector-patch"> (see lib/doc-template.html),
// plus `notice` (amber/warm) added to distinguish "needs attention" from
// "agent voice" — accent was doing double duty before this.
// Keeping the names and values identical means a reader's stored
// localStorage theme choice still resolves to the same colors here.
export interface Theme {
  bg: string;
  fg: string;
  accent: string;
  positive: string;
  negative: string;
  notice: string;
}

export type ThemeName = "janus-light" | "janus-dark" | "hc-dark" | "daylight" | "daylight-dark";

export const THEMES: Record<ThemeName, Theme> = {
  "janus-light": { bg: "#faf9fc", fg: "#18181b", accent: "#7c3aed", positive: "#0A5C21", negative: "#b91c1c", notice: "#b45309" },
  "janus-dark": { bg: "#0a0a0d", fg: "#fafafa", accent: "#a78bfa", positive: "#23D18B", negative: "#ef4444", notice: "#f59e0b" },
  "hc-dark": { bg: "#000000", fg: "#ffffff", accent: "#21A6FF", positive: "#23D18B", negative: "#F48771", notice: "#FFD700" },
  daylight: { bg: "#FAF8F4", fg: "#23262E", accent: "#2A5DB0", positive: "#0B6E5A", negative: "#8C1D18", notice: "#9A6700" },
  "daylight-dark": { bg: "#14161A", fg: "#E6E3DC", accent: "#7FB2F0", positive: "#34A98D", negative: "#FF8C82", notice: "#FBBF24" },
};

export const THEME_NAMES = Object.keys(THEMES) as ThemeName[];

export const DEFAULT_THEME: ThemeName = "janus-dark";

export const THEME_STORAGE_KEY = "entropy-machines-theme";

export function isThemeName(value: string): value is ThemeName {
  return Object.prototype.hasOwnProperty.call(THEMES, value);
}

// The one place style.setProperty() is called for theme colors. No CSS
// var(--x, fallback) anywhere — the six custom properties always carry a
// real value because this runs before anything reads them (see the inline
// script in index.html for the pre-React application of the stored theme).
export function applyTheme(name: ThemeName): void {
  const theme = THEMES[name];
  const root = document.documentElement.style;
  root.setProperty("--bg", theme.bg);
  root.setProperty("--fg", theme.fg);
  root.setProperty("--accent", theme.accent);
  root.setProperty("--positive", theme.positive);
  root.setProperty("--negative", theme.negative);
  root.setProperty("--notice", theme.notice);
}
