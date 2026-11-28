// The three short screens a new person sees once, after their first sign-in.
export type WelcomeSlide = { title: string; body: string };

export const WELCOME_SLIDES: WelcomeSlide[] = [
  { title: 'Find what you need', body: 'Browse items and services near you, save what you like, and message sellers. You can look around even before you sign in.' },
  { title: 'Sellers are checked', body: 'ZedMarket is a place to buy first. Anyone who wants to sell is verified by our team, and verified sellers and shops carry a badge.' },
  { title: 'Stay safe', body: 'Look at the item before you pay, meet in a public place and never share your PIN. Our safety page has the full list.' },
];

export const WELCOME_FLAG = 'welcome_seen';

// Shown once per phone. `seen` is null while the phone is still being asked, and the answer is unknown if reading failed:
// in both cases nothing is shown, so a storage problem can never trap someone on this screen.
export function shouldShowWelcome(seen: boolean | null, loaded: boolean): boolean {
  return loaded && seen === false;
}
