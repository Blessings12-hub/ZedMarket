import * as ImageManipulator from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';

import { MAX_PHOTOS, type ItemCondition } from '../../domain/listing';
import { parsePrice } from '../../domain/money';
import { cleanSearchTerm } from '../../domain/search';
import { supabase } from '../../lib/supabase';
import { readPhoto, uploadObject } from '../../lib/storage';
import { isMissingFunction } from './area';
import type {
  Category,
  Filters,
  ListingDetail,
  ListingAlert,
  ListingStatus,
  ListingSummary,
  Location,
  ModerationStatus,
  MyListing,
  SavedSearch,
  SellerPage,
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

// Rows that come back from the public search functions and views (see migration 0008).
type PublicRow = {
  id: string;
  title: string;
  price_zmw: number;
  condition: ItemCondition;
  town: string;
  area: string | null;
  seller_id: string;
  seller_name: string;
  seller_level: VerificationLevel;
  image_path: string | null;
};

function fromPublic(row: PublicRow): ListingSummary {
  return {
    id: row.id,
    title: row.title,
    price: Number(row.price_zmw),
    condition: row.condition,
    area: row.area ?? row.town,
    imagePath: row.image_path,
    sellerName: row.seller_name,
    sellerLevel: row.seller_level,
  };
}

async function rpcListings(fn: string, args: Record<string, unknown>): Promise<ListingSummary[]> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return (data as PublicRow[]).map(fromPublic);
}

// Works for guests and signed-in users alike. Wildcards in the search word are
// handled by the database function, so the word is only trimmed and capped here.
// With a province, only listings in that province are returned (migration 0030). If the server does not have that
// function yet, the older search runs instead, so the home screen never breaks while the update is pending.
export async function fetchListings(
  term: string,
  filters: Filters,
  page: number,
  sellerId: string | null = null,
  province: string | null = null,
): Promise<ListingSummary[]> {
  const cleaned = cleanSearchTerm(term);
  const args = {
    p_term: cleaned.length >= 2 ? cleaned : null,
    p_category_id: filters.categoryId,
    p_location_id: filters.locationId,
    p_conditions: filters.conditions,
    p_min_price: parsePrice(filters.minPrice),
    p_max_price: parsePrice(filters.maxPrice),
    p_verified_only: filters.verifiedOnly,
    p_sort: filters.sort,
    p_limit: PAGE_SIZE,
    p_offset: page * PAGE_SIZE,
    p_seller_id: sellerId,
  };
  if (province) {
    try {
      return await rpcListings('search_listings_in_province', { p_province: province, ...args });
    } catch (e) {
      if (!isMissingFunction(e)) throw e;
      console.warn('[listings] province search is not on the server yet; using the older search', e);
    }
  }
  return rpcListings('search_listings', args);
}

export const fetchFeatured = () => rpcListings('featured_listings_now', { p_limit: 10 });
export const fetchTrending = () => rpcListings('trending_listings', { p_days: 7, p_limit: 10 });
export const fetchNearby = (locationId: number) =>
  rpcListings('nearby_listings_ranked', { p_location_id: locationId, p_scope: 'district', p_limit: 10, p_offset: 0 });
export const fetchSimilar = (listingId: string) => rpcListings('similar_listings', { p_listing_id: listingId, p_limit: 10 });
export const fetchRecentlyViewed = () => rpcListings('recently_viewed', { p_limit: 20 });
export const fetchRecommended = () => rpcListings('recommended_listings', { p_limit: 10 });

export async function clearRecentlyViewed(): Promise<void> {
  const { error } = await supabase.rpc('clear_recently_viewed');
  if (error) throw error;
}

// Fire and forget: a failed view count must never get in the way of reading a listing.
export function recordView(listingId: string): void {
  void supabase.rpc('record_listing_view', { p_listing_id: listingId }).then(() => undefined, () => undefined);
}

// The public page first (works for guests). If nothing comes back and the person
// is signed in, it may be their own paused, sold or unreviewed listing.
export async function fetchListing(id: string, signedIn: boolean): Promise<ListingDetail> {
  const { data, error } = await supabase.from('public_listing_details').select('*').eq('id', id).maybeSingle();
  if (error) throw error;
  if (data) {
    const row = data as PublicRow & {
      description: string;
      warranty_info: string | null;
      return_policy: string | null;
      created_at: string;
      category_name: string;
      image_paths: string[];
    };
    return {
      ...fromPublic({ ...row, image_path: row.image_paths[0] ?? null }),
      description: row.description,
      warrantyInfo: row.warranty_info,
      returnPolicy: row.return_policy,
      postedAt: row.created_at,
      status: 'active',
      categoryName: row.category_name,
      sellerId: row.seller_id,
      imagePaths: row.image_paths,
    };
  }
  if (!signedIn) throw new Error('This listing is not available.');
  return fetchOwnListing(id);
}

