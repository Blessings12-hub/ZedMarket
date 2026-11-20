// Delivery model from section 11 of the blueprint.
//
// The blueprint's example type lists six statuses, while its status table also
// defines at_pickup and failed. All eight are included here.

export type DeliveryProvider = 'yango' | 'indrive' | 'zedmarket';

export type DeliveryStatus =
  | 'requested'
  | 'assigned'
  | 'at_pickup'
  | 'picked_up'
  | 'in_transit'
  | 'delivered'
  | 'cancelled'
  | 'failed';

export type Delivery = {
  id: string;
  order_id: string;
  seller_id: string;
  buyer_id: string;
  provider: DeliveryProvider;
  status: DeliveryStatus;
  status_reason: string | null;
  pickup_address: string;
  destination_address: string;
  estimated_arrival: string | null;
  estimated_arrival_source: 'provider' | 'routing' | null;
  tracking_url: string | null;
};

const STATUS_LABELS: Record<DeliveryStatus, string> = {
  requested: 'Delivery requested',
  assigned: 'Driver assigned',
  at_pickup: 'Driver at pickup',
  picked_up: 'Package collected',
  in_transit: 'On the way',
  delivered: 'Delivered',
  cancelled: 'Cancelled',
  failed: 'Delivery failed',
};

export function statusLabel(status: DeliveryStatus): string {
  return STATUS_LABELS[status];
}

// at_pickup and in_transit are optional because not every provider reports them.
const NEXT: Record<DeliveryStatus, DeliveryStatus[]> = {
  requested: ['assigned', 'cancelled', 'failed'],
  assigned: ['at_pickup', 'picked_up', 'cancelled', 'failed'],
  at_pickup: ['picked_up', 'cancelled', 'failed'],
  picked_up: ['in_transit', 'delivered', 'failed'],
  in_transit: ['delivered', 'failed'],
  delivered: [],
  cancelled: [],
  failed: [],
};

export function canMove(from: DeliveryStatus, to: DeliveryStatus): boolean {
  return NEXT[from].includes(to);
}

export function isFinished(status: DeliveryStatus): boolean {
  return NEXT[status].length === 0;
}

// Driver details and live location are only shared while a delivery is in progress.
export function isInProgress(status: DeliveryStatus): boolean {
  return status === 'assigned' || status === 'at_pickup' || status === 'picked_up' || status === 'in_transit';
}

// An arrival time is only shown when a provider or a routing service supplied it,
// and it is always worded as an estimate.
export function etaLabel(delivery: Pick<Delivery, 'status' | 'estimated_arrival' | 'estimated_arrival_source'>): string | null {
  if (isFinished(delivery.status)) return null;
  if (!delivery.estimated_arrival || !delivery.estimated_arrival_source) return null;

  const when = new Date(delivery.estimated_arrival);
  if (Number.isNaN(when.getTime())) return null;

  const time = when.toLocaleTimeString('en-ZM', { hour: '2-digit', minute: '2-digit' });
  return `Estimated arrival around ${time}`;
}
