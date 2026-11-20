import { supabase } from '../../lib/supabase';

export type Message = {
  id: string;
  conversationId: string;
  senderId: string;
  body: string;
  createdAt: string;
};

export type ConversationSummary = {
  id: string;
  listingTitle: string;
  otherName: string;
  lastMessageAt: string | null;
};

type RawMessage = { id: string; conversation_id: string; sender_id: string; body: string; created_at: string };

export function toMessage(row: RawMessage): Message {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    body: row.body,
    createdAt: row.created_at,
  };
}

export async function startConversation(listingId: string): Promise<string> {
  const { data, error } = await supabase.rpc('start_conversation', { p_listing_id: listingId });
  if (error) throw error;
  return data as string;
}

export async function listConversations(userId: string): Promise<ConversationSummary[]> {
  const { data, error } = await supabase
    .from('conversations')
    .select(
      `id, last_message_at, buyer_id,
       listing:listings(title),
       buyer:profiles!conversations_buyer_id_fkey(display_name),
       seller:profiles!conversations_seller_id_fkey(display_name)`,
    )
    .order('last_message_at', { ascending: false, nullsFirst: false });
  if (error) throw error;

  const rows = data as unknown as {
    id: string;
    last_message_at: string | null;
    buyer_id: string;
    listing: { title: string } | null;
    buyer: { display_name: string } | null;
    seller: { display_name: string } | null;
  }[];

  return rows.map((r) => ({
    id: r.id,
    listingTitle: r.listing?.title ?? 'Listing',
    otherName: (r.buyer_id === userId ? r.seller?.display_name : r.buyer?.display_name) ?? 'Member',
    lastMessageAt: r.last_message_at,
  }));
}

export async function loadMessages(conversationId: string): Promise<Message[]> {
  const { data, error } = await supabase
    .from('messages')
    .select('id, conversation_id, sender_id, body, created_at')
    .eq('conversation_id', conversationId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data as RawMessage[]).map(toMessage);
}

export async function sendMessage(conversationId: string, body: string): Promise<void> {
  const { error } = await supabase.from('messages').insert({ conversation_id: conversationId, body: body.trim() });
  if (error) throw error;
}

export async function markRead(conversationId: string, userId: string): Promise<void> {
  await supabase
    .from('messages')
    .update({ read_at: new Date().toISOString() })
    .eq('conversation_id', conversationId)
    .neq('sender_id', userId)
    .is('read_at', null);
}

export async function conversationInfo(conversationId: string, userId: string) {
  const { data, error } = await supabase
    .from('conversations')
    .select('buyer_id, seller_id, listing:listings(title)')
    .eq('id', conversationId)
    .single();
  if (error) throw error;
  const row = data as unknown as { buyer_id: string; seller_id: string; listing: { title: string } | null };
  return {
    otherUserId: row.buyer_id === userId ? row.seller_id : row.buyer_id,
    listingTitle: row.listing?.title ?? 'Listing',
  };
}