async function fetchOwnListing(id: string): Promise<ListingDetail> {
  const { data, error } = await supabase
    .from('listings')
    .select(
      `${SUMMARY_COLUMNS}, description, warranty_info, return_policy, created_at, status,
       category:categories(name)`,
    )
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new Error('This listing is not available.');

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
  const page = await fetchSellerPage(sellerId);
  return page
    ? { averageRating: page.averageRating, reviewCount: page.reviewCount, completedOrders: page.completedOrders }
    : { averageRating: 0, reviewCount: 0, completedOrders: 0 };
}

export async function fetchSellerPage(sellerId: string): Promise<SellerPage | null> {
  const { data, error } = await supabase.from('public_seller_profiles').select('*').eq('seller_id', sellerId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    sellerId: data.seller_id,
    displayName: data.display_name,
    bio: data.bio,
    level: data.verification_level,
    memberSince: data.member_since,
    averageRating: Number(data.average_rating ?? 0),
    reviewCount: data.review_count ?? 0,
    completedOrders: data.completed_orders ?? 0,
    activeListings: data.active_listings ?? 0,
  };
}

// ---------------------------------------------------------------------------
// Moderators: feature a listing on the home page
// ---------------------------------------------------------------------------

export async function featureListing(listingId: string, days: number): Promise<void> {
  const { error } = await supabase.rpc('feature_listing', { p_listing_id: listingId, p_days: days });
  if (error) throw error;
}

export async function unfeatureListing(listingId: string): Promise<void> {
  const { error } = await supabase.rpc('unfeature_listing', { p_listing_id: listingId });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Saved searches and alerts
// ---------------------------------------------------------------------------

export async function fetchSavedSearches(): Promise<SavedSearch[]> {
  const { data, error } = await supabase
    .from('saved_searches')
    .select('id, name, term, category_id, location_id, min_price, max_price, conditions')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((r) => ({
    id: r.id,
    name: r.name,
    term: r.term,
    categoryId: r.category_id,
    locationId: r.location_id,
    minPrice: r.min_price === null ? null : Number(r.min_price),
    maxPrice: r.max_price === null ? null : Number(r.max_price),
    conditions: r.conditions as ItemCondition[],
  }));
}

export async function saveSearch(name: string, term: string, filters: Filters): Promise<void> {
  const cleaned = cleanSearchTerm(term);
  const { error } = await supabase.from('saved_searches').insert({
    name: name.trim().slice(0, 60),
    term: cleaned.length >= 2 ? cleaned : null,
    category_id: filters.categoryId,
    location_id: filters.locationId,
    min_price: parsePrice(filters.minPrice),
    max_price: parsePrice(filters.maxPrice),
    conditions: filters.conditions,
  });
  if (error) throw error;
}

export async function deleteSavedSearch(id: string): Promise<void> {
  const { error } = await supabase.from('saved_searches').delete().eq('id', id);
  if (error) throw error;
}

export async function fetchAlerts(): Promise<ListingAlert[]> {
  const { data, error } = await supabase
    .from('listing_alerts')
    .select('id, listing_id, created_at, read_at, search:saved_searches(name), listing:listings(title, price_zmw)')
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  const rows = data as unknown as {
    id: string;
    listing_id: string;
    created_at: string;
    read_at: string | null;
    search: { name: string } | null;
    listing: { title: string; price_zmw: number } | null;
  }[];
  return rows
    .filter((r) => r.listing)
    .map((r) => ({
      id: r.id,
      listingId: r.listing_id,
      searchName: r.search?.name ?? '',
      title: r.listing!.title,
      price: Number(r.listing!.price_zmw),
      createdAt: r.created_at,
      read: r.read_at !== null,
    }));
}

export async function countUnreadAlerts(): Promise<number> {
  const { count, error } = await supabase
    .from('listing_alerts')
    .select('id', { count: 'exact', head: true })
    .is('read_at', null);
  if (error) throw error;
  return count ?? 0;
}

export async function markAlertRead(id: string): Promise<void> {
  const { error } = await supabase.from('listing_alerts').update({ read_at: new Date().toISOString() }).eq('id', id);
  if (error) throw error;
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
    .select(`created_at, listing:listings!favourites_listing_id_fkey!inner(${SUMMARY_COLUMNS})`)
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
  // Posting for a business: which business, which branch holds the item, and an optional starting stock count.
  businessId?: string | null;
  branchId?: string | null;
  stock?: number | null;
};

export type PublishResult = { id: string; moderationStatus: ModerationStatus; status: ListingStatus; stockNote?: string };

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
      business_id: input.businessId ?? null,
      branch_id: input.businessId ? (input.branchId ?? null) : null,
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

      const body = await readPhoto(photo.uri);
      const path = `${input.userId}/${listingId}/${i}.jpg`;

      await uploadObject('listing-images', path, body);
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

    // Stock is saved after the listing is live. If this step fails the listing still stands,
    // and the person is told to add the count from Business tools.
    let stockNote: string | undefined;
    if (input.businessId && input.stock !== null && input.stock !== undefined) {
      const tracked = await supabase.rpc('track_stock', { p_listing: listingId, p_quantity: input.stock, p_low_stock_at: 2 });
      if (tracked.error) stockNote = 'Your listing was posted, but the stock count was not saved. Add it from Business tools, then Stock.';
    }

    return {
      stockNote,
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
