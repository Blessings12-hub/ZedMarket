import * as DocumentPicker from 'expo-document-picker';
import * as ImagePicker from 'expo-image-picker';

import { readPhoto, uploadObject } from '../../lib/storage';
import { supabase } from '../../lib/supabase';
import { extensionFor, uploadProblem, type CalendarRow, type ContentStatus } from './domain';

// Every call goes through here so the real error is logged. Screens show friendlyError(); the log keeps the technical one.
async function rpc<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    console.error(`[media] ${name} failed`, error);
    throw error;
  }
  return data as T;
}
function check<T>(r: { data: unknown; error: unknown }, what: string): T {
  if (r.error) {
    console.error(`[media] ${what} failed`, r.error);
    throw r.error;
  }
  return (r.data ?? []) as T;
}

// The permissions this person has right now, from the database.
export const fetchPermissions = () => rpc<string[]>('staff_effective_permissions');

export type Overview = {
  assets: number; assets_awaiting_scan: number; drafts: number; submitted: number; approved_waiting: number;
  scheduled: number; published: number; open_requests: number; active_campaigns: number;
};
export const fetchOverview = () => rpc<Overview>('media_overview');

// ----- library -----
export type Asset = {
  id: string; title: string; description: string | null; category: string; kind: 'image' | 'video' | 'document'; status: 'active' | 'archived' | 'deleted';
  storagePath: string; mimeType: string; sizeBytes: number; scanStatus: string; version: number; uploadedBy: string; uploaderName: string; createdAt: string; updatedAt: string;
};
type RawAsset = {
  id: string; title: string; description: string | null; category: string; kind: Asset['kind']; status: Asset['status']; storage_path: string; mime_type: string;
  size_bytes: number; scan_status: string; version: number; uploaded_by: string; created_at: string; updated_at: string; uploader: { display_name: string } | null;
};
const ASSET_COLUMNS = 'id, title, description, category, kind, status, storage_path, mime_type, size_bytes, scan_status, version, uploaded_by, created_at, updated_at, uploader:profiles!media_assets_uploaded_by_fkey(display_name)';
const toAsset = (r: RawAsset): Asset => ({
  id: r.id, title: r.title, description: r.description, category: r.category, kind: r.kind, status: r.status, storagePath: r.storage_path, mimeType: r.mime_type,
  sizeBytes: Number(r.size_bytes), scanStatus: r.scan_status, version: r.version, uploadedBy: r.uploaded_by, uploaderName: r.uploader?.display_name ?? 'Unknown',
  createdAt: r.created_at, updatedAt: r.updated_at,
});

export async function listAssets(status: 'active' | 'archived'): Promise<Asset[]> {
  const rows = check<RawAsset[]>(await supabase.from('media_assets').select(ASSET_COLUMNS).eq('status', status).order('created_at', { ascending: false }).limit(100), 'list assets');
  return rows.map(toAsset);
}

export async function assetUrl(path: string): Promise<string | null> {
  const { data, error } = await supabase.storage.from('media-library').createSignedUrl(path, 300);
  if (error) {
    console.warn('[media] preview link failed', error);
    return null;
  }
  return data.signedUrl;
}

// Pick, check, upload to the person's own folder, register so the database checks the real file, then ask for the safety check.
// The safety check can fail without losing the upload: the file just stays "waiting" and can be checked later.
export async function uploadAsset(userId: string, meta: { title: string; description: string; category: string }, source: 'gallery' | 'pdf' = 'gallery'): Promise<'uploaded' | 'cancelled'> {
  let uri: string; let mime: string; let size: number | null | undefined;
  if (source === 'pdf') {
    const res = await DocumentPicker.getDocumentAsync({ type: 'application/pdf', copyToCacheDirectory: true, multiple: false });
    if (res.canceled || !res.assets[0]) return 'cancelled';
    const a = res.assets[0];
    uri = a.uri; mime = a.mimeType ?? 'application/pdf'; size = a.size;
  } else {
    const res = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images', 'videos'], quality: 1, allowsMultipleSelection: false });
    if (res.canceled || !res.assets[0]) return 'cancelled';
    const a = res.assets[0];
    uri = a.uri; mime = a.mimeType ?? (a.type === 'video' ? 'video/mp4' : 'image/jpeg'); size = a.fileSize;
  }
  const problem = uploadProblem({ mime, size });
  if (problem) throw new Error(problem);
  const ext = extensionFor(mime);
  if (!ext) throw new Error('Upload a JPG, PNG, WebP, MP4, MOV or PDF file.');
  const body = await readPhoto(uri);
  const path = `${userId}/${Date.now()}.${ext}`;
  await uploadObject('media-library', path, body, mime);
  const id = await rpc<string>('media_asset_register', { p_title: meta.title, p_description: meta.description || null, p_category: meta.category, p_path: path });
  await scanAsset(id);
  return 'uploaded';
}

