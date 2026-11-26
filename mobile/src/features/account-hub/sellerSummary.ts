// Reads my seller application for the Account Hub without letting a failure take the hub down.
// A failure is logged (by loadMine) and reported as an error message next to a null status. It is NOT turned into a
// quiet "no application": the hub shows the message so the person knows the answer is missing.
import { friendlyError } from '../../lib/errors';
import { loadMine, type Logger, type RpcResult } from '../seller-onboarding/mine';
import type { SellerApplicationState } from './hub';

export type SellerApplicationRead = { status: SellerApplicationState | null; error: string | null };

export async function readSellerApplication(call: () => PromiseLike<RpcResult>, log?: Logger): Promise<SellerApplicationRead> {
  try {
    const mine = await loadMine(call, log);
    return { status: mine.application?.status ?? null, error: null };
  } catch (e) {
    return { status: null, error: friendlyError(e) };
  }
}
