import { toDeliveryView, type DeliveryView } from '../../domain/ownDelivery';
import { supabase } from '../../lib/supabase';

export async function fetchDeliveryView(orderId: string): Promise<DeliveryView | null> {
  const { data, error } = await supabase.rpc('delivery_view', { p_order: orderId });
  if (error) throw error;
  return toDeliveryView(data);
}

export async function startDelivery(orderId: string, pickup: string, rider: string): Promise<void> {
  const { error } = await supabase.rpc('delivery_start', { p_order: orderId, p_pickup: pickup, p_rider: rider.trim() || null });
  if (error) throw error;
}

export async function setDeliveryStep(deliveryId: string, to: 'picked_up' | 'in_transit'): Promise<void> {
  const { error } = await supabase.rpc('delivery_set_status', { p_delivery: deliveryId, p_status: to });
  if (error) throw error;
}

export async function confirmDropoff(deliveryId: string, pin: string): Promise<{ ok: boolean; attemptsLeft: number }> {
  const { data, error } = await supabase.rpc('delivery_confirm_dropoff', { p_delivery: deliveryId, p_pin: pin });
  if (error) throw error;
  const r = data as { ok: boolean; attempts_left: number };
  return { ok: !!r.ok, attemptsLeft: r.attempts_left ?? 0 };
}

export async function cancelDelivery(deliveryId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('delivery_cancel', { p_delivery: deliveryId, p_reason: reason });
  if (error) throw error;
}
