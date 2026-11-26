import { roleCan, type BusinessRole } from '../../domain/business';
import { fetchAnalytics, fetchBranches, fetchBusinessListings, fetchBusinessOrders, fetchCatalogues, fetchInventory, fetchStorefront, type Analytics } from './api';
import { stockCounts, type BusinessFacts, type SetupFacts } from './dashboard';

export type BusinessDashboardData = { facts: BusinessFacts; setup: SetupFacts; analytics: Analytics | null; failed: string[] };

// Every piece is loaded on its own and only if this role may see it. A piece that fails is listed in `failed`,
// never shown as zero, and never stops the rest of the Business centre from working.
export async function fetchBusinessDashboard(businessId: string, slug: string, role: BusinessRole): Promise<BusinessDashboardData> {
  const orders = roleCan(role, 'manage_orders');
  const stock = roleCan(role, 'manage_inventory');
  const [req, conf, disp, low, out, store, branches, catalogues, listings, analytics] = await Promise.allSettled([
    orders ? fetchBusinessOrders(businessId, 'requested') : Promise.resolve([]),
    orders ? fetchBusinessOrders(businessId, 'confirmed') : Promise.resolve([]),
    orders ? fetchBusinessOrders(businessId, 'disputed') : Promise.resolve([]),
    stock ? fetchInventory(businessId, 'low') : Promise.resolve([]),
    stock ? fetchInventory(businessId, 'out') : Promise.resolve([]),
    slug ? fetchStorefront(slug) : Promise.resolve(null),
    roleCan(role, 'manage_branches') ? fetchBranches(businessId) : Promise.resolve([]),
    roleCan(role, 'manage_catalogues') ? fetchCatalogues(businessId) : Promise.resolve([]),
    roleCan(role, 'manage_listings') ? fetchBusinessListings(businessId) : Promise.resolve([]),
    roleCan(role, 'view_analytics') ? fetchAnalytics(businessId, 7) : Promise.resolve(null),
  ]);
  const failed: string[] = [];
  const take = <T,>(name: string, r: PromiseSettledResult<T>, fallback: T): T => {
    if (r.status === 'fulfilled') return r.value;
    failed.push(name);
    console.warn(`[business dashboard] ${name} could not be loaded`, r.reason);
    return fallback;
  };
  const requested = take('orders', req, []);
  const confirmed = take('orders', conf, []);
  const disputed = take('orders', disp, []);
  const lowRows = take('stock', low, []);
  const outRows = take('stock', out, []);
  const sf = take('storefront', store, null);
  return {
    facts: { requested: requested.length, confirmed: confirmed.length, disputed: disputed.length, ...stockCounts(lowRows, outRows) },
    setup: {
      branches: take('branches', branches, []).filter((b) => b.active).length,
      products: take('listings', listings, []).filter((l) => l.status === 'active').length,
      catalogues: take('catalogues', catalogues, []).length,
      verified: sf?.verified ?? false,
    },
    analytics: take('analytics', analytics, null),
    failed: [...new Set(failed)],
  };
}
