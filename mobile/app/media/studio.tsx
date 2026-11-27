import { useLocalSearchParams, useRouter } from 'expo-router';

import { Button } from '../../src/components/ui';
import { fetchPermissions, listContent } from '../../src/features/media/api';
import { ANNOUNCEMENT_KINDS, CONTENT_KINDS, STATUS_LABEL, has, queueGroups } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s, when } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { Text } from 'react-native';

// One list screen used three ways: all content, announcements only, or the publishing queue.
export default function Studio() {
  const router = useRouter();
  const { only } = useLocalSearchParams<{ only?: string }>();
  const perms = useLoad(fetchPermissions);
  const list = useLoad(() => listContent(only === 'announcements' ? { kinds: ANNOUNCEMENT_KINDS } : only === 'queue' ? { statuses: ['submitted', 'approved', 'scheduled'] } : {}), [only]);
  const p = perms.data ?? [];
  const items = list.data ?? [];
  const kindLabel = (k: string) => CONTENT_KINDS.find((x) => x.key === k)?.label ?? k;
  const card = (c: (typeof items)[number]) => (
    <Card key={c.id} title={c.title} note={`${kindLabel(c.kind)} · ${c.creatorName}`} meta={c.scheduledFor ? `Goes out ${when(c.scheduledFor)}` : `Updated ${when(c.updatedAt)}`} right={STATUS_LABEL[c.status]} onPress={() => router.push(`/media/item/${c.id}` as never)} />
  );
  const q = queueGroups(items.map((c) => ({ id: c.id, title: c.title, status: c.status, createdBy: c.createdBy, scheduledFor: c.scheduledFor })));
  const byId = new Map(items.map((c) => [c.id, c]));

  return (
    <MediaScreen loading={list.loading} error={list.error || perms.error} onRetry={() => { void list.reload(); void perms.reload(); }} denied={perms.data && !has(p, 'media.access') ? 'You do not have access to the Content Studio.' : undefined}>
      <Text style={s.title}>{only === 'queue' ? 'Publishing Queue' : only === 'announcements' ? 'Announcements' : 'Content Studio'}</Text>
      {has(p, 'media.create') ? <Button title={only === 'announcements' ? 'New announcement' : 'New content'} onPress={() => router.push(`/media/item/new${only === 'announcements' ? '?kind=announcement' : ''}` as never)} /> : null}
      {only === 'queue' ? (
        <>
          <Text style={s.muted}>Waiting for a decision</Text>{q.review.map((i) => card(byId.get(i.id)!))}
          <Text style={s.muted}>Approved, ready to publish</Text>{q.ready.map((i) => card(byId.get(i.id)!))}
          <Text style={s.muted}>Scheduled</Text>{q.scheduled.map((i) => card(byId.get(i.id)!))}
        </>
      ) : items.map(card)}
      {list.data && items.length === 0 ? <Text style={s.muted}>Nothing here yet.</Text> : null}
    </MediaScreen>
  );
}
