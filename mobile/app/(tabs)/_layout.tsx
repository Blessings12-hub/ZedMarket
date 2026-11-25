import { Ionicons } from '@expo/vector-icons';
import { Tabs } from 'expo-router';
import { useEffect } from 'react';
import { AppState, Platform, StyleSheet } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { showOrdersTab } from '../../src/domain/sellerAccess';
import { useCart } from '../../src/features/cart/store';
import { clearSellingAccess, refreshSellingAccess, useSellingAccess } from '../../src/features/seller/status';
import { colors } from '../../src/theme';

type IconName = React.ComponentProps<typeof Ionicons>['name'];

function icon(active: IconName, idle: IconName) {
  return ({ color, size, focused }: { color: string; size: number; focused: boolean }) => (
    <Ionicons name={focused ? active : idle} color={color} size={size + 2} />
  );
}

// Bottom navigation. A new account is a buyer account: Home, Messages, Cart and Account. The Orders tab mixes in selling
// requests, so it only appears once the verification team has approved the person as a seller; buyers open their
// purchases from the Account Hub. Other selling tools are not tabs: they live in the Account Hub and appear only for
// approved sellers. The "sell" and "orders" screens stay reachable by link, so the hub can still open them.
export default function TabsLayout() {
  const cartCount = useCart().length;
  const { userId } = useAuth();
  const { access } = useSellingAccess();

  // Keep the bar in step with the person's real status: on sign-in, and whenever the app comes back to the front
  // (for example after the team approves an application).
  useEffect(() => {
    if (!userId) {
      clearSellingAccess();
      return undefined;
    }
    void refreshSellingAccess(userId);
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') void refreshSellingAccess(userId);
    });
    return () => sub.remove();
  }, [userId]);

  return (
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: colors.primary,
        tabBarInactiveTintColor: colors.muted,
        tabBarShowLabel: true,
        tabBarLabelStyle: styles.label,
        tabBarStyle: styles.bar,
        headerStyle: { backgroundColor: colors.surface },
        headerTitleStyle: { color: colors.text },
      }}
    >
      <Tabs.Screen name="index" options={{ title: 'Home', tabBarIcon: icon('home', 'home-outline') }} />
      <Tabs.Screen name="messages" options={{ title: 'Messages', tabBarIcon: icon('chatbubble-ellipses', 'chatbubble-ellipses-outline') }} />
      <Tabs.Screen
        name="cart"
        options={{
          title: 'Cart',
          tabBarIcon: icon('cart', 'cart-outline'),
          tabBarBadge: cartCount > 0 ? cartCount : undefined,
          tabBarBadgeStyle: { backgroundColor: colors.danger, color: colors.onPrimary },
        }}
      />
      <Tabs.Screen
        name="orders"
        options={{ title: 'Orders', href: showOrdersTab(access.status) ? undefined : null, tabBarIcon: icon('receipt', 'receipt-outline') }}
      />
      <Tabs.Screen name="account" options={{ title: 'Account', tabBarIcon: icon('grid', 'grid-outline') }} />
      <Tabs.Screen name="sell" options={{ href: null, title: 'Post a listing' }} />
    </Tabs>
  );
}

const styles = StyleSheet.create({
  bar: {
    backgroundColor: colors.surface,
    borderTopColor: colors.border,
    height: Platform.OS === 'ios' ? 88 : 64,
    paddingTop: 6,
  },
  label: { fontSize: 11, fontWeight: '600' },
});
