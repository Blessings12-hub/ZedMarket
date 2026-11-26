import type { BusinessRole } from '../../domain/business';
import { supabase } from '../../lib/supabase';

type Row = Record<string, any>;

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

// ---------------------------------------------------------------------------
// Public storefront (works for signed-out visitors)
// ---------------------------------------------------------------------------

export type Storefront = {
  id: string;
  name: string;
  slug: string;
  description: string | null;
  logoPath: string | null;
  town: string | null;
  area: string | null;
  address: string | null;
  verified: boolean;
  registrationKind: 'registered' | 'informal_trader' | null;
  listingCount: number;
};

export type StorefrontBranch = { id: string; name: string; area: string | null; address: string | null; phone: string | null; isMain: boolean };
export type StorefrontCatalogue = { id: string; name: string; description: string | null; listingCount: number };
export type StorefrontListing = {
  id: string;
  title: string;
  price: number;
  condition: string;
  area: string | null;
  imagePath: string | null;
  branchName: string | null;
};

export const STOREFRONT_PAGE = 24;

export async function fetchStorefront(slug: string): Promise<Storefront | null> {
  const { data, error } = await supabase.from('public_businesses').select('*').eq('slug', slug).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const r = data as Row;
  return {
    id: r.id,
    name: r.name,
    slug: r.slug,
    description: r.description,
    logoPath: r.logo_path,
    town: r.town,
    area: r.area,
    address: r.address_text,
    verified: !!r.verified,
    registrationKind: r.registration_kind === 'informal_trader' ? 'informal_trader' : r.registration_kind === 'registered' ? 'registered' : null,
    listingCount: Number(r.listing_count),
  };
}

export async function fetchStorefrontBranches(businessId: string): Promise<StorefrontBranch[]> {
  const { data, error } = await supabase
    .from('public_business_branches')
    .select('id, name, area, address_text, phone, is_main')
    .eq('business_id', businessId)
    .order('is_main', { ascending: false });
  if (error) throw error;
  return ((data ?? []) as Row[]).map((b) => ({ id: b.id, name: b.name, area: b.area, address: b.address_text, phone: b.phone, isMain: b.is_main }));
}

export async function fetchStorefrontCatalogues(businessId: string): Promise<StorefrontCatalogue[]> {
  const { data, error } = await supabase
    .from('public_business_catalogues')
    .select('id, name, description, listing_count')
    .eq('business_id', businessId)
    .order('position');
  if (error) throw error;
  return ((data ?? []) as Row[]).map((c) => ({ id: c.id, name: c.name, description: c.description, listingCount: Number(c.listing_count) }));
}

export async function fetchStorefrontListings(businessId: string, catalogueId: string | null, term: string, offset: number): Promise<StorefrontListing[]> {
  const rows = await rpc<Row[]>('business_storefront_listings', {
    p_business: businessId,
    p_catalogue: catalogueId,
    p_term: term.trim() || null,
    p_limit: STOREFRONT_PAGE,
    p_offset: offset,
  });
  return rows.map((r) => ({
    id: r.id,
    title: r.title,
    price: Number(r.price_zmw),
    condition: r.condition,
    area: r.area,
    imagePath: r.image_path,
    branchName: r.branch_name,
  }));
}

// ---------------------------------------------------------------------------
// My businesses and invitations
// ---------------------------------------------------------------------------

export type MyMembership = { businessId: string; name: string; slug: string; role: BusinessRole };

export async function fetchMyMemberships(userId: string): Promise<MyMembership[]> {
  const { data, error } = await supabase
    .from('business_members')
    .select('role, business:businesses(id, name, slug)')
    .eq('user_id', userId);
  if (error) throw error;
  return ((data ?? []) as unknown as Array<{ role: BusinessRole; business: { id: string; name: string; slug: string } | null }>).flatMap((m) =>
    m.business ? [{ businessId: m.business.id, name: m.business.name, slug: m.business.slug, role: m.role }] : [],
  );
}

export type Invitation = { id: string; businessName: string; role: BusinessRole; invitedBy: string; expiresAt: string };

export async function fetchMyInvitations(): Promise<Invitation[]> {
  const rows = await rpc<Row[]>('my_invitations');
  return rows.map((r) => ({ id: r.id, businessName: r.business_name, role: r.role, invitedBy: r.invited_by_name, expiresAt: r.expires_at }));
}

// Deletes a business for good. Only the owner can; the database refuses while orders are open.
export const closeBusiness = (businessId: string, reason?: string) => rpc<void>('business_close', { p_business: businessId, p_reason: reason ?? null });

export const respondToInvitation = (id: string, accept: boolean) => rpc<void>('respond_invitation', { p_invitation: id, p_accept: accept });

// ---------------------------------------------------------------------------
// Team
// ---------------------------------------------------------------------------

