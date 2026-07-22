import { log } from './logger';

/**
 * Minimal SSE consumption over XMLHttpRequest.
 *
 * React Native's fetch has no streaming body support, but XHR fires
 * readystatechange with incremental `responseText` (readyState 3), which is
 * enough to parse `data: {json}\n\n` frames as the server flushes them —
 * both the chat POST response and the realtime GET stream use that framing.
 */
export interface SseHandle {
  close(): void;
}

export function consumeSse(options: {
  url: string;
  method: 'GET' | 'POST';
  headers: Record<string, string>;
  body?: string;
  onData(payload: unknown): void;
  onDone?(): void;
  onError?(error: Error): void;
}): SseHandle {
  const xhr = new XMLHttpRequest();
  let cursor = 0;
  let closed = false;

  const pump = () => {
    const text = xhr.responseText || '';
    // Frames are separated by a blank line; hold the (possibly partial) tail.
    let boundary = text.indexOf('\n\n', cursor);
    while (boundary !== -1) {
      const frame = text.slice(cursor, boundary);
      cursor = boundary + 2;
      for (const line of frame.split('\n')) {
        if (!line.startsWith('data:')) continue;
        const raw = line.slice(5).trim();
        if (!raw) continue;
        try {
          options.onData(JSON.parse(raw));
        } catch {
          log.warn('SSE frame was not JSON, ignored');
        }
      }
      boundary = text.indexOf('\n\n', cursor);
    }
  };

  xhr.onreadystatechange = () => {
    if (closed) return;
    if (xhr.readyState === 3 || xhr.readyState === 4) {
      if (xhr.status >= 400) {
        closed = true;
        options.onError?.(new Error(`SSE HTTP ${xhr.status}`));
        return;
      }
      pump();
    }
    if (xhr.readyState === 4) {
      closed = true;
      options.onDone?.();
    }
  };
  xhr.onerror = () => {
    if (closed) return;
    closed = true;
    options.onError?.(new Error('Network error'));
  };

  xhr.open(options.method, options.url);
  for (const [k, v] of Object.entries(options.headers)) xhr.setRequestHeader(k, v);
  xhr.send(options.body);

  return {
    close() {
      if (closed) return;
      closed = true;
      try {
        xhr.abort();
      } catch {
        // already settled
      }
    },
  };
}
