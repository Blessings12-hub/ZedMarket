import { supabase } from '../../lib/supabase';

export type AppNotification = {
  id: string;
  category: string;
  type: string;
  title: string;
  body: string | null;
  link: string | null;
  createdAt: string;
  read: boolean;
};

export type NotificationSetting = { category: string; inApp: boolean; push: boolean; email: boolean; sms: boolean };
export type Channels = { push: boolean; email: boolean; sms: boolean };

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export async function fetchNotifications(category: string | null, limit = 50): Promise<AppNotification[]> {
  let q = supabase
    .from('notifications')
    .select('id, category, type, title, body, link, created_at, read_at')
    .order('created_at', { ascending: false })
    .limit(limit);
  if (category) q = q.eq('category', category);
  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, category: r.category, type: r.type, title: r.title, body: r.body, link: r.link,
    createdAt: r.created_at, read: r.read_at !== null,
  }));
}

export async function countUnreadNotifications(): Promise<number> {
  return (await rpc<number>('unread_notification_count')) ?? 0;
}

export async function markRead(ids: string[]): Promise<void> {
  await rpc('mark_notifications_read', { p_ids: ids });
}

export async function markAllRead(category: string | null): Promise<void> {
  await rpc('mark_all_notifications_read', { p_category: category });
}

export async function fetchSettings(): Promise<NotificationSetting[]> {
  const rows = await rpc<any[]>('my_notification_settings');
  return rows.map((r) => ({ category: r.category, inApp: r.in_app, push: r.push, email: r.email, sms: r.sms }));
}

export async function saveSetting(s: NotificationSetting): Promise<void> {
  await rpc('set_notification_preference', {
    p_category: s.category, p_in_app: s.inApp, p_push: s.push, p_email: s.email, p_sms: s.sms,
  });
}

export async function fetchChannels(): Promise<Channels> {
  return rpc<Channels>('notification_channels');
}

export async function registerPushToken(token: string, platform: string): Promise<void> {
  await rpc('register_push_token', { p_token: token, p_platform: platform });
}

export async function unregisterPushToken(token: string): Promise<void> {
  await rpc('unregister_push_token', { p_token: token });
}

// Calls back with a new unread count whenever this user's notifications change.
export function watchNotifications(userId: string, onChange: () => void): () => void {
  const channel = supabase
    .channel(`notifications:${userId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${userId}` }, onChange)
    .subscribe();
  return () => {
    void supabase.removeChannel(channel);
  };
}
