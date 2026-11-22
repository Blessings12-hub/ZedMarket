import type { CancelKind, Fulfilment, OrderEventKind, OrderStatus, Receipt } from '../../domain/orders';
import { supabase } from '../../lib/supabase';

export type { OrderStatus } from '../../domain/orders';

export type Order = {
  id: string;
  ref: string;
  listingId: string;
  buyerId: string;
  sellerId: string;
  businessId: string | null;
  buyerName: string;
  sellerName: string;
  title: string;
  price: number;
  deliveryFee: number;
  total: number;
  fulfilment: Fulfilment;
  deliveryAddress: string | null;
  buyerNote: string | null;
  status: OrderStatus;
  cancelKind: CancelKind | null;
  cancelledBy: 'buyer' | 'seller' | 'system' | 'staff' | null;
  cancelledReason: string | null;
  createdAt: string;
  confirmedAt: string | null;
  handedOverAt: string | null;
  completedAt: string | null;
  expiresAt: string | null;
};

export type OrderEvent = {
  id: number;
  actorRole: 'buyer' | 'seller' | 'system' | 'staff';
  event: OrderEventKind;
  note: string | null;
  createdAt: string;
};

type RawOrder = {
  id: string;
  ref: string;
  listing_id: string;
  buyer_id: string;
  seller_id: string;
  business_id: string | null;
  buyer_name: string;
  seller_name: string;
  item_title: string;
  item_price_zmw: number;
  delivery_fee_zmw: number;
  total_zmw: number;
  fulfilment: Fulfilment;
  delivery_address: string | null;
  buyer_note: string | null;
  status: OrderStatus;
  cancel_kind: CancelKind | null;
  cancelled_by: Order['cancelledBy'];
  cancelled_reason: string | null;
  created_at: string;
  confirmed_at: string | null;
  handed_over_at: string | null;
  completed_at: string | null;
  expires_at: string | null;
};

function toOrder(r: RawOrder): Order {
  return {
    id: r.id,
    ref: r.ref,
    listingId: r.listing_id,
    buyerId: r.buyer_id,
    sellerId: r.seller_id,
    businessId: r.business_id,
    buyerName: r.buyer_name,
    sellerName: r.seller_name,
    title: r.item_title,
    price: Number(r.item_price_zmw),
    deliveryFee: Number(r.delivery_fee_zmw),
    total: Number(r.total_zmw),
    fulfilment: r.fulfilment,
    deliveryAddress: r.delivery_address,
    buyerNote: r.buyer_note,
    status: r.status,
    cancelKind: r.cancel_kind,
    cancelledBy: r.cancelled_by,
    cancelledReason: r.cancelled_reason,
    createdAt: r.created_at,
    confirmedAt: r.confirmed_at,
    handedOverAt: r.handed_over_at,
    completedAt: r.completed_at,
    expiresAt: r.expires_at,
  };
}

async function call(fn: string, args: Record<string, unknown>): Promise<Order> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return toOrder(data as RawOrder);
}

export const requestToBuy = (
  listingId: string,
  options: { fulfilment: Fulfilment; address: string; note: string } = { fulfilment: 'collection', address: '', note: '' },
) =>
  call('create_order', {
    p_listing_id: listingId,
    p_fulfilment: options.fulfilment,
    p_delivery_address: options.fulfilment === 'delivery' ? options.address.trim() : null,
    p_note: options.note.trim() || null,
  });

export const confirmOrder = (orderId: string, deliveryFee: number) =>
  call('confirm_order', { p_order_id: orderId, p_delivery_fee: deliveryFee });
export const declineOrder = (orderId: string, reason: string) =>
  call('decline_order', { p_order_id: orderId, p_reason: reason.trim() || null });
export const cancelOrder = (orderId: string, reason: string) =>
  call('cancel_order', { p_order_id: orderId, p_reason: reason.trim() || null });
export const markHandedOver = (orderId: string) => call('mark_handed_over', { p_order_id: orderId });
export const completeOrder = (orderId: string) => call('complete_order', { p_order_id: orderId });

export async function listOrders(): Promise<Order[]> {
  const { data, error } = await supabase.from('orders').select('*').order('created_at', { ascending: false });
  if (error) throw error;
  return (data as RawOrder[]).map(toOrder);
}

export async function fetchOrder(orderId: string): Promise<Order> {
  const { data, error } = await supabase.from('orders').select('*').eq('id', orderId).maybeSingle();
  if (error) throw error;
  if (!data) throw new Error('This order is not available.');
  return toOrder(data as RawOrder);
}

export async function fetchOrderEvents(orderId: string): Promise<OrderEvent[]> {
  const { data, error } = await supabase
    .from('order_events')
    .select('id, actor_role, event, note, created_at')
    .eq('order_id', orderId)
    .order('id');
  if (error) throw error;
  return (data ?? []).map((e) => ({
    id: e.id,
    actorRole: e.actor_role,
    event: e.event,
    note: e.note,
    createdAt: e.created_at,
  }));
}

export async function fetchReceipt(orderId: string): Promise<Receipt> {
  const { data, error } = await supabase.rpc('order_receipt', { p_order_id: orderId });
  if (error) throw error;
  return data as Receipt;
}

export async function isListingReserved(listingId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('listing_is_reserved', { p_listing_id: listingId });
  if (error) throw error;
  return data === true;
}
