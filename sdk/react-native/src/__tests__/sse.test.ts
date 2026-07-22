import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { consumeSse } from '../sse';

/**
 * Fake XMLHttpRequest — the SSE parser's only external dependency. Lets a test
 * drive incremental `responseText` growth (readyState 3) and completion
 * (readyState 4) the way React Native's XHR would.
 */
class FakeXHR {
  static last: FakeXHR | null = null;
  onreadystatechange: (() => void) | null = null;
  onerror: (() => void) | null = null;
  readyState = 0;
  status = 200;
  responseText = '';
  aborted = false;
  constructor() {
    FakeXHR.last = this;
  }
  open() {
    this.readyState = 1;
  }
  setRequestHeader() {}
  send() {}
  abort() {
    this.aborted = true;
  }
  /** Test helper: set the accumulated responseText + readyState, fire the handler. */
  push(text: string, readyState = 3) {
    this.responseText = text;
    this.readyState = readyState;
    this.onreadystatechange?.();
  }
}

beforeEach(() => {
  FakeXHR.last = null;
  vi.stubGlobal('XMLHttpRequest', FakeXHR);
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('consumeSse', () => {
  it('parses two complete frames delivered in one chunk', () => {
    const data: unknown[] = [];
    consumeSse({ url: 'x', method: 'GET', headers: {}, onData: (p) => data.push(p) });
    FakeXHR.last!.push('data: {"type":"text","content":"a"}\n\ndata: {"type":"done"}\n\n');
    expect(data).toEqual([
      { type: 'text', content: 'a' },
      { type: 'done' },
    ]);
  });

  it('buffers a partial frame until its terminator arrives', () => {
    const data: unknown[] = [];
    consumeSse({ url: 'x', method: 'GET', headers: {}, onData: (p) => data.push(p) });
    FakeXHR.last!.push('data: {"a":1}'); // no blank-line terminator yet
    expect(data).toEqual([]);
    FakeXHR.last!.push('data: {"a":1}\n\n'); // accumulated text now completes the frame
    expect(data).toEqual([{ a: 1 }]);
  });

  it('ignores a non-JSON data frame without throwing', () => {
    const data: unknown[] = [];
    consumeSse({ url: 'x', method: 'GET', headers: {}, onData: (p) => data.push(p) });
    FakeXHR.last!.push('data: not-json\n\n');
    expect(data).toEqual([]);
  });

  it('calls onError on HTTP >= 400 and never onData', () => {
    const data: unknown[] = [];
    let err: Error | null = null;
    consumeSse({
      url: 'x',
      method: 'GET',
      headers: {},
      onData: (p) => data.push(p),
      onError: (e) => {
        err = e;
      },
    });
    FakeXHR.last!.status = 401;
    FakeXHR.last!.push('data: {"a":1}\n\n');
    expect(err).toBeInstanceOf(Error);
    expect(data).toEqual([]);
  });

  it('calls onDone at readyState 4', () => {
    let done = false;
    consumeSse({
      url: 'x',
      method: 'GET',
      headers: {},
      onData: () => {},
      onDone: () => {
        done = true;
      },
    });
    FakeXHR.last!.push('', 4);
    expect(done).toBe(true);
  });

  it('close() aborts the underlying request', () => {
    const handle = consumeSse({ url: 'x', method: 'GET', headers: {}, onData: () => {} });
    handle.close();
    expect(FakeXHR.last!.aborted).toBe(true);
  });
});
