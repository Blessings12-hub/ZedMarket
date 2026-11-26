import { supabase } from '../../lib/supabase';
import { normalizeAccess, normalizeWorkload, type AccessRow, type Workload } from './domain';

export async function fetchWorkload(): Promise<Workload> {
  const { data, error } = await supabase.rpc('verification_workload');
  if (error) { console.error('[trust] verification_workload failed', error); throw error; }
  return normalizeWorkload(data);
}
export async function fetchAccess(hours: number): Promise<AccessRow[]> {
  const { data, error } = await supabase.rpc('verification_access_monitor', { p_hours: hours });
  if (error) { console.error('[trust] verification_access_monitor failed', error); throw error; }
  return normalizeAccess(data);
}
