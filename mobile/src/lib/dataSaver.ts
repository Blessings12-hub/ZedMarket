import { useSyncExternalStore } from 'react';

import { getFlag, setFlag } from './flags';

// Data saver: while it is on, lists show a plain card instead of loading every photo, and a listing opens with its
// first photo only. Photos are loaded when the person asks. It is kept on the phone, per phone.
let on = false;
const listeners = new Set<() => void>();
let started = false;

function emit() {
  listeners.forEach((l) => l());
}

export async function loadDataSaver(): Promise<void> {
  if (started) return;
  started = true;
  on = (await getFlag('data_saver')) === true;
  emit();
}

export async function setDataSaver(value: boolean): Promise<void> {
  on = value;
  emit();
  await setFlag('data_saver', value);
}

export function useDataSaver(): boolean {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => on,
    () => false,
  );
}
