import Constants from 'expo-constants';
import { Platform } from 'react-native';

import { createDeduper, describeError } from '../domain/errorReport';
import { supabase } from './supabase';

// Tells the ZedMarket team the app crashed, so a problem on someone else's phone is seen. It must never cause a
// second problem: everything here is wrapped, and a failed report is simply dropped.
const shouldSend = createDeduper();
let currentRoute = '';

export function setCurrentRoute(route: string): void {
  currentRoute = route;
}

export function reportError(error: unknown, where?: string): void {
  try {
    const report = describeError(error);
    if (!shouldSend(report)) return;
    const version = (Constants.expoConfig?.version as string | undefined) ?? null;
    void Promise.resolve(
      supabase.rpc('report_client_error', {
        p_message: report.message,
        p_stack: report.stack,
        p_route: where ?? (currentRoute || null),
        p_platform: Platform.OS === 'android' || Platform.OS === 'ios' || Platform.OS === 'web' ? Platform.OS : 'unknown',
        p_app_version: version,
      }),
    ).catch(() => undefined);
  } catch {
    // Reporting is best effort.
  }
}

let installed = false;

// Catches crashes that no screen handled. Installed once, when the app starts.
export function installErrorReporting(): void {
  if (installed) return;
  installed = true;
  try {
    const g = globalThis as unknown as {
      ErrorUtils?: { getGlobalHandler: () => (e: unknown, fatal?: boolean) => void; setGlobalHandler: (h: (e: unknown, fatal?: boolean) => void) => void };
      addEventListener?: (type: string, listener: (e: { error?: unknown; reason?: unknown; message?: string }) => void) => void;
    };
    if (g.ErrorUtils) {
      const previous = g.ErrorUtils.getGlobalHandler();
      g.ErrorUtils.setGlobalHandler((e, fatal) => {
        reportError(e);
        previous(e, fatal);
      });
    } else if (Platform.OS === 'web' && g.addEventListener) {
      g.addEventListener('error', (e) => reportError(e.error ?? e.message));
      g.addEventListener('unhandledrejection', (e) => reportError(e.reason));
    }
  } catch {
    // Not available in this environment.
  }
}
