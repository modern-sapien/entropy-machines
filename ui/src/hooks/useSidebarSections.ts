import { useSyncExternalStore } from "react";
import type { SidebarSectionGroup } from "../components/Sidebar";

export interface SidebarSectionsState {
  sections: SidebarSectionGroup[];
  currentSectionId?: string;
  onSelectSection?: (id: string) => void;
}

const EMPTY: SidebarSectionsState = { sections: [] };
let current: SidebarSectionsState = EMPTY;
const listeners = new Set<() => void>();

function emit() {
  for (const fn of listeners) fn();
}

function subscribe(fn: () => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

function getSnapshot(): SidebarSectionsState {
  return current;
}

export function setSidebarSections(state: SidebarSectionsState): void {
  current = state;
  emit();
}

export function clearSidebarSections(): void {
  current = EMPTY;
  emit();
}

export function useSidebarSections(): SidebarSectionsState {
  return useSyncExternalStore(subscribe, getSnapshot);
}
