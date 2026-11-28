// Which screens a signed-out visitor may open. Everything else sends them to sign in.
// Browsing is open to everyone so people can see what is for sale before they make an account.
// Buying, messaging, saving, selling and account screens need a signed-in user.

const PUBLIC_TOP_LEVEL = new Set(['(auth)', 'listing', 'seller', 'legal', 'safety']);

// `segments` is what Expo Router's useSegments() returns, for example
// ['(tabs)'] for the browse tab, ['(tabs)', 'sell'] for the sell tab, ['listing', '[id]'] for a listing.
export function isPublicRoute(segments: readonly string[]): boolean {
  const top = segments[0];
  if (top === undefined) return true;
  if (PUBLIC_TOP_LEVEL.has(top)) return true;
  // A shop's public page is open; the manage screens under /business/manage need sign-in.
  if (top === 'business') return segments.length === 2 && segments[1] === '[slug]';
  // The cart is kept on the phone, so a visitor can use it; checkout itself needs an account.
  if (top === '(tabs)') return segments.length === 1 || segments[1] === 'index' || segments[1] === 'cart';
  return false;
}
