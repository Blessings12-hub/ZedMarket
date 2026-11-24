import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, Chip, Notice } from '../../../src/components/ui';
import { SECTIONS, countsLine, formatWhen, statusLabel, timeLeft, type VoteSection } from '../../../src/domain/voting';
import { fetchProposals, fetchVoteAccess, type Proposal, type VoteAccess } from '../../../src/features/voting/api';
import { friendlyError } from '../../../src/lib/errors';
import { colors, radius, spacing } from '../../../src/theme';

export default function VotesHome() {
  const router = useRouter();
  const [section, setSection] = useState<VoteSection>('active');
  const [items, setItems] = useState<Proposal[] | null>(null);
  const [access, setAccess] = useState<VoteAccess | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(async (which: VoteSection) => {
    try {
      setError('');
      const [list, a] = await Promise.all([fetchProposals(which), fetchVoteAccess()]);
      setItems(list);
      setAccess(a);
    } catch (e) {
      setItems([]);
      setError(friendlyError(e) === 'Not allowed.' ? 'Staff voting needs staff access and your two-factor code. Open Staff tools first.' : friendlyError(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load(section);
    }, [load, section]),
  );

  function pick(next: VoteSection) {
    setItems(null);
    setSection(next);
  }

  const current = SECTIONS.find((s) => s.key === section)!;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Text style={styles.title}>Staff voting</Text>
      <Text style={styles.text}>
        A proposal passes only when two thirds of the eligible staff vote for it, and is rejected only when two thirds vote against it. Abstaining or not voting counts for neither side.
      </Text>

      <View style={styles.row}>
        {access?.canPropose ? <Button title="New proposal" onPress={() => router.push('/admin/votes/new')} /> : null}
        <Button title="My voting history" variant="secondary" onPress={() => router.push('/admin/votes/history')} />
      </View>

      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chips}>
        {SECTIONS.map((s) => (
          <Chip key={s.key} label={s.label} selected={s.key === section} onPress={() => pick(s.key)} />
        ))}
      </ScrollView>

      {items === null ? <ActivityIndicator color={colors.primary} /> : null}
      {items && items.length === 0 && !error ? <Text style={styles.text}>{current.empty}</Text> : null}

      {items?.map((p) => (
        <Pressable
          key={p.id}
          accessibilityRole="button"
          accessibilityLabel={`${p.reference}, ${p.title}, ${statusLabel(p.status)}`}
          onPress={() => router.push(`/admin/votes/${p.id}`)}
          style={styles.card}
        >
          <View style={styles.cardTop}>
            <Text style={styles.ref}>{p.reference}</Text>
            <Text style={styles.status}>{statusLabel(p.status)}</Text>
          </View>
          <Text style={styles.cardTitle}>{p.confidential ? 'Confidential: ' : ''}{p.title}</Text>
          <Text style={styles.meta}>Proposed by {p.proposerName}</Text>
          {p.status === 'active' ? (
            <>
              <Text style={styles.meta}>{countsLine({ for: p.forCount, against: p.againstCount, abstain: p.abstainCount, hidden: p.countsHidden })}</Text>
              <Text style={styles.meta}>
                Needs {p.requiredVotes} of {p.eligibleCount} · {timeLeft(p.closesAt)}
              </Text>
              {p.canVote ? <Text style={styles.action}>Your vote is needed</Text> : p.myChoice ? <Text style={styles.meta}>You have voted</Text> : null}
            </>
          ) : null}
          {p.status === 'pending' ? <Text style={styles.meta}>Opens {formatWhen(p.opensAt)}</Text> : null}
          {p.closedAt ? <Text style={styles.meta}>Closed {formatWhen(p.closedAt)}</Text> : null}
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  row: { gap: spacing.sm },
  chips: { gap: spacing.sm, paddingVertical: spacing.xs },
  card: { padding: spacing.md, gap: spacing.xs, borderRadius: radius.md, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  cardTop: { flexDirection: 'row', justifyContent: 'space-between' },
  ref: { fontSize: 13, fontWeight: '600', color: colors.muted },
  status: { fontSize: 13, fontWeight: '700', color: colors.primary },
  cardTitle: { fontSize: 16, fontWeight: '700', color: colors.text },
  meta: { fontSize: 14, color: colors.muted },
  action: { fontSize: 14, fontWeight: '700', color: colors.warning },
});
