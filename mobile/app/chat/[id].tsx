import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { Alert, FlatList, KeyboardAvoidingView, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { useAuth } from '../../src/auth/AuthProvider';
import { Notice } from '../../src/components/ui';
import {
  conversationInfo,
  loadMessages,
  markRead,
  sendMessage,
  toMessage,
  type Message,
} from '../../src/features/chat/api';
import { blockUser } from '../../src/features/reports/api';
import { friendlyError } from '../../src/lib/errors';
import { supabase } from '../../src/lib/supabase';
import { colors, radius, spacing } from '../../src/theme';

export default function ChatScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { userId } = useAuth();

  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState('');
  const [title, setTitle] = useState('Chat');
  const [otherUserId, setOtherUserId] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [sending, setSending] = useState(false);
  const listRef = useRef<FlatList<Message>>(null);

  useEffect(() => {
    if (!id || !userId) return;
    let active = true;

    (async () => {
      try {
        const [info, existing] = await Promise.all([conversationInfo(id, userId), loadMessages(id)]);
        if (!active) return;
        setTitle(info.listingTitle);
        setOtherUserId(info.otherUserId);
        setMessages(existing);
        markRead(id, userId);
      } catch (e) {
        if (active) setError(friendlyError(e));
      }
    })();

    // New messages arrive through realtime; row level security decides who receives them.
    const channel = supabase
      .channel(`conversation:${id}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'messages', filter: `conversation_id=eq.${id}` },
        (payload) => {
          const incoming = toMessage(payload.new as Parameters<typeof toMessage>[0]);
          setMessages((current) => (current.some((m) => m.id === incoming.id) ? current : [...current, incoming]));
          if (incoming.senderId !== userId) markRead(id, userId);
        },
      )
      .subscribe();

    return () => {
      active = false;
      supabase.removeChannel(channel);
    };
  }, [id, userId]);

  async function send() {
    const body = draft.trim();
    if (!body || !id) return;
    setSending(true);
    setError('');
    try {
      await sendMessage(id, body);
      setDraft('');
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setSending(false);
    }
  }

  function reportMessage(message: Message) {
    router.push({ pathname: '/report', params: { targetType: 'message', targetId: message.id } });
  }

  function confirmBlock() {
    if (!otherUserId) return;
    Alert.alert('Block this person?', 'You will no longer be able to message each other.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Block',
        style: 'destructive',
        onPress: async () => {
          try {
            await blockUser(otherUserId);
            router.back();
          } catch (e) {
            setError(friendlyError(e));
          }
        },
      },
    ]);
  }

  return (
    <SafeAreaView style={styles.screen} edges={['bottom']}>
      <Stack.Screen
        options={{
          title,
          headerRight: () => (
            <Pressable accessibilityRole="button" onPress={confirmBlock} hitSlop={8}>
              <Text style={{ color: colors.danger, fontWeight: '600' }}>Block</Text>
            </Pressable>
          ),
        }}
      />
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }} keyboardVerticalOffset={90}>
        {error ? (
          <View style={{ padding: spacing.md }}>
            <Notice tone="error">{error}</Notice>
          </View>
        ) : null}

        <FlatList
          ref={listRef}
          data={messages}
          keyExtractor={(m) => m.id}
          contentContainerStyle={styles.list}
          onContentSizeChange={() => listRef.current?.scrollToEnd({ animated: true })}
          ListHeaderComponent={
            <Text style={styles.safety}>
              Keep the conversation here. Never send money before you have seen the item. Press and hold a message to report it.
            </Text>
          }
          renderItem={({ item }) => {
            const mine = item.senderId === userId;
            return (
              <Pressable onLongPress={mine ? undefined : () => reportMessage(item)} style={[styles.bubble, mine ? styles.mine : styles.theirs]}>
                <Text style={mine ? styles.mineText : styles.theirsText}>{item.body}</Text>
              </Pressable>
            );
          }}
        />

        <View style={styles.composer}>
          <TextInput
            value={draft}
            onChangeText={setDraft}
            placeholder="Write a message"
            placeholderTextColor={colors.muted}
            style={styles.input}
            multiline
            maxLength={2000}
          />
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Send message"
            onPress={send}
            disabled={sending || draft.trim().length === 0}
            style={[styles.send, (sending || draft.trim().length === 0) && { opacity: 0.5 }]}
          >
            <Text style={styles.sendText}>Send</Text>
          </Pressable>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  list: { padding: spacing.lg, gap: spacing.sm },
  safety: { textAlign: 'center', fontSize: 13, color: colors.muted, marginBottom: spacing.md },
  bubble: { maxWidth: '82%', paddingHorizontal: spacing.md, paddingVertical: spacing.sm, borderRadius: radius.md },
  mine: { alignSelf: 'flex-end', backgroundColor: colors.primary },
  theirs: { alignSelf: 'flex-start', backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  mineText: { color: colors.onPrimary, fontSize: 16 },
  theirsText: { color: colors.text, fontSize: 16 },
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: spacing.sm,
    padding: spacing.md,
    borderTopWidth: 1,
    borderTopColor: colors.border,
    backgroundColor: colors.surface,
  },
  input: {
    flex: 1,
    maxHeight: 120,
    minHeight: 44,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    fontSize: 16,
    color: colors.text,
  },
  send: { minHeight: 44, justifyContent: 'center', paddingHorizontal: spacing.lg, borderRadius: radius.md, backgroundColor: colors.primary },
  sendText: { color: colors.onPrimary, fontWeight: '600' },
});
