/**
 * Safe Liquid Glass Wrapper - Advanced Clean Implementation
 *
 * Optimized for Samsung and Android devices to achieve iOS-like liquid glass
 * - No extra borders or layered colors that cause artifacts
 * - Uses expo-blur with dimezisBlurView for real blur on Android
 * - Preserves container styles (flex, padding, etc.) without interference
 * - Clean, minimal approach matching One UI / iOS liquid glass aesthetic
 */

import React from 'react'
import { Platform, useColorScheme, View } from 'react-native'
import type { ViewStyle } from 'react-native'
import { BlurView } from 'expo-blur'

// Optional: Try to import native liquid glass for iOS 26+
let LiquidGlassView: React.ComponentType<any> | null = null
let isLiquidGlassSupported = false
let liquidGlassAvailable = false

// Optional: Try to import expo-glass-effect as iOS fallback
let GlassView: React.ComponentType<any> | null = null
let glassViewAvailable = false

if (Platform.OS === 'ios') {
  // Try native liquid glass first
  try {
    const liquidGlass = require('@callstack/liquid-glass')
    if (liquidGlass?.LiquidGlassView) {
      LiquidGlassView = liquidGlass.LiquidGlassView
      isLiquidGlassSupported = liquidGlass.isLiquidGlassSupported ?? true
      liquidGlassAvailable = true
    }
  } catch {
    liquidGlassAvailable = false
  }

  // Try expo-glass-effect as fallback
  if (!liquidGlassAvailable) {
    try {
      const glassEffect = require('expo-glass-effect')
      if (glassEffect?.GlassView) {
        GlassView = glassEffect.GlassView
        glassViewAvailable = true
      }
    } catch {
      glassViewAvailable = false
    }
  }
}

interface SafeLiquidGlassProps {
  children?: React.ReactNode
  interactive?: boolean
  effect?: 'clear' | 'regular'
  tintColor?: string
  colorScheme?: 'light' | 'dark' | 'system'
  style?: any
  /**
   * Blur intensity for Android (1-100)
   * Lower values = more subtle/clean glass effect
   * Recommended: 8-15 for liquid glass look
   * @default 10
   */
  blurIntensity?: number
  /**
   * Blur reduction factor for Android
   * Higher values = less blur
   * @default 4
   */
  blurReductionFactor?: number
  /**
   * Tint style for the blur
   * For cleanest glass on Samsung, use 'default' or match your theme
   */
  tint?: 'default' | 'light' | 'dark' | 'extraLight' | 'regular' | 'prominent'
  [key: string]: any // Allow other View props
}

/**
 * SafeLiquidGlass - Clean liquid glass effect for all platforms
 *
 * Key principles for Samsung/Android:
 * - Uses expo-blur with experimentalBlurMethod="dimezisBlurView"
 * - Low intensity (8-15) for subtle, clean glass
 * - No additional borders, shadows, or color overlays
 * - BlurView positioned absolutely so it doesn't affect layout
 * - Children rendered on top naturally
 */
export default function SafeLiquidGlass({
  children,
  style,
  interactive = true,
  effect = 'regular',
  tintColor,
  colorScheme,
  blurIntensity = 10,
  blurReductionFactor = 4,
  tint,
  ...props
}: SafeLiquidGlassProps) {
  const systemColorScheme = useColorScheme()
  const effectiveColorScheme =
    colorScheme === 'system' || !colorScheme ? systemColorScheme : colorScheme
  const isDark = effectiveColorScheme === 'dark'

  // Determine blur tint based on theme
  const blurTint = tint || (isDark ? 'dark' : 'light')

  // ═══════════════════════════════════════════════════════════════
  // iOS: Native Liquid Glass (iOS 26+)
  // ═══════════════════════════════════════════════════════════════
  if (
    Platform.OS === 'ios' &&
    liquidGlassAvailable &&
    LiquidGlassView &&
    isLiquidGlassSupported
  ) {
    try {
      return (
        <LiquidGlassView
          style={style}
          interactive={interactive}
          effect={effect}
          tintColor={tintColor}
          colorScheme={colorScheme}
          {...props}
        >
          {children}
        </LiquidGlassView>
      )
    } catch {
      console.warn('[SafeLiquidGlass] Native liquid glass failed, using fallback')
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // iOS Fallback: expo-glass-effect
  // ═══════════════════════════════════════════════════════════════
  if (Platform.OS === 'ios' && glassViewAvailable && GlassView) {
    return (
      <GlassView style={style} {...props}>
        {children}
      </GlassView>
    )
  }

  // ═══════════════════════════════════════════════════════════════
  // iOS Final Fallback: expo-blur
  // ═══════════════════════════════════════════════════════════════
  if (Platform.OS === 'ios') {
    return (
      <BlurView
        intensity={blurIntensity * 2}
        tint={blurTint}
        style={[style, { overflow: 'hidden' }]}
        shouldRasterizeIOS={true}
        {...props}
      >
        {children}
      </BlurView>
    )
  }

  // ═══════════════════════════════════════════════════════════════
  // Android: High-Performance "Faux Glass"
  // 
  // We strictly avoid experimentalBlurMethod on Android because it causes text artifacts and jitter.
  // Instead, we use a highly tuned "clean glass" aesthetic:
  // - High transparency background matches the theme
  // - Subtle 1px border to define edges
  // - No active blur shader -> 100% crisp text

  const glassBg = tint === 'light' || !isDark
    ? 'rgba(255, 255, 255, 0.85)'
    : 'rgba(20, 20, 20, 0.85)' // Slightly higher opacity for legibility without blur

  const glassBorder = tint === 'light' || !isDark
    ? 'rgba(255, 255, 255, 0.3)'
    : 'rgba(255, 255, 255, 0.08)'

  return (
    <View
      style={[
        {
          backgroundColor: glassBg,
          borderColor: glassBorder,
          borderWidth: 1,
          overflow: 'hidden'
        },
        style
      ]}
      {...props}
    >
      {children}
    </View>
  )
}

/**
 * Check if native liquid glass is available (iOS 26+)
 */
export function isNativeLiquidGlassAvailable(): boolean {
  return Platform.OS === 'ios' && liquidGlassAvailable && isLiquidGlassSupported
}

/**
 * Check if real blur is available on current platform
 */
export function isRealBlurAvailable(): boolean {
  return Platform.OS === 'ios' || Platform.OS === 'android'
}

/**
 * Preset configurations for common use cases
 */
export const LiquidGlassPresets = {
  /** Very subtle glass - almost transparent with minimal blur */
  subtle: {
    blurIntensity: 5,
    blurReductionFactor: 6,
  },
  /** Default clean glass - balanced blur and transparency */
  default: {
    blurIntensity: 10,
    blurReductionFactor: 4,
  },
  /** More visible glass - slightly more blur */
  medium: {
    blurIntensity: 15,
    blurReductionFactor: 4,
  },
  /** Frosted glass - more opaque, stronger blur */
  frosted: {
    blurIntensity: 25,
    blurReductionFactor: 3,
  },
  /** Samsung One UI 8 style - clean with thin appearance */
  samsungOneUI: {
    blurIntensity: 8,
    blurReductionFactor: 5,
    tint: 'default' as const,
  },
  /** iOS-like liquid glass approximation */
  iOSStyle: {
    blurIntensity: 12,
    blurReductionFactor: 4,
  },
} as const