import { formatKwacha } from './money';

// Order rules as the app understands them. The database is the authority and refuses anything
// not allowed; this file only decides what to show. The test in orders.test.ts holds it to the
// same table the database tests use, so the two cannot drift apart unnoticed.

export type OrderStatus = 'requested' | 'confirmed' | 'cancelled' | 'completed' | 'disputed';
export type CancelKind = 'cancelled' | 'declined' | 'expired';
export type Fulfilment = 'collection' | 'delivery';
export type OrderRole = 'buyer' | 'seller';

export type OrderPhase =
  | 'requested'
  | 'confirmed'
  | 'handed_over'
  | 'completed'
  | 'cancelled'
  | 'declined'
  | 'expired'
  | 'disputed';

export type OrderAction = 'confirm' | 'decline' | 'cancel' | 'handover' | 'complete' | 'dispute';

export function orderPhase(o: { status: OrderStatus; cancelKind: CancelKind | null; handedOverAt: string | null }): OrderPhase {
  if (o.status === 'cancelled') return o.cancelKind ?? 'cancelled';
  if (o.status === 'confirmed' && o.handedOverAt) return 'handed_over';
  return o.status;
}

const ALLOWED: Record<OrderPhase, Partial<Record<OrderRole, OrderAction[]>>> = {
  requested: { seller: ['confirm', 'decline'], buyer: ['cancel'] },
  confirmed: { seller: ['handover', 'cancel', 'dispute'], buyer: ['complete', 'cancel', 'dispute'] },
  handed_over: { seller: ['dispute'], buyer: ['complete', 'dispute'] },
  completed: { seller: ['dispute'], buyer: ['dispute'] },
  cancelled: {},
  declined: {},
  expired: {},
  disputed: {},
};

export function availableActions(role: OrderRole, phase: OrderPhase): OrderAction[] {
  return ALLOWED[phase][role] ?? [];
}

// A review needs a completed order, once per person.
export const canReview = (phase: OrderPhase, alreadyReviewed: boolean) => phase === 'completed' && !alreadyReviewed;

export function phaseLabel(phase: OrderPhase, role: OrderRole, fulfilment: Fulfilment): string {
  const buyer = role === 'buyer';
  switch (phase) {
    case 'requested':
      return buyer ? 'Waiting for the seller to answer' : 'Waiting for you to answer';
    case 'confirmed':
      return fulfilment === 'delivery' ? 'Confirmed. Delivery to be arranged' : 'Confirmed. Collection to be arranged';
    case 'handed_over':
      return buyer ? 'Marked as handed over. Please confirm you have it' : 'Waiting for the buyer to confirm';
    case 'completed':
      return 'Completed';
    case 'cancelled':
      return 'Cancelled';
    case 'declined':
      return buyer ? 'The seller could not take this order' : 'You declined this order';
    case 'expired':
      return 'Expired';
    case 'disputed':
      return 'In dispute';
  }
}

export function actionLabel(action: OrderAction, fulfilment: Fulfilment): string {
  switch (action) {
    case 'confirm':
      return 'Confirm and reserve this item';
    case 'decline':
      return 'Decline';
    case 'cancel':
      return 'Cancel order';
    case 'handover':
      return fulfilment === 'delivery' ? 'Mark as delivered' : 'Mark as collected';
    case 'complete':
      return 'I have received it';
    case 'dispute':
      return 'Report a problem';
  }
}

export function expiryText(expiresAt: string | null, now: Date = new Date()): string | null {
  if (!expiresAt) return null;
  const ms = new Date(expiresAt).getTime() - now.getTime();
  if (Number.isNaN(ms)) return null;
  if (ms <= 0) return 'The time to answer has passed. This order will close shortly.';
  const hours = Math.ceil(ms / 3_600_000);
  if (hours < 24) return `Closes in ${hours} hour${hours === 1 ? '' : 's'} if nothing happens`;
  const days = Math.ceil(hours / 24);
  return `Closes in ${days} day${days === 1 ? '' : 's'} if nothing happens`;
}

// ---- Checkout ----

export const MAX_TEXT = 300;
export const MAX_DELIVERY_FEE = 100_000;

