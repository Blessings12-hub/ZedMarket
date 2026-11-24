import type { ReactNode } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, VerifiedBadge } from '../../components/ui';
import { colors, radius, spacing } from '../../theme';
import { avatarUrl, type HubProfile } from './api';
import { contextOptions, emailStatus, memberSince, type HubBusiness, type HubItem, type HubSection } from './hub';

export function AccountHeader({ profile, email, emailConfirmedAt, onEdit, onShare }: {
  profile: HubProfile; email: string | undefined; emailConfirmedAt: string | null | undefined; onEdit: () => void; onShare?: () => void;
}) {
  const url = avatarUrl(profile.avatarPath);
  const initials = profile.displayName.trim().slice(0, 1).toUpperCase();
  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        {url ? <Image source={{ uri: url }} style={styles.avatar} accessibilityLabel="Your profile photo" /> : (
          <View style={[styles.avatar, styles.avatarEmpty]}><Text style={styles.avatarText}>{initials}</Text></View>
        )}
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={styles.name} numberOfLines={1}>{profile.displayName}</Text>
          {email ? <Text style={styles.muted} numberOfLines={1}>{email}</Text> : null}
          <View style={styles.badges}>
            <VerifiedBadge level={profile.level} />
            <Text style={[styles.pill, emailStatus(emailConfirmedAt) === 'verified' ? styles.pillOk : styles.pillWarn]}>
              {emailStatus(emailConfirmedAt) === 'verified' ? 'Email confirmed' : 'Email not confirmed'}
            </Text>
          </View>
        </View>
      </View>
      <View style={styles.facts}>
        <Text style={styles.muted}>Member since</Text>
        <Text style={styles.value}>{memberSince(profile.createdAt)}</Text>
      </View>
      <View style={styles.actions}>
        <View style={{ flex: 1 }}><Button title="Edit profile" variant="secondary" onPress={onEdit} /></View>
        {onShare ? <View style={{ flex: 1 }}><Button title="Share profile" variant="secondary" onPress={onShare} /></View> : null}
      </View>
    </View>
  );
}

