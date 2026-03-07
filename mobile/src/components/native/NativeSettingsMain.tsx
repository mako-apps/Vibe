import React, { useMemo } from 'react'
import { Platform, StyleSheet, View, type ViewProps } from 'react-native'
import Constants from 'expo-constants'
import { requireNativeViewManager } from 'expo-modules-core'

export type NativeSettingsRowType = 'link' | 'switch' | 'value' | 'button'

export interface NativeSettingsMainRow {
  id: string
  icon: string
  label: string
  value?: string | boolean
  type?: NativeSettingsRowType
  color?: string
  divider?: boolean
  destructive?: boolean
}

export interface NativeSettingsMainSection {
  title?: string
  rows: NativeSettingsMainRow[]
}

interface NativeSettingsMainNativeEvent {
  type?: string
  rowId?: string
  value?: boolean
}

interface NativeSettingsMainViewProps extends ViewProps {
  isDark?: boolean
  backgroundColor?: string
  cardColor?: string
  textColor?: string
  textSecondaryColor?: string
  primaryColor?: string
  displayName?: string
  subtitle?: string
  editLabel?: string
  footerText?: string
  imageUri?: string
  fallbackText?: string
  avatarLoading?: boolean
  badgeTier?: string
  sections?: NativeSettingsMainSection[]
  onNativeEvent?: (event: { nativeEvent: NativeSettingsMainNativeEvent }) => void
}

let NativeSettingsMainView: React.ComponentType<NativeSettingsMainViewProps> | null = null
let nativeSettingsMainAvailable = false

try {
  const isExpoGo = Constants.appOwnership === 'expo'
  if (Platform.OS === 'ios' && !isExpoGo) {
    NativeSettingsMainView = requireNativeViewManager<NativeSettingsMainViewProps>('NativeSettingsMain')
    nativeSettingsMainAvailable = !!NativeSettingsMainView
  }
} catch {
  nativeSettingsMainAvailable = false
}

export function isNativeSettingsMainAvailable(): boolean {
  return Platform.OS === 'ios' && nativeSettingsMainAvailable
}

interface NativeSettingsMainProps extends NativeSettingsMainViewProps {}

export default function NativeSettingsMain(props: NativeSettingsMainProps) {
  const canRender = useMemo(() => isNativeSettingsMainAvailable(), [])
  if (!canRender || !NativeSettingsMainView) {
    return <View style={[styles.fill, props.style]} />
  }

  const Component = NativeSettingsMainView
  return <Component {...props} style={[styles.fill, props.style]} />
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
    backgroundColor: 'transparent',
  },
})
