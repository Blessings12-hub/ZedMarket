import { supabase } from '../../lib/supabase';
import { normalizeComparison, type Comparison } from './domain';

export async function fetchComparison(ids: string[]): Promise<Comparison> {
  const { data, error } = await supabase.rpc('compare_listings', { p_ids: ids });
  if (error) { console.error('[compare] compare_listings failed', error); throw error; }
  return normalizeComparison(data);
}
