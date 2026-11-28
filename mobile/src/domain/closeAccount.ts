// What a person is told before they delete their selling account or a business. Kept in one place so the wording can be
// tested. The database enforces the rules (owner only, no open orders, approved sellers only); this is only the warning.

export type CloseCopy = { heading: string; button: string; intro: string; points: string[]; confirm: string; keep: string; done: string };

export const SELLER_CLOSE: CloseCopy = {
  heading: 'Stop selling',
  button: 'Delete my selling account',
  intro: 'If you no longer want to sell, you can delete your selling account. This cannot be undone.',
  points: [
    'All your personal listings are taken off sale.',
    'You go back to a buyer account. Your purchases, messages and reviews stay.',
    'To sell again you must apply again: a new application, new documents and a new agreement. Our team verifies you from the start.',
    'Your verification documents are deleted after the retention period.',
    'You cannot do this while you have open orders. Finish or cancel them first.',
  ],
  confirm: 'Yes, delete my selling account',
  keep: 'Keep my selling account',
  done: 'Your selling account was closed. You can keep buying on ZedMarket, and your orders, reviews and records are kept.',
};

// A suspended seller can close the selling account instead of waiting. The record of the suspension is kept.
export const SELLER_CLOSE_SUSPENDED: CloseCopy = {
  heading: 'Close your selling account',
  button: 'Close my selling account',
  intro: 'Selling is switched off by our team. You can close your selling account instead of waiting. This cannot be undone.',
  points: [
    'Your listings stay off sale and are taken down.',
    'You go back to a buyer account. Your purchases, messages and reviews stay.',
    'To sell again you must apply again: a new application, new documents and a new agreement. Our team verifies you from the start.',
    'Our team keeps the record of the suspension.',
    'You cannot do this while you have open orders. Finish or cancel them first.',
  ],
  confirm: 'Yes, close my selling account',
  keep: 'Keep it as it is',
  done: 'Your selling account was closed. You can keep buying on ZedMarket, and your orders, reviews and records are kept.',
};

// A revoked seller can close too. Selling stays revoked: that was the team's decision and closing does not undo it.
export const SELLER_CLOSE_REVOKED: CloseCopy = {
  heading: 'Close your selling account',
  button: 'Close my selling account',
  intro: 'Selling approval was withdrawn by our team. You can close your selling account to take your listings down. Selling stays switched off. This cannot be undone.',
  points: [
    'Your listings are taken off sale.',
    'Your buyer account stays. Your purchases, messages and reviews stay.',
    'Selling stays switched off. To ask for a review, contact support.',
    'Your verification documents are deleted after the retention period. Our team keeps the record of what happened.',
    'You cannot do this while you have open orders. Finish or cancel them first.',
  ],
  confirm: 'Yes, close my selling account',
  keep: 'Keep it as it is',
  done: 'Your selling account was closed. Selling stays switched off. You can keep buying on ZedMarket.',
};

export const BUSINESS_CLOSE: CloseCopy = {
  heading: 'Delete this business',
  button: 'Delete this business',
  intro: 'Deleting a business removes it for good. This cannot be undone.',
  points: [
    'The business page, its listings, branches, catalogues, stock and team access are removed.',
    'Past orders and reviews stay on record.',
    'To sell as this business again you must register it again, and it is verified from the start.',
    'Only the owner can do this, and not while the business has open orders.',
  ],
  confirm: 'Yes, delete this business',
  keep: 'Keep this business',
  done: 'The business was deleted.',
};

// Deleting the whole ZedMarket account, for any buyer. The database refuses it while there are open orders and for staff.
export const ACCOUNT_DELETE: CloseCopy = {
  heading: 'Delete your ZedMarket account',
  button: 'Delete my account',
  intro: 'This removes your account from ZedMarket. It cannot be undone.',
  points: [
    'Your name is replaced with "Deleted user", and your email, about line, saved items, saved searches and delivery addresses are removed.',
    'You are signed out everywhere and can no longer sign in with this email.',
    'If you sell, your selling account and any business you own are deleted too, and their listings come off sale.',
    'Orders, chats and reviews stay, so the other person keeps their record. They will see "Deleted user".',
    'You cannot do this while you have open orders. Finish or cancel them first.',
  ],
  confirm: 'Yes, delete my account for good',
  keep: 'Keep my account',
  done: 'Your account was deleted.',
};
