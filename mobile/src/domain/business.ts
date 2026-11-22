export type BusinessRole = 'owner' | 'manager' | 'staff';

export type BusinessPermission =
  | 'view_team'
  | 'manage_team'
  | 'edit_profile'
  | 'manage_branches'
  | 'manage_catalogues'
  | 'manage_listings'
  | 'manage_inventory'
  | 'manage_orders'
  | 'view_analytics';

// Same order as the database test, so the two tables can be compared line by line.
export const PERMISSION_ORDER: BusinessPermission[] = [
  'view_team',
  'manage_team',
  'edit_profile',
  'manage_branches',
  'manage_catalogues',
  'manage_listings',
  'manage_inventory',
  'manage_orders',
  'view_analytics',
];

// A copy of business_can() in migration 0011. The database is what really enforces it;
// this only decides which buttons to show.
const MATRIX: Record<BusinessPermission, BusinessRole[]> = {
  view_team: ['owner', 'manager', 'staff'],
  manage_team: ['owner'],
  edit_profile: ['owner', 'manager'],
  manage_branches: ['owner', 'manager'],
  manage_catalogues: ['owner', 'manager'],
  manage_listings: ['owner', 'manager', 'staff'],
  manage_inventory: ['owner', 'manager', 'staff'],
  manage_orders: ['owner', 'manager', 'staff'],
  view_analytics: ['owner', 'manager'],
};

export function roleCan(role: BusinessRole | null | undefined, permission: BusinessPermission): boolean {
  return !!role && MATRIX[permission].includes(role);
}

export function permissionString(role: BusinessRole | null | undefined): string {
  return PERMISSION_ORDER.map((p) => (roleCan(role, p) ? 't' : 'f')).join('');
}

export const ROLE_LABELS: Record<BusinessRole, string> = { owner: 'Owner', manager: 'Manager', staff: 'Staff' };

export const ROLE_EXPLAINED: Record<BusinessRole, string> = {
  owner: 'Everything, including the team.',
  manager: 'Everything except the team. Can see analytics.',
  staff: 'Orders, listings and stock. No analytics, branches, catalogues or team.',
};

export function emailProblem(input: string): string | null {
  const v = input.trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v) || v.length > 254) return 'Enter a valid email address.';
  return null;
}

export function phoneProblem(input: string): string | null {
  const v = input.trim();
  if (v === '') return null;
  return /^\+?[0-9 ]{7,15}$/.test(v) ? null : 'Use digits only, for example +260 971 234 567.';
}

// Returns the whole number, or null if the text is not a sensible stock count.
export function parseQuantity(input: string): number | null {
  const v = input.trim();
  if (!/^-?\d{1,6}$/.test(v)) return null;
  return Number(v);
}

export function stockLabel(quantity: number | null, lowAt: number | null): string {
  if (quantity === null) return 'Stock not tracked';
  if (quantity === 0) return 'Out of stock';
  if (lowAt !== null && quantity <= lowAt) return `Low: ${quantity} left`;
  return `${quantity} in stock`;
}

export const STOCK_REASONS: Array<{ value: 'restock' | 'correction' | 'damaged' | 'return'; label: string; sign: 'add' | 'remove' | 'either' }> = [
  { value: 'restock', label: 'New stock arrived', sign: 'add' },
  { value: 'return', label: 'Customer return', sign: 'add' },
  { value: 'damaged', label: 'Damaged or lost', sign: 'remove' },
  { value: 'correction', label: 'Count correction', sign: 'either' },
];

// Turns what the person typed into the signed change the database expects, or explains the problem.
export function stockChange(
  reason: 'restock' | 'correction' | 'damaged' | 'return',
  amountText: string,
): { change: number } | { problem: string } {
  const n = parseQuantity(amountText);
  if (n === null || n === 0) return { problem: 'Enter a whole number, for example 3.' };
  const spec = STOCK_REASONS.find((r) => r.value === reason)!;
  if (spec.sign === 'either') return { change: n };
  if (n < 0) return { problem: 'Type the number without a minus sign.' };
  return { change: spec.sign === 'add' ? n : -n };
}

export type AnalyticsPeriod = 7 | 30 | 90;
export const PERIODS: AnalyticsPeriod[] = [7, 30, 90];
