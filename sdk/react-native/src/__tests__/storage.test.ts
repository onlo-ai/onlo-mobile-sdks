import { describe, it, expect } from 'vitest';
import { resolveStorage, setStorageAdapter } from '../storage';

describe('storage', () => {
  it('falls back to in-memory storage when AsyncStorage is absent', async () => {
    // @react-native-async-storage/async-storage is not installed in the test
    // env, so resolveStorage() must degrade to the memory adapter, not throw.
    const s = resolveStorage();
    await s.setItem('k', 'v');
    expect(await s.getItem('k')).toBe('v');
    await s.removeItem('k');
    expect(await s.getItem('k')).toBeNull();
  });

  it('honors a custom adapter set via setStorageAdapter', async () => {
    const calls: string[] = [];
    setStorageAdapter({
      getItem: async () => {
        calls.push('get');
        return 'x';
      },
      setItem: async () => {
        calls.push('set');
      },
      removeItem: async () => {
        calls.push('remove');
      },
    });
    const s = resolveStorage();
    await s.setItem('a', 'b');
    await s.getItem('a');
    expect(calls).toEqual(['set', 'get']);
  });
});
