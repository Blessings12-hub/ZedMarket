import type { AddressKind, Coverage, CoverageLevel, Place } from '../../domain/locations';
import { supabase } from '../../lib/supabase';

let placesCache: Promise<Place[]> | null = null;

// The list of places is small and rarely changes, so it is fetched once per app start.
export function loadPlaces(): Promise<Place[]> {
  if (!placesCache) {
    placesCache = (async () => {
      const { data, error } = await supabase.from('locations').select('id, province, district, town, area').order('town').order('area', { nullsFirst: true });
      if (error) throw error;
      return data as Place[];
    })();
    placesCache.catch(() => {
      placesCache = null;
    });
  }
  return placesCache;
}

export type SavedAddress = {
  id: string;
  label: string;
  kind: AddressKind;
  locationId: number;
  street: string | null;
  landmark: string | null;
  directions: string | null;
  latitude: number | null;
  longitude: number | null;
  isDefault: boolean;
};

type RawAddress = {
  id: string; label: string; kind: AddressKind; location_id: number; street: string | null; landmark: string | null;
  directions: string | null; latitude: number | null; longitude: number | null; is_default: boolean;
};

const toAddress = (r: RawAddress): SavedAddress => ({
  id: r.id, label: r.label, kind: r.kind, locationId: r.location_id, street: r.street, landmark: r.landmark,
  directions: r.directions, latitude: r.latitude, longitude: r.longitude, isDefault: r.is_default,
});

export async function listMyAddresses(): Promise<SavedAddress[]> {
  const { data, error } = await supabase
    .from('saved_addresses')
    .select('id, label, kind, location_id, street, landmark, directions, latitude, longitude, is_default')
    .order('is_default', { ascending: false })
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data as RawAddress[]).map(toAddress);
}

export type AddressDraft = {
  id: string | null; label: string; kind: AddressKind; locationId: number; street: string; landmark: string; directions: string; isDefault: boolean;
};

// Coordinates are not sent: there is no map picker yet, and the app never guesses a position.
export async function saveAddress(d: AddressDraft): Promise<SavedAddress> {
  const { data, error } = await supabase.rpc('save_address', {
    p_id: d.id,
    p_label: d.label.trim(),
    p_kind: d.kind,
    p_location_id: d.locationId,
    p_street: d.street.trim() || null,
    p_landmark: d.landmark.trim() || null,
    p_directions: d.directions.trim() || null,
    p_default: d.isDefault,
  });
  if (error) throw error;
  return toAddress(data as RawAddress);
}

export async function deleteAddress(id: string): Promise<void> {
  const { error } = await supabase.rpc('delete_address', { p_id: id });
  if (error) throw error;
}

export type DeliveryArea = { locationId: number; level: CoverageLevel; label: string };

// businessId null means the person's own personal listings.
export async function fetchMyDeliveryAreas(businessId: string | null): Promise<DeliveryArea[]> {
  const { data, error } = await supabase.rpc('my_delivery_areas', { p_business: businessId });
  if (error) throw error;
  return (data as { location_id: number; level: CoverageLevel; label: string }[]).map((r) => ({ locationId: r.location_id, level: r.level, label: r.label }));
}

export async function saveDeliveryAreas(businessId: string | null, areas: { locationId: number; level: CoverageLevel }[]): Promise<void> {
  const { error } = await supabase.rpc('set_delivery_areas', {
    p_business: businessId,
    p_areas: areas.map((a) => ({ location_id: a.locationId, level: a.level })),
  });
  if (error) throw error;
}

export type DeliveryInfo = { restricted: boolean; areas: { level: CoverageLevel; label: string }[] };

export async function fetchListingDeliveryInfo(listingId: string): Promise<DeliveryInfo | null> {
  const { data, error } = await supabase.rpc('listing_delivery_info', { p_listing: listingId });
  if (error) throw error;
  return (data as DeliveryInfo | null) ?? null;
}

export async function checkDelivery(listingId: string, locationId: number | null): Promise<Coverage> {
  const { data, error } = await supabase.rpc('delivery_check', { p_listing: listingId, p_location: locationId });
  if (error) throw error;
  return data as Coverage;
}

export async function sharePickupAddress(orderId: string, addressId: string): Promise<void> {
  const { error } = await supabase.rpc('share_pickup_address', { p_order: orderId, p_address: addressId });
  if (error) throw error;
}
