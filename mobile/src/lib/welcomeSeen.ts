import { WELCOME_FLAG } from '../domain/welcome';
import { getFlag, setFlag } from './flags';

// Remembers, per person and per phone, that the welcome screens were shown. The in-memory copy is set at once, so the
// app never sends the person back to the welcome screens while the phone is still saving the answer.
const seenNow = new Set<string>();
const key = (userId: string) => `${WELCOME_FLAG}.${userId}`;

export function markWelcomeSeen(userId: string): void {
  seenNow.add(userId);
  void setFlag(key(userId), true);
}

export const welcomeSeenNow = (userId: string): boolean => seenNow.has(userId);

export const readWelcomeSeen = (userId: string): Promise<boolean | null> => getFlag(key(userId));
