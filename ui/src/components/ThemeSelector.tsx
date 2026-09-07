import type { ChangeEvent } from "react";
import { useTheme } from "../hooks/useTheme";

export function ThemeSelector() {
  const { theme, setTheme, themeNames } = useTheme();

  function onChange(ev: ChangeEvent<HTMLSelectElement>) {
    const next = ev.target.value;
    if (themeNames.includes(next as (typeof themeNames)[number])) {
      setTheme(next as (typeof themeNames)[number]);
    }
  }

  return (
    <select className="theme-selector" title="Theme" value={theme} onChange={onChange}>
      {themeNames.map((name) => (
        <option key={name} value={name}>
          {name.replace(/-/g, " ")}
        </option>
      ))}
    </select>
  );
}
