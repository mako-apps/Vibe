import React, { useMemo } from 'react'
import {
  Platform,
  StyleSheet,
  View,
  type NativeSyntheticEvent,
  type ViewProps,
} from 'react-native'
import Constants from 'expo-constants'
import { requireNativeViewManager } from 'expo-modules-core'

export type NativeStoryCameraEventPayload =
  | {
      type: 'capture'
      uri: string
      mediaType: 'image' | 'video'
      mirrored?: boolean
    }
  | {
      type: 'close' | 'openDrafts'
    }
  | {
      type: 'error'
      message?: string
    }

interface NativeStoryCameraViewProps extends ViewProps {
  deferMountMs?: number
  onNativeEvent?: (event: NativeSyntheticEvent<NativeStoryCameraEventPayload>) => void
}

let NativeStoryCameraView: React.ComponentType<NativeStoryCameraViewProps> | null = null
let nativeStoryCameraAvailable = false

try {
  const isExpoGo = Constants.appOwnership === 'expo'
  if (Platform.OS === 'ios' && !isExpoGo) {
    NativeStoryCameraView = requireNativeViewManager<NativeStoryCameraViewProps>('NativeStoryCamera')
    nativeStoryCameraAvailable = !!NativeStoryCameraView
  }
} catch {
  nativeStoryCameraAvailable = false
}

export function isNativeStoryCameraAvailable(): boolean {
  return Platform.OS === 'ios' && nativeStoryCameraAvailable
}

export default function NativeStoryCamera(props: NativeStoryCameraViewProps) {
  const canRender = useMemo(() => isNativeStoryCameraAvailable(), [])
  if (!canRender || !NativeStoryCameraView) {
    return <View style={[styles.fill, props.style]} />
  }

  const Component = NativeStoryCameraView
  return <Component {...props} style={[styles.fill, props.style]} />
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
    backgroundColor: 'transparent',
  },
})
