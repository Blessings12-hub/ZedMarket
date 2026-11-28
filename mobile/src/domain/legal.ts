// The Terms of Use and Privacy Notice shown in the app. IMPORTANT: this is a plain-language STARTER text written to
// describe how ZedMarket works today. It has NOT been reviewed by a Zambian lawyer. Do not launch publicly until it has been
// reviewed and replaced or approved, then raise TERMS_VERSION so people accept the new text.

export const TERMS_VERSION = '2026-1';
export const LEGAL_DRAFT_NOTE = 'Draft text. It has not been checked by a lawyer yet and will change before ZedMarket opens to the public.';

export type LegalSection = { title: string; points: string[] };

export const TERMS: LegalSection[] = [
  {
    title: 'What ZedMarket is',
    points: [
      'ZedMarket is a place where people in Zambia list items and services, and where buyers find them. ZedMarket is not the seller and does not own the items listed.',
      'Buyers and sellers agree on the price, the handover and the payment between themselves unless the app says otherwise.',
    ],
  },
  {
    title: 'Your account',
    points: [
      'Give true information and keep your password private. You are responsible for what happens on your account.',
      'You can delete your account in Account, Security and login. Open orders must be finished first.',
    ],
  },
  {
    title: 'Selling',
    points: [
      'Selling is only for people and businesses our team has verified. We may ask for documents and may refuse or stop an account.',
      'Do not list prohibited, stolen, fake or dangerous items. Listings are checked and may be removed.',
    ],
  },
  {
    title: 'Behaving well',
    points: [
      'Be honest and respectful. No threats, harassment, scams or false reviews.',
      'We may remove content, limit an account or suspend it to protect other people. You can appeal a decision from the app.',
    ],
  },
  {
    title: 'Limits',
    points: [
      'We work to keep ZedMarket safe and running, but we cannot promise it will always be available or error free.',
      'We are not responsible for what happens between a buyer and a seller outside what the law requires. Read the safety advice before you pay.',
    ],
  },
];

export const PRIVACY: LegalSection[] = [
  {
    title: 'What we keep',
    points: [
      'Your name, email address and the details you add to your profile, such as an about line, area and delivery addresses.',
      'Your listings, chats, orders, reviews and reports, because these are part of how trading works and how disputes are settled.',
      'For sellers: the identity and business documents you upload for verification.',
      'When the app crashes: the error text, the screen it happened on and the kind of device. No messages or passwords.',
    ],
  },
  {
    title: 'Who sees it',
    points: [
      'Other people see your display name, profile and listings. They do not see your email address.',
      'Our staff see only what their job needs, and what they do is written to an audit log.',
      'Verification documents are seen only by the verification team and are deleted after the retention period.',
    ],
  },
  {
    title: 'Your choices',
    points: [
      'You can edit your profile, and choose which notifications you get.',
      'You can delete your account. Your name is replaced with "Deleted user", your email, saved items and addresses are removed, and sign-in is switched off. Orders and chats stay, because the other person needs their record.',
    ],
  },
  {
    title: 'Questions',
    points: ['Use Help in the app to ask about your information or to report a problem.'],
  },
];
