import { describe, it, expect, afterEach } from 'vitest';
import { store } from '../store';

// The store is a shared singleton — reset after every test so order can't leak.
afterEach(() => store.reset());

describe('store', () => {
  it('delivers the current state to a new subscriber immediately', () => {
    let seen: { ready: boolean } | null = null;
    const unsub = store.subscribe((s) => {
      seen = s;
    });
    expect(seen).not.toBeNull();
    expect(seen!.ready).toBe(false);
    unsub();
  });

  it('merges a patch and notifies subscribers', () => {
    const readyValues: boolean[] = [];
    const unsub = store.subscribe((s) => readyValues.push(s.ready));
    store.set({ ready: true });
    expect(store.get().ready).toBe(true);
    expect(readyValues.at(-1)).toBe(true);
    unsub();
  });

  it('stops notifying after unsubscribe', () => {
    let count = 0;
    const unsub = store.subscribe(() => count++);
    const afterInitial = count; // subscribe fires once immediately
    unsub();
    store.set({ sending: true });
    expect(count).toBe(afterInitial);
  });

  it('reset restores the initial state', () => {
    store.set({ unreadCount: 5, visible: true });
    store.reset();
    expect(store.get().unreadCount).toBe(0);
    expect(store.get().visible).toBe(false);
  });
});
