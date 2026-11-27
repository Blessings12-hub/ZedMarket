// Safety check for Media Library files, plus clean-up of files whose record was deleted.
//
// scan:   { "asset_id": "<uuid>" }  -> reads the start of the stored file, checks it really is the type it claims to be
//         (and that a PDF carries no scripts or launch actions), then records clean / infected through
//         public.media_record_scan(). The CALLER never supplies the verdict, only the file id.
// purge:  { "purge": true }         -> removes stored files whose library record is already deleted (needs media.delete).
//
// This is a file-type and content check, NOT an antivirus engine. To add a real one (for example ClamAV), call it where
// `verdict()` is used below; nothing else needs to change.
//
// Deploy:  supabase functions deploy media-scan
// NOTE: written to the Supabase Edge Function pattern but NOT run in the build environment (no Deno/Supabase there).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

const ascii = (b: Uint8Array, from: number, to: number) => String.fromCharCode(...b.slice(from, to));

// Returns 'clean' or a short reason the file is refused.
function verdict(mime: string, head: Uint8Array): 'clean' | string {
  switch (mime) {
    case 'image/jpeg':
      return head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff ? 'clean' : 'not a real JPEG';
    case 'image/png':
      return ascii(head, 1, 4) === 'PNG' && head[0] === 0x89 ? 'clean' : 'not a real PNG';
    case 'image/webp':
      return ascii(head, 0, 4) === 'RIFF' && ascii(head, 8, 12) === 'WEBP' ? 'clean' : 'not a real WebP';
    case 'video/mp4':
    case 'video/quicktime':
      return ['ftyp', 'moov', 'mdat', 'free', 'wide'].includes(ascii(head, 4, 8)) ? 'clean' : 'not a real video';
    case 'application/pdf': {
      if (ascii(head, 0, 5) !== '%PDF-') return 'not a real PDF';
      const text = ascii(head, 0, head.length);
      return /\/(JavaScript|JS|Launch|OpenAction|EmbeddedFile)\b/.test(text) ? 'PDF contains scripts or embedded files' : 'clean';
    }
    default:
      return 'unsupported type';
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'Sign in first.' }, 401);

  let body: { asset_id?: string; purge?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Bad request.' }, 400);
  }

  const url = Deno.env.get('SUPABASE_URL')!;
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // The database decides who this is (and their two-factor level); nothing is trusted from the request.
  const { data: perms, error: permError } = await asUser.rpc('staff_effective_permissions');
  if (permError || !Array.isArray(perms)) return json({ error: 'Not allowed.' }, 403);

  if (body.purge) {
    if (!perms.includes('media.delete')) return json({ error: 'Not allowed.' }, 403);
    const { data: gone, error } = await admin.from('media_assets').select('id, storage_path').eq('status', 'deleted').limit(100);
    if (error) return json({ error: 'Could not look for files to remove.' }, 500);
    const paths = (gone ?? []).map((r: { storage_path: string }) => r.storage_path);
    if (paths.length === 0) return json({ removed: 0 });
    const res = await admin.storage.from('media-library').remove(paths);
    if (res.error) return json({ error: 'Could not remove the files.' }, 500);
    return json({ removed: res.data?.length ?? 0 });
  }

  if (!perms.includes('media.upload')) return json({ error: 'Not allowed.' }, 403);
  const id = String(body.asset_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'Bad file.' }, 400);

  const { data: asset } = await admin.from('media_assets').select('id, storage_path, mime_type, scan_status, status').eq('id', id).maybeSingle();
  if (!asset || asset.status === 'deleted') return json({ error: 'File not found.' }, 404);
  if (asset.scan_status !== 'pending') return json({ result: asset.scan_status }); // already decided; never re-decided by a caller

  const signed = await admin.storage.from('media-library').createSignedUrl(asset.storage_path, 60);
  if (signed.error) return json({ error: 'Could not read the file.' }, 500);
  const res = await fetch(signed.data.signedUrl, { headers: { Range: 'bytes=0-1048575' } });
  if (!res.ok && res.status !== 206) {
    await admin.rpc('media_record_scan', { p_asset: id, p_result: 'failed' });
    return json({ result: 'failed' });
  }
  const head = new Uint8Array(await res.arrayBuffer());
  const reason = head.length < 12 ? 'file is empty or too short' : verdict(asset.mime_type, head);
  const result = reason === 'clean' ? 'clean' : 'infected';
  const { error } = await admin.rpc('media_record_scan', { p_asset: id, p_result: result });
  if (error) return json({ error: 'Could not record the result.' }, 500);
  return json({ result, reason: result === 'clean' ? null : reason });
});
