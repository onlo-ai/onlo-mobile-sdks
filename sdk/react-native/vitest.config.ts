import { defineConfig } from 'vitest/config';

// Unit tests run in a plain Node env — the SDK's core logic (SSE parser, store,
// client, logger, storage) has no DB / env-var / React-Native dependency; the
// only external boundaries (fetch, XMLHttpRequest) are stubbed per-test.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
});
