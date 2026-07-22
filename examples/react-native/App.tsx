import React, {useState} from 'react';
import {Button, SafeAreaView, Text, View} from 'react-native';
import {Onlo, type OnloSessionState} from '@onlo/react-native';

// Local host foundation: load a public SDK key from private build configuration.
// Never put an Operator signing secret or a user JWT in this bundle.
const publicSdkKey: string | undefined = undefined;

export default function App(): React.JSX.Element {
  const [state, setState] = useState<OnloSessionState>('uninitialized');

  const initialize = async () => {
    if (!publicSdkKey) return;
    await Onlo.initialize({sdkKey: publicSdkKey});
    Onlo.observeState(setState);
  };

  const identifyAfterHostLogin = async () => {
    const userJwt = await fetchShortLivedOnloUserJwtFromOperatorBackend();
    await Onlo.loginIdentifiedUser({userJwt});
  };

  return <SafeAreaView><View style={{padding: 24, gap: 12}}>
    <Text>Native state: {state}</Text>
    <Button title="Initialize local host" onPress={initialize} />
    <Button title="Sign in through host backend" onPress={identifyAfterHostLogin} disabled={!publicSdkKey} />
    <Button title="Support" onPress={() => Onlo.present()} disabled={!publicSdkKey} />
  </View></SafeAreaView>;
}

async function fetchShortLivedOnloUserJwtFromOperatorBackend(): Promise<string> {
  throw new Error('Implement an authenticated call to the Operator backend. Do not sign or persist a JWT in JavaScript.');
}
