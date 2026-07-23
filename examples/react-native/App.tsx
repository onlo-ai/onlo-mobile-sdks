import React, {useEffect, useState} from 'react';
import {ActivityIndicator, Button, SafeAreaView, Text, View} from 'react-native';
import {Onlo, type OnloSessionState} from '@onlo/react-native';
import {onloConfig} from './onlo.config';

const readyStates: ReadonlySet<OnloSessionState> =
  new Set(['anonymousReady', 'identifiedReady']);

export default function App(): React.JSX.Element {
  const [state, setState] = useState<OnloSessionState>('uninitialized');
  const [hostSignedIn, setHostSignedIn] = useState(false);
  const [supportError, setSupportError] = useState<string>();

  useEffect(() => {
    const subscription = Onlo.observeState(setState);
    if (onloConfig.sdkKey) {
      void Onlo.initialize({sdkKey: onloConfig.sdkKey})
        .catch(() => setSupportError('Support is temporarily unavailable.'));
    }
    return () => subscription.remove();
  }, []);

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

  const supportReady = readyStates.has(state);
  const supportPreparing = Boolean(onloConfig.sdkKey) && !supportReady && !supportError;

  return <SafeAreaView><View style={{padding: 24, gap: 12}}>
    <Text>Host account: {hostSignedIn ? 'signed in' : 'signed out'}</Text>
    <Text>Native state: {state}</Text>
    {supportPreparing ? <ActivityIndicator accessibilityLabel="Preparing support" /> : null}
    {supportError ? <Text>{supportError}</Text> : null}
    <Button title="Complete host login" onPress={completeHostLogin} />
    <Button title="Support" onPress={() => Onlo.present()} disabled={!supportReady} />
  </View></SafeAreaView>;
}

async function fetchShortLivedOnloUserJwtFromOperatorBackend(): Promise<string> {
  throw new Error('Implement an authenticated call to the Operator backend. Do not sign or persist a JWT in JavaScript.');
}
