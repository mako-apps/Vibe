import React, { useMemo } from 'react'
import { Platform, StyleSheet, View, type ViewProps } from 'react-native'
import Constants from 'expo-constants'
import { requireNativeViewManager } from 'expo-modules-core'

interface NativeGlobalMusicPlayerViewProps extends ViewProps {
  isDark?: boolean
  surfaceColor?: string
  textColor?: string
  textSecondaryColor?: string
  primaryColor?: string
  topInset?: number
}

let NativeGlobalMusicPlayerView: React.ComponentType<NativeGlobalMusicPlayerViewProps> | null = null
let nativeGlobalMusicPlayerAvailable = false

try {
  const isExpoGo = Constants.appOwnership === 'expo'
  if (Platform.OS === 'ios' && !isExpoGo) {
    NativeGlobalMusicPlayerView =
      requireNativeViewManager<NativeGlobalMusicPlayerViewProps>('NativeGlobalMusicPlayer')
    nativeGlobalMusicPlayerAvailable = !!NativeGlobalMusicPlayerView
  }
} catch {
  nativeGlobalMusicPlayerAvailable = false
}

export function isNativeGlobalMusicPlayerAvailable(): boolean {
  return Platform.OS === 'ios' && nativeGlobalMusicPlayerAvailable
}

export default function NativeGlobalMusicPlayer(props: NativeGlobalMusicPlayerViewProps) {
  const canRender = useMemo(() => isNativeGlobalMusicPlayerAvailable(), [])
  if (!canRender || !NativeGlobalMusicPlayerView) {
    return <View pointerEvents="box-none" style={[styles.fill, props.style]} />
  }

  const Component = NativeGlobalMusicPlayerView
  return <Component {...props} pointerEvents="box-none" style={[styles.fill, props.style]} />
}

const styles = StyleSheet.create({
  fill: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'transparent',
    zIndex: 1000,
    elevation: 1000,
  },
})
