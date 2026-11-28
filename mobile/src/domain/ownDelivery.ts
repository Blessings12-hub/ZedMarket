// Delivery by the seller's own rider (migration 0039). No map and no live tracking: a few clear steps and a PIN.

export type OwnDeliveryStatus = 'assigned' | 'picked_up' | 'in_transit' | 'delivered' | 'cancelled' | 'failed' | 'requested' | 'at_pickup';

export const PIN_LENGTH = 4;

const LABELS: Record<string, string> = {
  requested: 'Delivery requested',
  assigned: 'Delivery arranged',
  at_pickup: 'Rider at the pickup place',
  picked_up: 'Item picked up',
  in_transit: 'On its way',
  delivered: 'Delivered',
  cancelled: 'Delivery cancelled',
  failed: 'Delivery failed',
};

export function ownDeliveryLabel(status: string): string {
  return LABELS[status] ?? status.replace(/_/g, ' ');
}

export function isLive(status: string): boolean {
  return status === 'assigned' || status === 'picked_up' || status === 'in_transit';
}

// The one step the seller can take next, or null when there is none.
export function nextStep(status: string): { to: 'picked_up' | 'in_transit'; button: string } | null {
  if (status === 'assigned') return { to: 'picked_up', button: 'Rider has picked up the item' };
  if (status === 'picked_up') return { to: 'in_transit', button: 'Rider is on the way' };
  return null;
}

// The seller may enter the PIN once the item is with the rider.
export function canEnterPin(status: string, attemptsLeft: number): boolean {
  return (status === 'picked_up' || status === 'in_transit') && attemptsLeft > 0;
}

export function cleanPin(text: string): string {
  return text.replace(/[^0-9]/g, '').slice(0, PIN_LENGTH);
}

export function pinReady(text: string): boolean {
  return cleanPin(text).length === PIN_LENGTH;
}

export function pinResultMessage(ok: boolean, attemptsLeft: number): string {
  if (ok) return 'PIN accepted. The item is handed over.';
  if (attemptsLeft <= 0) return 'Too many wrong PINs. Cancel this delivery or ask ZedMarket support for help.';
  return `That PIN is not right. ${attemptsLeft} ${attemptsLeft === 1 ? 'try' : 'tries'} left.`;
}

export type DeliveryView = {
  id: string;
  status: string;
  riderName: string | null;
  pickupAddress: string;
  destinationAddress: string;
  statusReason: string | null;
  pin: string | null;
  attemptsLeft: number;
  events: { status: string; note: string | null; at: string }[];
};

type RawView = {
  id: string; status: string; rider_name: string | null; pickup_address: string; destination_address: string;
  status_reason: string | null; pin: string | null; attempts_left: number;
  events: { status: string; note: string | null; at: string }[];
};

export function toDeliveryView(raw: unknown): DeliveryView | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as RawView;
  if (typeof r.id !== 'string' || typeof r.status !== 'string') return null;
  return {
    id: r.id, status: r.status, riderName: r.rider_name ?? null, pickupAddress: r.pickup_address ?? '',
    destinationAddress: r.destination_address ?? '', statusReason: r.status_reason ?? null, pin: r.pin ?? null,
    attemptsLeft: typeof r.attempts_left === 'number' ? r.attempts_left : 0,
    events: Array.isArray(r.events) ? r.events : [],
  };
}
