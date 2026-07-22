import { describe, it, expect, vi, afterEach } from 'vitest';
import { OnloClient, OnloApiError } from '../client';

afterEach(() => vi.unstubAllGlobals());

function stubFetch(response: unknown, ok = true, status = 200) {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok,
      status,
      json: async () => response,
      text: async () => JSON.stringify(response),
    }),
  );
}

describe('OnloClient.handshake', () => {
  it('returns a session + config on success', async () => {
    stubFetch({ sessionId: 's1', chatToken: 't1', config: { accent: '#000' }, sdkFamily: 'react-native' });
    const client = new OnloClient('https://api.test', 'onlo_rn_sk_x');
    const result = await client.handshake({ visitorId: 'v1' });
    expect(result.session.sessionId).toBe('s1');
    expect(result.session.chatToken).toBe('t1');
    expect(result.sdkFamily).toBe('react-native');
    expect(result.config).toEqual({ accent: '#000' });
  });

  it('throws OnloApiError carrying the server error code on 401', async () => {
    stubFetch(
      { error: 'session_not_established', message: 'Session could not be established' },
      false,
      401,
    );
    const client = new OnloClient('https://api.test', 'bad_key');
    await expect(client.handshake({ visitorId: 'v1' })).rejects.toMatchObject({
      name: 'OnloApiError',
      code: 'session_not_established',
      status: 401,
    });
  });

  it('sends the identity payload when identify data is supplied', async () => {
    stubFetch({ sessionId: 's', chatToken: 't', config: null, platform: 'rn' });
    const client = new OnloClient('https://api.test', 'k');
    await client.handshake({
      visitorId: 'v1',
      identity: { userJwt: 'header.payload.signature' },
    });
    const body = JSON.parse((globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body);
    expect(body.identity).toEqual({ userJwt: 'header.payload.signature' });
    expect(body.sdkKey).toBe('k');
  });
});

describe('OnloClient.listConversations', () => {
  it('returns the conversations array from the response', async () => {
    stubFetch({
      conversations: [
        {
          id: 'c1',
          sessionId: 's1',
          title: 'Hi',
          unread: false,
          unreadCount: 0,
          status: 'active',
          updatedAt: '2026-01-01',
          messageCount: 2,
          lastMessageRole: 'assistant',
        },
      ],
    });
    const client = new OnloClient('https://api.test', 'k');
    const list = await client.listConversations({ sessionId: 's1', chatToken: 't1' });
    expect(list).toHaveLength(1);
    expect(list[0].id).toBe('c1');
  });

  it('throws OnloApiError on a failed list request', async () => {
    stubFetch({}, false, 500);
    const client = new OnloClient('https://api.test', 'k');
    await expect(client.listConversations({ sessionId: 's', chatToken: 't' })).rejects.toBeInstanceOf(
      OnloApiError,
    );
  });
});
