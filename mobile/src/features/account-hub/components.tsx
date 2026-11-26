import { Ionicons } from '@expo/vector-icons';
import type { ReactNode } from 'react';
import { Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, VerifiedBadge } from '../../components/ui';
import { colors, radius, spacing } from '../../theme';
import { avatarUrl, type HubProfile } from './api';
import { badgeText, STRIP_STEPS, type Nudge, type SellingBanner as BannerModel, type StripItem, type Tile } from './dashboard';
import { contextOptions, emailStatus, memberSince, type HubBusiness, type HubItem, type HubSection } from './hub';

type IconName = React.ComponentProps<typeof Ionicons>['name'];

// One icon per hub row, chosen by the row's key so the rules in hub.ts stay free of screen code.
const ICONS: Record<string, IconName> = {
  // buying
  orders: 'receipt-outline', saved: 'heart-outline', cart: 'cart-outline', messages: 'chatbubble-ellipses-outline', listings: 'pricetags-outline',
  alerts: 'search-outline', reviews: 'star-outline', payments: 'card-outline',
  // help and settings
  notifications: 'notifications-outline', support: 'help-buoy-outline', cases: 'document-text-outline',
  personal: 'person-outline', addresses: 'location-outline', security: 'shield-checkmark-outline', 'notification-settings': 'options-outline',
  // selling and business
  'seller-dashboard': 'stats-chart-outline', 'my-products': 'cube-outline', post: 'add-circle-outline', 'coverage-areas': 'navigate-outline',
  'selling-orders': 'receipt-outline', enquiries: 'chatbubble-ellipses-outline', 'seller-verification': 'ribbon-outline', 'seller-paused': 'pause-circle-outline',
  storefront: 'storefront-outline', public: 'globe-outline', catalogue: 'albums-outline', inventory: 'layers-outline', 'biz-orders': 'receipt-outline',
  branches: 'git-branch-outline', team: 'people-outline', 'biz-analytics': 'stats-chart-outline', 'biz-verify': 'ribbon-outline',
  'become-seller': 'storefront-outline', 'register-business': 'business-outline',
  // staff
  'staff-tools': 'construct-outline',
};
const iconFor = (key: string): IconName => ICONS[key] ?? 'ellipse-outline';

