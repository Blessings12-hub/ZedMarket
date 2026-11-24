import type { Visibility } from '../../domain/birthdays';
import { supabase } from '../../lib/supabase';

// Every call goes through a database function (migration 0017). The birthday tables are closed to the app,
// and the database decides who may see what. Nothing returned here ever contains a year of birth.

export type MyBirthday = { hasBirthday: boolean; month: number | null; day: number | null; visibility: Visibility; showPhoto: boolean; position: string | null };
export type Celebrant = { userId: string; name: string; avatarPath: string | null; position: string | null; eventId: string | null; isMe: boolean; messageCount: number };
export type Upcoming = { userId: string; name: string; avatarPath: string | null; position: string | null; month: number; day: number; nextDate: string; daysUntil: number };
export type MonthEntry = { userId: string; name: string; avatarPath: string | null; position: string | null; month: number; day: number };
export type BoardEvent = {
  eventId: string; userId: string; name: string; avatarPath: string | null; position: string | null; eventDate: string;
  iAmBirthdayPerson: boolean; canWrite: boolean; myMessageCount: number; maxMessages: number;
};
export type Wish = { id: string; senderId: string; senderName: string; body: string | null; createdAt: string; isMine: boolean; hidden: boolean };
export type MyEvent = { eventId: string; eventDate: string; messageCount: number };
export type WishReport = { reportId: string; messageId: string; body: string | null; senderName: string; reporterName: string; reason: string; eventDate: string; birthdayPerson: string; createdAt: string; messageHidden: boolean };

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

// Photos are the existing public avatar pictures. There is no upload screen in the app yet.
export function avatarUrl(path: string | null): string | null {
  if (!path) return null;
  return supabase.storage.from('avatars').getPublicUrl(path).data.publicUrl;
}

export async function fetchMyBirthday(): Promise<MyBirthday> {
  const r = (await rpc<any[]>('my_birthday_profile'))[0];
  return {
    hasBirthday: !!r?.has_birthday, month: r?.birth_month ?? null, day: r?.birth_day ?? null,
    visibility: (r?.visibility ?? 'staff') as Visibility, showPhoto: r?.show_photo ?? true, position: r?.position_title ?? null,
  };
}

export async function saveMyBirthday(input: { month: number; day: number; visibility: Visibility; showPhoto: boolean; position: string }): Promise<void> {
  await rpc('set_my_birthday', {
    p_month: input.month, p_day: input.day, p_visibility: input.visibility, p_show_photo: input.showPhoto, p_position: input.position.trim() || null,
  });
}

export async function removeMyBirthday(): Promise<void> {
  await rpc('clear_my_birthday');
}

export async function fetchToday(): Promise<Celebrant[]> {
  return (await rpc<any[]>('staff_birthdays_today')).map((r) => ({
    userId: r.user_id, name: r.display_name, avatarPath: r.avatar_path, position: r.position_title,
    eventId: r.event_id, isMe: !!r.is_me, messageCount: r.message_count ?? 0,
  }));
}

export async function fetchUpcoming(days = 30): Promise<Upcoming[]> {
  return (await rpc<any[]>('staff_birthdays_upcoming', { p_days: days })).map((r) => ({
    userId: r.user_id, name: r.display_name, avatarPath: r.avatar_path, position: r.position_title,
    month: r.birth_month, day: r.birth_day, nextDate: r.next_date, daysUntil: r.days_until,
  }));
}

export async function fetchMonth(month: number): Promise<MonthEntry[]> {
  return (await rpc<any[]>('staff_birthdays_month', { p_month: month })).map((r) => ({
    userId: r.user_id, name: r.display_name, avatarPath: r.avatar_path, position: r.position_title, month: r.birth_month, day: r.birth_day,
  }));
}

export async function fetchBoardEvent(eventId: string): Promise<BoardEvent> {
  const r = (await rpc<any[]>('birthday_event', { p_event: eventId }))[0];
  return {
    eventId: r.event_id, userId: r.user_id, name: r.display_name, avatarPath: r.avatar_path, position: r.position_title, eventDate: r.event_date,
    iAmBirthdayPerson: !!r.i_am_birthday_person, canWrite: !!r.can_write, myMessageCount: r.my_message_count, maxMessages: r.max_messages,
  };
}

export async function fetchWishes(eventId: string): Promise<Wish[]> {
  return (await rpc<any[]>('birthday_messages', { p_event: eventId })).map((r) => ({
    id: r.message_id, senderId: r.sender_id, senderName: r.sender_name, body: r.body, createdAt: r.created_at, isMine: !!r.is_mine, hidden: !!r.hidden,
  }));
}

export async function sendWish(eventId: string, body: string): Promise<void> {
  await rpc('send_birthday_message', { p_event: eventId, p_body: body });
}

export async function fetchMyEvents(): Promise<MyEvent[]> {
  return (await rpc<any[]>('my_birthday_events')).map((r) => ({ eventId: r.event_id, eventDate: r.event_date, messageCount: r.message_count }));
}

export async function reportWish(messageId: string, reason: string): Promise<void> {
  await rpc('report_birthday_message', { p_message: messageId, p_reason: reason });
}

export async function fetchWishReports(): Promise<WishReport[]> {
  return (await rpc<any[]>('birthday_reports_queue')).map((r) => ({
    reportId: r.report_id, messageId: r.message_id, body: r.body, senderName: r.sender_name, reporterName: r.reporter_name, reason: r.reason,
    eventDate: r.event_date, birthdayPerson: r.birthday_person, createdAt: r.created_at, messageHidden: !!r.message_hidden,
  }));
}

export async function decideWishReport(reportId: string, action: 'hide' | 'dismiss', note: string): Promise<void> {
  await rpc('resolve_birthday_report', { p_report: reportId, p_action: action, p_note: note });
}
