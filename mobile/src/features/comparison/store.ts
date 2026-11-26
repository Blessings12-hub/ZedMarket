import { useSyncExternalStore } from 'react';
import { toggleCompare } from './domain';

// The list lives in memory for the session. Nothing sensitive, nothing stored on the phone.
let ids: string[] = [];
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function toggle(id: string): boolean {
  const r = toggleCompare(ids, id);
  ids = r.ids;
  emit();
  return r.full;
}
export const clear = () => { ids = []; emit(); };
export const remove = (id: string) => { ids = ids.filter((x) => x !== id); emit(); };
export function useCompare(): string[] {
  return useSyncExternalStore((cb) => { listeners.add(cb); return () => { listeners.delete(cb); }; }, () => ids, () => ids);
}