export function AccountHeader({ profile, email, emailConfirmedAt, onEdit, onShare, isSeller }: {
  profile: HubProfile; email: string | undefined; emailConfirmedAt: string | null | undefined; onEdit: () => void; onShare?: () => void; isSeller?: boolean;
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
            {isSeller ? <Text style={[styles.pill, styles.pillOk]}>Verified seller</Text> : null}
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

export type QuickAction = { key: string; label: string; onPress: () => void; badge?: string; icon?: string };
export function AccountQuickActions({ actions }: { actions: QuickAction[] }) {
  return (
    <View style={styles.quick}>
      {actions.map((a) => (
        <Pressable key={a.key} accessibilityRole="button" accessibilityLabel={a.badge ? `${a.label}, ${a.badge}` : a.label} onPress={a.onPress} style={styles.tile}>
          <Ionicons name={iconFor(a.icon ?? a.key)} size={24} color={colors.primary} accessibilityElementsHidden />
          <Text style={styles.tileLabel} numberOfLines={1}>{a.label}</Text>
          {a.badge ? <Text style={styles.tileBadge} numberOfLines={1}>{a.badge}</Text> : null}
        </Pressable>
      ))}
    </View>
  );
}

export function AccountMenuItem({ item, last, onPress }: { item: HubItem; last: boolean; onPress: () => void }) {
  return (
    <Pressable accessibilityRole="button" accessibilityLabel={item.badge ? `${item.title}, ${item.badge}` : item.title} onPress={onPress} style={[styles.item, !last && styles.itemLine]}>
      <View style={styles.iconChip} accessibilityElementsHidden>
        <Ionicons name={iconFor(item.key)} size={20} color={colors.primary} />
      </View>
      <View style={{ flex: 1 }}>
        <Text style={styles.itemTitle}>{item.title}</Text>
        {item.subtitle ? <Text style={styles.muted}>{item.subtitle}</Text> : null}
      </View>
      {item.badge ? <Text style={styles.itemBadge}>{item.badge}</Text> : null}
      <Ionicons name="chevron-forward" size={18} color={colors.muted} accessibilityElementsHidden />
    </Pressable>
  );
}

export function AccountSection({ section, onOpen, footer }: { section: HubSection; onOpen: (item: HubItem) => void; footer?: ReactNode }) {
  return (
    <View style={{ gap: spacing.sm }}>
      <View style={{ gap: 2 }}>
        <Text style={styles.sectionTitle} accessibilityRole="header">{section.title}</Text>
        {section.note ? <Text style={styles.muted}>{section.note}</Text> : null}
      </View>
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
      <Text style={[styles.pill, business.verified ? styles.pillOk : styles.pillWarn]}>{business.verified ? 'Verified business' : 'Not verified yet: drafts only'}</Text>
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

// ----- redesigned top of the hub -----

// Compact: photo, name, and one line of status. Details live in Edit profile.
export function HubHeader({ profile, email, emailConfirmedAt, isSeller, onEdit, onShare }: {
  profile: HubProfile; email: string | undefined; emailConfirmedAt: string | null | undefined; isSeller: boolean; onEdit: () => void; onShare?: () => void;
}) {
  const url = avatarUrl(profile.avatarPath);
  const confirmed = emailStatus(emailConfirmedAt) === 'verified';
  return (
    <View style={styles.hubHeader}>
      <Pressable accessibilityRole="button" accessibilityLabel="Edit profile" onPress={onEdit}>
        {url ? <Image source={{ uri: url }} style={styles.avatar} accessibilityLabel="Your profile photo" /> : (
          <View style={[styles.avatar, styles.avatarEmpty]}><Text style={styles.avatarText}>{profile.displayName.trim().slice(0, 1).toUpperCase()}</Text></View>
        )}
      </Pressable>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={styles.name} numberOfLines={1}>{profile.displayName}</Text>
        <Text style={styles.muted} numberOfLines={1}>{email ?? `Member since ${memberSince(profile.createdAt)}`}</Text>
        <View style={styles.badges}>
          <VerifiedBadge level={profile.level} />
          {isSeller ? <Text style={[styles.pill, styles.pillOk]}>Verified seller</Text> : null}
          {!confirmed ? <Text style={[styles.pill, styles.pillWarn]}>Email not confirmed</Text> : null}
        </View>
      </View>
      <View style={{ gap: spacing.xs }}>
        <Pressable accessibilityRole="button" accessibilityLabel="Edit profile" onPress={onEdit} style={styles.roundBtn}>
          <Ionicons name="create-outline" size={20} color={colors.primary} />
        </Pressable>
        {onShare ? (
          <Pressable accessibilityRole="button" accessibilityLabel="Share profile" onPress={onShare} style={styles.roundBtn}>
            <Ionicons name="share-outline" size={20} color={colors.primary} />
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

// Three across, two rows. A small count badge sits on the icon.
export function TilesGrid({ tiles, onOpen }: { tiles: Tile[]; onOpen: (t: Tile) => void }) {
  return (
    <View style={styles.grid}>
      {tiles.map((t) => {
        const badge = badgeText(t.count);
        return (
          <Pressable key={t.key} accessibilityRole="button" accessibilityLabel={badge ? `${t.label}, ${badge}` : t.label} onPress={() => onOpen(t)} style={styles.gridTile}>
            <View>
              <Ionicons name={iconFor(t.key)} size={26} color={colors.primary} accessibilityElementsHidden />
              {badge ? <Text style={styles.countBadge}>{badge}</Text> : null}
            </View>
            <Text style={styles.tileLabel} numberOfLines={1}>{t.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

// Horizontal cards, one per open purchase, with a four-step progress bar.
export function OrderStrip({ items, more, onOpen }: { items: StripItem[]; more: number; onOpen: () => void }) {
  if (items.length === 0) return null;
  return (
    <View style={{ gap: spacing.sm }}>
      <View style={styles.stripHead}>
        <Text style={styles.stripTitle} accessibilityRole="header">Your orders in progress</Text>
        <Pressable accessibilityRole="button" onPress={onOpen} hitSlop={8}><Text style={styles.link}>{more > 0 ? `See all (+${more})` : 'See all'}</Text></Pressable>
      </View>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
        {items.map((o) => (
          <Pressable key={o.id} accessibilityRole="button" accessibilityLabel={`${o.title}, ${o.label}`} onPress={onOpen} style={[styles.orderCard, o.needsYou && styles.orderNeeds, o.problem && styles.orderProblem]}>
            <Text style={styles.itemTitle} numberOfLines={1}>{o.title}</Text>
            <Text style={[styles.muted, (o.needsYou || o.problem) && { color: colors.warning, fontWeight: '600' }]} numberOfLines={2}>{o.label}</Text>
            <View style={styles.steps} accessibilityElementsHidden>
              {STRIP_STEPS.map((s, i) => <View key={s} style={[styles.step, i <= o.step && !o.problem && styles.stepOn, o.problem && i <= o.step && styles.stepBad]} />)}
            </View>
          </Pressable>
        ))}
      </ScrollView>
    </View>
  );
}

export function NudgeCard({ nudge, onPress }: { nudge: Nudge; onPress: () => void }) {
  return (
    <View style={styles.nudge}>
      <Text style={styles.itemTitle}>{nudge.title}</Text>
      <Text style={styles.muted}>{nudge.body}</Text>
      <Button title={nudge.cta} variant="secondary" onPress={onPress} />
    </View>
  );
}

// An invitation, not a push: buying comes first, selling needs verification.
export function SellingBanner({ banner, onOpen }: { banner: BannerModel; onOpen: (href: BannerModel['href']) => void }) {
  return (
    <View style={styles.banner}>
      <View style={styles.bannerTop}>
        <Ionicons name="storefront-outline" size={22} color={colors.onPrimary} accessibilityElementsHidden />
        <Text style={styles.bannerTitle} accessibilityRole="header">{banner.title}</Text>
        {banner.badge ? <Text style={styles.bannerBadge}>{banner.badge}</Text> : null}
      </View>
      <Text style={styles.bannerBody}>{banner.body}</Text>
      <Pressable accessibilityRole="button" onPress={() => onOpen(banner.href)} style={styles.bannerBtn}>
        <Text style={styles.bannerBtnText}>{banner.cta}</Text>
      </Pressable>
      {banner.secondary ? (
        <Pressable accessibilityRole="button" onPress={() => onOpen(banner.secondary!.href)} hitSlop={8}>
          <Text style={styles.bannerLink}>{banner.secondary.title}</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

// Grey blocks in the shape of the page, so it does not jump when the data arrives.
export function HubSkeleton() {
  return (
    <View style={{ gap: spacing.md }} accessibilityLabel="Loading your account" accessibilityRole="progressbar">
      <View style={[styles.skel, { height: 84 }]} />
      <View style={styles.grid}>{[0, 1, 2, 3, 4, 5].map((i) => <View key={i} style={[styles.gridTile, styles.skel, { backgroundColor: colors.border }]} />)}</View>
      <View style={[styles.skel, { height: 110 }]} />
      <View style={[styles.skel, { height: 180 }]} />
    </View>
  );
}

const styles = StyleSheet.create({
  hubHeader: { flexDirection: 'row', gap: spacing.md, alignItems: 'center', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  roundBtn: { width: 40, height: 40, borderRadius: 20, backgroundColor: colors.primarySoft, alignItems: 'center', justifyContent: 'center' },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  gridTile: { flexBasis: '31%', flexGrow: 1, minHeight: 84, backgroundColor: colors.primarySoft, borderRadius: radius.md, alignItems: 'center', justifyContent: 'center', padding: spacing.sm, gap: 6 },
  countBadge: { position: 'absolute', top: -6, right: -12, minWidth: 18, paddingHorizontal: 4, height: 18, lineHeight: 18, borderRadius: 9, overflow: 'hidden', textAlign: 'center', fontSize: 11, fontWeight: '700', color: colors.onPrimary, backgroundColor: colors.primary },
  stripHead: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  stripTitle: { fontSize: 17, fontWeight: '700', color: colors.text },
  link: { fontSize: 14, fontWeight: '600', color: colors.primary },
  orderCard: { width: 230, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4 },
  orderNeeds: { borderColor: colors.warning, backgroundColor: colors.warningSoft },
  orderProblem: { borderColor: colors.danger },
  steps: { flexDirection: 'row', gap: 4, marginTop: spacing.sm },
  step: { flex: 1, height: 4, borderRadius: 2, backgroundColor: colors.border },
  stepOn: { backgroundColor: colors.primary },
  stepBad: { backgroundColor: colors.danger },
  nudge: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  banner: { backgroundColor: colors.primary, borderRadius: radius.md, padding: spacing.lg, gap: spacing.sm },
  bannerTop: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  bannerTitle: { flex: 1, fontSize: 18, fontWeight: '700', color: colors.onPrimary },
  bannerBadge: { fontSize: 12, fontWeight: '700', color: colors.primary, backgroundColor: colors.onPrimary, paddingHorizontal: spacing.sm, paddingVertical: 2, borderRadius: radius.sm, overflow: 'hidden' },
  bannerBody: { fontSize: 14, lineHeight: 20, color: colors.onPrimary },
  bannerBtn: { minHeight: 48, borderRadius: radius.md, backgroundColor: colors.onPrimary, alignItems: 'center', justifyContent: 'center', marginTop: spacing.xs },
  bannerBtnText: { fontSize: 15, fontWeight: '700', color: colors.primary },
  bannerLink: { fontSize: 14, fontWeight: '600', color: colors.onPrimary, textDecorationLine: 'underline', textAlign: 'center', paddingVertical: spacing.xs },
  skel: { backgroundColor: colors.primarySoft, borderRadius: radius.md },

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
  tile: { flex: 1, minHeight: 84, backgroundColor: colors.primarySoft, borderRadius: radius.md, alignItems: 'center', justifyContent: 'center', padding: spacing.sm, gap: 4 },
  tileLabel: { fontSize: 13, fontWeight: '600', color: colors.primaryDark },
  tileBadge: { fontSize: 11, color: colors.primary },
  sectionTitle: { fontSize: 17, fontWeight: '700', color: colors.text, marginTop: spacing.md },
  item: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, minHeight: 56, paddingVertical: spacing.sm },
  itemLine: { borderBottomWidth: 1, borderBottomColor: colors.border },
  itemTitle: { fontSize: 15, fontWeight: '600', color: colors.text },
  itemBadge: { fontSize: 12, fontWeight: '600', color: colors.primary, backgroundColor: colors.primarySoft, paddingHorizontal: spacing.sm, paddingVertical: 2, borderRadius: radius.sm, overflow: 'hidden' },
  iconChip: { width: 36, height: 36, borderRadius: 18, backgroundColor: colors.primarySoft, alignItems: 'center', justifyContent: 'center' },
  summary: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  statValue: { fontSize: 20, fontWeight: '700', color: colors.text },
});
