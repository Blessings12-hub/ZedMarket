// Opens one verification document for a support officer.
//
// 1. The caller's own JWT is forwarded, so the database sees the real officer (and their two-factor level).
// 2. public.verification_open_document() checks support role + aal2 + not-own-application + scan clean, writes the
//    audit row FIRST, and returns the bucket, path and lifetime.
// 3. Only then is a signed link created with the service role. It lasts a minute (platform setting).
//
// Deploy:  supabase functions deploy verification-document-url
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
// NOTE: written to the Supabase Edge Function pattern but NOT run in the build environment (no Deno/Supabase there).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);

  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'Sign in first.' }, 401);

  let documentId = '';
  try {
    documentId = String((await req.json()).document_id ?? '');
  } catch {
    return json({ error: 'Bad request.' }, 400);
  }
  if (!/^[0-9a-f-]{36}$/i.test(documentId)) return json({ error: 'Bad document.' }, 400);

  const asUser = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data, error } = await asUser.rpc('verification_open_document', { p_document: documentId });
  if (error || !data || !data[0]) return json({ error: error?.message ?? 'Not allowed.' }, 403);

  const { bucket, path, seconds } = data[0] as { bucket: string; path: string; seconds: number };
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const signed = await admin.storage.from(bucket).createSignedUrl(path, Math.min(Math.max(seconds, 10), 120));
  if (signed.error) return json({ error: 'Could not open the file.' }, 500);
  return json({ url: signed.data.signedUrl, expires_in: seconds });
});
