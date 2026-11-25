// Who may see selling tools. ZedMarket is a buying app first: a person becomes a seller only after the verification
// team approves them (profiles.seller_status = 'active'). Nothing here grants access: the database checks every action
// again. This only decides which screens and buttons are shown, so it can be tested without a phone.

export type SellerStatus = 'none' | 'active' | 'suspended' | 'revoked';

export type SellingAccess = {
  status: SellerStatus;
  // Member of at least one business. Business listings are checked against the business by the database, so business
  // members can open the selling screens even when they are not approved as an individual seller.
  hasBusiness: boolean;
};

export const NO_ACCESS: SellingAccess = { status: 'none', hasBusiness: false };

export function toSellerStatus(value: unknown): SellerStatus {
  return value === 'active' || value === 'suspended' || value === 'revoked' ? value : 'none';
}

// The Orders tab in the bottom bar is a selling tool. Buyers reach their purchases from the Account Hub instead.
export const showOrdersTab = (status: SellerStatus): boolean => status === 'active';

// Selling screens (post a listing, my listings, seller numbers, delivery places) open for approved sellers and for
// business members only.
export const canUseSellingScreens = (a: SellingAccess): boolean => a.status === 'active' || a.hasBusiness;

// "Share profile" shares a seller page, so only an approved seller gets it.
export const canShareSellerProfile = (status: SellerStatus): boolean => status === 'active';

// The Selling filter and "You are selling" labels. Someone who used to sell keeps seeing their old orders.
export const showSellingOrders = (status: SellerStatus, hasSellingOrders: boolean): boolean => status !== 'none' || hasSellingOrders;

export type GateMessage = { title: string; body: string; action: string };

// What a person sees if they reach a selling screen without being approved.
export function gateMessage(status: SellerStatus): GateMessage {
  if (status === 'suspended' || status === 'revoked') {
    return {
      title: status === 'revoked' ? 'Selling has been revoked' : 'Selling is switched off',
      body: 'Your listings and history are kept. You can read why and how to ask for a review.',
      action: 'See what happened',
    };
  }
  return {
    title: 'Selling is for verified sellers',
    body: 'ZedMarket is a place to buy first. To sell, send a short application and our team will verify you. Selling tools appear in your Account once you are approved.',
    action: 'Become a seller',
  };
}
