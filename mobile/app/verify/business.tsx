import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Field, Notice, SectionTitle } from '../../src/components/ui';
import {
  makeSlug,
  reviewStateLabel,
  slugProblem,
  validateBusinessName,
  validateRegistration,
} from '../../src/domain/trust';
import {
  createBusiness,
  fetchBusinessRequest,
  pickOnePhoto,
  submitBusinessVerification,
  type VerificationRequest,
} from '../../src/features/trust/api';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function BusinessScreen() {
  const { businessId } = useLocalSearchParams<{ businessId?: string }>();
  const router = useRouter();
  const { userId } = useAuth();

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [registration, setRegistration] = useState('');
  const [photo, setPhoto] = useState<string | null>(null);
  const [request, setRequest] = useState<VerificationRequest | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!businessId) return;
    fetchBusinessRequest(businessId)
      .then(setRequest)
      .catch((e) => setError(friendlyError(e)));
  }, [businessId]);

  async function create() {
    const problem = validateBusinessName(name) ?? slugProblem(makeSlug(name));
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      const id = await createBusiness(name, makeSlug(name), description);
      router.replace({ pathname: '/verify/business', params: { businessId: id } });
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function choosePhoto() {
    try {
      const uri = await pickOnePhoto();
      if (uri) setPhoto(uri);
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  async function submit() {
    if (!userId || !businessId) return;
    const problem = validateRegistration(registration);
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      await submitBusinessVerification(userId, businessId, registration, photo);
      setRequest(await fetchBusinessRequest(businessId));
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!businessId) {
    return (
      <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        {error ? <Notice tone="error">{error}</Notice> : null}
        <Field label="Business name" value={name} onChangeText={setName} maxLength={80} />
        <Field
          label="What do you sell? (optional)"
          value={description}
          onChangeText={setDescription}
          multiline
          maxLength={1000}
          style={{ minHeight: 80, textAlignVertical: 'top' }}
        />
        <Button title="Create business" onPress={create} loading={busy} />
      </ScrollView>
    );
  }

  const waiting = request?.state === 'pending';

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {error ? <Notice tone="error">{error}</Notice> : null}
      {request ? (
        <>
          <SectionTitle>Where things stand</SectionTitle>
          <Text style={styles.text}>{reviewStateLabel(request.state)}</Text>
          {request.state === 'rejected' && request.note ? <Text style={styles.reason}>{request.note}</Text> : null}
        </>
      ) : null}

      {!waiting ? (
        <>
          <SectionTitle>Registration details</SectionTitle>
          <Field label="Registration number from your PACRA certificate" value={registration} onChangeText={setRegistration} maxLength={40} autoCapitalize="characters" />
          <Text style={styles.text}>Add a photo of the certificate if you have one. It helps the check go faster.</Text>
          {photo ? <Image source={{ uri: photo }} style={styles.preview} resizeMode="contain" /> : null}
          <Button title={photo ? 'Choose a different photo' : 'Add a photo of the certificate'} variant="secondary" onPress={choosePhoto} />
          <Button title="Send for checking" onPress={submit} loading={busy} />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  text: { fontSize: 15, lineHeight: 22, color: colors.muted },
  reason: { fontSize: 14, color: colors.danger },
  preview: { width: '100%', height: 220, borderRadius: radius.md, backgroundColor: colors.surface },
});