export function AccountTypeSwitcher({ businesses, value, onChange }: { businesses: HubBusiness[]; value: string; onChange: (key: string) => void }) {
  if (businesses.length === 0) return null;
  return (
    <View style={styles.switcher} accessibilityRole="tablist">
      {contextOptions(businesses).map((o) => (
        <Pressable key={o.key} accessibilityRole="tab" accessibilityState={{ selected: value === o.key }} onPress={() => onChange(o.key)} style={[styles.seg, value === o.key && styles.segOn]}>
          <Text style={[styles.segText, value === o.key && styles.segTextOn]} numberOfLines={1}>{o.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}

export type QuickAction = { key: string; label: string; onPress: () => void; badge?: string };
export function AccountQuickActions({ actions }: { actions: QuickAction[] }) {
  return (
    <View style={styles.quick}>
      {actions.map((a) => (
        <Pressable key={a.key} accessibilityRole="button" accessibilityLabel={a.badge ? `${a.label}, ${a.badge}` : a.label} onPress={a.onPress} style={styles.tile}>
          <Text style={styles.tileLabel}>{a.label}</Text>
          {a.badge ? <Text style={styles.tileBadge}>{a.badge}</Text> : null}
        </Pressable>
      ))}
    </View>
  );
}

export function AccountMenuItem({ item, last, onPress }: { item: HubItem; last: boolean; onPress: () => void }) {
  return (
    <Pressable accessibilityRole="button" accessibilityLabel={item.badge ? `${item.title}, ${item.badge}` : item.title} onPress={onPress} style={[styles.item, !last && styles.itemLine]}>
      <View style={{ flex: 1 }}>
        <Text style={styles.itemTitle}>{item.title}</Text>
        {item.subtitle ? <Text style={styles.muted}>{item.subtitle}</Text> : null}
      </View>
      {item.badge ? <Text style={styles.itemBadge}>{item.badge}</Text> : null}
      <Text style={styles.chev} accessibilityElementsHidden>{'>'}</Text>
    </Pressable>
  );
}

export function AccountSection({ section, onOpen, footer }: { section: HubSection; onOpen: (item: HubItem) => void; footer?: ReactNode }) {
  return (
    <View style={{ gap: spacing.sm }}>
      <Text style={styles.sectionTitle} accessibilityRole="header">{section.title}</Text>
      <View style={styles.card}>
        {section.items.map((it, i) => <AccountMenuItem key={it.key} item={it} last={i === section.items.length - 1} onPress={() => onOpen(it)} />)}
      </View>
      {footer}
    </View>
  );
}

export function SellerSummary({ live, waiting, total }: { live: number; waiting: number; total: number }) {
  return (
    <View style={styles.summary}>
      <Stat label="Live" value={live} /><Stat label="Waiting for review" value={waiting} /><Stat label="All listings" value={total} />
    </View>
  );
}

export function BusinessSummary({ business }: { business: HubBusiness }) {
  return (
    <View style={styles.summary}>
      <View style={{ flex: 1 }}>
        <Text style={styles.itemTitle} numberOfLines={1}>{business.name}</Text>
        <Text style={styles.muted}>Your role: {business.role}</Text>
      </View>
      <Text style={[styles.pill, business.verified ? styles.pillOk : styles.pillWarn]}>{business.verified ? 'Verified business' : 'Not verified yet'}</Text>
    </View>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <View style={{ flex: 1, alignItems: 'center' }}>
      <Text style={styles.statValue}>{value}</Text>
      <Text style={[styles.muted, { textAlign: 'center' }]}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  headerRow: { flexDirection: 'row', gap: spacing.md, alignItems: 'center' },
  avatar: { width: 64, height: 64, borderRadius: 32 },
  avatarEmpty: { backgroundColor: colors.primarySoft, alignItems: 'center', justifyContent: 'center' },
  avatarText: { fontSize: 26, fontWeight: '700', color: colors.primary },
  name: { fontSize: 20, fontWeight: '700', color: colors.text },
  muted: { fontSize: 13, color: colors.muted, lineHeight: 18 },
  value: { fontSize: 14, fontWeight: '600', color: colors.text },
  badges: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap', alignItems: 'center', marginTop: 2 },
  pill: { fontSize: 12, fontWeight: '600', paddingHorizontal: spacing.sm, paddingVertical: 2, borderRadius: radius.sm, overflow: 'hidden' },
  pillOk: { backgroundColor: colors.primarySoft, color: colors.primary },
  pillWarn: { backgroundColor: colors.warningSoft, color: colors.warning },
  facts: { flexDirection: 'row', justifyContent: 'space-between' },
  actions: { flexDirection: 'row', gap: spacing.sm },
  switcher: { flexDirection: 'row', backgroundColor: colors.primarySoft, borderRadius: radius.md, padding: 4, gap: 4 },
  seg: { flex: 1, minHeight: 44, borderRadius: radius.sm, alignItems: 'center', justifyContent: 'center', paddingHorizontal: spacing.sm },
  segOn: { backgroundColor: colors.surface },
  segText: { fontSize: 14, color: colors.muted, fontWeight: '600' },
  segTextOn: { color: colors.primary },
  quick: { flexDirection: 'row', gap: spacing.sm },
  tile: { flex: 1, minHeight: 72, backgroundColor: colors.primarySoft, borderRadius: radius.md, alignItems: 'center', justifyContent: 'center', padding: spacing.sm, gap: 2 },
  tileLabel: { fontSize: 14, fontWeight: '600', color: colors.primaryDark },
  tileBadge: { fontSize: 11, color: colors.primary },
  sectionTitle: { fontSize: 16, fontWeight: '700', color: colors.text, marginTop: spacing.sm },
  item: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, minHeight: 56, paddingVertical: spacing.sm },
  itemLine: { borderBottomWidth: 1, borderBottomColor: colors.border },
  itemTitle: { fontSize: 15, fontWeight: '600', color: colors.text },
  itemBadge: { fontSize: 12, fontWeight: '600', color: colors.primary, backgroundColor: colors.primarySoft, paddingHorizontal: spacing.sm, paddingVertical: 2, borderRadius: radius.sm, overflow: 'hidden' },
  chev: { fontSize: 18, color: colors.muted },
  summary: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  statValue: { fontSize: 20, fontWeight: '700', color: colors.text },
});
