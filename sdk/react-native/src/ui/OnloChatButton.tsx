import React, { useEffect } from 'react';
import { Modal, Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native';
import { OnloSDK } from '../onlo';
import type { OnloStrings } from '../types';
import { Messenger, useOnloState } from './Messenger';
import { useOnloTheme } from './theme';

/**
 * Invisible host that renders the messenger modal when OnloSDK.present() /
 * openConversation() is called. Mount ONE of these near your app root if you
 * want programmatic presentation without the floating launcher.
 */
export function OnloMessengerHost({ strings }: { strings?: Partial<OnloStrings> }): React.JSX.Element {
  const state = useOnloState();

  useEffect(() => OnloSDK.__bindHost(), []);

  return (
    <Modal
      visible={state.visible}
      animationType="slide"
      presentationStyle="pageSheet"
      onRequestClose={() => OnloSDK.__onMessengerClosed()}
    >
      <SafeAreaView style={styles.modalRoot}>
        <Messenger strings={strings} />
      </SafeAreaView>
    </Modal>
  );
}

/**
 * Pre-built floating launcher (guide §7 Option B): a bottom-right chat button
 * with an unread badge that opens the messenger. Includes the host modal —
 * don't also mount <OnloMessengerHost /> when using this.
 */
export function OnloChatButton({ strings }: { strings?: Partial<OnloStrings> }): React.JSX.Element {
  const state = useOnloState();
  const theme = useOnloTheme(state.theme);

  return (
    <>
      <OnloMessengerHost strings={strings} />
      {!state.visible && (
        <View pointerEvents="box-none" style={styles.launcherWrap}>
          <Pressable
            onPress={() => OnloSDK.present()}
            style={[styles.launcher, { backgroundColor: theme.accent }]}
            accessibilityLabel="Open support chat"
          >
            <Text style={styles.launcherIcon}>💬</Text>
            {state.unreadCount > 0 && (
              <View style={styles.badge}>
                <Text style={styles.badgeText}>{state.unreadCount > 9 ? '9+' : state.unreadCount}</Text>
              </View>
            )}
          </Pressable>
        </View>
      )}
    </>
  );
}

const styles = StyleSheet.create({
  modalRoot: { flex: 1 },
  launcherWrap: {
    position: 'absolute',
    right: 18,
    bottom: 24,
  },
  launcher: {
    width: 54,
    height: 54,
    borderRadius: 27,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 4 },
    elevation: 6,
  },
  launcherIcon: { fontSize: 22 },
  badge: {
    position: 'absolute',
    top: -3,
    right: -3,
    minWidth: 19,
    height: 19,
    borderRadius: 10,
    backgroundColor: '#dc2626',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  badgeText: { color: '#fff', fontSize: 10, fontWeight: '700' },
});
