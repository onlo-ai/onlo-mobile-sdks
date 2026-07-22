import type { OnloLogLevel } from './types';

const ORDER: Record<OnloLogLevel, number> = { none: 0, error: 1, warning: 2, verbose: 3 };

let level: OnloLogLevel = 'error';

export function setLogLevel(next: OnloLogLevel): void {
  level = next;
}

function enabled(min: OnloLogLevel): boolean {
  return ORDER[level] >= ORDER[min];
}

export const log = {
  error(...args: unknown[]): void {
    if (enabled('error')) console.error('[Onlo]', ...args);
  },
  warn(...args: unknown[]): void {
    if (enabled('warning')) console.warn('[Onlo]', ...args);
  },
  info(...args: unknown[]): void {
    if (enabled('verbose')) console.log('[Onlo]', ...args);
  },
};
