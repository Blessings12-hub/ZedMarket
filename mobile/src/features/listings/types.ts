import type { ItemCondition } from '../../domain/listing';

export type VerificationLevel = 'unverified' | 'contact_verified' | 'identity_verified';
export type ListingStatus = 'draft' | 'active' | 'sold' | 'unavailable' | 'removed';
export type ModerationStatus = 'pending' | 'approved' | 'rejected';

export type Category = { id: number; name: string };
export type Location = { id: number; town: string; area: string | null };

export type ListingSummary = {
  id: string;
  title: string;
  price: number;
  condition: ItemCondition;
  area: string;
  imagePath: string | null;
  sellerName: string;
  sellerLevel: VerificationLevel;
};

export type ListingDetail = ListingSummary & {
  description: string;
  warrantyInfo: string | null;
  returnPolicy: string | null;
  postedAt: string;
  status: ListingStatus;
  categoryName: string;
  sellerId: string;
  imagePaths: string[];
};

export type SellerStats = {
  averageRating: number;
  reviewCount: number;
  completedOrders: number;
};

export type MyListing = {
  id: string;
  title: string;
  price: number;
  status: ListingStatus;
  moderationStatus: ModerationStatus;
  moderationNote: string | null;
};

export type SortOrder = 'newest' | 'price_asc' | 'price_desc';

export type Filters = {
  categoryId: number | null;
  locationId: number | null;
  conditions: ItemCondition[];
  minPrice: string;
  maxPrice: string;
  verifiedOnly: boolean;
  sort: SortOrder;
};

export const defaultFilters: Filters = {
  categoryId: null,
  locationId: null,
  conditions: [],
  minPrice: '',
  maxPrice: '',
  verifiedOnly: false,
  sort: 'newest',
};

export function countActiveFilters(f: Filters): number {
  let count = 0;
  if (f.categoryId !== null) count += 1;
  if (f.locationId !== null) count += 1;
  if (f.conditions.length > 0) count += 1;
  if (f.minPrice !== '' || f.maxPrice !== '') count += 1;
  if (f.verifiedOnly) count += 1;
  if (f.sort !== 'newest') count += 1;
  return count;
}
