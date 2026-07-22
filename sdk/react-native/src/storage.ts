import { log } from './logger';

/**
 * Pluggable persistence. v1 uses @react-native-async-storage/async-storage
 * when the host app has it installed (optional peer dependency), otherwise an
 * in-memory fallback (session/visitor state then lasts one app run — warned).
 *
 * Deviation from the integration guide §14 (Keychain / EncryptedSharedPreferences),
 * recorded in the README: hardware-backed storage requires a native module and
 * lands with the native SDKs. The session token is a short-lived (7d), org- and
 * visitor-scoped credential.
 */
export interface OnloStorageAdapter {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

class MemoryStorage implements OnloStorageAdapter {
  private map = new Map<string, string>();
  async getItem(key: string): Promise<string | null> {
    return this.map.has(key) ? (this.map.get(key) as string) : null;
  }
  async setItem(key: string, value: string): Promise<void> {
    this.map.set(key, value);
  }
  async removeItem(key: string): Promise<void> {
    this.map.delete(key);
  }
}

let adapter: OnloStorageAdapter | null = null;

export function resolveStorage(): OnloStorageAdapter {
  if (adapter) return adapter;
  try {
    // Optional peer — resolved at runtime so the SDK works without it.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require('@react-native-async-storage/async-storage');
    const asyncStorage = (mod?.default ?? mod) as OnloStorageAdapter | undefined;
    if (asyncStorage && typeof asyncStorage.getItem === 'function') {
      adapter = asyncStorage;
      return adapter;
    }
  } catch {
    // not installed — fall through to memory
  }
  log.warn(
    'AsyncStorage not found — sessions will not persist across app restarts. ' +
      'Install @react-native-async-storage/async-storage for persistence.',
  );
  adapter = new MemoryStorage();
  return adapter;
}

/** Test/advanced hook: replace the storage backend before initialize(). */
export function setStorageAdapter(custom: OnloStorageAdapter): void {
  adapter = custom;
}
