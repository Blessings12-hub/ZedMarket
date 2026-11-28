import { useEffect, useState } from 'react';
import { ActivityIndicator, Linking, ScrollView, Share, StyleSheet, Text } from 'react-native';

import { Button, Notice, SectionTitle } from '../src/components/ui';
import { inviteMessage } from '../src/domain/invite';
import { webBase, whatsappShareUrl } from '../src/domain/share';
import { fetchInviteCount, fetchMyInviteCode } from '../src/features/launch/api';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

export default function Invite() {
  const [code, setCode] = useState('');
  const [count, setCount] = useState(0);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      try {
        setCode(await fetchMyInviteCode());
        setCount(await fetchInviteCount().catch(() => 0));
      } catch (e) {
        setError(friendlyError(e));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const message = code ? inviteMessage(code, webBase(process.env.EXPO_PUBLIC_WEB_URL)) : '';

  async function shareWhatsApp() {
    try {
      await Linking.openURL(whatsappShareUrl(message));
    } catch {
      setError('WhatsApp could not be opened. Use Share instead.');
    }
  }

  async function shareAny() {
    try {
      await Share.share({ message });
    } catch {
      // Closing the share sheet is not an error.
    }
  }

  if (loading) return <ActivityIndicator style={{ marginTop: spacing.xl }} color={colors.primary} />;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <SectionTitle>Your invite code</SectionTitle>
      {code ? <Text selectable style={styles.code}>{code}</Text> : null}
      <Text style={styles.help}>Share it with friends. They enter it once, in their first 30 days. There is no reward yet; this only shows how many friends joined.</Text>
      <Text style={styles.count}>{count === 1 ? '1 friend has joined with your code' : `${count} friends have joined with your code`}</Text>
      {code ? (
        <>
          <Button title="Share on WhatsApp" onPress={shareWhatsApp} />
          <Button title="Share another way" variant="secondary" onPress={shareAny} />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  code: { fontSize: 32, fontWeight: '800', letterSpacing: 4, color: colors.primary, backgroundColor: colors.primarySoft, padding: spacing.lg, borderRadius: radius.md, textAlign: 'center' },
  help: { fontSize: 14, color: colors.muted, lineHeight: 20 },
  count: { fontSize: 15, fontWeight: '600', color: colors.text },
});
