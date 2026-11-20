import * as ImageManipulator from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';

import { MAX_PHOTOS, type ItemCondition } from '../../domain/listing';
import { parsePrice } from '../../domain/money';
import { searchFilter } from '../../domain/search';
import { supabase } from '../../lib/supabase';
import type {
  Category,
  Filters,
  ListingDetail,
  ListingStatus,
  ListingSummary,
  Location,
  ModerationStatus,
  MyListing,
  SellerStats,
  VerificationLevel,
} from './types';

export const PAGE_SIZE = 20;
const PHOTO_WIDTH = 1280;

type RawImage = { storage_path: string; position: number };
type RawListing = {
  id: string;
  title: string;
  price_zmw: number;
  condition: ItemCondition;
  location: { area: string | null; town: string } | null;
  seller: { id: string; display_name: string; verification_level: VerificationLevel } | null;
  images: RawImage[] | null;
};

const SUMMARY_COLUMNS = `
  id, title, price_zmw, condition,
  location:locations(area, town),
  seller:profiles!inner(id, display_name, verification_level),
  images:listing_images(storage_path, position)
`;

function sortedImages(images: RawImage[] | null): RawImage[] {
  return [...(images ?? [])].sort((a, b) => a.position - b.position);
}

function toSummary(row: RawListing): ListingSummary {
  return {
    id: row.id,
    title: row.title,
    price: Number(row.price_zmw),
    condition: row.condition,
    area: row.location?.area ?? row.location?.town ?? '',
    imagePath: sortedImages(row.images)[0]?.storage_path ?? null,
    sellerName: row.seller?.display_name ?? '',
    sellerLevel: row.seller?.verification_level ?? 'unverified',
  };
}

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

let referenceCache: Promise<{ categories: Category[]; locations: Location[] }> | null = null;

export function loadReferenceData() {
  if (!referenceCache) {
    referenceCache = Promise.all([
      supabase.from('categories').select('id, name').eq('is_active', true).order('sort_order'),
      supabase.from('locations').select('id, town, area').order('area', { nullsFirst: true }),
    ]).then(([categories, locations]) => {
      if (categories.error) throw categories.error;
      if (locations.error) throw locations.error;
      return { categories: categories.data as Category[], locations: locations.data as Location[] };
    });
    referenceCache.catch(() => {
      referenceCache = null;
    });
  }
  return referenceCache;
}

// ---------------------------------------------------------------------------
// Browsing
// ---------------------------------------------------------------------------

export async function fetchListings(term: string, filters: Filters, page: number): Promise<ListingSummary[]> {
  let query = supabase
    .from('listings')
    .select(SUMMARY_COLUMNS)
    .eq('status', 'active')
    .eq('moderation_status', 'approved');

  const text = searchFilter(term);
  if (text) query = query.or(text);

  if (filters.categoryId !== null) query = query.eq('category_id', filters.categoryId);
  if (filters.locationId !== null) query = query.eq('location_id', filters.locationId);
  if (filters.conditions.length > 0) query = query.in('condition', filters.conditions);
  if (filters.verifiedOnly) query = query.neq('seller.verification_level', 'unverified');

  const min = parsePrice(filters.minPrice);
  const max = parsePrice(filters.maxPrice);
  if (min !== null) query = query.gte('price_zmw', min);
  if (max !== null) query = query.lte('price_zmw', max);

  if (filters.sort === 'price_asc') query = query.order('price_zmw', { ascending: true });
  else if (filters.sort === 'price_desc') query = query.order('price_zmw', { ascending: false });
  else query = query.order('created_at', { ascending: false });

  const from = page * PAGE_SIZE;
  const { data, error } = await query.range(from, from + PAGE_SIZE - 1);
  if (error) throw error;
  return (data as unknown as RawListing[]).map(toSummary);
}

export async function fetchListing(id: string): Promise<ListingDetail> {
  const { data, error } = await supabase
    .from('listings')
    .select(
      `${SUMMARY_COLUMNS}, description, warranty_info, return_policy, created_at, status,
       category:categories(name)`,
    )
    .eq('id', id)
    .single();
  if (error) throw error;

  const row = data as unknown as RawListing & {
    description: string;
    warranty_info: string | null;
    return_policy: string | null;
    created_at: string;
    status: ListingStatus;
    category: { name: string } | null;
  };

  return {
    ...toSummary(row),
    description: row.description,
    warrantyInfo: row.warranty_info,
    returnPolicy: row.return_policy,
    postedAt: row.created_at,
    status: row.status,
    categoryName: row.category?.name ?? '',
    sellerId: row.seller?.id ?? '',
    imagePaths: sortedImages(row.images).map((i) => i.storage_path),
  };
}

export async function fetchSellerStats(sellerId: string): Promise<SellerStats> {
  const { data, error } = await supabase
    .from('seller_stats')
    .select('average_rating, review_count, completed_orders')
    .eq('seller_id', sellerId)
    .maybeSingle();
  if (error) throw error;
  return {
    averageRating: Number(data?.average_rating ?? 0),
    reviewCount: data?.review_count ?? 0,
    completedOrders: data?.completed_orders ?? 0,
  };
}

// ---------------------------------------------------------------------------
// Favourites
// ---------------------------------------------------------------------------

