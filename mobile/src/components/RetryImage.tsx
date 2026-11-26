import { useEffect, useRef, useState } from 'react';
import { Image, type ImageProps } from 'react-native';

// An image that tries again by itself when the network drops while it loads (common on mobile data).
// It retries up to three times with a growing pause, adding a small query value so the phone does not reuse the failed answer.
export function RetryImage({ source, onError, ...rest }: ImageProps) {
  const [attempt, setAttempt] = useState(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  let src = source;
  if (attempt > 0 && source && typeof source === 'object' && !Array.isArray(source) && 'uri' in source && source.uri) {
    const sep = source.uri.includes('?') ? '&' : '?';
    src = { ...source, uri: `${source.uri}${sep}r=${attempt}` };
  }

  return (
    <Image
      {...rest}
      source={src}
      onError={(e) => {
        if (attempt < 3) {
          timer.current = setTimeout(() => setAttempt((a) => a + 1), 1000 * 2 ** attempt);
        }
        onError?.(e);
      }}
    />
  );
}