export type TeamMember = { userId: string; name: string; role: BusinessRole; joinedAt: string };
export type OpenInvitation = { id: string; email: string; role: BusinessRole; expiresAt: string };

export async function fetchTeam(businessId: string): Promise<TeamMember[]> {
  const rows = await rpc<Row[]>('business_team', { p_business: businessId });
  return rows.map((r) => ({ userId: r.user_id, name: r.display_name, role: r.role, joinedAt: r.joined_at }));
}

export async function fetchOpenInvitations(businessId: string): Promise<OpenInvitation[]> {
  const rows = await rpc<Row[]>('business_open_invitations', { p_business: businessId });
  return rows.map((r) => ({ id: r.id, email: r.email, role: r.role, expiresAt: r.expires_at }));
}

export const inviteMember = (businessId: string, email: string, role: BusinessRole) =>
  rpc<string>('invite_member', { p_business: businessId, p_email: email.trim(), p_role: role });
export const revokeInvitation = (id: string) => rpc<void>('revoke_invitation', { p_invitation: id });
export const changeMemberRole = (businessId: string, userId: string, role: BusinessRole) =>
  rpc<void>('set_member_role', { p_business: businessId, p_user: userId, p_role: role });
export const removeMember = (businessId: string, userId: string) => rpc<void>('remove_member', { p_business: businessId, p_user: userId });

// ---------------------------------------------------------------------------
// Branches and catalogues (managers and owners)
// ---------------------------------------------------------------------------

export type Branch = { id: string; name: string; address: string | null; phone: string | null; isMain: boolean; active: boolean; locationId: number | null };

export async function fetchBranches(businessId: string): Promise<Branch[]> {
  const { data, error } = await supabase
    .from('business_branches')
    .select('id, name, address_text, phone, is_main, active, location_id')
    .eq('business_id', businessId)
    .order('is_main', { ascending: false })
    .order('name');
  if (error) throw error;
  return ((data ?? []) as Row[]).map((b) => ({
    id: b.id,
    name: b.name,
    address: b.address_text,
    phone: b.phone,
    isMain: b.is_main,
    active: b.active,
    locationId: b.location_id,
  }));
}

export const createBranch = (businessId: string, name: string, address: string, phone: string, isMain: boolean) =>
  rpc<string>('create_branch', {
    p_business: businessId,
    p_name: name.trim(),
    p_location_id: null,
    p_address: address.trim() || null,
    p_phone: phone.trim() || null,
    p_is_main: isMain,
  });

export const saveBranch = (b: Branch, changes: Partial<Pick<Branch, 'name' | 'address' | 'phone' | 'active' | 'isMain'>>) => {
  const next = { ...b, ...changes };
  return rpc<void>('update_branch', {
    p_branch: b.id,
    p_name: next.name.trim(),
    p_location_id: next.locationId,
    p_address: next.address?.trim() || null,
    p_phone: next.phone?.trim() || null,
    p_active: next.active,
    p_is_main: next.isMain,
  });
};

export type Catalogue = { id: string; name: string; description: string | null; visible: boolean; position: number };

export async function fetchCatalogues(businessId: string): Promise<Catalogue[]> {
  const { data, error } = await supabase
    .from('business_catalogues')
    .select('id, name, description, is_visible, position')
    .eq('business_id', businessId)
    .order('position');
  if (error) throw error;
  return ((data ?? []) as Row[]).map((c) => ({ id: c.id, name: c.name, description: c.description, visible: c.is_visible, position: c.position }));
}

export const createCatalogue = (businessId: string, name: string, description: string) =>
  rpc<string>('create_catalogue', { p_business: businessId, p_name: name.trim(), p_description: description.trim() || null });
export const saveCatalogue = (c: Catalogue, changes: Partial<Pick<Catalogue, 'name' | 'description' | 'visible'>>) => {
  const next = { ...c, ...changes };
  return rpc<void>('update_catalogue', {
    p_catalogue: c.id,
    p_name: next.name.trim(),
    p_description: next.description?.trim() || null,
    p_visible: next.visible,
    p_position: next.position,
  });
};
export const deleteCatalogue = (id: string) => rpc<void>('delete_catalogue', { p_catalogue: id });

export type BusinessListing = { id: string; title: string; status: string };

export async function fetchBusinessListings(businessId: string): Promise<BusinessListing[]> {
  const { data, error } = await supabase
    .from('listings')
    .select('id, title, status')
    .eq('business_id', businessId)
    .neq('status', 'removed')
    .order('title');
  if (error) throw error;
  return (data ?? []) as BusinessListing[];
}

export async function fetchCatalogueListingIds(catalogueId: string): Promise<string[]> {
  const { data, error } = await supabase.from('catalogue_listings').select('listing_id, position').eq('catalogue_id', catalogueId).order('position');
  if (error) throw error;
  return ((data ?? []) as Row[]).map((r) => r.listing_id as string);
}

