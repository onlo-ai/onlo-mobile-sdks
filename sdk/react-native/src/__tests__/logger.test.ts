import { describe, it, expect, vi, afterEach } from 'vitest';
import { log, setLogLevel } from '../logger';

afterEach(() => {
  setLogLevel('error'); // restore module default
  vi.restoreAllMocks();
});

describe('logger level gating', () => {
  it('suppresses everything at level none', () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    setLogLevel('none');
    log.error('boom');
    expect(err).not.toHaveBeenCalled();
  });

  it('at error level logs errors but not info', () => {
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    const info = vi.spyOn(console, 'log').mockImplementation(() => {});
    setLogLevel('error');
    log.error('e');
    log.info('i');
    expect(err).toHaveBeenCalledOnce();
    expect(info).not.toHaveBeenCalled();
  });

  it('at verbose level logs info', () => {
    const info = vi.spyOn(console, 'log').mockImplementation(() => {});
    setLogLevel('verbose');
    log.info('i');
    expect(info).toHaveBeenCalledOnce();
  });
});
