import React, { useState } from 'react';
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { BlurView } from 'expo-blur';

import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import { useThemeStore } from '../src/lib/stores/theme-store';

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

type SampleProps = {
  title: string;
  mode: 'safe' | 'blur' | 'plain';
  effect?: 'clear' | 'regular';
  small?: boolean;
  themeDark: boolean;
  onPress: () => void;
};

function SampleButton({ title, mode, effect, small, themeDark, onPress }: SampleProps) {
  const baseStyle = [
    styles.buttonBase,
    small ? styles.buttonSmall : styles.buttonWide,
    {
      borderRadius: small ? 20 : 22,
    },
  ];

  const content = (
    <Pressable onPress={onPress} style={styles.touchLayer}>
      <Text style={[styles.buttonText, { color: themeDark ? '#F4F4F5' : '#0A0A0B' }]}>{title}</Text>
    </Pressable>
  );

  if (mode === 'safe') {
    return (
      <SafeLiquidGlass
        style={baseStyle}
        blurIntensity={small ? 10 : 18}
        effect={effect}
        tint={themeDark ? 'dark' : 'light'}
      >
        {content}
      </SafeLiquidGlass>
    );
  }

  if (mode === 'blur') {
    return (
      <BlurView
        style={baseStyle}
        intensity={small ? 25 : 35}
        tint={themeDark ? 'dark' : 'light'}
      >
        {content}
      </BlurView>
    );
  }

  return (
    <View
      style={[
        ...baseStyle,
        {
          backgroundColor: themeDark ? 'rgba(38, 38, 45, 0.82)' : 'rgba(245, 245, 248, 0.88)',
          borderWidth: StyleSheet.hairlineWidth,
          borderColor: themeDark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.09)',
        },
      ]}
    >
      {content}
    </View>
  );
}

export default function GlassDebugScreen() {
  const router = useRouter();
  const { colors, effectiveTheme } = useThemeStore();
  const isDark = effectiveTheme === 'dark';
  const [lastPressed, setLastPressed] = useState('none');

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen options={{ title: 'Glass Debug' }} />

      <View style={styles.headerRow}>
        <Pressable onPress={() => router.back()} style={styles.backBtn}>
          <Text style={[styles.backText, { color: colors.text }]}>Back</Text>
        </Pressable>
        <Text style={[styles.statusText, { color: withAlpha(colors.text, 0.7) }]}>
          Last pressed: {lastPressed}
        </Text>
      </View>

      <ScrollView contentContainerStyle={styles.scrollContent}>
        <Text style={[styles.sectionTitle, { color: colors.text }]}>Small (40x40)</Text>
        <View style={styles.row}>
          <SampleButton title="S-Clear" mode="safe" effect="clear" small themeDark={isDark} onPress={() => setLastPressed('safe small clear')} />
          <SampleButton title="S-Regular" mode="safe" effect="regular" small themeDark={isDark} onPress={() => setLastPressed('safe small regular')} />
          <SampleButton title="Blur" mode="blur" small themeDark={isDark} onPress={() => setLastPressed('blur small')} />
          <SampleButton title="Plain" mode="plain" small themeDark={isDark} onPress={() => setLastPressed('plain small')} />
        </View>

        <Text style={[styles.sectionTitle, { color: colors.text }]}>Pill (160x44)</Text>
        <View style={styles.pillColumn}>
          <SampleButton title="Safe Clear Pill" mode="safe" effect="clear" themeDark={isDark} onPress={() => setLastPressed('safe clear pill')} />
          <SampleButton title="Safe Regular Pill" mode="safe" effect="regular" themeDark={isDark} onPress={() => setLastPressed('safe regular pill')} />
          <SampleButton title="Blur Pill (Baseline)" mode="blur" themeDark={isDark} onPress={() => setLastPressed('blur pill')} />
          <SampleButton title="Plain Pill (Baseline)" mode="plain" themeDark={isDark} onPress={() => setLastPressed('plain pill')} />
        </View>

        <Text style={[styles.sectionTitle, { color: colors.text }]}>Notes</Text>
        <Text style={[styles.noteText, { color: withAlpha(colors.text, 0.72) }]}>
          Compare shape distortion between Safe Liquid Glass clear/regular vs Blur baseline.
          If only Safe Regular warps, keep compact controls on effect="clear".
        </Text>
        <Text style={[styles.noteText, { color: withAlpha(colors.text, 0.72) }]}>
          Platform: {Platform.OS} ({effectiveTheme})
        </Text>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  headerRow: {
    paddingTop: 12,
    paddingHorizontal: 14,
    gap: 10,
  },
  backBtn: {
    alignSelf: 'flex-start',
    paddingVertical: 6,
    paddingHorizontal: 10,
    borderRadius: 10,
    backgroundColor: 'rgba(127,127,127,0.16)',
  },
  backText: {
    fontSize: 14,
    fontWeight: '600',
  },
  statusText: {
    fontSize: 13,
  },
  scrollContent: {
    padding: 14,
    paddingBottom: 40,
    gap: 12,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: '700',
    marginTop: 8,
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 10,
  },
  pillColumn: {
    gap: 10,
  },
  buttonBase: {
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonSmall: {
    width: 40,
    height: 40,
  },
  buttonWide: {
    width: 160,
    height: 44,
  },
  touchLayer: {
    width: '100%',
    height: '100%',
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 8,
  },
  buttonText: {
    fontSize: 12,
    fontWeight: '700',
    textAlign: 'center',
  },
  noteText: {
    fontSize: 13,
    lineHeight: 18,
  },
});
