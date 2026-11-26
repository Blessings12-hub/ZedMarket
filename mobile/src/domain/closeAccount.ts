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
  done: 'Your selling account was deleted.',
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