export async function isFavourite(listingId: string): Promise<boolean> {
  const { count, error } = await supabase
    .from('favourites')
    .select('listing_id', { count: 'exact', head: true })
    .eq('listing_id', listingId);
  if (error) throw error;
  return (count ?? 0) > 0;
}

export async function setFavourite(listingId: string, saved: boolean): Promise<void> {
  const { error } = saved
    ? await supabase.from('favourites').insert({ listing_id: listingId })
    : await supabase.from('favourites').delete().eq('listing_id', listingId);
  if (error) throw error;
}

export async function fetchFavourites(): Promise<ListingSummary[]> {
  const { data, error } = await supabase
    .from('favourites')
    .select(`created_at, listing:listings!inner(${SUMMARY_COLUMNS})`)
    .order('created_at', { ascending: false });
  if (error) throw error;
  const rows = data as unknown as { listing: RawListing }[];
  return rows.map((r) => toSummary(r.listing));
}

// ---------------------------------------------------------------------------
// A seller's own listings
// ---------------------------------------------------------------------------

export async function fetchMyListings(userId: string): Promise<MyListing[]> {
  const { data, error } = await supabase
    .from('listings')
    .select('id, title, price_zmw, status, moderation_status, moderation_note')
    .eq('seller_id', userId)
    .neq('status', 'removed')
    .order('created_at', { ascending: false });
  if (error) throw error;

  return (data as unknown as {
    id: string;
    title: string;
    price_zmw: number;
    status: ListingStatus;
    moderation_status: ModerationStatus;
    moderation_note: string | null;
  }[]).map((r) => ({
    id: r.id,
    title: r.title,
    price: Number(r.price_zmw),
    status: r.status,
    moderationStatus: r.moderation_status,
    moderationNote: r.moderation_note,
  }));
}

export async function setListingStatus(id: string, status: Exclude<ListingStatus, 'removed'>): Promise<void> {
  const { error } = await supabase.from('listings').update({ status }).eq('id', id);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Creating a listing
// ---------------------------------------------------------------------------

export type PickedPhoto = { uri: string };

// Photos are resized and re-encoded before upload. That keeps data use low and
// drops metadata such as the GPS position stored in the original file.
export async function pickPhotos(remaining: number): Promise<PickedPhoto[]> {
  if (remaining <= 0) return [];

  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['images'],
    allowsMultipleSelection: true,
    selectionLimit: Math.min(remaining, MAX_PHOTOS),
    quality: 1,
  });
  if (result.canceled) return [];

  const prepared: PickedPhoto[] = [];
  for (const asset of result.assets) {
    const actions = asset.width > PHOTO_WIDTH ? [{ resize: { width: PHOTO_WIDTH } }] : [];
    const out = await ImageManipulator.manipulateAsync(asset.uri, actions, {
      compress: 0.75,
      format: ImageManipulator.SaveFormat.JPEG,
    });
    prepared.push({ uri: out.uri });
  }
  return prepared;
}

export type NewListing = {
  userId: string;
  title: string;
  price: number;
  description: string;
  categoryId: number;
  locationId: number;
  condition: ItemCondition;
  warrantyInfo: string;
  returnPolicy: string;
  photos: PickedPhoto[];
};

export type PublishResult = { id: string; moderationStatus: ModerationStatus; status: ListingStatus };

// A listing starts as a draft, photos are added, then it is published. The database
// refuses to publish without a photo and decides whether a moderator must look first.
export async function publishListing(input: NewListing): Promise<PublishResult> {
  const created = await supabase
    .from('listings')
    .insert({
      title: input.title.trim(),
      price_zmw: input.price,
      description: input.description.trim(),
      category_id: input.categoryId,
      location_id: input.locationId,
      condition: input.condition,
      warranty_info: input.warrantyInfo.trim() || null,
      return_policy: input.returnPolicy.trim() || null,
    })
    .select('id')
    .single();
  if (created.error) throw created.error;

  const listingId = created.data.id as string;
  const uploaded: string[] = [];

  try {
    for (let i = 0; i < input.photos.length; i += 1) {
      const photo = input.photos[i];
      if (!photo) continue;

      const body = await (await fetch(photo.uri)).arrayBuffer();
      const path = `${input.userId}/${listingId}/${i}.jpg`;

      const upload = await supabase.storage.from('listing-images').upload(path, body, {
        contentType: 'image/jpeg',
        upsert: false,
      });
      if (upload.error) throw upload.error;
      uploaded.push(path);

      const row = await supabase.from('listing_images').insert({ listing_id: listingId, storage_path: path, position: i });
      if (row.error) throw row.error;
    }

    const published = await supabase
      .from('listings')
      .update({ status: 'active' })
      .eq('id', listingId)
      .select('id, status, moderation_status')
      .single();
    if (published.error) throw published.error;

    return {
      id: listingId,
      status: published.data.status as ListingStatus,
      moderationStatus: published.data.moderation_status as ModerationStatus,
    };
  } catch (error) {
    // Clean up so a failed attempt does not leave a half-finished listing behind.
    if (uploaded.length > 0) await supabase.storage.from('listing-images').remove(uploaded);
    await supabase.from('listings').delete().eq('id', listingId);
    throw error;
  }
}
