import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { CONDITIONS, MAX_PHOTOS, validateListing, type ItemCondition, type ListingErrors } from '../../src/domain/listing';
import { parsePrice } from '../../src/domain/money';
import { loadReferenceData, pickPhotos, publishListing, type PickedPhoto } from '../../src/features/listings/api';
import type { Category, Location } from '../../src/features/listings/types';
import { friendlyError } from '../../src/lib/errors';
import { colors, radius, spacing } from '../../src/theme';

export default function SellScreen() {
  const router = useRouter();
  const { userId } = useAuth();

  const [categories, setCategories] = useState<Category[]>([]);
  const [locations, setLocations] = useState<Location[]>([]);

  const [title, setTitle] = useState('');
  const [price, setPrice] = useState('');
  const [description, setDescription] = useState('');
  const [categoryId, setCategoryId] = useState<number | null>(null);
  const [locationId, setLocationId] = useState<number | null>(null);
  const [condition, setCondition] = useState<ItemCondition | null>(null);
  const [warrantyInfo, setWarrantyInfo] = useState('');
  const [returnPolicy, setReturnPolicy] = useState('');
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);

  const [errors, setErrors] = useState<ListingErrors>({});
  const [failure, setFailure] = useState('');
  const [result, setResult] = useState<'live' | 'review' | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    loadReferenceData()
      .then((ref) => {
        setCategories(ref.categories);
        setLocations(ref.locations);
      })
      .catch((e) => setFailure(friendlyError(e)));
  }, []);

  async function addPhotos() {
    try {
      const picked = await pickPhotos(MAX_PHOTOS - photos.length);
      if (picked.length > 0) setPhotos((current) => [...current, ...picked].slice(0, MAX_PHOTOS));
    } catch (e) {
      setFailure(friendlyError(e));
    }
  }

  function reset() {
    setTitle('');
    setPrice('');
    setDescription('');
    setCategoryId(null);
    setLocationId(null);
    setCondition(null);
    setWarrantyInfo('');
    setReturnPolicy('');
    setPhotos([]);
    setErrors({});
    setFailure('');
    setResult(null);
  }

  async function submit() {
    setFailure('');
    const found = validateListing({
      title,
      price,
      description,
      categoryId,
      locationId,
      condition,
      warrantyInfo,
      returnPolicy,
      photoCount: photos.length,
    });
    setErrors(found);
    if (Object.keys(found).length > 0 || !userId) return;

    const parsed = parsePrice(price);
    if (parsed === null || categoryId === null || locationId === null || condition === null) return;

    setBusy(true);
    try {
      const outcome = await publishListing({
        userId,
        title,
        price: parsed,
        description,
        categoryId,
        locationId,
        condition,
        warrantyInfo,
        returnPolicy,
        photos,
      });
      setResult(outcome.moderationStatus === 'approved' ? 'live' : 'review');
    } catch (e) {
      setFailure(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  if (result) {
    return (
      <View style={styles.done}>
        <Text style={styles.doneTitle}>{result === 'live' ? 'Your listing is live' : 'Your listing is being checked'}</Text>
        <Text style={styles.doneText}>
          {result === 'live'
            ? 'Buyers can find it now. You can pause it or mark it as sold from your account.'
            : 'A moderator looks at some listings before they appear, for example higher-priced items from new sellers. You will find it under My listings, and it goes live once it is approved.'}
        </Text>
        <Button title="Back to Browse" onPress={() => { reset(); router.replace('/'); }} />
        <Button title="Post another item" variant="secondary" onPress={reset} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {failure ? <Notice tone="error">{failure}</Notice> : null}

      <SectionTitle>Photos</SectionTitle>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: spacing.sm }}>
        {photos.map((photo, index) => (
          <Pressable
            key={photo.uri}
            accessibilityLabel={`Remove photo ${index + 1}`}
            onPress={() => setPhotos((current) => current.filter((p) => p.uri !== photo.uri))}
          >
            <Image source={{ uri: photo.uri }} style={styles.thumb} />
            <Text style={styles.remove}>Remove</Text>
          </Pressable>
        ))}
        {photos.length < MAX_PHOTOS ? (
          <Pressable accessibilityRole="button" style={[styles.thumb, styles.addPhoto]} onPress={addPhotos}>
            <Text style={styles.addPhotoText}>Add photo</Text>
          </Pressable>
        ) : null}
      </ScrollView>
      {errors.photoCount ? <Text style={styles.error}>{errors.photoCount}</Text> : (
        <Text style={styles.hint}>Use clear photos of the actual item. Up to {MAX_PHOTOS}.</Text>
      )}

      <Field label="Title" value={title} onChangeText={setTitle} maxLength={120} error={errors.title} />
      <Field label="Price (kwacha)" value={price} onChangeText={setPrice} keyboardType="numeric" error={errors.price} />

      <SectionTitle>Category</SectionTitle>
      <View style={styles.row}>
        {categories.map((c) => (
          <Chip key={c.id} label={c.name} selected={categoryId === c.id} onPress={() => setCategoryId(c.id)} />
        ))}
      </View>
      {errors.categoryId ? <Text style={styles.error}>{errors.categoryId}</Text> : null}

      <SectionTitle>Condition</SectionTitle>
      <View style={styles.row}>
        {CONDITIONS.map((c) => (
          <Chip key={c.value} label={c.label} selected={condition === c.value} onPress={() => setCondition(c.value)} />
        ))}
      </View>
      {errors.condition ? <Text style={styles.error}>{errors.condition}</Text> : null}

      <SectionTitle>Where is it?</SectionTitle>
      <View style={styles.row}>
        {locations.map((l) => (
          <Chip key={l.id} label={l.area ?? l.town} selected={locationId === l.id} onPress={() => setLocationId(l.id)} />
        ))}
      </View>
      {errors.locationId ? <Text style={styles.error}>{errors.locationId}</Text> : null}

      <Field
        label="Description"
        value={description}
        onChangeText={setDescription}
        multiline
        maxLength={4000}
        style={{ minHeight: 110, textAlignVertical: 'top' }}
        error={errors.description}
      />
      <Field label="Warranty (optional)" value={warrantyInfo} onChangeText={setWarrantyInfo} maxLength={500} error={errors.warrantyInfo} />
      <Field label="Returns (optional)" value={returnPolicy} onChangeText={setReturnPolicy} maxLength={500} error={errors.returnPolicy} />

      <Button title="Publish listing" onPress={submit} loading={busy} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl * 2 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  thumb: { width: 92, height: 92, borderRadius: radius.sm },
  addPhoto: { borderWidth: 1, borderStyle: 'dashed', borderColor: colors.primary, alignItems: 'center', justifyContent: 'center' },
  addPhotoText: { color: colors.primary, fontWeight: '600' },
  remove: { textAlign: 'center', color: colors.muted, fontSize: 12, marginTop: 2 },
  hint: { color: colors.muted, fontSize: 13 },
  error: { color: colors.danger, fontSize: 13 },
  done: { flex: 1, padding: spacing.xl, gap: spacing.lg, justifyContent: 'center', backgroundColor: colors.background },
  doneTitle: { fontSize: 24, fontWeight: '700', color: colors.text },
  doneText: { fontSize: 16, lineHeight: 24, color: colors.muted },
});
