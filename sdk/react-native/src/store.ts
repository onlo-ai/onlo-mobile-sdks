/**
 * Tiny observable store — the single state container shared by the OnloSDK
 * singleton and the messenger UI. No external state library: subscribers get
 * the whole state on every change and select what they need.
 */
import type { OnloConversationSummary, OnloMessage, OnloTheme } from './types';

export interface OnloState {
  ready: boolean;
  visible: boolean;
  screen: 'list' | 'thread';
  theme: Partial<OnloTheme> | null;
  conversations: OnloConversationSummary[];
  messages: OnloMessage[];
  streamingText: string | null;
  sending: boolean;
  unreadCount: number;
  offlineQueued: number;
  errorNotice: string | null;
}

const initialState: OnloState = {
  ready: false,
  visible: false,
  screen: 'thread',
  theme: null,
  conversations: [],
  messages: [],
  streamingText: null,
  sending: false,
  unreadCount: 0,
  offlineQueued: 0,
  errorNotice: null,
};

type Listener = (state: OnloState) => void;

class Store {
  private state: OnloState = { ...initialState };
  private listeners = new Set<Listener>();

  get(): OnloState {
    return this.state;
  }

  set(patch: Partial<OnloState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener(this.state);
  }

  reset(): void {
    this.set({ ...initialState });
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }
}

export const store = new Store();
