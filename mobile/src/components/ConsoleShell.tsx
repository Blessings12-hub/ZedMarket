import { usePathname, useRouter } from 'expo-router';
import { useState, type ReactNode } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, useWindowDimensions, View } from 'react-native';

import { activeItemKey, CONSOLE_HOME, consoleMenu, isWide } from '../domain/console';
import type { AdminRole } from '../domain/admin';
import { colors, radius, spacing } from '../theme';

// Frame around every console page: a side menu on wide screens, a menu button on narrow ones.
export function ConsoleShell({ roles, children }: { roles: AdminRole[]; children: ReactNode }) {
  const { width } = useWindowDimensions();
  const pathname = usePathname();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const wide = isWide(width);
  const active = activeItemKey(pathname);
  const groups = consoleMenu(roles);

  const menu = (
    <ScrollView style={wide ? styles.side : styles.drawer} contentContainerStyle={styles.menuContent}>
      <Pressable accessibilityRole="link" onPress={() => { setOpen(false); router.push(CONSOLE_HOME); }}>
        <Text style={styles.brand}>ZedMarket staff</Text>
      </Pressable>
      <Text style={styles.roles}>{roles.join(', ')}</Text>
      {groups.map((g) => (
        <View key={g.group} style={styles.group}>
          <Text style={styles.groupTitle}>{g.group}</Text>
          {g.items.map((i) => (
            <Pressable
              key={i.key}
              accessibilityRole="link"
              style={[styles.item, active === i.key && styles.itemActive]}
              onPress={() => { setOpen(false); router.push(i.href as never); }}
            >
              <Text style={[styles.itemText, active === i.key && styles.itemTextActive]}>{i.title}</Text>
            </Pressable>
          ))}
        </View>
      ))}
    </ScrollView>
  );

  if (wide) {
    return (
      <View style={styles.wideRoot}>
        {menu}
        <View style={styles.main}>{children}</View>
      </View>
    );
  }
  return (
    <View style={styles.narrowRoot}>
      <Pressable accessibilityRole="button" style={styles.menuButton} onPress={() => setOpen(!open)}>
        <Text style={styles.menuButtonText}>{open ? 'Close menu' : 'Menu'}</Text>
      </Pressable>
      {open ? menu : <View style={styles.main}>{children}</View>}
    </View>
  );
}

const styles = StyleSheet.create({
  wideRoot: { flex: 1, flexDirection: 'row', backgroundColor: colors.background },
  narrowRoot: { flex: 1, backgroundColor: colors.background },
  main: { flex: 1, width: '100%', maxWidth: 1100, alignSelf: 'center' },
  side: { width: 250, flexGrow: 0, backgroundColor: colors.surface, borderRightWidth: 1, borderRightColor: colors.border },
  drawer: { flex: 1, backgroundColor: colors.surface },
  menuContent: { padding: spacing.lg, gap: spacing.md },
  brand: { fontSize: 18, fontWeight: '700', color: colors.primary },
  roles: { fontSize: 12, color: colors.muted },
  group: { gap: spacing.xs },
  groupTitle: { fontSize: 12, fontWeight: '700', color: colors.muted, textTransform: 'uppercase', marginTop: spacing.sm },
  item: { paddingVertical: spacing.sm, paddingHorizontal: spacing.md, borderRadius: radius.md },
  itemActive: { backgroundColor: colors.primarySoft },
  itemText: { fontSize: 15, color: colors.text },
  itemTextActive: { fontWeight: '700', color: colors.primaryDark },
  menuButton: { padding: spacing.md, backgroundColor: colors.surface, borderBottomWidth: 1, borderBottomColor: colors.border },
  menuButtonText: { fontSize: 15, fontWeight: '600', color: colors.primary },
});
