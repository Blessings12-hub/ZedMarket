import Constants from 'expo-constants';
import { Platform } from 'react-native';

import { registerPushToken, unregisterPushToken } from './api';

// Push needs the `expo-notifications` package and a development or production build with a
// project id; it does not work in Expo Go. The package is loaded only if it is installed, so the
// app still runs without it. UNTESTED on a real phone: check against Expo's notifications docs.
function loadModule(): any | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    return require('expo-notifications');
  } catch {
    return null;
  }
}

let currentToken: string | null = null;

export async function enablePush(projectId?: string): Promise<'on' | 'denied' | 'unavailable'> {
  const N = loadModule();
  if (!N || Platform.OS === 'web') return 'unavailable';
  try {
    let { status } = await N.getPermissionsAsync();
    if (status !== 'granted') status = (await N.requestPermissionsAsync()).status;
    if (status !== 'granted') return 'denied';
    // The project id appears in app.json (extra.eas.projectId) once the owner runs `eas init`.
    const id = projectId ?? (Constants.expoConfig?.extra as { eas?: { projectId?: string } } | undefined)?.eas?.projectId;
    if (!id) return 'unavailable';
    const res = await N.getExpoPushTokenAsync({ projectId: id });
    currentToken = res.data as string;
    await registerPushToken(currentToken, Platform.OS === 'ios' ? 'ios' : 'android');
    return 'on';
  } catch {
    return 'unavailable';
  }
}

// Call before signing out so the next person on this phone does not get this person's alerts.
export async function disablePushForThisPhone(): Promise<void> {
  if (!currentToken) return;
  const t = currentToken;
  currentToken = null;
  await unregisterPushToken(t).catch(() => undefined);
}

// When someone taps a push notification, hand its link to the router.
export function onNotificationTapped(open: (link: string | null) => void): () => void {
  const N = loadModule();
  if (!N) return () => undefined;
  const sub = N.addNotificationResponseReceivedListener((r: any) => {
    const link = r?.notification?.request?.content?.data?.link;
    open(typeof link === 'string' ? link : null);
  });
  return () => sub.remove();
}

// Show a banner when a notification arrives while the app is open. Call once when the app starts.
export function showPushWhileOpen(): void {
  const N = loadModule();
  if (!N || Platform.OS === 'web') return;
  try {
    N.setNotificationHandler({
      handleNotification: async () => ({ shouldPlaySound: false, shouldSetBadge: false, shouldShowBanner: true, shouldShowList: true }),
    });
  } catch {
    // Push is optional: never stop the app because of it.
  }
}
