import { useRouter } from 'expo-router';
import { useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Notice, SectionTitle } from '../../src/components/ui';
import { DOCUMENT_TYPES, type DocumentType } from '../../src/domain/trust';
import { pickOnePhoto, submitIdentity } from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function IdentityCheck() {
  const router = useRouter();
  const { userId } = useAuth();
  const [type, setType] = useState<DocumentType | null>(null);
  const [photo, setPhoto] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  async function choosePhoto() {
    try {
      const uri = await pickOnePhoto();
      if (uri) setPhoto(uri);
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  async function submit() {
    if (!userId || !type || !photo) return;
    setBusy(true);
    setError('');
    try {
      await submitIdentity(userId, type, photo);
      setSent(true);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (sent) {
    return (
      <View style={styles.done}>
        <Text style={styles.title}>We have your document</Text>
        <Text style={styles.text}>Someone on our team will check it. You will see the result on the verification page.</Text>
        <Button title="Done" onPress={() => router.back()} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>Which document will you use?</SectionTitle>
      <View style={styles.row}>
        {DOCUMENT_TYPES.map((d) => (
          <Chip key={d.value} label={d.label} selected={type === d.value} onPress={() => setType(d.value)} />
        ))}
      </View>

      <SectionTitle>Photo of the document</SectionTitle>
      <Text style={styles.text}>The whole document, flat, in good light, with every word readable.</Text>
      {photo ? <Image source={{ uri: photo }} style={styles.preview} resizeMode="contain" /> : null}
      <Button title={photo ? 'Choose a different photo' : 'Choose a photo'} variant="secondary" onPress={choosePhoto} />

      <Button title="Send for checking" onPress={submit} loading={busy} disabled={!type || !photo} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  preview: { width: '100%', height: 220, borderRadius: radius.md, backgroundColor: colors.surface },
  done: { flex: 1, padding: spacing.xl, gap: spacing.lg, justifyContent: 'center', backgroundColor: colors.background },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
});
