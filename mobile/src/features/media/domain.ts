// Media Department: plain logic the screens use. No network here, so it is easy to test.
// What a person MAY do is decided by the database. The permission list comes from the server (staff_effective_permissions)
// and these helpers only choose which buttons to show. Nothing here invents a permission.

export type Permissions = readonly string[];
export const has = (perms: Permissions, key: string) => perms.includes(key);

export type ContentStatus = 'draft' | 'submitted' | 'changes_requested' | 'approved' | 'rejected' | 'scheduled' | 'published' | 'withdrawn' | 'archived';

export const STATUS_LABEL: Record<ContentStatus, string> = {
  draft: 'Draft',
  submitted: 'Waiting for approval',
  changes_requested: 'Changes requested',
  approved: 'Approved, not published',
  rejected: 'Rejected',
  scheduled: 'Scheduled',
  published: 'Published',
  withdrawn: 'Withdrawn',
  archived: 'Archived',
};

export const CONTENT_KINDS = [
  { key: 'poster', label: 'Poster' }, { key: 'banner', label: 'Banner' }, { key: 'advert', label: 'Advert' },
  { key: 'social_post', label: 'Social post' }, { key: 'announcement', label: 'Announcement' }, { key: 'notice', label: 'Public notice' },
  { key: 'education', label: 'How-to guide' }, { key: 'video', label: 'Video' },
] as const;
export const CHANNELS = [
  { key: 'in_app', label: 'In the app' }, { key: 'website', label: 'Website' }, { key: 'facebook', label: 'Facebook' },
  { key: 'instagram', label: 'Instagram' }, { key: 'tiktok', label: 'TikTok' }, { key: 'other', label: 'Other' },
] as const;
export const CATEGORIES = [
  { key: 'poster', label: 'Posters' }, { key: 'banner', label: 'Banners' }, { key: 'advert', label: 'Adverts' }, { key: 'social', label: 'Social' },
  { key: 'video', label: 'Videos' }, { key: 'announcement', label: 'Announcements' }, { key: 'education', label: 'Guides' },
  { key: 'brand', label: 'Brand' }, { key: 'other', label: 'Other' },
] as const;
export const TITLE_LABEL: Record<string, string> = { lead: 'Media lead', designer: 'Designer', social_media: 'Social media', editor: 'Editor', member: 'Team member' };

// ----- dashboard sections, each tied to the permission that opens it -----
export type MediaSection = { key: string; title: string; note: string; href: string; needs: string };

const SECTIONS: MediaSection[] = [
  { key: 'studio', title: 'Content Studio', note: 'Create posters, banners, posts and guides', href: '/media/studio', needs: 'media.access' },
  { key: 'library', title: 'Media Library', note: 'Images, videos and graphics', href: '/media/library', needs: 'media.access' },
  { key: 'campaigns', title: 'Campaign Manager', note: 'Organise marketing campaigns', href: '/media/campaigns', needs: 'media.access' },
  { key: 'announcements', title: 'Announcements', note: 'Public announcements and notices', href: '/media/studio?only=announcements', needs: 'media.access' },
  { key: 'queue', title: 'Publishing Queue', note: 'Waiting for approval or publication', href: '/media/studio?only=queue', needs: 'media.access' },
  { key: 'calendar', title: 'Content Calendar', note: 'Scheduled campaigns and announcements', href: '/media/calendar', needs: 'media.access' },
  { key: 'performance', title: 'Performance', note: 'Reach and engagement numbers', href: '/media/performance', needs: 'media.performance' },
  { key: 'requests', title: 'Requests', note: 'Asks from other departments', href: '/media/requests', needs: 'media.access' },
  { key: 'activity', title: 'Activity record', note: 'Who did what in Media', href: '/media/activity', needs: 'media.activity' },
];

export function mediaSections(perms: Permissions): MediaSection[] {
  // The dashboard itself needs media.access; each section then needs its own permission as well.
  if (!has(perms, 'media.access')) return [];
  return SECTIONS.filter((s) => has(perms, s.needs));
}

// ----- what can be done to one piece of content -----
export type ContentAction = 'edit' | 'submit' | 'approve' | 'changes' | 'reject' | 'publish' | 'schedule' | 'withdraw';

// Mirrors the database rules so the right buttons show. The database still refuses anything that is not allowed.
export function contentActions(status: ContentStatus, perms: Permissions, isCreator: boolean): ContentAction[] {
  const out: ContentAction[] = [];
  if (has(perms, 'media.create') && isCreator) {
    if (status === 'draft' || status === 'changes_requested' || status === 'rejected' || status === 'withdrawn') out.push('edit');
    if (status === 'draft' || status === 'changes_requested') out.push('submit');
  }
  if (has(perms, 'media.review') && !isCreator && status === 'submitted') out.push('approve', 'changes', 'reject');
  if (has(perms, 'media.publish')) {
    if (status === 'approved' || status === 'scheduled') out.push('publish', 'schedule');
    if (status === 'published' || status === 'scheduled') out.push('withdraw');
  }
  return out;
}

