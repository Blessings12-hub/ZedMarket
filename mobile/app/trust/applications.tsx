import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Image, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice } from '../../src/components/ui';
import { canReviewApplications, reasonProblem, type AdminRole } from '../../src/domain/admin';
import { STATUS_LABELS, type ApplicationKind, type ApplicationStatus } from '../../src/domain/trustAdmin';
import { fetchMyRoles } from '../../src/features/admin/api';
import {
  PAGE_SIZE,
  decideApplication,
  fetchApplications,
  openDocument,
  type Application,
} from '../../src/features/trust-admin/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

const STATUSES: ApplicationStatus[] = ['pending', 'approved', 'rejected'];

export default function Applications() {
  const router = useRouter();
  const { userId } = useAuth();
  const params = useLocalSearchParams<{ status?: string }>();
  const [status, setStatus] = useState<ApplicationStatus>(STATUSES.includes(params.status as ApplicationStatus) ? (params.status as ApplicationStatus) : 'pending');
  const [kind, setKind] = useState<ApplicationKind>('identity');
  const [search, setSearch] = useState('');
  const [roles, setRoles] = useState<AdminRole[]>([]);
  const [items, setItems] = useState<Application[]>([]);
  const [more, setMore] = useState(false);
  const [images, setImages] = useState<Record<string, string>>({});
  const [rejectingId, setRejectingId] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const load = useCallback(
    async (offset = 0) => {
      try {
        const page = await fetchApplications(kind, status, search, offset);
        setItems((current) => (offset === 0 ? page : [...current, ...page]));
        setMore(page.length === PAGE_SIZE);
        setError('');
      } catch (e) {
        setError(friendlyError(e));
      } finally {
        setLoading(false);
      }
    },
    [kind, status, search],
  );

  useFocusEffect(
    useCallback(() => {
      if (userId) fetchMyRoles(userId).then(setRoles).catch(() => {});
      setLoading(true);
      load(0);
    }, [load, userId]),
  );

  const mayReview = canReviewApplications(roles);

  async function showDocument(app: Application) {
    try {
      const url = await openDocument(app);
      setImages((current) => ({ ...current, [app.id]: url }));
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  async function decide(app: Application, approve: boolean) {
    if (!approve) {
      const problem = reasonProblem(note);
      if (problem) {
        setError(problem);
        return;
      }
    }
    setBusyId(app.id);
    setError('');
    try {
      await decideApplication(app, approve, note);
      setRejectingId(null);
      setNote('');
      await load(0);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <View style={styles.screen}>
      <View style={styles.filters}>
        <View style={styles.row}>
          {STATUSES.map((s) => (
            <Chip key={s} label={STATUS_LABELS[s]} selected={status === s} onPress={() => setStatus(s)} />
          ))}
        </View>
        <View style={styles.row}>
          <Chip label="People" selected={kind === 'identity'} onPress={() => setKind('identity')} />
          <Chip label="Businesses" selected={kind === 'business'} onPress={() => setKind('business')} />
        </View>
        <Field label="Search by name" value={search} onChangeText={setSearch} onSubmitEditing={() => load(0)} returnKeyType="search" />
        {error ? <Notice tone="error">{error}</Notice> : null}
      </View>

      <FlatList
        data={items}
        keyExtractor={(i) => `${i.kind}-${i.id}`}
        refreshing={loading}
        onRefresh={() => load(0)}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, flexGrow: 1 }}
        ListEmptyComponent={loading ? null : <Text style={styles.empty}>Nothing here.</Text>}
        ListFooterComponent={more ? <Button title="Load more" variant="secondary" onPress={() => load(items.length)} /> : null}
        renderItem={({ item }) => {
          const busy = busyId === item.id;
          const pending = item.status === 'pending';
          const ownApplication = item.subjectUserId === userId;
          return (
            <View style={styles.card}>
              <Text style={styles.kind}>{item.kind === 'identity' ? 'Identity check' : 'Business check'} · {STATUS_LABELS[item.status]}</Text>
              <Text style={styles.title}>{item.subjectName}</Text>
              <Text style={styles.detail}>{item.detail}</Text>
              <Text style={styles.meta}>Sent {new Date(item.submittedAt).toLocaleString()}</Text>
              {item.reviewedAt ? (
                <Text style={styles.meta}>
                  Decided {new Date(item.reviewedAt).toLocaleString()} by {item.reviewerName ?? 'unknown'}
                  {item.reviewerNote ? ` — ${item.reviewerNote}` : ''}
                </Text>
              ) : null}

              <Button
                title="Open the person's profile"
                variant="secondary"
                onPress={() => router.push({ pathname: '/trust/user/[id]', params: { id: item.subjectUserId } })}
              />

              {mayReview && item.hasDocument ? (
                images[item.id] ? (
                  <Image source={{ uri: images[item.id] }} style={styles.photo} resizeMode="contain" />
                ) : (
                  <Button title="Review the document" variant="secondary" onPress={() => showDocument(item)} />
                )
              ) : null}

              {mayReview && pending ? (
                ownApplication ? (
                  <Notice tone="warning">This is your own application. Another staff member must decide it.</Notice>
                ) : rejectingId === item.id ? (
                  <>
                    <Field
                      label="What is wrong? The person will see this."
                      value={note}
                      onChangeText={setNote}
                      multiline
                      maxLength={500}
                      style={{ minHeight: 80, textAlignVertical: 'top' }}
                    />
                    <Button title="Reject" variant="danger" onPress={() => decide(item, false)} loading={busy} />
                    <Button title="Back" variant="secondary" onPress={() => setRejectingId(null)} disabled={busy} />
                  </>
                ) : (
                  <>
                    <Button title="Approve" onPress={() => decide(item, true)} loading={busy} />
                    <Button
                      title="Reject"
                      variant="secondary"
                      disabled={busy}
                      onPress={() => {
                        setRejectingId(item.id);
                        setNote('');
                        setError('');
                      }}
                    />
                  </>
                )
              ) : null}
            </View>
          );
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  filters: { padding: spacing.lg, gap: spacing.sm },
  row: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.lg, gap: spacing.sm },
  kind: { fontSize: 13, color: colors.muted },
  title: { fontSize: 17, fontWeight: '600', color: colors.text },
  detail: { fontSize: 15, color: colors.text, textTransform: 'capitalize' },
  meta: { fontSize: 12, color: colors.muted },
  photo: { width: '100%', height: 260, backgroundColor: colors.primarySoft, borderRadius: radius.sm },
  empty: { textAlign: 'center', color: colors.muted, marginTop: spacing.xl },
});
