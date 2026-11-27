// The cart is a saved shortlist of listings the buyer means to request. ZedMarket does not take payment, and each
// seller confirms their own request, so every item is still requested one at a time at checkout.
export type CartItem = {
  listingId: string;
  title: string;
  price: number;
  sellerName: string;
  imagePath: string | null;
  addedAt: string;
  quantity?: number; // missing in older saved carts: counts as 1
};

export const MAX_CART_ITEMS = 30;

export function addToCart(items: readonly CartItem[], item: CartItem): CartItem[] {
  if (items.some((i) => i.listingId === item.listingId)) return [...items];
  if (items.length >= MAX_CART_ITEMS) return [...items];
  return [...items, item];
}

export function removeFromCart(items: readonly CartItem[], listingId: string): CartItem[] {
  return items.filter((i) => i.listingId !== listingId);
}

export function inCart(items: readonly CartItem[], listingId: string): boolean {
  return items.some((i) => i.listingId === listingId);
}

export const MAX_CART_QUANTITY = 1000;

const clampQuantity = (q: unknown): number => (typeof q === 'number' && Number.isInteger(q) && q >= 1 ? Math.min(q, MAX_CART_QUANTITY) : 1);

// `stock` is how many buyers can order right now: a number for counted stock, null/undefined for a one-off item or when it
// could not be read. Then only 1 can be ordered, which is also what checkout will ask for.
export function effectiveQuantity(item: CartItem, stock: number | null | undefined): number {
  const wanted = clampQuantity(item.quantity);
  if (stock == null) return 1;
  return Math.max(1, Math.min(wanted, stock));
}

export function setCartQuantity(items: readonly CartItem[], listingId: string, quantity: number): CartItem[] {
  return items.map((i) => (i.listingId === listingId ? { ...i, quantity: clampQuantity(quantity) } : i));
}

export function cartTotal(items: readonly CartItem[], stock: Readonly<Record<string, number | null>> = {}): number {
  return Math.round(items.reduce((sum, i) => sum + i.price * effectiveQuantity(i, stock[i.listingId]), 0) * 100) / 100;
}

// Reads whatever was stored, keeping only well-formed items, so a damaged value never breaks the screen.
export function parseCart(raw: string | null): CartItem[] {
  if (!raw) return [];
  try {
    const data: unknown = JSON.parse(raw);
    if (!Array.isArray(data)) return [];
    const seen = new Set<string>();
    const out: CartItem[] = [];
    for (const v of data) {
      const o = v as Partial<CartItem> | null;
      if (!o || typeof o.listingId !== 'string' || typeof o.title !== 'string' || typeof o.price !== 'number' || !Number.isFinite(o.price)) continue;
      if (seen.has(o.listingId)) continue;
      seen.add(o.listingId);
      out.push({
        listingId: o.listingId,
        title: o.title,
        price: o.price,
        sellerName: typeof o.sellerName === 'string' ? o.sellerName : '',
        imagePath: typeof o.imagePath === 'string' ? o.imagePath : null,
        addedAt: typeof o.addedAt === 'string' ? o.addedAt : '',
        quantity: clampQuantity(o.quantity),
      });
      if (out.length >= MAX_CART_ITEMS) break;
    }
    return out;
  } catch {
    return [];
  }
}