// Asks the media-scan function to check the stored file. Never throws: a failure leaves the file "waiting for the safety check".
export async function scanAsset(id: string): Promise<void> {
  const { error } = await supabase.functions.invoke('media-scan', { body: { asset_id: id } });
  if (error) console.warn('[media] safety check could not run yet', error);
}

// Asks for another safety check on every file still waiting (up to 20 at a time). Used when the first attempt could not run.
export async function rescanWaiting(): Promise<number> {
  const { data, error } = await supabase.functions.invoke('media-scan', { body: { rescan: true } });
  if (error) throw error;
  return Number((data as { checked?: number } | null)?.checked ?? 0);
}

// Removes stored files whose record is already deleted (clean-up after a failed removal).
export async function purgeDeleted(): Promise<void> {
  const { error } = await supabase.functions.invoke('media-scan', { body: { purge: true } });
  if (error) console.warn('[media] clean-up could not run yet', error);
}

export const updateAsset = (id: string, title: string, description: string, category: string, note?: string) =>
  rpc<void>('media_asset_update', { p_asset: id, p_title: title, p_description: description, p_category: category, p_note: note ?? null });
export const archiveAsset = (id: string, archive: boolean) => rpc<void>('media_asset_archive', { p_asset: id, p_archive: archive });

// Marks the record deleted (the database checks everything), then removes the stored file.
export async function deleteAsset(id: string, confirm: string): Promise<void> {
  const path = await rpc<string>('media_asset_delete', { p_asset: id, p_confirm: confirm });
  const { error } = await supabase.storage.from('media-library').remove([path]);
  if (error) {
    console.warn('[media] the record was deleted but the stored file could not be removed yet', error);
    await purgeDeleted(); // second try by the server, which also clears older leftovers
  }
}

// ----- content -----
export type Content = {
  id: string; kind: string; title: string; body: string | null; channel: string | null; campaignId: string | null; status: ContentStatus; version: number;
  createdBy: string; creatorName: string; createdAt: string; submittedAt: string | null; reviewedBy: string | null; reviewerName: string | null; reviewedAt: string | null;
  reviewNote: string | null; scheduledFor: string | null; publishedAt: string | null; updatedAt: string;
};
type RawContent = {
  id: string; kind: string; title: string; body: string | null; channel: string | null; campaign_id: string | null; status: ContentStatus; version: number; created_by: string;
  created_at: string; submitted_at: string | null; reviewed_by: string | null; reviewed_at: string | null; review_note: string | null; scheduled_for: string | null;
  published_at: string | null; updated_at: string; creator: { display_name: string } | null; reviewer: { display_name: string } | null;
};
const CONTENT_COLUMNS = 'id, kind, title, body, channel, campaign_id, status, version, created_by, created_at, submitted_at, reviewed_by, reviewed_at, review_note, scheduled_for, published_at, updated_at, creator:profiles!media_content_created_by_fkey(display_name), reviewer:profiles!media_content_reviewed_by_fkey(display_name)';
const toContent = (r: RawContent): Content => ({
  id: r.id, kind: r.kind, title: r.title, body: r.body, channel: r.channel, campaignId: r.campaign_id, status: r.status, version: r.version, createdBy: r.created_by,
  creatorName: r.creator?.display_name ?? 'Unknown', createdAt: r.created_at, submittedAt: r.submitted_at, reviewedBy: r.reviewed_by, reviewerName: r.reviewer?.display_name ?? null,
  reviewedAt: r.reviewed_at, reviewNote: r.review_note, scheduledFor: r.scheduled_for, publishedAt: r.published_at, updatedAt: r.updated_at,
});

export async function listContent(opts: { kinds?: string[]; statuses?: ContentStatus[] } = {}): Promise<Content[]> {
  let q = supabase.from('media_content').select(CONTENT_COLUMNS).order('updated_at', { ascending: false }).limit(100);
  if (opts.kinds) q = q.in('kind', opts.kinds);
  if (opts.statuses) q = q.in('status', opts.statuses);
  return check<RawContent[]>(await q, 'list content').map(toContent);
}

export type ContentDetail = { content: Content; assetIds: string[]; events: { id: number; event: string; actor: string; note: string | null; at: string }[]; versions: { version: number; title: string; at: string }[] };

