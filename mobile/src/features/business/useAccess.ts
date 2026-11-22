import { useEffect, useState } from 'react';

import { useAuth } from '../../auth/AuthProvider';
import type { BusinessRole } from '../../domain/business';
import { supabase } from '../../lib/supabase';

// The signed-in person's role in one business, plus its name. The database checks every action again.
export function useBusinessAccess(businessId: string | undefined) {
  const { userId } = useAuth();
  const [state, setState] = useState<{ role: BusinessRole | null; name: string; slug: string; loading: boolean }>({
    role: null,
    name: '',
    slug: '',
    loading: true,
  });

  useEffect(() => {
    if (!businessId || !userId) return;
    let cancelled = false;
    (async () => {
      const { data } = await supabase
        .from('business_members')
        .select('role, business:businesses(name, slug)')
        .eq('business_id', businessId)
        .eq('user_id', userId)
        .maybeSingle();
      if (cancelled) return;
      const row = data as unknown as { role: BusinessRole; business: { name: string; slug: string } | null } | null;
      setState({ role: row?.role ?? null, name: row?.business?.name ?? '', slug: row?.business?.slug ?? '', loading: false });
    })();
    return () => {
      cancelled = true;
    };
  }, [businessId, userId]);

  return state;
}
