// Where the home screen looks. Everything here is plain logic so it can be tested without a phone.
// The home screen shows every listing in the province. "Search for items near you" narrows it to one area.
import { formatPlace, type Place } from '../../domain/locations';

export const DEFAULT_PROVINCE = 'Lusaka';

// The province to browse: the one where the person's delivery location is, otherwise Lusaka.
export function provinceFor(places: Place[], locationId: number | null | undefined): string {
  const here = locationId == null ? undefined : places.find((p) => p.id === locationId);
  return here?.province ?? DEFAULT_PROVINCE;
}

export type AreaChoice = { id: number; label: string; town: string };

// Named areas of the province, A to Z by town then area. A typed word keeps the ones that contain it (any case).
export function areaChoices(places: Place[], province: string, query = ''): AreaChoice[] {
  const q = query.trim().toLowerCase();
  return places
    .filter((p) => p.province === province && p.area)
    .filter((p) => q === '' || `${p.area} ${p.town}`.toLowerCase().includes(q))
    .sort((a, b) => a.town.localeCompare(b.town) || (a.area ?? '').localeCompare(b.area ?? ''))
    .map((p) => ({ id: p.id, label: formatPlace(p), town: p.town }));
}

// What the "near you" button says: the chosen area, or the province-wide default.
export function browseLabel(places: Place[], province: string, areaId: number | null): string {
  const area = areaId == null ? undefined : places.find((p) => p.id === areaId && p.province === province);
  return area ? formatPlace(area) : `All of ${province}`;
}

// An area picked earlier may not belong to this province any more (the person moved). Then it is dropped.
export function validArea(places: Place[], province: string, areaId: number | null): number | null {
  return areaId != null && places.some((p) => p.id === areaId && p.province === province) ? areaId : null;
}

// The server function for provinces arrives with migration 0030. Until it is applied, the app must not break: it falls
// back to the older search and says nothing is wrong.
export function isMissingFunction(error: unknown): boolean {
  const e = (error ?? {}) as { code?: string; message?: string };
  return e.code === 'PGRST202' || e.code === '42883' || /could not find the function/i.test(e.message ?? '');
}

// ----- the buyer's delivery location -----

export type DeliveryAddress = { id: string; label: string; kind: 'delivery' | 'pickup' | 'both'; locationId: number; street: string | null; landmark: string | null; isDefault: boolean };

// The default delivery address wins; otherwise the newest delivery-capable one. Pickup-only addresses never count.
export function pickDeliveryAddress<T extends DeliveryAddress>(rows: T[]): T | null {
  const usable = rows.filter((r) => r.kind !== 'pickup');
  return usable.find((r) => r.isDefault) ?? usable[0] ?? null;
}

// "Kabulonga, Lusaka" for the top bar, and the longer line with street and landmark for the order.
export function deliveryShort(places: Place[], a: Pick<DeliveryAddress, 'locationId'> | null): string | null {
  const place = a ? places.find((p) => p.id === a.locationId) : undefined;
  return place ? formatPlace(place) : null;
}

export function deliveryLong(places: Place[], a: Pick<DeliveryAddress, 'locationId' | 'street' | 'landmark'> | null): string | null {
  if (!a) return null;
  const parts = [a.street?.trim(), a.landmark?.trim(), deliveryShort(places, a)].filter((x): x is string => !!x);
  return parts.length > 0 ? parts.join(', ') : null;
}
