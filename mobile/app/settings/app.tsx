import { ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { SectionTitle } from '../../src/components/ui';
import { setDataSaver, useDataSaver } from '../../src/lib/dataSaver';
import { colors, spacing } from '../../src/theme';

export default function AppSettings() {
  const saver = useDataSaver();
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <SectionTitle>Mobile data</SectionTitle>
      <View style={styles.row}>
        <View style={{ flex: 1, gap: 4 }}>
          <Text style={styles.label}>Data saver</Text>
          <Text style={styles.help}>
            Lists show a plain card and load a photo only when you tap Show photo. A listing opens with its first photo, and you load the rest when you want them. Good for slow or expensive mobile data.
          </Text>
        </View>
        <Switch accessibilityLabel="Data saver" value={saver} onValueChange={(v) => void setDataSaver(v)} />
      </View>
      <Text style={styles.help}>This setting is kept on this phone only.</Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  label: { fontSize: 16, fontWeight: '600', color: colors.text },
  help: { fontSize: 13, color: colors.muted, lineHeight: 19 },
});
