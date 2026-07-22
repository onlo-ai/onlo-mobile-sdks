import { consumeSse, type SseHandle } from './sse';
import { log } from './logger';
import type {
  OnloChatEvent,
  OnloConversationSummary,
  OnloIdentifyOptions,
  OnloMessage,
  OnloSession,
  OnloTheme,
} from './types';

export interface HandshakeResult {
  session: OnloSession;
  config: Partial<OnloTheme> | null;
  sdkFamily: string;
  identityWarning?: string;
}

export class OnloApiError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly status: number,
  ) {
    super(message);
    this.name = 'OnloApiError';
  }
}

/** Thin HTTP client over the Onlo widget-family endpoints. */
export class OnloClient {
  constructor(
    private readonly baseUrl: string,
    private readonly apiKey: string,
    private readonly bundleId?: string,
  ) {}

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, '')}${path}`;
  }

  async handshake(params: {
    visitorId: string;
    sessionId?: string;
    identity?: OnloIdentifyOptions;
  }): Promise<HandshakeResult> {
    const res = await fetch(this.url('/api/sdk/handshake'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sdkKey: this.apiKey,
        bundleId: this.bundleId,
        visitorId: params.visitorId,
        sessionId: params.sessionId,
        identity: params.identity
          ? { userJwt: params.identity.userJwt }
          : undefined,
      }),
    });
    const data = (await res.json().catch(() => ({}))) as Record<string, unknown>;
    if (!res.ok) {
      throw new OnloApiError(
        String(data.error || 'session_not_established'),
        String(data.message || 'Session could not be established'),
        res.status,
      );
    }
    log.info('Session established', data.sessionId);
    return {
      session: { sessionId: String(data.sessionId), chatToken: String(data.chatToken) },
      config: (data.config as Partial<OnloTheme> | null) ?? null,
      sdkFamily: String(data.sdkFamily || 'react-native'),
      identityWarning: typeof data.identityWarning === 'string' ? data.identityWarning : undefined,
    };
  }

  /** POST a visitor message; events stream back over SSE. Returns a handle to abort. */
  sendMessage(
    session: OnloSession,
    text: string,
    handlers: { onEvent(event: OnloChatEvent): void; onDone?(): void; onError?(error: Error): void },
  ): SseHandle {
    return consumeSse({
      url: this.url('/api/widget/chat'),
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.chatToken}`,
      },
      body: JSON.stringify({ sessionId: session.sessionId, message: text }),
      onData: (payload) => handlers.onEvent(payload as OnloChatEvent),
      onDone: handlers.onDone,
      onError: handlers.onError,
    });
  }

  /** Realtime events (agent/human replies while the thread is open). */
  openStream(
    session: OnloSession,
    handlers: { onEvent(event: { type: string; conversationId?: string }): void; onError?(error: Error): void },
  ): SseHandle {
    return consumeSse({
      url: this.url('/api/widget/stream'),
      method: 'GET',
      headers: { Authorization: `Bearer ${session.chatToken}` },
      onData: (payload) => handlers.onEvent(payload as { type: string; conversationId?: string }),
      onError: handlers.onError,
    });
  }

  async listConversations(session: OnloSession): Promise<OnloConversationSummary[]> {
    const res = await fetch(this.url('/api/widget/conversations'), {
      headers: { Authorization: `Bearer ${session.chatToken}` },
    });
    if (!res.ok) throw new OnloApiError('list_failed', `Failed to load conversations (${res.status})`, res.status);
    const data = (await res.json()) as { conversations?: OnloConversationSummary[] };
    return data.conversations ?? [];
  }

  async getConversationMessages(session: OnloSession, conversationId: string): Promise<OnloMessage[]> {
    const res = await fetch(this.url(`/api/widget/conversations/${conversationId}`), {
      headers: { Authorization: `Bearer ${session.chatToken}` },
    });
    if (!res.ok) throw new OnloApiError('detail_failed', `Failed to load conversation (${res.status})`, res.status);
    const data = (await res.json()) as { messages?: Array<Record<string, unknown>> };
    return (data.messages ?? []).map((m) => ({
      id: String(m.id),
      role: String(m.role ?? 'assistant'),
      content: String(m.content ?? ''),
      createdAt: String(m.createdAt ?? ''),
    }));
  }
}
