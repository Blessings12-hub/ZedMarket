import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { ActivityIndicator, View } from 'react-native';

import { AuthProvider, useAuth } from '../src/auth/AuthProvider';
import { isPublicRoute } from '../src/domain/routes';
import { colors } from '../src/theme';

// Signed-out visitors can browse, open listings and seller pages, and see the sign-in screens.
// Anything that needs an account sends them to sign in. Signed-in users never see the (auth) screens.
function AuthGate() {
  const { session, loading } = useAuth();
  const segments = useSegments();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;
    const inAuthGroup = segments[0] === '(auth)';
    if (!session && !isPublicRoute(segments)) router.replace('/sign-in');
    else if (session && inAuthGroup) router.replace('/');
  }, [session, loading, segments, router]);

  if (loading) {
    return (
      <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background }}>
        <ActivityIndicator color={colors.primary} />
      </View>
    );
  }

  return (
    <Stack screenOptions={{ headerTintColor: colors.primary, headerStyle: { backgroundColor: colors.surface } }}>
      <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
      <Stack.Screen name="(auth)" options={{ headerShown: false }} />
      <Stack.Screen name="listing/[id]" options={{ title: 'Listing' }} />
      <Stack.Screen name="chat/[id]" options={{ title: 'Chat' }} />
      <Stack.Screen name="report" options={{ title: 'Report', presentation: 'modal' }} />
      <Stack.Screen name="orders" options={{ title: 'Your orders' }} />
      <Stack.Screen name="saved" options={{ title: 'Saved items' }} />
      <Stack.Screen name="verify/index" options={{ title: 'Get verified' }} />
      <Stack.Screen name="verify/identity" options={{ title: 'Identity check' }} />
      <Stack.Screen name="verify/business" options={{ title: 'Business' }} />
      <Stack.Screen name="review/[orderId]" options={{ title: 'Leave a review' }} />
      <Stack.Screen name="seller/[id]" options={{ title: 'Seller' }} />
      <Stack.Screen name="alerts" options={{ title: 'Saved searches and alerts' }} />
      <Stack.Screen name="dispute/open" options={{ title: 'Report a problem' }} />
      <Stack.Screen name="dispute/[id]" options={{ title: 'Dispute' }} />
      <Stack.Screen name="appeal" options={{ title: 'Appeal a decision' }} />
      <Stack.Screen name="admin/index" options={{ title: 'Staff tools' }} />
      <Stack.Screen name="admin/listings" options={{ title: 'Listings to review' }} />
      <Stack.Screen name="admin/reports" options={{ title: 'Open reports' }} />
      <Stack.Screen name="admin/report/[id]" options={{ title: 'Report' }} />
      <Stack.Screen name="admin/verifications" options={{ title: 'Verification requests' }} />
      <Stack.Screen name="admin/disputes" options={{ title: 'Disputes' }} />
      <Stack.Screen name="admin/dispute/[id]" options={{ title: 'Dispute' }} />
      <Stack.Screen name="admin/appeals" options={{ title: 'Appeals' }} />
      <Stack.Screen name="admin/flags" options={{ title: 'Risk flags' }} />
      <Stack.Screen name="admin/team" options={{ title: 'Staff team' }} />
      <Stack.Screen name="admin/audit" options={{ title: 'Audit log' }} />
    </Stack>
  );
}

export default function RootLayout() {
  return (
    <AuthProvider>
      <StatusBar style="dark" />
      <AuthGate />
    </AuthProvider>
  );
}