export async function getContent(id: string): Promise<ContentDetail> {
  const [c, a, e, v] = await Promise.all([
    supabase.from('media_content').select(CONTENT_COLUMNS).eq('id', id).single(),
    supabase.from('media_content_assets').select('asset_id, position').eq('content_id', id).order('position'),
    supabase.from('media_content_events').select('id, event, note, created_at, actor:profiles!media_content_events_actor_id_fkey(display_name)').eq('content_id', id).order('id', { ascending: false }),
    supabase.from('media_content_versions').select('version, title, changed_at').eq('content_id', id).order('version', { ascending: false }),
  ]);
  if (c.error) throw c.error;
  const events = check<{ id: number; event: string; note: string | null; created_at: string; actor: { display_name: string } | null }[]>(e, 'content events');
  return {
    content: toContent(c.data as unknown as RawContent),
    assetIds: check<{ asset_id: string }[]>(a, 'content assets').map((x) => x.asset_id),
    events: events.map((x) => ({ id: x.id, event: x.event, actor: x.actor?.display_name ?? 'System', note: x.note, at: x.created_at })),
    versions: check<{ version: number; title: string; changed_at: string }[]>(v, 'content versions').map((x) => ({ version: x.version, title: x.title, at: x.changed_at })),
  };
}

export const saveContent = (input: { id: string | null; kind: string; title: string; body: string; channel: string | null; campaignId: string | null; assetIds: string[]; requestId?: string | null }) =>
  rpc<string>('media_content_save', {
    p_id: input.id, p_kind: input.kind, p_title: input.title, p_body: input.body || null, p_channel: input.channel, p_campaign: input.campaignId,
    p_assets: input.assetIds, p_request: input.requestId ?? null,
  });
export const submitContent = (id: string) => rpc<void>('media_content_submit', { p_id: id });
export const reviewContent = (id: string, decision: 'approve' | 'reject' | 'changes', note: string) => rpc<void>('media_content_review', { p_id: id, p_decision: decision, p_note: note || null });
export const publishContent = (id: string, when: string | null) => rpc<void>('media_content_publish', { p_id: id, p_when: when });
export const withdrawContent = (id: string, reason: string) => rpc<void>('media_content_withdraw', { p_id: id, p_reason: reason });

// ----- campaigns -----
export type Campaign = { id: string; name: string; description: string | null; startsOn: string | null; endsOn: string | null; status: string };
export async function listCampaigns(): Promise<Campaign[]> {
  const rows = check<{ id: string; name: string; description: string | null; starts_on: string | null; ends_on: string | null; status: string }[]>(
    await supabase.from('media_campaigns').select('id, name, description, starts_on, ends_on, status').order('created_at', { ascending: false }).limit(100), 'list campaigns');
  return rows.map((r) => ({ id: r.id, name: r.name, description: r.description, startsOn: r.starts_on, endsOn: r.ends_on, status: r.status }));
}
export const saveCampaign = (c: { id: string | null; name: string; description: string; startsOn: string | null; endsOn: string | null; status: string }) =>
  rpc<string>('media_campaign_save', { p_id: c.id, p_name: c.name, p_description: c.description, p_starts: c.startsOn, p_ends: c.endsOn, p_status: c.status });

// ----- requests -----
export type MediaRequest = { id: string; kind: string; title: string; details: string; priority: string; dueOn: string | null; status: string; fromDepartment: string; requesterName: string; assignedTo: string | null; note: string | null; createdAt: string };
export async function listRequests(): Promise<MediaRequest[]> {
  const rows = check<{ id: string; kind: string; title: string; details: string; priority: string; due_on: string | null; status: string; from_department: string; assigned_to: string | null; resolution_note: string | null; created_at: string; requester: { display_name: string } | null }[]>(
    await supabase.from('media_requests').select('id, kind, title, details, priority, due_on, status, from_department, assigned_to, resolution_note, created_at, requester:profiles!media_requests_requested_by_fkey(display_name)').order('created_at', { ascending: false }).limit(100), 'list requests');
  return rows.map((r) => ({ id: r.id, kind: r.kind, title: r.title, details: r.details, priority: r.priority, dueOn: r.due_on, status: r.status, fromDepartment: r.from_department, requesterName: r.requester?.display_name ?? 'Unknown', assignedTo: r.assigned_to, note: r.resolution_note, createdAt: r.created_at }));
}
export const createRequest = (kind: string, title: string, details: string, priority: string, dueOn: string | null) =>
  rpc<string>('media_request_create', { p_kind: kind, p_title: title, p_details: details, p_priority: priority, p_due: dueOn });
