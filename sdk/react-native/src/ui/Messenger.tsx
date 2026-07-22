import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { OnloSDK } from '../onlo';
import { store, type OnloState } from '../store';
import type { OnloStrings } from '../types';
import { useOnloTheme } from './theme';

const DEFAULT_STRINGS: OnloStrings = {
  headerTitle: '',
  inputPlaceholder: 'Type your message…',
  send: 'Send',
  newConversation: 'New conversation',
  conversationsTitle: 'Conversations',
  offlineNotice: 'You appear to be offline — messages will send when you reconnect.',
  errorNotice: 'Something went wrong. Please try again.',
  close: 'Close',
};

export function useOnloState(): OnloState {
  const [state, setState] = useState<OnloState>(store.get());
  useEffect(() => store.subscribe(setState), []);
  return state;
}

/** Full messenger screen: header + (thread | conversation list) + composer. */
export function Messenger({ strings: stringOverrides }: { strings?: Partial<OnloStrings> }): React.JSX.Element {
  const state = useOnloState();
  const theme = useOnloTheme(state.theme);
  const strings = { ...DEFAULT_STRINGS, ...(stringOverrides || {}) };
  const [draft, setDraft] = useState('');
  const listRef = useRef<FlatList | null>(null);

  useEffect(() => {
    if (state.screen === 'thread') {
      const timer = setTimeout(() => listRef.current?.scrollToEnd({ animated: true }), 80);
      return () => clearTimeout(timer);
    }
    return undefined;
  }, [state.messages.length, state.streamingText, state.screen]);

  const send = () => {
    if (!draft.trim()) return;
    OnloSDK.__sendMessage(draft);
    setDraft('');
  };

  const headerTitle = strings.headerTitle || theme.botName;

  return (
    <View style={[styles.root, { backgroundColor: theme.background }]}>
      {/* Header */}
      <View style={[styles.header, { backgroundColor: theme.accent }]}>
        <View style={styles.headerLogo}>
          <Text style={styles.headerLogoText}>{theme.logoInitials}</Text>
        </View>
        <View style={styles.headerTitles}>
          <Text style={[styles.headerTitle, { color: theme.headerText }]} numberOfLines={1}>
            {headerTitle}
          </Text>
          {!!theme.botSubtitle && (
            <Text style={[styles.headerSub, { color: theme.headerText }]} numberOfLines={1}>
              {theme.botSubtitle}
            </Text>
          )}
        </View>
        <Pressable
          onPress={() => (state.screen === 'thread' ? OnloSDK.__showList() : store.set({ screen: 'thread' }))}
          style={styles.headerBtn}
          accessibilityLabel={state.screen === 'thread' ? strings.conversationsTitle : strings.close}
        >
          <Text style={[styles.headerBtnText, { color: theme.headerText }]}>
            {state.screen === 'thread' ? '☰' : '‹'}
          </Text>
        </Pressable>
        <Pressable onPress={() => OnloSDK.__onMessengerClosed()} style={styles.headerBtn} accessibilityLabel={strings.close}>
          <Text style={[styles.headerBtnText, { color: theme.headerText }]}>✕</Text>
        </Pressable>
      </View>

      {state.screen === 'list' ? (
        <View style={styles.flex}>
          <Pressable
            onPress={() => OnloSDK.__newConversation()}
            style={[styles.newConvBtn, { borderColor: theme.accent }]}
          >
            <Text style={[styles.newConvText, { color: theme.accent }]}>{strings.newConversation}</Text>
          </Pressable>
          <FlatList
            data={state.conversations}
            keyExtractor={(item) => item.id}
            renderItem={({ item }) => (
              <Pressable style={styles.convRow} onPress={() => OnloSDK.__selectConversation(item.id)}>
                <View style={styles.flex}>
                  <Text style={[styles.convTitle, { color: theme.incomingText }]} numberOfLines={1}>
                    {item.title}
                  </Text>
                  <Text style={[styles.convMeta, { color: theme.mutedText }]} numberOfLines={1}>
                    {new Date(item.updatedAt).toLocaleString()}
                  </Text>
                </View>
                {item.unreadCount > 0 && (
                  <View style={[styles.unreadDot, { backgroundColor: theme.accent }]}>
                    <Text style={styles.unreadDotText}>{item.unreadCount}</Text>
                  </View>
                )}
              </Pressable>
            )}
          />
        </View>
      ) : (
        <KeyboardAvoidingView
          style={styles.flex}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
          keyboardVerticalOffset={Platform.OS === 'ios' ? 8 : 0}
        >
          <FlatList
            ref={listRef}
            style={styles.flex}
            contentContainerStyle={styles.threadContent}
            data={state.messages}
            keyExtractor={(item) => item.id}
            ListHeaderComponent={
              state.messages.length === 0 ? (
                <View style={[styles.bubble, styles.incoming, { backgroundColor: theme.incomingBubble }]}>
                  <Text style={{ color: theme.incomingText }}>{theme.greeting}</Text>
                </View>
              ) : null
            }
            renderItem={({ item }) => {
              const isUser = item.role === 'user';
              return (
                <View
                  style={[
                    styles.bubble,
                    isUser ? styles.outgoing : styles.incoming,
                    { backgroundColor: isUser ? theme.outgoingBubble : theme.incomingBubble },
                  ]}
                >
                  <Text style={{ color: isUser ? theme.outgoingText : theme.incomingText }}>{item.content}</Text>
                  {theme.showTimestamps && !!item.createdAt && (
                    <Text style={[styles.timestamp, { color: isUser ? theme.outgoingText : theme.mutedText }]}>
                      {new Date(item.createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                    </Text>
                  )}
                </View>
              );
            }}
            ListFooterComponent={
              state.streamingText != null ? (
                <View style={[styles.bubble, styles.incoming, { backgroundColor: theme.incomingBubble }]}>
                  <Text style={{ color: theme.incomingText }}>{state.streamingText || '…'}</Text>
                </View>
              ) : state.sending ? (
                <View style={[styles.bubble, styles.incoming, { backgroundColor: theme.incomingBubble }]}>
                  <ActivityIndicator size="small" color={theme.accent} />
                </View>
              ) : null
            }
          />

          {state.offlineQueued > 0 && (
            <Text style={[styles.notice, { color: theme.mutedText }]}>{strings.offlineNotice}</Text>
          )}
          {!!state.errorNotice && <Text style={[styles.notice, { color: '#c2410c' }]}>{strings.errorNotice}</Text>}

          <View style={styles.composer}>
            <TextInput
              style={[styles.input, { color: theme.incomingText, borderColor: theme.incomingBubble }]}
              value={draft}
              onChangeText={setDraft}
              placeholder={strings.inputPlaceholder}
              placeholderTextColor={theme.mutedText}
              multiline
              onSubmitEditing={send}
            />
            <Pressable
              onPress={send}
              disabled={!draft.trim() || state.sending}
              style={[styles.sendBtn, { backgroundColor: theme.accent, opacity: !draft.trim() || state.sending ? 0.5 : 1 }]}
              accessibilityLabel={strings.send}
            >
              <Text style={styles.sendBtnText}>↑</Text>
            </Pressable>
          </View>
        </KeyboardAvoidingView>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  flex: { flex: 1 },
  header: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 14, paddingVertical: 12, gap: 10 },
  headerLogo: {
    width: 30,
    height: 30,
    borderRadius: 15,
    backgroundColor: 'rgba(255,255,255,0.18)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerLogoText: { color: '#fff', fontSize: 12, fontWeight: '700' },
  headerTitles: { flex: 1 },
  headerTitle: { fontSize: 15, fontWeight: '600' },
  headerSub: { fontSize: 11, opacity: 0.75, marginTop: 1 },
  headerBtn: { padding: 6 },
  headerBtnText: { fontSize: 16 },
  threadContent: { padding: 14, gap: 8 },
  bubble: { maxWidth: '82%', borderRadius: 14, paddingHorizontal: 12, paddingVertical: 9, marginBottom: 8 },
  incoming: { alignSelf: 'flex-start', borderBottomLeftRadius: 4 },
  outgoing: { alignSelf: 'flex-end', borderBottomRightRadius: 4 },
  timestamp: { fontSize: 10, opacity: 0.6, marginTop: 4, alignSelf: 'flex-end' },
  notice: { fontSize: 11, textAlign: 'center', paddingHorizontal: 16, paddingBottom: 6 },
  composer: { flexDirection: 'row', alignItems: 'flex-end', padding: 10, gap: 8 },
  input: {
    flex: 1,
    borderWidth: 1,
    borderRadius: 20,
    paddingHorizontal: 14,
    paddingTop: 9,
    paddingBottom: 9,
    fontSize: 14,
    maxHeight: 110,
  },
  sendBtn: { width: 38, height: 38, borderRadius: 19, alignItems: 'center', justifyContent: 'center' },
  sendBtnText: { color: '#fff', fontSize: 17, fontWeight: '700' },
  newConvBtn: {
    margin: 12,
    borderWidth: 1,
    borderRadius: 10,
    paddingVertical: 10,
    alignItems: 'center',
  },
  newConvText: { fontSize: 13, fontWeight: '600' },
  convRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 12,
    gap: 10,
  },
  convTitle: { fontSize: 13.5, fontWeight: '600' },
  convMeta: { fontSize: 11, marginTop: 2 },
  unreadDot: { minWidth: 20, height: 20, borderRadius: 10, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 5 },
  unreadDotText: { color: '#fff', fontSize: 10, fontWeight: '700' },
});
