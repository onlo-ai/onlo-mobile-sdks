import React, {useEffect, useState} from 'react';
import {ActivityIndicator, AppState, Button, SafeAreaView, Text, View} from 'react-native';
import {
  Onlo,
  type OnloPushNotificationPayload,
  type OnloSessionState,
} from '@onlo/react-native';
import {onloConfig} from './onlo.config';

const readyStates: ReadonlySet<OnloSessionState> =
  new Set(['anonymousReady', 'identifiedReady']);

export default function App(): React.JSX.Element {
  const [state, setState] = useState<OnloSessionState>('uninitialized');
  const [hostSignedIn, setHostSignedIn] = useState(false);
  const [supportError, setSupportError] = useState<string>();

  useEffect(() => {
    const subscription = Onlo.observeState(setState);
    // Native owns foreground/background recovery. This subscription proves the
    // host forwards lifecycle by keeping the native bridge installed.
    const lifecycle = AppState.addEventListener('change', () => undefined);
    if (onloConfig.sdkKey) {
      void Onlo.initialize({sdkKey: onloConfig.sdkKey})
        .catch(() => setSupportError('Support is temporarily unavailable.'));
    }
    return () => {
      lifecycle.remove();
      subscription.remove();
    };
  }, []);

  const continueAnonymously = () => {
    void Onlo.loginUnidentifiedUser().catch(() => {
      setSupportError('Anonymous support is temporarily unavailable.');
    });
  };

  const completeHostLogin = () => {
    // The host login succeeds independently. Preparing identified support continues in background.
    setHostSignedIn(true);
    void identifyForSupport().catch(() => {
      setSupportError('Signed in. Support identity will retry when available.');
    });
  };

  const identifyForSupport = async () => {
    const userJwt = await fetchShortLivedOnloUserJwtFromOperatorBackend();
    await Onlo.loginIdentifiedUser({userJwt});
  };

  const logoutOrSwitchAccount = async () => {
    await Onlo.logout();
    setHostSignedIn(false);
    setSupportError(undefined);
  };

  const supportReady = readyStates.has(state);
  const supportPreparing = Boolean(onloConfig.sdkKey) && !supportReady && !supportError;

  return <SafeAreaView><View style={{padding: 24, gap: 12}}>
    <Text>Host account: {hostSignedIn ? 'signed in' : 'signed out'}</Text>
    <Text>Native state: {state}</Text>
    {supportPreparing ? <ActivityIndicator accessibilityLabel="Preparing support" /> : null}
    {supportError ? <Text>{supportError}</Text> : null}
    <Button title="Continue anonymously" onPress={continueAnonymously} />
    <Button title="Complete host login" onPress={completeHostLogin} />
    <Button
      title="Support (attachments use native picker/camera)"
      onPress={() => Onlo.present()}
      disabled={!supportReady}
    />
    <Button title="Log out / switch account" onPress={logoutOrSwitchAccount} />
  </View></SafeAreaView>;
}

async function fetchShortLivedOnloUserJwtFromOperatorBackend(): Promise<string> {
  if (!onloConfig.operatorBackendUrl) {
    throw new Error('Configure an authenticated Operator-backend URL.');
  }
  const response = await fetch(`${onloConfig.operatorBackendUrl}/v1/onlo-user-jwt`, {
    method: 'POST',
    credentials: 'include',
    headers: {'Content-Type': 'application/json'},
    body: '{}',
  });
  if (!response.ok) throw new Error('Operator backend rejected the host session.');
  const value = await response.json() as {userJwt?: unknown};
  if (typeof value.userJwt !== 'string') throw new Error('Operator backend returned an invalid response.');
  return value.userJwt;
}

/** Call from the host's APNs/FCM integration; JS never stores the token. */
export async function forwardPushTokenToOnlo(provider: 'apns' | 'fcm', token: string) {
  await Onlo.setPushToken({provider, token});
}

/** Call from the host notification callback; native re-authorises before navigation. */
export async function forwardOnloNotification(payload: OnloPushNotificationPayload) {
  return Onlo.handlePushNotification(payload);
}

/** Call from the host deep-link router; native authorises the conversation. */
export async function forwardOnloDeepLink(url: string) {
  const match = new URL(url).pathname.match(/^\/support\/conversations\/([^/]+)$/);
  if (!match) return false;
  await Onlo.openConversation(decodeURIComponent(match[1]));
  return true;
}
