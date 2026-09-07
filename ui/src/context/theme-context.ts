import { createContext } from "react";
import type { ThemeName } from "../data/themes";

export interface ThemeContextValue {
  theme: ThemeName;
  setTheme: (name: ThemeName) => void;
  themeNames: ThemeName[];
}

export const ThemeContext = createContext<ThemeContextValue | null>(null);
