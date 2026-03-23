import { Platform } from 'react-native'

export interface NativeMusicPlayerStateEvent {
  currentTrack?: Record<string, unknown> | null
  queue?: Array<Record<string, unknown>>
  isPlaying?: boolean
  isExpanded?: boolean
  progress?: number
  duration?: number
  playbackRate?: number
  tracks?: Record<string, Record<string, unknown>>
  downloadingTracks?: Record<string, number>
}

export interface NativeMusicPlayerModule {
  isSupported(): boolean
  getState(): NativeMusicPlayerStateEvent
  setQueue(queue: Array<Record<string, unknown>>): void
  setTrack(track: Record<string, unknown>): void
  setIsPlaying(isPlaying: boolean): void
  setIsExpanded(isExpanded: boolean): void
  setPlaybackRate(rate: number): void
  playNext(): void
  playPrev(): void
  reset(): void
  seekTo(milliseconds: number): void
  cacheTrack(track: Record<string, unknown>): Record<string, unknown> | null
  getTrack(trackId: string): Record<string, unknown> | null
  removeTrack(trackId: string): void
  downloadTrack(track: Record<string, unknown>): Promise<Record<string, unknown> | null>
}

const MODULE_NAME = 'NativeGlobalMusicPlayer'

let cachedModule: NativeMusicPlayerModule | null | undefined

const loadOptionalNativeModule = <T>(moduleName: string): T | null => {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const core = require('expo-modules-core')

    if (typeof core.requireNativeModule === 'function') {
      try {
        return core.requireNativeModule(moduleName) as T
      } catch {
        // Fall through to optional lookup.
      }
    }

    if (typeof core.requireOptionalNativeModule === 'function') {
      const optional = core.requireOptionalNativeModule(moduleName) as T | null
      if (optional) return optional
    }

    const proxy = core.NativeModulesProxy as Record<string, T> | undefined
    return proxy?.[moduleName] ?? null
  } catch {
    return null
  }
}

export const getNativeMusicPlayerModule = (): NativeMusicPlayerModule | null => {
  if (cachedModule !== undefined) return cachedModule
  if (Platform.OS !== 'ios') {
    cachedModule = null
    return null
  }
  cachedModule = loadOptionalNativeModule<NativeMusicPlayerModule>(MODULE_NAME)
  return cachedModule
}

type NativeMusicPlayerSubscription = { remove: () => void }

export const addNativeMusicPlayerListener = (
  listener: (event: NativeMusicPlayerStateEvent) => void,
): NativeMusicPlayerSubscription | null => {
  const nativeModule = getNativeMusicPlayerModule()
  if (!nativeModule) return null
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { EventEmitter } = require('expo-modules-core')
    const emitter = new EventEmitter(nativeModule)
    return emitter.addListener('onPlaybackState', listener)
  } catch {
    return null
  }
}

export const isNativeMusicPlayerAvailable = (): boolean => {
  if (Platform.OS !== 'ios') return false
  return !!getNativeMusicPlayerModule()
}
