import { Ionicons } from '@expo/vector-icons';
import { Tabs } from 'expo-router';
import { Platform, StyleSheet } from 'react-native';

import { useCart } from '../../src/features/cart/store';
import { colors } from '../../src/theme';

type IconName = React.ComponentProps<typeof Ionicons>['name'];

function icon(active: IconName, idle: IconName) {
  return ({ color, size, focused }: { color: string; size: number; focused: boolean }) => (
    <Ionicons name={focused ? active : idle} color={color} size={size + 2} />
  );
}

// Bottom navigation: Home, Messages, Cart, Orders, Account. Selling tools are not a tab: they live in the Account
// Hub and only appear once a person has started selling. The "sell" screen stays reachable from the hub.
export default function TabsLayout() {
  const cartCount = useCart().length;
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
      <Tabs.Screen name="orders" options={{ title: 'Orders', tabBarIcon: icon('receipt', 'receipt-outline') }} />
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
