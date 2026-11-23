import { supabase } from '../../lib/supabase';
import { pickOnePhoto, signedUrl, uploadPrivate } from '../trust/api';

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export type Category = { key: string; label: string; hint: string };
export type MyTicket = { id: string; ref: string; subject: string; category: string; status: string; updatedAt: string; unreadReply: boolean };
export type TicketMessage = { id: string; role: 'customer' | 'staff'; body: string; createdAt: string };
export type TicketDetail = {
  id: string; ref: string; subject: string; status: string; resolutionCode: string | null; resolutionNote: string | null;
  rating: number | null; createdAt: string;
};

export async function fetchCategories(): Promise<Category[]> {
  const { data, error } = await supabase.from('support_categories').select('key, label, hint').order('sort_order');
  if (error) throw error;
  return (data ?? []) as Category[];
}

export async function openTicket(category: string, subject: string, description: string, orderId: string | null): Promise<string> {
  const row = await rpc<{ id: string }>('open_ticket', { p_category: category, p_subject: subject, p_description: description, p_order_id: orderId });
  return row.id;
}

export async function fetchMyTickets(): Promise<MyTicket[]> {
  const rows = await rpc<any[]>('my_tickets', { p_limit: 50 });
  return rows.map((r) => ({ id: r.id, ref: r.ref, subject: r.subject, category: r.category, status: r.status, updatedAt: r.updated_at, unreadReply: r.unread_reply }));
}

export async function fetchTicket(id: string): Promise<{ ticket: TicketDetail; messages: TicketMessage[]; files: { id: string; path: string }[] }> {
  const [t, m, a] = await Promise.all([
    supabase.from('support_tickets')
      .select('id, ref, subject, status, resolution_code, resolution_note, customer_rating, created_at').eq('id', id).single(),
    supabase.from('support_messages').select('id, author_role, body, created_at').eq('ticket_id', id).order('created_at'),
    supabase.from('support_attachments').select('id, storage_path').eq('ticket_id', id).order('created_at'),
  ]);
  if (t.error) throw t.error;
  if (m.error) throw m.error;
  if (a.error) throw a.error;
  const d: any = t.data;
  return {
    ticket: { id: d.id, ref: d.ref, subject: d.subject, status: d.status, resolutionCode: d.resolution_code, resolutionNote: d.resolution_note, rating: d.customer_rating, createdAt: d.created_at },
    messages: (m.data ?? []).map((x: any) => ({ id: x.id, role: x.author_role, body: x.body, createdAt: x.created_at })),
    files: (a.data ?? []).map((x: any) => ({ id: x.id, path: x.storage_path })),
  };
}

export async function replyToTicket(id: string, body: string): Promise<void> {
  await rpc('reply_ticket', { p_ticket: id, p_body: body });
}

// Picks a photo, stores it in the private evidence bucket, then records it on the ticket.
export async function attachPhoto(userId: string, ticketId: string): Promise<boolean> {
  const uri = await pickOnePhoto();
  if (!uri) return false;
  const path = await uploadPrivate('support-evidence', userId, ticketId, uri);
  await rpc('add_ticket_attachment', { p_ticket: ticketId, p_path: path });
  return true;
}

export function evidenceLink(path: string): Promise<string> {
  return signedUrl('support-evidence', path);
}

export async function rateTicket(id: string, rating: number, comment: string): Promise<void> {
  await rpc('rate_ticket', { p_ticket: id, p_rating: rating, p_comment: comment || null });
}

export async function closeMyTicket(id: string): Promise<void> {
  await rpc('customer_close_ticket', { p_ticket: id });
}

// ---- Staff ------------------------------------------------------------------

export type QueueRow = {
  id: string; ref: string; subject: string; category: string; status: string; priority: string; requester: string;
  assignedName: string | null; assignedTo: string | null; dueAt: string; overdue: boolean; updatedAt: string;
};

export async function fetchQueue(status: string | null, view: string, overdueOnly: boolean, search: string): Promise<QueueRow[]> {
  const rows = await rpc<any[]>('support_queue', {
    p_status: status, p_view: view, p_category: null, p_overdue_only: overdueOnly, p_search: search.trim() || null, p_limit: 50, p_offset: 0,
  });
  return rows.map((r) => ({
    id: r.id, ref: r.ref, subject: r.subject, category: r.category, status: r.status, priority: r.priority, requester: r.requester_name,
    assignedName: r.assigned_name, assignedTo: r.assigned_to, dueAt: r.due_at, overdue: r.overdue, updatedAt: r.updated_at,
  }));
}

export async function fetchStaffTicket(id: string): Promise<any> {
  return rpc<any>('support_ticket_detail', { p_ticket: id });
}
export const claimTicket = (id: string) => rpc('support_claim', { p_ticket: id });
export const staffReply = (id: string, body: string, internal: boolean) => rpc('support_reply', { p_ticket: id, p_body: body, p_internal: internal });
export const setTicketStatus = (id: string, status: string) => rpc('support_set_status', { p_ticket: id, p_status: status });
export const escalateTicket = (id: string, reason: string) => rpc('support_escalate', { p_ticket: id, p_reason: reason });
export const resolveTicket = (id: string, code: string, note: string) => rpc('support_resolve', { p_ticket: id, p_code: code, p_note: note });
export const assignTicket = (id: string, userId: string | null) => rpc('support_assign', { p_ticket: id, p_user: userId });

export async function fetchOverview(days = 30): Promise<{ metric: string; value: number | null }[]> {
  const rows = await rpc<any[]>('support_overview', { p_days: days });
  return rows.map((r) => ({ metric: r.metric, value: r.value === null ? null : Number(r.value) }));
}

export type AgentRow = {
  id: string; name: string; resolved: number; firstResponse: number | null; resolution: number | null;
  rating: number | null; openNow: number; overdueNow: number;
};
export async function fetchPerformance(days = 30): Promise<AgentRow[]> {
  const rows = await rpc<any[]>('support_performance', { p_days: days });
  const num = (v: any) => (v === null || v === undefined ? null : Number(v));
  return rows.map((r) => ({
    id: r.agent_id, name: r.agent_name, resolved: r.resolved, firstResponse: num(r.avg_first_response_minutes),
    resolution: num(r.avg_resolution_hours), rating: num(r.avg_rating), openNow: r.open_now, overdueNow: r.overdue_now,
  }));
}
