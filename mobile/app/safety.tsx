import { Fragment } from 'react';
import { ScrollView, StyleSheet, Text } from 'react-native';

import { Notice, SectionTitle } from '../src/components/ui';
import { SAFETY_SECTIONS } from '../src/domain/safetyTips';
import { colors, spacing } from '../src/theme';

// Open to everyone, including guests, so it can be shared and read before signing up.
export default function Safety() {
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <Notice>At the moment ZedMarket does not hold your money. You and the seller agree how to pay, so a few habits keep you safe.</Notice>
      {SAFETY_SECTIONS.map((s) => (
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