export function validateCheckout(input: { fulfilment: Fulfilment; address: string; note: string }): string | null {
  const address = input.address.trim();
  const note = input.note.trim();
  if (input.fulfilment === 'delivery' && address.length === 0) {
    return 'Enter a delivery address or a landmark the seller can find.';
  }
  if (address.length > MAX_TEXT || note.length > MAX_TEXT) return 'The address and note must each be 300 characters or fewer.';
  return null;
}

// The seller types the fee as text. Empty means no fee.
export function parseDeliveryFee(text: string): { fee: number } | { error: string } {
  const cleaned = text.trim().replace(/^K\s*/i, '').replace(/,/g, '');
  if (cleaned === '') return { fee: 0 };
  if (!/^\d+(\.\d{1,2})?$/.test(cleaned)) return { error: 'Enter the fee as a number, for example 50.' };
  const fee = Number(cleaned);
  if (fee > MAX_DELIVERY_FEE) return { error: 'The delivery fee cannot be more than K100,000.' };
  return { fee };
}

// ---- History and receipt ----

export type OrderEventKind =
  | 'requested'
  | 'confirmed'
  | 'declined'
  | 'cancelled'
  | 'expired'
  | 'handed_over'
  | 'completed'
  | 'auto_completed'
  | 'disputed'
  | 'settled_by_staff';

export function eventText(event: OrderEventKind, actorRole: 'buyer' | 'seller' | 'system' | 'staff', fulfilment: Fulfilment): string {
  switch (event) {
    case 'requested':
      return 'Buy request sent';
    case 'confirmed':
      return 'The seller confirmed the order and reserved the item';
    case 'declined':
      return actorRole === 'system' ? 'Closed: the item is no longer available to this buyer' : 'The seller declined the order';
    case 'cancelled':
      return actorRole === 'buyer'
        ? 'The buyer cancelled'
        : actorRole === 'seller'
          ? 'The seller cancelled'
          : actorRole === 'staff'
            ? 'Cancelled by ZedMarket support'
            : 'Cancelled because the listing is no longer available';
    case 'expired':
      return 'Expired because nobody acted in time';
    case 'handed_over':
      return fulfilment === 'delivery' ? 'The seller marked it as delivered' : 'The seller marked it as collected';
    case 'completed':
      return 'The buyer confirmed they have the item';
    case 'auto_completed':
      return 'Completed automatically: the buyer did not respond or report a problem in time';
    case 'disputed':
      return actorRole === 'buyer' ? 'The buyer reported a problem' : 'The seller reported a problem';
    case 'settled_by_staff':
      return 'Settled by ZedMarket support';
  }
}

export type Receipt = {
  receipt_number: string;
  order_status: string;
  item: string;
  item_price_zmw: number;
  delivery_fee_zmw: number;
  total_zmw: number;
  fulfilment: Fulfilment;
  buyer: string;
  seller: string;
  requested_at: string;
  confirmed_at: string | null;
  handed_over_at: string | null;
  completed_at: string;
  payment_note: string;
};

const day = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('en-ZM', { day: 'numeric', month: 'short', year: 'numeric' }) : '');

// Plain text for sharing or saving. It repeats what the database receipt says, including the
// line that no payment was handled by ZedMarket.
export function receiptText(r: Receipt): string {
  const lines = [
    `ZedMarket receipt ${r.receipt_number}`,
    `Item: ${r.item}`,
    `Price: ${formatKwacha(Number(r.item_price_zmw))}`,
  ];
  if (Number(r.delivery_fee_zmw) > 0) lines.push(`Delivery fee: ${formatKwacha(Number(r.delivery_fee_zmw))}`);
  lines.push(
    `Total agreed: ${formatKwacha(Number(r.total_zmw))}`,
    `${r.fulfilment === 'delivery' ? 'Delivery' : 'Collection'}`,
    `Buyer: ${r.buyer}`,
    `Seller: ${r.seller}`,
    `Requested: ${day(r.requested_at)}`,
  );
  if (r.confirmed_at) lines.push(`Confirmed: ${day(r.confirmed_at)}`);
  lines.push(`Completed: ${day(r.completed_at)}`, '', r.payment_note);
  return lines.join('\n');
}
