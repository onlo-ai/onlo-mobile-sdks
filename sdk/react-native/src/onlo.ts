import { OnloClient, OnloApiError, type HandshakeResult } from './client';
import { log, setLogLevel as setLoggerLevel } from './logger';
import { resolveStorage } from './storage';
import { store } from './store';
import type { SseHandle } from './sse';
import type {
  OnloChatEvent,
  OnloIdentifyOptions,
  OnloInitOptions,
  OnloLogLevel,
  OnloMessage,
  OnloSession,
} from './types';

const DEFAULT_BASE_URL = 'https://app.onlo.ai';
const OUTBOX_LIMIT = 20;

interface Persisted {
  session?: OnloSession;
  visitorId?: string;
  outbox?: string[];
}

function uuid(): string {
  // crypto.getRandomValues exists on modern Hermes; Math.random fallback is
  // acceptable for a visitor id (not a security credential).
  const cryptoObj = (globalThis as { crypto?: { getRandomValues?(a: Uint8Array): Uint8Array } }).crypto;
  const bytes = new Uint8Array(16);
  if (cryptoObj?.getRandomValues) cryptoObj.getRandomValues(bytes);
  else for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

class OnloSdkImpl {
  private options: OnloInitOptions | null = null;
  private client: OnloClient | null = null;
  private session: OnloSession | null = null;
  private visitorId: string | null = null;
  // User JWTs are short-lived bearer proofs. Keep only in memory for the
  // identify exchange; never persist them with resumable SDK state.
  private identity: OnloIdentifyOptions | null = null;
  private outbox: string[] = [];
  private stream: SseHandle | null = null;
  private activeSend: SseHandle | null = null;
  private unreadListeners = new Set<(count: number) => void>();
  private lastUnread = 0;
  private hostMounted = false;
  private initPromise: Promise<void> | null = null;

  // ── Lifecycle ─────────────────────────────────────────────

  initialize(options: OnloInitOptions): void {
    if (!options?.apiKey) {
      log.error('initialize() requires an apiKey');
      return;
    }
    this.options = { baseUrl: DEFAULT_BASE_URL, ...options };
    if (options.logLevel) setLoggerLevel(options.logLevel);
    this.client = new OnloClient(this.options.baseUrl as string, options.apiKey, options.bundleId);
    log.info('Initialized');
    this.initPromise = this.restoreAndHandshake().catch((err) => {
      log.error('Startup handshake failed:', err instanceof Error ? err.message : err);
    });
  }

  /** Pre-warm the session + theme so the first present() is instant. */
  async preload(): Promise<void> {
    await this.ensureReady();
  }

  setLogLevel(level: OnloLogLevel): void {
    setLoggerLevel(level);
  }

  // ── Identity (guide §9) ───────────────────────────────────

  async identify(identity: OnloIdentifyOptions): Promise<void> {
    if (!this.requireInit()) return;
    if (!identity?.userJwt || identity.userJwt.split('.').length !== 3) {
      log.error('identify() requires a userJwt minted by your backend');
      return;
    }
    this.identity = identity;
    try {
      await this.handshake();
    } finally {
      this.identity = null;
    }
  }

  async logout(): Promise<void> {
    if (!this.requireInit()) return;
    this.closeStream();
    this.activeSend?.close();
    await this.clearLocalSession();
    this.identity = null;
    this.outbox = [];
    await this.persist();
    store.reset();
    this.emitUnread(0);
    log.info('Logged out — next user gets a fresh session');
  }

  // ── UI surface ────────────────────────────────────────────

  present(): void {
    if (!this.requireInit()) return;
    if (!this.hostMounted) {
      log.warn('present() called but no messenger host is mounted — render <OnloChatButton /> (or <OnloMessengerHost />) in your app root.');
    }
    store.set({ visible: true });
    void this.onMessengerOpened();
  }

  hide(): void {
    store.set({ visible: false });
    this.closeStream();
  }

  openConversation(conversationId: string): void {
    if (!this.requireInit()) return;
    store.set({ visible: true });
    void this.activateConversation(conversationId);
  }

  onUnreadCountChange(listener: (count: number) => void): () => void {
    this.unreadListeners.add(listener);
    listener(this.lastUnread);
    return () => this.unreadListeners.delete(listener);
  }

  // ── Internal: host binding (used by the UI components) ────

  __bindHost(): () => void {
    this.hostMounted = true;
    return () => {
      this.hostMounted = false;
    };
  }

  __sendMessage(text: string): void {
    void this.sendMessage(text);
  }

  __selectConversation(conversationId: string): void {
    void this.activateConversation(conversationId);
  }

  __newConversation(): void {
    void (async () => {
      await this.clearLocalSession();
      await this.persist();
      store.set({ messages: [], streamingText: null, screen: 'thread' });
      await this.handshake();
    })();
  }

  __showList(): void {
    store.set({ screen: 'list' });
    void this.refreshConversations();
  }

  __onMessengerClosed(): void {
    this.hide();
  }

  // ── Session plumbing ──────────────────────────────────────

  private requireInit(): boolean {
    if (!this.options || !this.client) {
      log.error('Call OnloSDK.initialize({ apiKey }) before using the SDK');
      return false;
    }
    return true;
  }

  private storageKey(suffix: string): string {
    const prefix = (this.options?.apiKey || 'anon').slice(0, 24);
    return `@onlo/${prefix}/${suffix}`;
  }

  private async restoreAndHandshake(): Promise<void> {
    const storage = resolveStorage();
    try {
      const raw = await storage.getItem(this.storageKey('state'));
      if (raw) {
        const persisted = JSON.parse(raw) as Persisted;
        this.session = persisted.session ?? null;
        this.visitorId = persisted.visitorId ?? null;
        this.outbox = persisted.outbox ?? [];
      }
    } catch {
      log.warn('Persisted state unreadable — starting fresh');
    }
    if (!this.visitorId) this.visitorId = uuid();
    await this.handshake();
  }

  private async persist(): Promise<void> {
    const storage = resolveStorage();
    const persisted: Persisted = {
      session: this.session ?? undefined,
      visitorId: this.visitorId ?? undefined,
      outbox: this.outbox,
    };
    try {
      await storage.setItem(this.storageKey('state'), JSON.stringify(persisted));
    } catch {
      log.warn('Failed to persist session state');
    }
  }

  private async clearLocalSession(): Promise<void> {
    this.session = null;
    this.visitorId = uuid();
  }

  private async handshake(): Promise<HandshakeResult | null> {
    if (!this.client || !this.visitorId) return null;
    try {
      const result = await this.client.handshake({
        visitorId: this.visitorId,
        sessionId: this.session?.sessionId,
        identity: this.identity ?? undefined,
      });
      this.session = result.session;
      if (result.identityWarning) log.warn(result.identityWarning);
      store.set({ ready: true, theme: result.config });
      await this.persist();
      void this.flushOutbox();
      void this.refreshUnread();
      return result;
    } catch (err) {
      if (err instanceof OnloApiError) log.error(`Handshake failed: ${err.code} — ${err.message}`);
      else log.error('Handshake failed:', err instanceof Error ? err.message : err);
      throw err;
    }
  }

  private async ensureReady(): Promise<OnloSession | null> {
    if (this.initPromise) await this.initPromise.catch(() => undefined);
    if (!this.session) await this.handshake().catch(() => undefined);
    return this.session;
  }

  // ── Messaging ─────────────────────────────────────────────

  private async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;
    const session = await this.ensureReady();
    const optimistic: OnloMessage = {
      id: `local_${uuid()}`,
      role: 'user',
      content: trimmed,
      createdAt: new Date().toISOString(),
    };
    store.set({ messages: [...store.get().messages, optimistic], errorNotice: null });

    if (!session || !this.client) {
      this.queueOffline(trimmed);
      return;
    }

    store.set({ sending: true, streamingText: null });
    let streamed = '';
    this.activeSend = this.client.sendMessage(session, trimmed, {
      onEvent: (event: OnloChatEvent) => {
        if (event.type === 'text') {
          streamed += event.content;
          store.set({ streamingText: streamed });
        } else if (event.type === 'done') {
          const finalText = streamed;
          const next = [...store.get().messages];
          if (finalText) {
            next.push({ id: `srv_${uuid()}`, role: 'assistant', content: finalText, createdAt: new Date().toISOString() });
          }
          store.set({ messages: next, streamingText: null, sending: false });
          void this.refreshUnread();
        } else if (event.type === 'error') {
          store.set({ sending: false, streamingText: null, errorNotice: event.error });
        }
      },
      onDone: () => {
        if (store.get().sending) store.set({ sending: false, streamingText: null });
      },
      onError: () => {
        // Network drop — queue for retry, keep the optimistic bubble.
        this.queueOffline(trimmed, { silent: true });
        store.set({ sending: false, streamingText: null });
      },
    });
  }

  private queueOffline(text: string, opts?: { silent?: boolean }): void {
    if (this.outbox.length >= OUTBOX_LIMIT) this.outbox.shift();
    this.outbox.push(text);
    void this.persist();
    store.set({ offlineQueued: this.outbox.length });
    if (!opts?.silent) log.warn('Message queued — will send when back online');
  }

  private async flushOutbox(): Promise<void> {
    if (!this.outbox.length || !this.session || !this.client) return;
    const pending = [...this.outbox];
    this.outbox = [];
    store.set({ offlineQueued: 0 });
    await this.persist();
    for (const text of pending) {
      await new Promise<void>((resolveFlush) => {
        this.client!.sendMessage(this.session!, text, {
          onEvent: () => undefined,
          onDone: () => resolveFlush(),
          onError: () => {
            this.queueOffline(text, { silent: true });
            resolveFlush();
          },
        });
      });
    }
    void this.refreshUnread();
  }

  // ── Conversations / unread / realtime ─────────────────────

  private async onMessengerOpened(): Promise<void> {
    const session = await this.ensureReady();
    if (!session) return;
    await this.loadActiveThread();
    this.openRealtimeStream();
    void this.flushOutbox();
  }

  private async loadActiveThread(): Promise<void> {
    if (!this.client || !this.session) return;
    try {
      const conversations = await this.client.listConversations(this.session);
      store.set({ conversations });
      const active = conversations.find((c) => c.sessionId === this.session?.sessionId);
      if (active) {
        const messages = await this.client.getConversationMessages(this.session, active.id);
        store.set({ messages });
      }
      this.computeUnread();
    } catch (err) {
      log.warn('Thread load failed:', err instanceof Error ? err.message : err);
    }
  }

  private async activateConversation(conversationId: string): Promise<void> {
    if (!this.client || !this.session) return;
    try {
      const conversations = store.get().conversations.length
        ? store.get().conversations
        : await this.client.listConversations(this.session);
      const target = conversations.find((c) => c.id === conversationId);
      if (!target) {
        log.warn(`openConversation: ${conversationId} not found for this visitor`);
        return;
      }
      // Continuing an old conversation = re-handshake with its sessionId (the
      // server validates ownership and reuses it), then load its messages.
      this.session = { ...this.session, sessionId: target.sessionId };
      await this.handshake();
      const messages = await this.client.getConversationMessages(this.session, conversationId);
      store.set({ messages, screen: 'thread' });
    } catch (err) {
      log.warn('openConversation failed:', err instanceof Error ? err.message : err);
    }
  }

  private async refreshConversations(): Promise<void> {
    if (!this.client || !this.session) return;
    try {
      const conversations = await this.client.listConversations(this.session);
      store.set({ conversations });
      this.computeUnread();
    } catch {
      // list refresh is best-effort
    }
  }

  private async refreshUnread(): Promise<void> {
    await this.refreshConversations();
  }

  private computeUnread(): void {
    const total = store.get().conversations.reduce((sum, conv) => sum + (conv.unreadCount || 0), 0);
    store.set({ unreadCount: total });
    this.emitUnread(total);
  }

  private emitUnread(count: number): void {
    if (count === this.lastUnread) return;
    this.lastUnread = count;
    for (const listener of this.unreadListeners) listener(count);
  }

  private openRealtimeStream(): void {
    if (!this.client || !this.session || this.stream) return;
    this.stream = this.client.openStream(this.session, {
      onEvent: (event) => {
        if (event.type === 'inbox.message' || event.type === 'inbox.conversation') {
          void this.loadActiveThread();
        }
      },
      onError: () => {
        this.closeStream();
      },
    });
  }

  private closeStream(): void {
    this.stream?.close();
    this.stream = null;
  }
}

export const OnloSDK = new OnloSdkImpl();
