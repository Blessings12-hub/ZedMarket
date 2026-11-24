import { Image, StyleSheet, Text, View } from 'react-native';

import { initials } from '../../domain/birthdays';
import { colors } from '../../theme';
import { avatarUrl } from './api';

// A round photo, or the person's initials when there is no photo (or they chose not to show it).
export function Avatar({ name, path, size = 44 }: { name: string; path: string | null; size?: number }) {
  const uri = avatarUrl(path);
  const box = { width: size, height: size, borderRadius: size / 2 };
  if (uri) return <Image source={{ uri }} style={box} accessibilityLabel={`Photo of ${name}`} />;
  return (
    <View style={[styles.fallback, box]} accessibilityLabel={name}>
      <Text style={[styles.text, { fontSize: size * 0.4 }]}>{initials(name)}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  fallback: { backgroundColor: colors.primarySoft, alignItems: 'center', justifyContent: 'center' },
  text: { color: colors.primary, fontWeight: '700' },
});
