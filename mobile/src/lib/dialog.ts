import { Alert, Platform } from 'react-native';

import { runWebDialog, type DialogButton } from '../domain/dialog';

export type { DialogButton };

// Use this instead of Alert.alert. Same arguments. On a phone it is the native pop-up; in a browser (where Alert does
// nothing) it uses the browser's own message and confirm boxes, so questions and error messages are never lost.
export function showAlert(title: string, message?: string, buttons?: DialogButton[]): void {
  if (Platform.OS !== 'web') {
    Alert.alert(title, message, buttons);
    return;
  }
  const g = globalThis as { confirm?: (t: string) => boolean; alert?: (t: string) => void };
  runWebDialog(title, message, buttons, (t) => (g.confirm ? g.confirm(t) : false), (t) => g.alert?.(t));
}
