import { supabase } from '../../lib/supabase';

export type OrderStatus = 'requested' | 'confirmed' | 'cancelled' | 'completed' | 'disputed';

export type Order = {
  id: string;
  ref: string;
  listingId: string;
  buyerId: string;
  sellerId: string;
  title: string;
  price: number;
  total: number;
  fulfilment: 'collection' | 'delivery';
  status: OrderStatus;
  createdAt: string;
};

export const ORDER_STATUS_LABELS: Record<OrderStatus, string> = {
  requested: 'Waiting for the seller',
  confirmed: 'Confirmed',
  cancelled: 'Cancelled',
  completed: 'Completed',
  disputed: 'In dispute',
};

type RawOrder = {
  id: string;
  ref: string;
  listing_id: string;
  buyer_id: string;
  seller_id: string;
  item_title: string;
  item_price_zmw: number;
  total_zmw: number;
  fulfilment: 'collection' | 'delivery';
  status: OrderStatus;
  created_at: string;
};

function toOrder(r: RawOrder): Order {
  return {
    id: r.id,
    ref: r.ref,
    listingId: r.listing_id,
    buyerId: r.buyer_id,
    sellerId: r.seller_id,
    title: r.item_title,
    price: Number(r.item_price_zmw),
    total: Number(r.total_zmw),
    fulfilment: r.fulfilment,
    status: r.status,
    createdAt: r.created_at,
  };
}

export async function requestToBuy(listingId: string): Promise<Order> {
  const { data, error } = await supabase.rpc('create_order', {
    p_listing_id: listingId,
    p_fulfilment: 'collection',
  });
  if (error) throw error;
  return toOrder(data as RawOrder);
}

export async function listOrders(): Promise<Order[]> {
  const { data, error } = await supabase.from('orders').select('*').order('created_at', { ascending: false });
  if (error) throw error;
  return (data as RawOrder[]).map(toOrder);
}

export async function changeOrderStatus(orderId: string, status: OrderStatus, reason?: string): Promise<void> {
  const { error } = await supabase.rpc('set_order_status', {
    p_order_id: orderId,
    p_status: status,
    p_reason: reason ?? null,
  });
  if (error) throw error;
}
