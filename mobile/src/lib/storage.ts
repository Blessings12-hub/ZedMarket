import { supabase } from './supabase';
import { isTransientError, withRetry } from './resilientFetch';

// Reads a picked photo from the phone. Retried because on some phones the first read of a freshly edited image can fail.
export async function readPhoto(uri: string): Promise<ArrayBuffer> {
  return withRetry(async () => (await (await fetch(uri)).arrayBuffer()), { retries: 2, baseDelayMs: 300, shouldRetry: () => true });
}

function alreadyThere(error: { message?: string; statusCode?: string | number } | null): boolean {
  if (!error) return false;
  return String(error.statusCode ?? '') === '409' || /already exists|duplicate/i.test(error.message ?? '');
}

// Uploads a file and repeats the upload if the connection drops part-way.
// If an earlier attempt actually reached the server, "already exists" on the repeat is counted as success.
export async function uploadObject(bucket: string, path: string, body: ArrayBuffer, contentType = 'image/jpeg'): Promise<void> {
  await withRetry(
    async () => {
      const { error } = await supabase.storage.from(bucket).upload(path, body, { contentType, upsert: false, cacheControl: '31536000' });
      if (error && !alreadyThere(error)) throw error;
    },
    { retries: 3, baseDelayMs: 1000, shouldRetry: isTransientError },
  );
}
