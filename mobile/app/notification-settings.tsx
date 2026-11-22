import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ScrollView, StyleSheet, Switch, Text, View } from 'react-native';

import { Button, Notice } from '../src/components/ui';
import { CATEGORIES, canTurnOff } from '../src/domain/notifications';
import {
  fetchChannels,
  fetchSettings,
  saveSetting,
  type Channels,
  type NotificationSetting,
} from '../src/features/notifications/api';
import { enablePush } from '../src/features/notifications/push';
import { friendlyError } from '../src/lib/errors';
import { colors, radius, spacing } from '../src/theme';

export default function NotificationSettingsScreen() {
  const [settings, setSettings] = useState<NotificationSetting[]>([]);
  const [channels, setChannels] = useState<Channels>({ push: true, email: false, sms: false });
  const [error, setError] = useState('');
  const [pushNote, setPushNote] = useState('');

  const load = useCallback(async () => {
    try {
      const [s, c] = await Promise.all([fetchSettings(), fetchChannels()]);
      setSettings(s);
      setChannels(c);
      setError('');
    } catch (e) {
      setError(friendlyError(e));
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  async function change(next: NotificationSetting) {
    const before = settings;
    setSettings((prev) => prev.map((s) => (s.category === next.category ? next : s)));
    try {
      await saveSetting(next);
    } catch (e) {
      setSettings(before);
      setError(friendlyError(e));
    }
  }

  async function turnOnPush() {
    const r = await enablePush();
    setPushNote(
      r === 'on'
        ? 'Push notifications are on for this phone.'
        : r === 'denied'
          ? 'Notifications are blocked for ZedMarket. Allow them in your phone settings.'
          : 'Push is not available in this version of the app yet.',
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <Button title="Turn on push for this phone" variant="secondary" onPress={turnOnPush} />
      {pushNote ? <Notice>{pushNote}</Notice> : null}
      {!channels.email && !channels.sms ? (
        <Notice>Email and SMS are not available yet. In-app and push are.</Notice>
      ) : null}
      {CATEGORIES.map((c) => {
        const s = settings.find((x) => x.category === c.key);
        if (!s) return null;
        const locked = !canTurnOff(c.key);
        return (
          <View key={c.key} style={styles.card}>
            <Text style={styles.title}>{c.label}</Text>
            <Text style={styles.hint}>{c.hint}</Text>
            <Line label="Show in the app" value={s.inApp} disabled={locked} onChange={(v) => change({ ...s, inApp: v })} />
            <Line label="Push to this phone" value={s.push} disabled={locked || !s.inApp} onChange={(v) => change({ ...s, push: v })} />
            {channels.email ? <Line label="Email" value={s.email} disabled={!s.inApp} onChange={(v) => change({ ...s, email: v })} /> : null}
            {channels.sms ? <Line label="SMS" value={s.sms} disabled={!s.inApp} onChange={(v) => change({ ...s, sms: v })} /> : null}
          </View>
        );
      })}
    </ScrollView>
  );
}

function Line({ label, value, disabled, onChange }: { label: string; value: boolean; disabled?: boolean; onChange: (v: boolean) => void }) {
  return (
    <View style={styles.line}>
      <Text style={styles.label}>{label}</Text>
      <Switch value={value} onValueChange={onChange} disabled={disabled} />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, padding: spacing.md, gap: spacing.sm, borderWidth: 1, borderColor: colors.border },
  title: { color: colors.text, fontSize: 16, fontWeight: '700' },
  hint: { color: colors.muted, fontSize: 13 },
  line: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  label: { color: colors.text, fontSize: 15 },
});
