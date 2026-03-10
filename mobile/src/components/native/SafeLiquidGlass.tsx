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
import { Platform, StyleSheet, useColorScheme, View } from 'react-native'
import type { ViewStyle } from 'react-native'
import { BlurView } from 'expo-blur'

// Optional: Try to import native liquid glass for iOS 26+
let LiquidGlassView: React.ComponentType<any> | null = null
let liquidGlassAvailable = false

if (Platform.OS === 'ios') {
  try {
    const liquidGlass = require('@callstack/liquid-glass')
    if (liquidGlass?.LiquidGlassView) {
      LiquidGlassView = liquidGlass.LiquidGlassView
      liquidGlassAvailable = true
    }
  } catch {
    liquidGlassAvailable = false
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
  const flattenedStyle = StyleSheet.flatten(style) || {}
  const styleBackgroundColor = (flattenedStyle as Record<string, any>).backgroundColor

  // Determine blur tint based on theme
  const blurTint = tint || (isDark ? 'dark' : 'light')

  // ═══════════════════════════════════════════════════════════════
  // iOS: Native Liquid Glass (iOS 26+)
  // ═══════════════════════════════════════════════════════════════
  if (
    Platform.OS === 'ios' &&
    liquidGlassAvailable &&
    LiquidGlassView
  ) {
    try {
      const styleWithoutPaint = { ...(flattenedStyle as Record<string, any>) }
      delete styleWithoutPaint.backgroundColor
      delete styleWithoutPaint.borderColor
      delete styleWithoutPaint.borderWidth
      delete styleWithoutPaint.overflow

      return (
        <LiquidGlassView
          style={styleWithoutPaint}
          interactive={interactive}
          effect={effect}
          tintColor={tintColor ?? styleBackgroundColor}
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
  // iOS Final Fallback: expo-blur
  // ═══════════════════════════════════════════════════════════════
  if (Platform.OS === 'ios') {
    return (
      <BlurView
        intensity={blurIntensity * 2}
        tint={blurTint}
        style={style}
        shouldRasterizeIOS={true}
        {...props}
      >
        {children}
      </BlurView>
    )
  }

  // ═══════════════════════════════════════════════════════════════
  // Android: Clean Liquid Glass using expo-blur
  // ═══════════════════════════════════════════════════════════════
  //
  // IMPORTANT: expo-blur's BlurView on Android blurs the content
  // BEHIND the component (what's underneath in z-order), not its children.
  // Children rendered inside BlurView appear on top of the blur.
  //
  // If children are getting blurred, it means they're somehow being
  // rendered behind the blur layer. The fix is to ensure children
  // are direct children of BlurView so they render ON TOP of the blur effect.

  // IMPORTANT: On Android, we must render the BlurView as a background 
  // layer to avoid blurring the children (text, etc.) and remove 
  // hardware texture rendering which causes shadows/artifacts.
  return (
    <View style={[style, { overflow: 'hidden' }]} {...props}>
      <BlurView
        intensity={blurIntensity}
        tint={blurTint}
        experimentalBlurMethod="dimezisBlurView"
        blurReductionFactor={blurReductionFactor}
        style={[StyleSheet.absoluteFill, { backgroundColor: 'transparent' }]}
        removeClippedSubviews={false}
      />
      {children}
    </View>
  )
}

/**
 * Check if native liquid glass is available (iOS 26+)
 */
export function isNativeLiquidGlassAvailable(): boolean {
  return Platform.OS === 'ios' && liquidGlassAvailable
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
