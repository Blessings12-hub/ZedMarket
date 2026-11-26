// The "Deliver to" card on an order. A seller (a person or a business member) must see exactly where the goods go
// before they confirm and while they hand over. Buyers know their own address, so they do not get the card.
import { orderPhase, type Fulfilment, type OrderRole, type OrderStatus, type CancelKind } from '../../domain/orders';

export type DeliverToInput = {
  role: OrderRole;
  fulfilment: Fulfilment;
  status: OrderStatus;
  cancelKind: CancelKind | null;
  handedOverAt: string | null;
  buyerName: string;
  deliveryAddress: string | null;
  deliveryFee: number;
  buyerNote: string | null;
};

export type DeliverTo = { title: string; address: string; buyerName: string; note: string | null; missing: boolean };

// Only while the order is still being arranged or delivered. Finished and cancelled orders do not need it.
export function deliverTo(o: DeliverToInput): DeliverTo | null {
  if (o.role !== 'seller' || o.fulfilment !== 'delivery') return null;
  const phase = orderPhase(o);
  if (phase !== 'requested' && phase !== 'confirmed' && phase !== 'handed_over') return null;
  const address = (o.deliveryAddress ?? '').trim();
  return {
    title: phase === 'requested' ? 'Deliver to (check before you confirm)' : 'Deliver to',
    address: address || 'The buyer did not give an address. Ask them in chat before you confirm.',
    buyerName: o.buyerName,
    note: o.buyerNote?.trim() ? o.buyerNote.trim() : null,
    missing: address === '',
  };
}
