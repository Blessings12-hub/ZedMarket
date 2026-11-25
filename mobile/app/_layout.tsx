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
      <Stack.Screen name="addresses/index" options={{ title: 'Saved addresses' }} />
      <Stack.Screen name="addresses/edit" options={{ title: 'Address' }} />
      <Stack.Screen name="delivery/areas" options={{ title: 'Where I deliver' }} />
      <Stack.Screen name="saved" options={{ title: 'Saved items' }} />
      <Stack.Screen name="verify/index" options={{ title: 'Get verified' }} />
      <Stack.Screen name="verify/identity" options={{ title: 'Identity check' }} />
      <Stack.Screen name="verify/business" options={{ title: 'Business' }} />
      <Stack.Screen name="review/[orderId]" options={{ title: 'Leave a review' }} />
      <Stack.Screen name="seller/[id]" options={{ title: 'Seller' }} />
      <Stack.Screen name="alerts" options={{ title: 'Saved searches and alerts' }} />
      <Stack.Screen name="pay/[orderId]" options={{ title: 'Pay' }} />
      <Stack.Screen name="payments" options={{ title: 'Payments' }} />
      <Stack.Screen name="profile/edit" options={{ title: 'Edit profile' }} />
      <Stack.Screen name="settings/security" options={{ title: 'Security and login' }} />
      <Stack.Screen name="account/listings" options={{ title: 'My products' }} />
      <Stack.Screen name="account/reviews" options={{ title: 'My reviews' }} />
      <Stack.Screen name="account/cases" options={{ title: 'Disputes, appeals and reports' }} />
      <Stack.Screen name="analytics/index" options={{ title: 'My numbers' }} />
      <Stack.Screen name="analytics/sales" options={{ title: 'Sales report' }} />
      <Stack.Screen name="analytics/listing/[id]" options={{ title: 'Listing numbers' }} />
      <Stack.Screen name="admin/stats" options={{ title: 'Statistics' }} />
      <Stack.Screen name="finance/index" options={{ title: 'Finance' }} />
      <Stack.Screen name="finance/payment/[id]" options={{ title: 'Payment' }} />
      <Stack.Screen name="finance/refunds" options={{ title: 'Refunds' }} />
      <Stack.Screen name="support/index" options={{ title: 'Help' }} />
      <Stack.Screen name="support/new" options={{ title: 'Ask for help' }} />
      <Stack.Screen name="support/[id]" options={{ title: 'Your ticket' }} />
      <Stack.Screen name="helpdesk/index" options={{ title: 'Help desk' }} />
      <Stack.Screen name="helpdesk/performance" options={{ title: 'Team performance' }} />
      <Stack.Screen name="helpdesk/ticket/[id]" options={{ title: 'Ticket' }} />
      <Stack.Screen name="notifications" options={{ title: 'Notifications' }} />
      <Stack.Screen name="notification-settings" options={{ title: 'Notification settings' }} />
      <Stack.Screen name="checkout/[listingId]" options={{ title: 'Request to buy' }} />
      <Stack.Screen name="order/[id]" options={{ title: 'Order' }} />
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
      <Stack.Screen name="admin/votes/index" options={{ title: 'Staff voting' }} />
      <Stack.Screen name="admin/votes/new" options={{ title: 'New proposal' }} />
      <Stack.Screen name="admin/votes/history" options={{ title: 'My voting history' }} />
      <Stack.Screen name="admin/votes/[id]" options={{ title: 'Proposal' }} />
      <Stack.Screen name="admin/birthdays/index" options={{ title: 'Staff birthdays' }} />
      <Stack.Screen name="admin/birthdays/mine" options={{ title: 'My birthday' }} />
      <Stack.Screen name="admin/birthdays/reports" options={{ title: 'Reported wishes' }} />
      <Stack.Screen name="admin/birthdays/[id]" options={{ title: 'Birthday board' }} />
      <Stack.Screen name="admin/team" options={{ title: 'Staff team' }} />
      <Stack.Screen name="admin/audit" options={{ title: 'Audit log' }} />
      <Stack.Screen name="business/[slug]" options={{ title: 'Shop' }} />
      <Stack.Screen name="business/invitations" options={{ title: 'Team invitations' }} />
      <Stack.Screen name="business/manage/index" options={{ title: 'Business tools' }} />
      <Stack.Screen name="business/manage/[id]/index" options={{ title: 'Your business' }} />
      <Stack.Screen name="business/manage/[id]/orders" options={{ title: 'Business orders' }} />
      <Stack.Screen name="business/manage/[id]/inventory" options={{ title: 'Stock' }} />
      <Stack.Screen name="business/manage/[id]/team" options={{ title: 'Team' }} />
      <Stack.Screen name="business/manage/[id]/branches" options={{ title: 'Branches' }} />
      <Stack.Screen name="business/manage/[id]/catalogues" options={{ title: 'Catalogues' }} />
      <Stack.Screen name="seller/listings" options={{ title: 'Listings' }} />
      <Stack.Screen name="seller/listing/[id]" options={{ title: 'Listing' }} />
      <Stack.Screen name="admin/jobs" options={{ title: 'Your jobs' }} />
      <Stack.Screen name="business/manage/[id]/imports/index" options={{ title: 'Import products' }} />
      <Stack.Screen name="business/manage/[id]/imports/[job]" options={{ title: 'Import' }} />
      <Stack.Screen name="business/manage/[id]/analytics" options={{ title: 'Analytics' }} />
      <Stack.Screen name="trust/index" options={{ title: 'User & Trust Management' }} />
      <Stack.Screen name="trust/applications" options={{ title: 'Verification applications' }} />
      <Stack.Screen name="trust/users" options={{ title: 'Users' }} />
      <Stack.Screen name="trust/user/[id]" options={{ title: 'User profile' }} />
      <Stack.Screen name="trust/audit" options={{ title: 'Audit trail' }} />
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
