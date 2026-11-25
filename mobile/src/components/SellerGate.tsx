import { useRouter } from 'expo-router';
import { useEffect, type ReactNode } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../auth/AuthProvider';
import { canUseSellingScreens, gateMessage } from '../domain/sellerAccess';
import { refreshSellingAccess, useSellingAccess } from '../features/seller/status';
import { colors, spacing } from '../theme';
import { Button, Notice } from './ui';

// Wraps every selling screen. Buyers who have not been verified by the team see an invitation to apply instead of the
// screen. This is a courtesy: the database refuses selling actions from anyone who is not approved.
export function SellerGate({ children }: { children: ReactNode }) {
  const router = useRouter();
  const { userId } = useAuth();
  const { access, loaded, failed } = useSellingAccess();

  useEffect(() => {
    if (userId) void refreshSellingAccess(userId);
  }, [userId]);

  if (!userId) {
    return (
      <View style={styles.center}>
        <Text style={styles.title}>Sign in to continue</Text>
        <Button title="Sign in" onPress={() => router.push('/(auth)/sign-in')} />
      </View>
    );
  }
  if (failed) {
    return (
      <View style={styles.center}>
        <Notice tone="error">We could not check your seller status. Check your connection and try again.</Notice>
        <Button title="Try again" variant="secondary" onPress={() => void refreshSellingAccess(userId)} />
      </View>
    );
  }
  if (!loaded) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }
  if (canUseSellingScreens(access)) return <>{children}</>;

  const m = gateMessage(access.status);
  return (
    <View style={styles.center}>
      <Text style={styles.title}>{m.title}</Text>
      <Text style={styles.body}>{m.body}</Text>
      <Button title={m.action} onPress={() => router.replace('/verify/seller')} />
      <Button title="Back to my account" variant="secondary" onPress={() => router.replace('/(tabs)/account')} />
    </View>
  );
}

const styles = StyleSheet.create({
  center: { flex: 1, justifyContent: 'center', gap: spacing.md, padding: spacing.lg, backgroundColor: colors.background },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.muted, lineHeight: 22 },
});
