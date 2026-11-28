import { Fragment } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';

import { LEGAL_DRAFT_NOTE, type LegalSection } from '../domain/legal';
import { colors, spacing } from '../theme';
import { Notice, SectionTitle } from './ui';

export function LegalView({ sections }: { sections: LegalSection[] }) {
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Notice tone="warning">{LEGAL_DRAFT_NOTE}</Notice>
      {sections.map((s) => (
        <Fragment key={s.title}>
          <SectionTitle>{s.title}</SectionTitle>
          {s.points.map((p) => (
            <Text key={p} style={styles.text}>{'•  '}{p}</Text>
          ))}
        </Fragment>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, color: colors.text, lineHeight: 22 },
});
