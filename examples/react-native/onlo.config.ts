/**
 * Public app configuration only. A production host may generate this value in CI because the SDK
 * key is safe to embed. Never add a user JWT or Operator signing secret to this file.
 */
export const onloConfig = {
  sdkKey: '',
  operatorBackendUrl: '',
} as const;