export const updateRequest = (id: string, status: string, assignedTo?: string | null, note?: string) =>
  rpc<void>('media_request_update', { p_id: id, p_status: status, p_assigned_to: assignedTo ?? null, p_note: note ?? null });

// ----- calendar, performance, activity -----
export async function fetchCalendar(from: string, to: string): Promise<CalendarRow[]> {
  const rows = await rpc<{ kind: 'content' | 'campaign'; id: string; title: string; at: string | null; status: string }[]>('media_calendar', { p_from: from, p_to: to });
  return rows;
}
export type PerformanceRow = { content_id: string; title: string; kind: string; published_at: string | null; impressions: number; clicks: number; engagements: number };
export const fetchPerformance = () => rpc<PerformanceRow[]>('media_performance_summary');
export const recordPerformance = (contentId: string, channel: string, impressions: number, clicks: number, engagements: number) =>
  rpc<void>('media_record_performance', { p_content: contentId, p_channel: channel, p_impressions: impressions, p_clicks: clicks, p_engagements: engagements });
export type ActivityRow = { at: string; actor_name: string | null; action: string; target_type: string | null; target_id: string | null; metadata: Record<string, unknown> };
export const fetchActivity = () => rpc<ActivityRow[]>('media_activity', { p_limit: 200 });

// ----- administrators: appoint, titles, permissions -----
export type MediaPerson = { userId: string; name: string; title: string; overrides: { permission: string; effect: 'grant' | 'revoke' }[] };
export async function listMediaPeople(): Promise<MediaPerson[]> {
  const [roles, titles, over] = await Promise.all([
    supabase.from('admin_roles').select('user_id, person:profiles!admin_roles_user_id_fkey(display_name)').eq('role', 'media'),
    supabase.from('media_staff').select('user_id, title'),
    supabase.from('staff_permission_overrides').select('user_id, permission, effect').like('permission', 'media.%'),
  ]);
  const r = check<{ user_id: string; person: { display_name: string } | null }[]>(roles, 'media staff');
  const t = new Map(check<{ user_id: string; title: string }[]>(titles, 'media titles').map((x) => [x.user_id, x.title]));
  const o = check<{ user_id: string; permission: string; effect: 'grant' | 'revoke' }[]>(over, 'permission overrides');
  return r.map((p) => ({ userId: p.user_id, name: p.person?.display_name ?? 'Unknown', title: t.get(p.user_id) ?? 'member', overrides: o.filter((x) => x.user_id === p.user_id).map((x) => ({ permission: x.permission, effect: x.effect })) }));
}
export const setMediaTitle = (userId: string, title: string) => rpc<void>('media_set_title', { p_user: userId, p_title: title });
export const grantPermission = (userId: string, permission: string, reason: string) => rpc<void>('grant_staff_permission', { p_user: userId, p_permission: permission, p_reason: reason || null });
export const revokePermission = (userId: string, permission: string, reason: string) => rpc<void>('revoke_staff_permission', { p_user: userId, p_permission: permission, p_reason: reason || null });
export const resetPermission = (userId: string, permission: string) => rpc<void>('reset_staff_permission', { p_user: userId, p_permission: permission });
export async function listPermissionCatalogue(): Promise<{ key: string; description: string }[]> {
  return check<{ key: string; description: string }[]>(await supabase.from('staff_permissions').select('key, description').eq('department', 'media').order('key'), 'permission catalogue');
}

// ----- public announcements (everyone, including guests) -----
export type PublicAnnouncement = { id: string; kind: string; title: string; body: string | null; published_at: string };
// Counts a view or tap of an announcement. Best effort: it must never get in the way of reading it.
export async function trackAnnouncement(id: string, event: 'view' | 'click'): Promise<void> {
  const { error } = await supabase.rpc('media_track', { p_content: id, p_event: event });
  if (error) console.warn('[media] could not count that', error.message);
}
export const fetchAnnouncements = () => rpc<PublicAnnouncement[]>('media_public_announcements', { p_limit: 20 });


// ----- pause or restore a person's access to a department (administrators only) -----
export type AccessPause = { userId: string; permission: string };
export async function listAccessPauses(): Promise<AccessPause[]> {
  const r = await supabase.from('staff_permission_overrides').select('user_id, permission').eq('effect', 'revoke').like('permission', '%.access');
  return check<{ user_id: string; permission: string }[]>(r, 'access pauses').map((x) => ({ userId: x.user_id, permission: x.permission }));
}
