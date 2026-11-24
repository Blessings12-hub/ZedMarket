// Pure helpers for places and addresses. No network, so they are easy to test.
// The database is the source of truth for every rule here; these only give people an early, friendly message.

export type Place = { id: number; province: string; district: string | null; town: string; area: string | null };
export type AddressKind = 'delivery' | 'pickup' | 'both';
export type CoverageLevel = 'area' | 'town' | 'district' | 'province';

export const ADDRESS_KIND_LABELS: Record<AddressKind, string> = {
  delivery: 'Delivery',
  pickup: 'Pickup (where buyers collect)',
  both: 'Delivery and pickup',
};

export const COVERAGE_LEVEL_LABELS: Record<CoverageLevel, string> = {
  area: 'This area only',
  town: 'Whole town',
  district: 'Whole district',
  province: 'Whole province',
};

// Same box the database enforces (roughly the outline of Zambia).
export function coordinatesProblem(lat: number | null, lng: number | null): string | null {
  if (lat === null && lng === null) return null;
  if (lat === null || lng === null) return 'Give both latitude and longitude, or neither.';
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return 'Coordinates must be numbers.';
  if (lat < -18.2 || lat > -8.1 || lng < 21.9 || lng > 33.8) return 'Those coordinates are outside Zambia.';
  return null;
}

export type AddressInput = { label: string; kind: AddressKind; locationId: number | null; street: string; landmark: string; directions: string };

export function validateAddress(a: AddressInput): string | null {
  const label = a.label.trim();
  if (label.length < 1 || label.length > 40) return 'Give the address a short name, for example "Home" or "Shop" (up to 40 letters).';
  if (a.locationId === null) return 'Choose the town or area.';
  const street = a.street.trim();
  const landmark = a.landmark.trim();
  if (!street && !landmark) return 'Add a street or a landmark so people can find it.';
  if (street.length > 150 || landmark.length > 150) return 'Street and landmark can be at most 150 letters each.';
  if (a.directions.trim().length > 300) return 'Directions can be at most 300 letters.';
  return null;
}

// One readable line, used for previews. The saved text sent with an order is built by the database.
export function formatPlace(p: Pick<Place, 'town' | 'area'>): string {
  return p.area ? `${p.area}, ${p.town}` : p.town;
}

// Province -> district -> town -> area, built from the flat list of places.
export function provinces(places: Place[]): string[] {
  return [...new Set(places.map((p) => p.province))].sort();
}
export function districtsIn(places: Place[], province: string): string[] {
  return [...new Set(places.filter((p) => p.province === province && p.district).map((p) => p.district as string))].sort();
}
export function townsIn(places: Place[], province: string, district: string): string[] {
  return [...new Set(places.filter((p) => p.province === province && p.district === district).map((p) => p.town))].sort();
}
// Rows for one town: the town itself (area null) and its named areas. Returns places with an id to pick.
export function areasIn(places: Place[], province: string, district: string, town: string): Place[] {
  return places
    .filter((p) => p.province === province && p.district === district && p.town === town)
    .sort((a, b) => (a.area ?? '').localeCompare(b.area ?? ''));
}

export type Coverage = 'unrestricted' | 'covered' | 'outside' | 'needs_area';

// What to tell a buyer before they send a delivery request.
export function coverageMessage(c: Coverage): { ok: boolean; text: string } {
  switch (c) {
    case 'unrestricted': return { ok: true, text: 'The seller has not limited where they deliver. They will confirm with you.' };
    case 'covered': return { ok: true, text: 'This seller delivers to your area.' };
    case 'outside': return { ok: false, text: 'This seller does not deliver to that area. Choose collection or another address.' };
    case 'needs_area': return { ok: false, text: 'Choose your area so we can check this seller delivers there.' };
  }
}

// Short line for a listing page, from listing_delivery_info.
export function deliverySummary(info: { restricted: boolean; areas: { level: string; label: string }[] } | null): string | null {
  if (!info) return null;
  if (!info.restricted) return null;
  const labels = info.areas.map((a) => a.label);
  if (labels.length <= 3) return `Delivers to: ${labels.join('; ')}`;
  return `Delivers to: ${labels.slice(0, 3).join('; ')} and ${labels.length - 3} more`;
}

// A link that opens the place in the phone's maps app. Only built when real coordinates were saved.
export function mapsLink(lat: number | null, lng: number | null): string | null {
  if (lat === null || lng === null || coordinatesProblem(lat, lng)) return null;
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
}