export const setCatalogueListings = (catalogueId: string, listingIds: string[]) =>
  rpc<void>('set_catalogue_listings', { p_catalogue: catalogueId, p_listing_ids: listingIds });

// ---------------------------------------------------------------------------
// Inventory
// ---------------------------------------------------------------------------

export type InventoryFilter = 'all' | 'tracked' | 'untracked' | 'low' | 'out';
export type InventoryRow = {
  listingId: string;
  title: string;
  status: string;
  branchName: string | null;
  tracked: boolean;
  quantity: number | null;
  lowStockAt: number | null;
  isLow: boolean;
};
export type StockMove = { id: number; change: number; quantityAfter: number; reason: string; note: string | null; actorName: string | null; createdAt: string };

export async function fetchInventory(businessId: string, filter: InventoryFilter, offset = 0): Promise<InventoryRow[]> {
  const rows = await rpc<Row[]>('business_inventory', { p_business: businessId, p_filter: filter, p_limit: 50, p_offset: offset });
  return rows.map((r) => ({
    listingId: r.listing_id,
    title: r.title,
    status: r.status,
    branchName: r.branch_name,
    tracked: r.tracked,
    quantity: r.quantity,
    lowStockAt: r.low_stock_at,
    isLow: r.is_low,
  }));
}

export const trackStock = (listingId: string, quantity: number, lowAt: number) =>
  rpc<void>('track_stock', { p_listing: listingId, p_quantity: quantity, p_low_stock_at: lowAt });
export const adjustStock = (listingId: string, change: number, reason: string, note: string) =>
  rpc<number>('adjust_stock', { p_listing: listingId, p_change: change, p_reason: reason, p_note: note.trim() || null });

export async function fetchStockHistory(listingId: string): Promise<StockMove[]> {
  const rows = await rpc<Row[]>('stock_history', { p_listing: listingId, p_limit: 30 });
  return rows.map((r) => ({
    id: Number(r.id),
    change: r.change,
    quantityAfter: r.quantity_after,
    reason: r.reason,
    note: r.note,
    actorName: r.actor_name,
    createdAt: r.created_at,
  }));
}

// ---------------------------------------------------------------------------
// Orders and analytics
// ---------------------------------------------------------------------------

export type BusinessOrder = {
  id: string;
  itemTitle: string;
  price: number;
  status: 'requested' | 'confirmed' | 'cancelled' | 'completed' | 'disputed';
  fulfilment: 'collection' | 'delivery';
  buyerName: string;
  deliveryAddress: string | null;
  branchName: string | null;
  createdAt: string;
};

export async function fetchBusinessOrders(businessId: string, status: BusinessOrder['status'] | null, offset = 0): Promise<BusinessOrder[]> {
  const rows = await rpc<Row[]>('business_orders', { p_business: businessId, p_status: status, p_branch: null, p_limit: 30, p_offset: offset });
  return rows.map((r) => ({
    id: r.id,
    itemTitle: r.item_title,
    price: Number(r.item_price_zmw),
    status: r.status,
    fulfilment: r.fulfilment,
    buyerName: r.buyer_name,
    deliveryAddress: r.delivery_address,
    branchName: r.branch_name,
    createdAt: r.created_at,
  }));
}

export type Analytics = {
  periodDays: number;
  ordersReceived: number;
  ordersByStatus: Record<string, number>;
  ordersOpenNow: number;
  completedOrders: number;
  completedValue: number;
  listingViews: number;
  savesTotal: number;
  activeListings: number;
  lowStock: number;
  outOfStock: number;
  topListings: Array<{ id: string; title: string; completed: number; views: number; saves: number }>;
  byBranch: Array<{ branch: string; orders: number; completedValue: number }>;
};

export async function fetchAnalytics(businessId: string, days: number): Promise<Analytics> {
  const a = await rpc<Row>('business_analytics', { p_business: businessId, p_days: days });
  return {
    periodDays: a.period_days,
    ordersReceived: a.orders_received,
    ordersByStatus: a.orders_by_status ?? {},
    ordersOpenNow: a.orders_open_now,
    completedOrders: a.completed_orders,
    completedValue: Number(a.completed_value_zmw),
    listingViews: a.listing_views,
    savesTotal: a.saves_total,
    activeListings: a.active_listings,
    lowStock: a.low_stock,
    outOfStock: a.out_of_stock,
    topListings: (a.top_listings ?? []).map((t: Row) => ({ id: t.id, title: t.title, completed: t.completed, views: t.views, saves: t.saves })),
    byBranch: (a.by_branch ?? []).map((b: Row) => ({ branch: b.branch, orders: b.orders, completedValue: Number(b.completed_value_zmw) })),
  };
}
