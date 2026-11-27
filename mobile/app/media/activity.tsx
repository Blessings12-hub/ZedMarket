import { Text } from 'react-native';

import { fetchActivity, fetchPermissions } from '../../src/features/media/api';
import { has } from '../../src/features/media/domain';
import { MediaScreen, styles as s, when } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';

export default function Activity() {
  const perms = useLoad(fetchPermissions);
  const list = useLoad(fetchActivity);
  return (
    <MediaScreen loading={list.loading} error={list.error || perms.error} onRetry={() => void list.reload()} denied={perms.data && !has(perms.data, 'media.activity') ? 'You do not have access to the activity record.' : undefined}>
      <Text style={s.title}>Activity record</Text>
      {(list.data ?? []).map((a, i) => <Text key={i} style={s.muted}>{`${when(a.at)} · ${a.actor_name ?? 'System'} · ${a.action.replace(/^media\./, '').replace(/[._]/g, ' ')}`}</Text>)}
      {list.data && list.data.length === 0 ? <Text style={s.muted}>No activity yet.</Text> : null}
    </MediaScreen>
  );
}