export const ACTION_LABEL: Record<ContentAction, string> = {
  edit: 'Edit', submit: 'Submit for approval', approve: 'Approve', changes: 'Ask for changes', reject: 'Reject',
  publish: 'Publish now', schedule: 'Schedule', withdraw: 'Withdraw',
};
// Actions that need the person to write a reason.
export const NEEDS_NOTE: ContentAction[] = ['changes', 'reject', 'withdraw'];

export type QueueItem = { id: string; title: string; status: ContentStatus; createdBy: string; scheduledFor: string | null };

// The Publishing Queue: what needs a decision, what is ready to go out, what is already scheduled.
export function queueGroups(items: QueueItem[]) {
  return {
    review: items.filter((i) => i.status === 'submitted'),
    ready: items.filter((i) => i.status === 'approved'),
    scheduled: items.filter((i) => i.status === 'scheduled'),
  };
}

export const ANNOUNCEMENT_KINDS = ['announcement', 'notice'];

// ----- uploads: the same limits the database applies -----
export const UPLOAD_LIMITS = { image: 10 * 1024 * 1024, video: 50 * 1024 * 1024, document: 20 * 1024 * 1024 } as const;
const TYPES: Record<string, { kind: keyof typeof UPLOAD_LIMITS; ext: string }> = {
  'image/jpeg': { kind: 'image', ext: 'jpg' }, 'image/png': { kind: 'image', ext: 'png' }, 'image/webp': { kind: 'image', ext: 'webp' },
  'video/mp4': { kind: 'video', ext: 'mp4' }, 'video/quicktime': { kind: 'video', ext: 'mov' }, 'application/pdf': { kind: 'document', ext: 'pdf' },
};

export function extensionFor(mime: string): string | null {
  return TYPES[mime]?.ext ?? null;
}

export function uploadProblem(file: { mime: string | null | undefined; size: number | null | undefined }): string | null {
  const t = file.mime ? TYPES[file.mime] : undefined;
  if (!t) return 'Upload a JPG, PNG, WebP, MP4, MOV or PDF file.';
  if (file.size != null && file.size > UPLOAD_LIMITS[t.kind]) return `That file is too large. ${t.kind === 'image' ? 'Images up to 10 MB' : t.kind === 'video' ? 'Videos up to 50 MB' : 'PDFs up to 20 MB'}.`;
  if (file.size != null && file.size <= 0) return 'That file is empty.';
  return null;
}

export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export const DELETE_WORD = 'DELETE';
export const deleteConfirmed = (typed: string) => typed.trim() === DELETE_WORD;

export function scanLabel(scan: string): string {
  return scan === 'clean' ? 'Safety check passed' : scan === 'infected' ? 'Failed the safety check' : scan === 'failed' ? 'Safety check could not run' : 'Waiting for the safety check';
}

// ----- calendar -----
export type CalendarRow = { kind: 'content' | 'campaign'; id: string; title: string; at: string | null; status: string };

// Groups by calendar day in Lusaka time, oldest day first.
export function groupByDay(rows: CalendarRow[]): { day: string; rows: CalendarRow[] }[] {
  const days = new Map<string, CalendarRow[]>();
  for (const r of rows) {
    if (!r.at) continue;
    const t = new Date(r.at);
    if (Number.isNaN(t.getTime())) continue;
    const day = t.toLocaleDateString('en-CA', { timeZone: 'Africa/Lusaka' });
    days.set(day, [...(days.get(day) ?? []), r]);
  }
  return [...days.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([day, r]) => ({ day, rows: r }));
}

// ----- requests -----
export const REQUEST_KINDS = [
  { key: 'graphic', label: 'Graphic or poster' }, { key: 'announcement', label: 'Announcement' }, { key: 'campaign', label: 'Campaign' },
  { key: 'educational', label: 'Educational material' }, { key: 'statement', label: 'Official statement' }, { key: 'other', label: 'Something else' },
] as const;
export const PRIORITIES = ['low', 'normal', 'high', 'urgent'] as const;

export function requestProblem(title: string, details: string): string | null {
  if (title.trim().length < 3 || title.trim().length > 120) return 'Give the request a short title (3 to 120 letters).';
  if (details.trim().length < 3 || details.trim().length > 2000) return 'Say what you need (up to 2000 letters).';
  return null;
}

export function contentProblem(title: string, body: string): string | null {
  if (title.trim().length < 2 || title.trim().length > 120) return 'Give it a title (2 to 120 letters).';
  if (body.length > 5000) return 'The text can be at most 5000 letters.';
  return null;
}

// ----- attaching library files to content -----
// Only files that passed the safety check and are not archived can be attached.
export function attachable<T extends { status: string; scanStatus: string }>(assets: T[]): T[] {
  return assets.filter((a) => a.status === 'active' && a.scanStatus === 'clean');
}
export function toggleId(ids: string[], id: string): string[] {
  return ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id].slice(0, 10);
}

// ----- pausing a department's access -----
// Mirrors staff_role_access_key in the database. Administrators and Media have no pause here.
export const PAUSABLE: Record<string, { key: string; label: string }> = {
  support: { key: 'support.access', label: 'Support and Verification' },
  moderator: { key: 'moderation.access', label: 'Moderation' },
  finance: { key: 'finance.access', label: 'Finance' },
};
