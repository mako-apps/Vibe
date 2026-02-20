import React, { useMemo, useState } from 'react';
import {
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  getNativeChatRuntimeInfo,
  mapMessagesToNativeRows,
  NativeChatSurface,
  type NativeChatAppearance,
} from '../src/native/chat';
import WallpaperBackground from '../src/components/chat/WallpaperBackground';
import ChatScreenHeader from '../src/components/chat/ChatScreenHeader';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';

type MockMessage = {
  id: string;
  text: string;
  timestamp: string;
  timestampMs: number;
  isMe: boolean;
  status?: string;
};

const withAlpha = (color: string, alpha: number) => {
  if (!color) return `rgba(255, 255, 255, ${alpha})`;
  if (color.startsWith('#') && color.length >= 7) {
    const r = parseInt(color.slice(1, 3), 16);
    const g = parseInt(color.slice(3, 5), 16);
    const b = parseInt(color.slice(5, 7), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }
  return color;
};

const resolveMeGradient = (theme: any): [string, string] => {
  if (Array.isArray(theme?.bubbleMeGradient) && theme.bubbleMeGradient.length >= 2) {
    return [theme.bubbleMeGradient[0], theme.bubbleMeGradient[1]];
  }
  if (typeof theme?.bubbleMe === 'string' && theme.bubbleMe) {
    return [theme.bubbleMe, theme.bubbleMe];
  }
  return ['#7C5CE0', '#6A4FCF'];
};

const resolveThemSolid = (theme: any): string => {
  if (Array.isArray(theme?.bubbleThemGradient) && theme.bubbleThemGradient.length > 0) {
    const first = theme.bubbleThemGradient[0];
    if (typeof first === 'string' && first.length > 0) return first;
  }
  if (typeof theme?.bubbleThem === 'string' && theme.bubbleThem) {
    return theme.bubbleThem;
  }
  return '#2a2a4a';
};

export default function NativeChatMockScreen() {
  const insets = useSafeAreaInsets();
  const { colors, effectiveTheme } = useThemeStore();
  const { activeTheme } = useWallpaperStore();
  const runtime = useMemo(() => getNativeChatRuntimeInfo(), []);

  const messages = useMemo<MockMessage[]>(() => [
    { id: '1', text: 'Native mock list', timestamp: '10:01', timestampMs: Date.now() - 240000, isMe: false, status: 'sent' },
    { id: '2', text: 'Crossfade should be native', timestamp: '10:02', timestampMs: Date.now() - 180000, isMe: true, status: 'sent' },
    { id: '3', text: 'No chatlist route here', timestamp: '10:03', timestampMs: Date.now() - 120000, isMe: false, status: 'sent' },
  ], []);

  const nativeRows = useMemo(() => mapMessagesToNativeRows(messages.map((m) => ({
    id: m.id,
    text: m.text,
    isMe: m.isMe,
    timestampMs: m.timestampMs,
    timestamp: m.timestamp,
    status: m.status,
    type: 'text',
  }))), [messages]);

  const resolvedTheme = useMemo(() => {
    const theme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
    if (!theme.backgroundGradient) {
      return {
        ...theme,
        backgroundGradient: [colors.background, colors.background],
      };
    }
    return theme;
  }, [activeTheme, colors.background, effectiveTheme]);
  const meGradient = useMemo<[string, string]>(() => resolveMeGradient(resolvedTheme), [resolvedTheme]);
  const themSolid = useMemo(() => resolveThemSolid(resolvedTheme), [resolvedTheme]);
  const [animMode, setAnimMode] = useState(2);
  const ANIMATION_MODES = ['None', 'SlideUp', 'Telegram', 'Spring'];

  const nativeAppearance = useMemo<NativeChatAppearance>(() => ({
    backgroundMode: 'transparent',
    wallpaperGradient: (resolvedTheme.backgroundGradient || [colors.background, colors.background]).slice(0, 3),
    wallpaperOpacity: 1,
    bubbleMeGradient: [...meGradient],
    bubbleThemColor: themSolid,
    textColorMe: resolvedTheme.textColorMe || '#FFFFFF',
    textColorThem: resolvedTheme.textColorThem || '#DDDDDD',
    timeColorMe: withAlpha(resolvedTheme.textColorMe || '#FFFFFF', 0.72),
    timeColorThem: withAlpha(resolvedTheme.textColorThem || '#FFFFFF', 0.5),
    dayTextColor: withAlpha(resolvedTheme.textColorThem || '#ECEFFF', 0.82),
    dayBackgroundColor: withAlpha(resolvedTheme.backgroundGradient?.[0] || colors.background, 0.42),
    dayBorderColor: withAlpha('#FFFFFF', 0.16),
    insertionAnimationMode: animMode,
  }), [resolvedTheme, colors.background, meGradient, themSolid, animMode]);

  return (
    <View style={styles.screen}>
      <WallpaperBackground theme={resolvedTheme} />
      <ChatScreenHeader
        title="Native Chat Mock"
        subtitle={runtime.enabled ? `Mode: ${ANIMATION_MODES[animMode]}` : 'fallback runtime'}
        isOnline={runtime.enabled}
        colors={colors}
        effectiveTheme={effectiveTheme as 'light' | 'dark'}
        wallpaperGradient={resolvedTheme.backgroundGradient || [colors.background, colors.background]}
        bubbleTheme={{ meGradient }}
        onPressAvatar={() => {
          setAnimMode((prev) => (prev + 1) % 4);
        }}
      />

      {/* Mode Toggles Overlay */}
      <View style={[styles.modeToggleContainer, { top: insets.top + 54 }]}>
        {ANIMATION_MODES.map((label, idx) => (
          <TouchableOpacity
            key={label}
            style={[styles.modeChip, animMode === idx && styles.modeChipActive]}
            onPress={() => setAnimMode(idx)}
          >
            <Text style={[styles.modeChipText, animMode === idx && styles.modeChipTextActive]}>
              {label}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* Native surface with native input bar — no JS input, no keyboard shifting */}
      <View style={styles.listContainer}>
        <NativeChatSurface
          surfaceId="native-chat-mock-surface"
          rows={nativeRows}
          appearance={nativeAppearance}
          inputBarEnabled
          nativeSendEnabled
          inputPlaceholder="Message"
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: '#000',
  },
  listContainer: {
    flex: 1,
  },
  modeToggleContainer: {
    position: 'absolute',
    left: 0,
    right: 0,
    flexDirection: 'row',
    justifyContent: 'center',
    paddingHorizontal: 16,
    paddingVertical: 8,
    gap: 8,
    backgroundColor: 'transparent',
    zIndex: 900,
  },
  modeChip: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 12,
    backgroundColor: 'rgba(255,255,255,0.1)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.1)',
  },
  modeChipActive: {
    backgroundColor: 'rgba(124, 92, 224, 0.4)',
    borderColor: '#7C5CE0',
  },
  modeChipText: {
    fontSize: 10,
    color: 'rgba(255,255,255,0.6)',
    fontWeight: '600',
  },
  modeChipTextActive: {
    color: '#fff',
  },
});
