import { useCallback, useState, type ReactNode } from "react";
import {
  applyTheme,
  DEFAULT_THEME,
  isThemeName,
  THEME_NAMES,
  THEME_STORAGE_KEY,
  type ThemeName,
} from "../data/themes";
import { ThemeContext } from "./theme-context";

function readStoredTheme(): ThemeName {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (stored && isThemeName(stored)) return stored;
  } catch {
    // localStorage unavailable (private mode, etc.) — fall through to default.
  }
  return DEFAULT_THEME;
}

// Assumes the inline script in index.html has already applied the stored
// (or default) theme via style.setProperty() before React mounts — that is
// what prevents the theme flash. This reads the same storage key so its
// state agrees with what is already on <html>.
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<ThemeName>(readStoredTheme);

  const setTheme = useCallback((name: ThemeName) => {
    applyTheme(name);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, name);
    } catch {
      // Best-effort persistence; the in-memory state below still updates.
    }
    setThemeState(name);
  }, []);

  return (
    <ThemeContext.Provider value={{ theme, setTheme, themeNames: THEME_NAMES }}>
      {children}
    </ThemeContext.Provider>
  );
}
