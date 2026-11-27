// Quantity rules shown in the app. They mirror the database (1 to 1000, never more than what is available);
// the database stays the judge, these only give a readable message before a round trip.
export const MAX_QUANTITY = 1000;

export type QuantityResult = { quantity: number } | { error: string };

// `available` is the count buyers are shown (null for a one-off item, which is always 1).
export function parseQuantity(text: string, available: number | null): QuantityResult {
  if (available === null) return { quantity: 1 };
  const t = text.trim();
  if (!/^\d{1,4}$/.test(t)) return { error: 'Enter how many you want, as a whole number.' };
  const n = Number(t);
  if (n < 1) return { error: 'Choose at least 1.' };
  if (n > MAX_QUANTITY) return { error: `Choose a quantity between 1 and ${MAX_QUANTITY}.` };
  if (available <= 0) return { error: 'None are available right now.' };
  if (n > available) return { error: `Only ${available} available right now. Order ${available} or fewer.` };
  return { quantity: n };
}

// "Quantity 4" only when it matters; a partly filled order says what was handed over.
export function quantityLine(ordered: number, handedOver: number | null): string | null {
  if (ordered <= 1 && (handedOver === null || handedOver === ordered)) return null;
  if (handedOver !== null && handedOver !== ordered) return `Quantity ${ordered} ordered, ${handedOver} handed over`;
  return `Quantity ${ordered}`;
}

// The seller's "how many did you hand over" box: empty means all of them.
export function parseHandedOver(text: string, ordered: number): QuantityResult {
  const t = text.trim();
  if (t === '') return { quantity: ordered };
  if (!/^\d{1,4}$/.test(t)) return { error: 'Enter how many were handed over, as a whole number.' };
  const n = Number(t);
  if (n < 1 || n > ordered) return { error: `Say how many were handed over: between 1 and ${ordered}.` };
  return { quantity: n };
}

export type BranchOption = { id: string; name: string; available: number };
// Which branch to suggest when confirming: the one with the most free stock that can fill the whole order.
export function suggestBranch(options: BranchOption[], quantity: number): string | null {
  const fits = options.filter((b) => b.available >= quantity).sort((a, b) => b.available - a.available);
  return fits[0]?.id ?? null;
}
