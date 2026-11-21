import { formatKwacha } from './money';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// EXPO_PUBLIC_WEB_URL is the address of the deployed web version, for example
// https://zedmarket.example. Without it, shares carry text only. A link is never
// invented: it is only built when the web address was actually configured.
export function webBase(raw: string | undefined | null): string | null {
  const value = (raw ?? '').trim();
  if (!/^https?:\/\/[^\s/]+/i.test(value)) return null;
  return value.replace(/\/+$/, '');
}

export function listingLink(base: string | null, listingId: string): string | null {
  return base && UUID.test(listingId) ? `${base}/listing/${listingId.toLowerCase()}` : null;
}

export function sellerLink(base: string | null, sellerId: string): string | null {
  return base && UUID.test(sellerId) ? `${base}/seller/${sellerId.toLowerCase()}` : null;
}

export function listingShareMessage(input: { title: string; price: number; link: string | null }): string {
  const head = `${input.title} for ${formatKwacha(input.price)} on ZedMarket`;
  return input.link ? `${head}\n${input.link}` : head;
}

export function sellerShareMessage(input: { name: string; link: string | null }): string {
  const head = `${input.name} on ZedMarket`;
  return input.link ? `${head}\n${input.link}` : head;
}
