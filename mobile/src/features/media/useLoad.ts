import { useFocusEffect } from 'expo-router';
import { useCallback, useRef, useState } from 'react';

import { friendlyError } from '../../lib/errors';

// Loads something whenever the screen comes into view. Errors are kept (never turned into an empty list) so the screen
// can show them with a retry button. A slow older answer never replaces a newer one.
export function useLoad<T>(load: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const latest = useRef(0);

  const reload = useCallback(async () => {
    const mine = ++latest.current;
    setLoading(true);
    try {
      const d = await load();
      if (mine === latest.current) {
        setData(d);
        setError('');
      }
    } catch (e) {
      if (mine === latest.current) setError(friendlyError(e));
    } finally {
      if (mine === latest.current) setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  useFocusEffect(useCallback(() => { void reload(); }, [reload]));
  return { data, error, loading, reload };
}
