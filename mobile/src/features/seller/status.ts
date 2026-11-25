import { useSyncExternalStore } from 'react';

import { NO_ACCESS, toSellerStatus, type SellingAccess } from '../../domain/sellerAccess';
import { supabase } from '../../lib/supabase';

// One shared answer to "is this person an approved seller?", so the bottom bar, the Account Hub and every selling
// screen agree. It only controls what is shown. The database still refuses selling actions from anyone not approved.
type Snapshot = { access: SellingAccess; loaded: boolean; failed: boolean };

let snapshot: Snapshot = { access: NO_ACCESS, loaded: false, failed: false };
const listeners = new Set<() => void>();

function set(next: Snapshot) {
  snapshot = next;
  listeners.forEach((l) => l());
}

export function setSellingAccess(access: SellingAccess) {
  set({ access, loaded: true, failed: false });
}

// Signed out (or a different person signing in): forget the last answer.
export function clearSellingAccess() {
  set({ access: NO_ACCESS, loaded: false, failed: false });
}

export async function refreshSellingAccess(userId: string): Promise<void> {
  const [p, m] = await Promise.all([
    supabase.from('profiles').select('seller_status').eq('id', userId).single(),
    supabase.from('business_members').select('business_id', { count: 'exact', head: true }).eq('user_id', userId),
  ]);
  if (p.error) {
    // Keep the last known answer when there is one; otherwise stay closed and say we could not check.
    set({ ...snapshot, failed: !snapshot.loaded });
    return;
  }
  setSellingAccess({ status: toSellerStatus((p.data as { seller_status?: unknown } | null)?.seller_status), hasBusiness: (m.count ?? 0) > 0 });
}

const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => listeners.delete(l);
};

export function useSellingAccess(): Snapshot {
  return useSyncExternalStore(subscribe, () => snapshot, () => snapshot);
}
