import { useRouter } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';

import { fetchOverview, fetchPermissions } from '../../src/features/media/api';
import { mediaSections } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { colors, radius, spacing } from '../../src/theme';

export default function MediaHome() {
  const router = useRouter();
  const perms = useLoad(fetchPermissions);
  const sections = perms.data ? mediaSections(perms.data) : [];
  const allowed = sections.length > 0;
  const overview = useLoad(async () => (allowed ? fetchOverview() : null), [allowed]);
  const o = overview.data;

  const tiles = o
    ? [
        ['Waiting for approval', o.submitted], ['Approved, to publish', o.approved_waiting], ['Scheduled', o.scheduled], ['Published', o.published],
        ['Drafts', o.drafts], ['Open requests', o.open_requests], ['Active campaigns', o.active_campaigns], ['Files in library', o.assets],
      ]
    : [];

  return (
    <MediaScreen
      loading={perms.loading}
      error={perms.error || overview.error}
      onRetry={() => { void perms.reload(); void overview.reload(); }}
      denied={perms.data && !allowed ? 'This account does not have access to the Media Department.' : undefined}
    >
      <Text style={s.title}>Media Department</Text>
      {o && o.assets_awaiting_scan > 0 ? <Text style={s.muted}>{`${o.assets_awaiting_scan} file(s) are waiting for the safety check.`}</Text> : null}
      <View style={local.grid}>
        {tiles.map(([label, n]) => (
          <View key={label as string} style={local.tile}>
            <Text style={local.num}>{n as number}</Text>
            <Text style={s.meta}>{label as string}</Text>
          </View>
        ))}
      </View>
      {sections.map((x) => (
        <Card key={x.key} title={x.title} note={x.note} onPress={() => router.push(x.href as never)} />
      ))}
    </MediaScreen>
  );
}

const local = StyleSheet.create({
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: { width: '48%', backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md },
  num: { fontSize: 24, fontWeight: '700', color: colors.primaryDark },
});
