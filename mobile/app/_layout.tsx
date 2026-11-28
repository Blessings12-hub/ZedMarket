import { Stack, useRouter, useSegments, type ErrorBoundaryProps } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Text, View } from 'react-native';

import { Button } from '../src/components/ui';
import { shouldShowWelcome } from '../src/domain/welcome';
import { loadDataSaver } from '../src/lib/dataSaver';
import { installErrorReporting, reportError, setCurrentRoute } from '../src/lib/report';
import { readWelcomeSeen, welcomeSeenNow } from '../src/lib/welcomeSeen';

import { AuthProvider, useAuth } from '../src/auth/AuthProvider';
import { isPublicRoute } from '../src/domain/routes';
import { onNotificationTapped, showPushWhileOpen } from '../src/features/notifications/push';
import { supabaseConfigured } from '../src/lib/supabase';
import { colors } from '../src/theme';

// Signed-out visitors can browse, open listings and seller pages, and see the sign-in screens.
// Anything that needs an account sends them to sign in. Signed-in users never see the (auth) screens.
function AuthGate() {
  const { session, userId, loading } = useAuth();
  const segments = useSegments();
  const router = useRouter();
  // Has this phone shown the welcome screens to this person? Unknown until the phone answers.
  const [welcomeSeen, setWelcomeSeen] = useState<boolean | null>(null);
  const [welcomeChecked, setWelcomeChecked] = useState(false);

  useEffect(() => {
    showPushWhileOpen();
    return onNotificationTapped((link) => {
      if (link && link.startsWith('/')) router.push(link as never);
    });
  }, [router]);

  useEffect(() => {
    setCurrentRoute(`/${segments.join('/')}`);
  }, [segments]);

  useEffect(() => {
    let cancelled = false;
    setWelcomeChecked(false);
    if (!userId) return;
    readWelcomeSeen(userId).then((seen) => {
      if (cancelled) return;
      setWelcomeSeen(seen);
      setWelcomeChecked(true);
    });
    return () => { cancelled = true; };
  }, [userId]);

  useEffect(() => {
    if (loading) return;
    const showWelcome = !!userId && !welcomeSeenNow(userId) && shouldShowWelcome(welcomeSeen, welcomeChecked);
    const inAuthGroup = segments[0] === '(auth)';
    if (!session && !isPublicRoute(segments)) router.replace('/sign-in');
    else if (session && inAuthGroup) router.replace(showWelcome ? '/welcome' : '/');
    else if (session && showWelcome && segments[0] === '(tabs)') router.replace('/welcome');
  }, [session, userId, loading, segments, router, welcomeSeen, welcomeChecked]);

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
      <Stack.Screen name="verify/seller" options={{ title: 'Become a seller' }} />
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
      <Stack.Screen name="purchases" options={{ title: 'My orders' }} />
      <Stack.Screen name="sell-hub" options={{ title: 'Selling and business' }} />
      <Stack.Screen name="order/[id]" options={{ title: 'Order' }} />
      <Stack.Screen name="dispute/open" options={{ title: 'Report a problem' }} />
      <Stack.Screen name="dispute/[id]" options={{ title: 'Dispute' }} />
      <Stack.Screen name="appeal" options={{ title: 'Appeal a decision' }} />
      <Stack.Screen name="announcements" options={{ title: 'News and announcements' }} />
      <Stack.Screen name="media/index" options={{ title: 'Media Department' }} />
      <Stack.Screen name="media/library" options={{ title: 'Media Library' }} />
      <Stack.Screen name="media/studio" options={{ title: 'Content Studio' }} />
      <Stack.Screen name="media/item/[id]" options={{ title: 'Content' }} />
      <Stack.Screen name="media/campaigns" options={{ title: 'Campaigns' }} />
      <Stack.Screen name="media/calendar" options={{ title: 'Content Calendar' }} />
      <Stack.Screen name="media/performance" options={{ title: 'Performance' }} />
      <Stack.Screen name="media/requests" options={{ title: 'Requests' }} />
      <Stack.Screen name="media/activity" options={{ title: 'Activity record' }} />
      <Stack.Screen name="media/people" options={{ title: 'Media staff' }} />
      <Stack.Screen name="admin/access" options={{ title: 'Pause or restore access' }} />
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
      <Stack.Screen name="business/manage/[id]/branch-stock" options={{ title: 'Stock per branch' }} />
      <Stack.Screen name="business/manage/[id]/team" options={{ title: 'Team' }} />
      <Stack.Screen name="business/manage/[id]/branches" options={{ title: 'Branches' }} />
      <Stack.Screen name="business/manage/[id]/catalogues" options={{ title: 'Catalogues' }} />
      <Stack.Screen name="selling/listings" options={{ title: 'Listings' }} />
      <Stack.Screen name="selling/listing/[id]" options={{ title: 'Listing' }} />
      <Stack.Screen name="admin/jobs" options={{ title: 'Your jobs' }} />
      <Stack.Screen name="business/manage/[id]/imports/index" options={{ title: 'Import products' }} />
      <Stack.Screen name="business/manage/[id]/imports/[job]" options={{ title: 'Import' }} />
      <Stack.Screen name="business/manage/[id]/analytics" options={{ title: 'Analytics' }} />
      <Stack.Screen name="trust/index" options={{ title: 'User & Trust Management' }} />
      <Stack.Screen name="trust/applications" options={{ title: 'Verification applications' }} />
      <Stack.Screen name="trust/seller-applications" options={{ title: 'Seller applications' }} />
      <Stack.Screen name="trust/seller-application/[id]" options={{ title: 'Review application' }} />
      <Stack.Screen name="compare" options={{ title: 'Compare' }} />
      <Stack.Screen name="trust/photo-flags" options={{ title: 'Repeated photos' }} />
      <Stack.Screen name="trust/workload" options={{ title: 'Workload and access' }} />
      <Stack.Screen name="trust/business-applications" options={{ title: 'Business applications' }} />
      <Stack.Screen name="trust/business-application/[id]" options={{ title: 'Review business' }} />
      <Stack.Screen name="trust/users" options={{ title: 'Users' }} />
      <Stack.Screen name="trust/user/[id]" options={{ title: 'User profile' }} />
      <Stack.Screen name="trust/audit" options={{ title: 'Audit trail' }} />
      <Stack.Screen name="welcome" options={{ headerShown: false }} />
      <Stack.Screen name="invite" options={{ title: 'Invite friends' }} />
      <Stack.Screen name="safety" options={{ title: 'Safety tips' }} />
      <Stack.Screen name="settings/app" options={{ title: 'Data saver' }} />
      <Stack.Screen name="legal/terms" options={{ title: 'Terms of Use' }} />
      <Stack.Screen name="legal/privacy" options={{ title: 'Privacy Notice' }} />
      <Stack.Screen name="admin/health" options={{ title: 'App health' }} />
      <Stack.Screen name="admin/promotions" options={{ title: 'Promotion requests' }} />
      <Stack.Screen name="promote/[listingId]" options={{ title: 'Promote a listing' }} />
    </Stack>
  );
}

