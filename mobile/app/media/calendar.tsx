import { useRouter } from 'expo-router';
import { Text } from 'react-native';

import { fetchCalendar, fetchPermissions } from '../../src/features/media/api';
import { groupByDay, has } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';

export default function Calendar() {
  const router = useRouter();
  const perms = useLoad(fetchPermissions);
  const cal = useLoad(() => {
    const from = new Date(Date.now() - 7 * 864e5).toISOString();
    const to = new Date(Date.now() + 90 * 864e5).toISOString();
    return fetchCalendar(from, to);
  });
  const days = groupByDay(cal.data ?? []);
  return (
    <MediaScreen loading={cal.loading} error={cal.error || perms.error} onRetry={() => void cal.reload()} denied={perms.data && !has(perms.data, 'media.access') ? 'You do not have access to the calendar.' : undefined}>
      <Text style={s.title}>Content Calendar</Text>
      {days.map((d) => (
        <React.Fragment key={d.day}>
          <Text style={s.muted}>{d.day}</Text>
          {d.rows.map((r) => <Card key={`${r.kind}${r.id}`} title={r.title} note={r.kind === 'campaign' ? 'Campaign' : 'Content'} right={r.status} onPress={r.kind === 'content' ? () => router.push(`/media/item/${r.id}` as never) : undefined} />)}
        </React.Fragment>
      ))}
      {cal.data && days.length === 0 ? <Text style={s.muted}>Nothing scheduled in the next three months.</Text> : null}
    </MediaScreen>
  );
}
import React from 'react';
