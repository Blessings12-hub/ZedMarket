// Sends queued push notifications. UNTESTED against the real Expo service:
// the database side is tested, this file has only been written, never run.
// Check the request and response shapes against Expo's push documentation before relying on it.
//
// Set these secrets on the Supabase project (never put them in the app):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (provided by Supabase to Edge Functions), WORKER_SECRET
// Call it on a schedule with the header  x-worker-secret: <WORKER_SECRET>
//
// Email and SMS are not sent here: no provider has been chosen. Those deliveries stay switched off.
import { createClient } from 'npm:@supabase/supabase-js@2';

const EXPO_URL = 'https://exp.host/--/api/v2/push/send';
const BATCH = 100;

type Job = { delivery_id: number; channel: string; token: string | null; title: string; body: string | null; link: string | null };
type Ticket = { status: 'ok' | 'error'; id?: string; message?: string; details?: { error?: string } };

Deno.serve(async (req) => {
  const secret = Deno.env.get('WORKER_SECRET');
  if (!secret || req.headers.get('x-worker-secret') !== secret) {
    return new Response('Not allowed', { status: 401 });
  }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });

  const { data, error } = await db.rpc('claim_notification_deliveries', { p_limit: BATCH });
  if (error) return new Response(error.message, { status: 500 });
  const jobs = ((data ?? []) as Job[]);

  let sent = 0;
  let failed = 0;
  const push = jobs.filter((j) => j.channel === 'push' && j.token);

  // Anything that is not push (email, sms) has no sender yet: hand it back for a later retry
  // without disabling anything, so it is visible as failed rather than silently lost.
  for (const j of jobs.filter((j) => j.channel !== 'push' || !j.token)) {
    await db.rpc('report_notification_delivery', {
      p_id: j.delivery_id, p_ok: false, p_error: `No sender for ${j.channel}.`, p_retry: false, p_disable_token: false,
    });
    failed++;
  }

  if (push.length > 0) {
    let tickets: Ticket[] | null = null;
    let httpError = '';
    try {
      const res = await fetch(EXPO_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify(
          push.map((j) => ({ to: j.token, title: j.title, body: j.body ?? undefined, data: { link: j.link }, sound: 'default' })),
        ),
      });
      if (res.ok) tickets = ((await res.json()).data ?? []) as Ticket[];
      else httpError = `Push service answered ${res.status}.`;
    } catch (e) {
      httpError = e instanceof Error ? e.message : 'Could not reach the push service.';
    }

    for (let i = 0; i < push.length; i++) {
      const j = push[i];
      const t = tickets?.[i];
      if (!t) {
        await db.rpc('report_notification_delivery', { p_id: j.delivery_id, p_ok: false, p_error: httpError || 'No answer for this message.', p_retry: true });
        failed++;
      } else if (t.status === 'ok') {
        await db.rpc('report_notification_delivery', { p_id: j.delivery_id, p_ok: true, p_provider_ref: t.id ?? null });
        sent++;
      } else {
        const gone = t.details?.error === 'DeviceNotRegistered';
        await db.rpc('report_notification_delivery', {
          p_id: j.delivery_id, p_ok: false, p_error: (t.details?.error ?? t.message ?? 'Rejected').slice(0, 200),
          p_retry: !gone, p_disable_token: gone,
        });
        failed++;
      }
    }
    // Receipts (a later check that the phone company really delivered) are not read yet.
  }

  return Response.json({ claimed: jobs.length, sent, failed });
});