// Shown instead of a blank page when the app was built without its Supabase settings.
function NotConfigured() {
  return (
    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24, gap: 12, backgroundColor: colors.background }}>
      <Text style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>ZedMarket is not set up yet</Text>
      <Text style={{ fontSize: 15, color: colors.muted, textAlign: 'center', lineHeight: 22 }}>
        This copy of the app was built without its Supabase settings. Add EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_ANON_KEY
        where the app is built (for example, Vercel project settings, Environment Variables), then build it again.
      </Text>
    </View>
  );
}

// Shown when a screen crashes, instead of a white page. The crash is reported to the team, and the person can try again.
export function ErrorBoundary({ error, retry }: ErrorBoundaryProps) {
  useEffect(() => {
    reportError(error);
  }, [error]);
  return (
    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24, gap: 12, backgroundColor: colors.background }}>
      <Text style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Something went wrong</Text>
      <Text style={{ fontSize: 15, color: colors.muted, textAlign: 'center', lineHeight: 22 }}>
        We have told the ZedMarket team. Please try again, and if it keeps happening, use Help to message us.
      </Text>
      <Button title="Try again" onPress={retry} />
    </View>
  );
}

export default function RootLayout() {
  useEffect(() => {
    installErrorReporting();
    void loadDataSaver();
  }, []);
  if (!supabaseConfigured) return <NotConfigured />;
  return (
    <AuthProvider>
      <StatusBar style="dark" />
      <AuthGate />
    </AuthProvider>
  );
}
