import { useColorScheme } from 'react-native';
import type { OnloTheme } from '../types';

export interface ResolvedTheme {
  accent: string;
  background: string;
  headerText: string;
  incomingBubble: string;
  incomingText: string;
  outgoingBubble: string;
  outgoingText: string;
  mutedText: string;
  botName: string;
  botSubtitle: string;
  greeting: string;
  showTimestamps: boolean;
  logoInitials: string;
}

const LIGHT_DEFAULTS = {
  background: '#ffffff',
  incomingBubble: '#f4f4f5',
  incomingText: '#0a0a0a',
  outgoingBubble: '#1B1917',
  outgoingText: '#ffffff',
  mutedText: '#8a8a8a',
};

const DARK_DEFAULTS = {
  background: '#1e1e26',
  incomingBubble: '#2c2c35',
  incomingText: '#f1f1f4',
  outgoingBubble: '#4c4cf0',
  outgoingText: '#ffffff',
  mutedText: '#9a9aa5',
};

/** Merge the dashboard-driven widget theme (guide §11) with sane defaults. */
export function useOnloTheme(config: Partial<OnloTheme> | null): ResolvedTheme {
  const scheme = useColorScheme();
  const dark = !!config?.darkMode && scheme === 'dark';
  const base = dark ? DARK_DEFAULTS : LIGHT_DEFAULTS;
  return {
    accent: config?.accent || '#1B1917',
    background: (dark ? config?.darkBackground : config?.chatBackground) || base.background,
    headerText: '#ffffff',
    incomingBubble: (dark ? config?.darkIncomingColor : config?.incomingColor) || base.incomingBubble,
    incomingText: (dark ? config?.darkIncomingTextColor : config?.incomingTextColor) || base.incomingText,
    outgoingBubble: (dark ? config?.darkOutgoingColor : config?.outgoingColor) || base.outgoingBubble,
    outgoingText: (dark ? config?.darkOutgoingTextColor : config?.outgoingTextColor) || base.outgoingText,
    mutedText: base.mutedText,
    botName: config?.botName || 'Support',
    botSubtitle: config?.botSubtitle || '',
    greeting: config?.greeting || 'Hi there 👋\nHow can I help you today?',
    showTimestamps: config?.showTimestamps !== false,
    logoInitials: (config?.headerLogoText || config?.botName || 'ON').slice(0, 2).toUpperCase(),
  };
}
