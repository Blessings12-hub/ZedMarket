// Safety check for Media Library files, plus clean-up of files whose record was deleted.
//
// scan:   { "asset_id": "<uuid>" }  -> reads the start of the stored file, checks it really is the type it claims to be
//         (and that a PDF carries no scripts or launch actions), then records clean / infected through
//         public.media_record_scan(). The CALLER never supplies the verdict, only the file id.
// purge:  { "purge": true }         -> removes stored files whose library record is already deleted (needs media.delete).
//
// rescan: { "rescan": true }       -> checks up to 20 files still waiting (for example after a temporary failure).
//
// Two layers:
//  1. Always: the real file type is checked, and a PDF may not carry scripts or embedded files.
//  2. Optional, when the secret VIRUSTOTAL_API_KEY is set: the file's SHA-256 fingerprint is looked up at VirusTotal.
//     Only the fingerprint is sent, never the file. A file known as malware is refused. A fingerprint VirusTotal has never
//     seen is not proof of safety, so layer 1 still applies. If VirusTotal cannot be reached the file stays "waiting" and
//     can be checked again (rescan); it is never marked clean without the check you asked for.
//     Free VirusTotal keys allow only a few lookups a minute, so a busy day may leave files waiting a little longer.
//     This is not a full antivirus engine; it catches known threats and disguised files.
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

  let body: { asset_id?: string; purge?: boolean; rescan?: boolean };
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

  if (body.rescan) {
    const { data: waiting } = await admin.from('media_assets').select('id').in('scan_status', ['pending', 'failed']).neq('status', 'deleted').order('created_at').limit(20);
    let checked = 0;
    for (const w of waiting ?? []) {
      await admin.from('media_assets').update({ scan_status: 'pending' }).eq('id', w.id).eq('scan_status', 'failed');
      const r = await scanOne(admin, w.id as string);
      if (r.result === 'clean' || r.result === 'infected') checked++;
    }
    return json({ checked });
  }

  const id = String(body.asset_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'Bad file.' }, 400);
  const out = await scanOne(admin, id);
  return json(out.body, out.status);
});

type Admin = ReturnType<typeof createClient>;
type Outcome = { result: string; status: number; body: Record<string, unknown> };

async function sha256Hex(bytes: ArrayBuffer): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// 'known' = VirusTotal says malware, 'unknown' = never seen / fine, 'unavailable' = could not ask.
async function lookup(hash: string, key: string): Promise<'known' | 'unknown' | 'unavailable'> {
  try {
    const r = await fetch(`https://www.virustotal.com/api/v3/files/${hash}`, { headers: { 'x-apikey': key } });
    if (r.status === 404) return 'unknown';
    if (!r.ok) return 'unavailable';
    const j = await r.json();
    const s = j?.data?.attributes?.last_analysis_stats ?? {};
    return Number(s.malicious ?? 0) + Number(s.suspicious ?? 0) > 0 ? 'known' : 'unknown';
  } catch {
    return 'unavailable';
  }
}

async function scanOne(admin: Admin, id: string): Promise<Outcome> {
  const { data: asset } = await admin.from('media_assets').select('id, storage_path, mime_type, size_bytes, scan_status, status').eq('id', id).maybeSingle();
  if (!asset || asset.status === 'deleted') return { result: 'missing', status: 404, body: { error: 'File not found.' } };
  if (asset.scan_status !== 'pending') return { result: asset.scan_status, status: 200, body: { result: asset.scan_status } }; // never re-decided by a caller

  const signed = await admin.storage.from('media-library').createSignedUrl(asset.storage_path, 120);
  if (signed.error) return { result: 'error', status: 500, body: { error: 'Could not read the file.' } };

  const key = Deno.env.get('VIRUSTOTAL_API_KEY');
  const useVt = !!key && Number(asset.size_bytes) <= 32 * 1024 * 1024; // whole file is read only to fingerprint it
  const res = await fetch(signed.data.signedUrl, useVt ? {} : { headers: { Range: 'bytes=0-1048575' } });
  if (!res.ok && res.status !== 206) {
    await admin.rpc('media_record_scan', { p_asset: id, p_result: 'failed' });
    return { result: 'failed', status: 200, body: { result: 'failed' } };
  }
  const buf = await res.arrayBuffer();
  const head = new Uint8Array(buf.slice(0, 1048576));

  let reason = head.length < 12 ? 'file is empty or too short' : verdict(asset.mime_type, head);
  if (reason === 'clean' && useVt) {
    const found = await lookup(await sha256Hex(buf), key!);
    if (found === 'unavailable') return { result: 'pending', status: 200, body: { result: 'pending', note: 'The malware check is not reachable right now. Try again later.' } };
    if (found === 'known') reason = 'known malware';
  }
  const result = reason === 'clean' ? 'clean' : 'infected';
  const { error } = await admin.rpc('media_record_scan', { p_asset: id, p_result: result });
  if (error) return { result: 'error', status: 500, body: { error: 'Could not record the result.' } };
  return { result, status: 200, body: { result, reason: result === 'clean' ? null : reason } };
}
