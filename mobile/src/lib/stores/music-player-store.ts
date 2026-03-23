import { create } from 'zustand'

import type { MusicTrack } from '../agent/types'
import {
  addNativeMusicPlayerListener,
  getNativeMusicPlayerModule,
  type NativeMusicPlayerStateEvent,
} from '../../native/music/runtime'

interface MusicPlayerState {
  currentTrack: MusicTrack | null
  isPlaying: boolean
  queue: MusicTrack[]
  isExpanded: boolean
  progress: number
  duration: number
  playbackRate: number

  setTrack: (track: MusicTrack) => void
  setQueue: (tracks: MusicTrack[]) => void
  setIsPlaying: (isPlaying: boolean) => void
  setIsExpanded: (isExpanded: boolean) => void
  setProgress: (progress: number) => void
  setDuration: (duration: number) => void
  setPlaybackRate: (rate: number) => void
  playNext: () => void
  playPrev: () => void
  reset: () => void
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value)

const asString = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim().length > 0 ? value : undefined

const asNumber = (value: unknown): number | undefined =>
  typeof value === 'number' && Number.isFinite(value) ? value : undefined

const toMusicTrack = (value: unknown): MusicTrack | null => {
  if (!isRecord(value)) return null
  const title = asString(value.title)
  const artist = asString(value.artist)
  if (!title || !artist) return null

  const links = isRecord(value.links) ? value.links as MusicTrack['links'] : {}
  return {
    video_id: asString(value.video_id) ?? asString(value.track_id),
    id: asString(value.id),
    source: asString(value.source) as MusicTrack['source'] | undefined,
    title,
    artist,
    album: asString(value.album),
    duration: asString(value.duration),
    preview_url:
      asString(value.preview_url)
      ?? asString(value.stream_url)
      ?? asString(value.local_uri),
    cover: asString(value.cover),
    links,
  }
}

const toNativeTrackPayload = (track: MusicTrack): Record<string, unknown> => {
  const value = track as MusicTrack & Record<string, unknown>
  return {
    ...value,
    video_id: track.video_id ?? asString(value.video_id),
    id: track.id ?? asString(value.id),
    source: track.source ?? asString(value.source),
    title: track.title,
    artist: track.artist,
    album: track.album ?? asString(value.album),
    duration: track.duration ?? asString(value.duration),
    duration_seconds: asNumber(value.duration_seconds),
    preview_url: track.preview_url ?? asString(value.preview_url),
    stream_url: asString(value.stream_url),
    cover: track.cover ?? asString(value.cover),
    local_uri: asString(value.local_uri),
    links: track.links ?? {},
  }
}

const applyNativePlaybackState = (snapshot: NativeMusicPlayerStateEvent | null | undefined) => {
  if (!snapshot) return
  useMusicPlayerStore.setState((state) => ({
    ...state,
    currentTrack: toMusicTrack(snapshot.currentTrack) ?? null,
    queue: (snapshot.queue ?? []).map(toMusicTrack).filter(Boolean) as MusicTrack[],
    isPlaying: !!snapshot.isPlaying,
    isExpanded: !!snapshot.isExpanded,
    progress: asNumber(snapshot.progress) ?? 0,
    duration: asNumber(snapshot.duration) ?? 0,
    playbackRate: asNumber(snapshot.playbackRate) ?? 1,
  }))
}

export const useMusicPlayerStore = create<MusicPlayerState>((set, get) => ({
  currentTrack: null,
  isPlaying: false,
  queue: [],
  isExpanded: false,
  progress: 0,
  duration: 0,
  playbackRate: 1,

  setTrack: (track) => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.setTrack(toNativeTrackPayload(track))
      return
    }

    const current = get().currentTrack
    const isSameTrack =
      current?.preview_url === track.preview_url
      && current?.id === track.id
      && current?.source === track.source
    if (isSameTrack) {
      set({ isPlaying: true })
    } else {
      set({ currentTrack: track, isPlaying: true, progress: 0, playbackRate: 1 })
    }
  },

  setQueue: (queue) => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.setQueue(queue.map(toNativeTrackPayload))
      return
    }
    set({ queue })
  },

  setIsPlaying: (isPlaying) => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.setIsPlaying(isPlaying)
      return
    }
    set({ isPlaying })
  },

  setIsExpanded: (isExpanded) => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.setIsExpanded(isExpanded)
      return
    }
    set({ isExpanded })
  },

  setProgress: (progress) => {
    set({ progress })
  },

  setDuration: (duration) => {
    set({ duration })
  },

  setPlaybackRate: (rate) => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.setPlaybackRate(rate)
      return
    }
    set({ playbackRate: rate })
  },

  playNext: () => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.playNext()
      return
    }
    const { queue, currentTrack } = get()
    if (!currentTrack || queue.length === 0) return
    const idx = queue.findIndex((t) => t.preview_url === currentTrack.preview_url)
    if (idx > -1 && idx < queue.length - 1) {
      set({ currentTrack: queue[idx + 1], isPlaying: true, progress: 0 })
    }
  },

  playPrev: () => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.playPrev()
      return
    }
    const { queue, currentTrack } = get()
    if (!currentTrack || queue.length === 0) return
    const idx = queue.findIndex((t) => t.preview_url === currentTrack.preview_url)
    if (idx > 0) {
      set({ currentTrack: queue[idx - 1], isPlaying: true, progress: 0 })
    }
  },

  reset: () => {
    const nativeModule = getNativeMusicPlayerModule()
    if (nativeModule) {
      nativeModule.reset()
      return
    }
    set({
      currentTrack: null,
      isPlaying: false,
      queue: [],
      progress: 0,
      duration: 0,
      isExpanded: false,
      playbackRate: 1,
    })
  },
}))

let nativeMusicPlayerBootstrapped = false
let nativeMusicPlayerSubscription: { remove: () => void } | null = null

const ensureNativeMusicPlayerRuntime = () => {
  if (nativeMusicPlayerBootstrapped) return
  const nativeModule = getNativeMusicPlayerModule()
  if (!nativeModule) return

  nativeMusicPlayerBootstrapped = true
  try {
    applyNativePlaybackState(nativeModule.getState())
  } catch {
    // Leave the JS store in its default state if native init fails.
  }
  nativeMusicPlayerSubscription = addNativeMusicPlayerListener(applyNativePlaybackState)
}

ensureNativeMusicPlayerRuntime()

export const disposeNativeMusicPlayerRuntimeForTests = () => {
  nativeMusicPlayerSubscription?.remove()
  nativeMusicPlayerSubscription = null
  nativeMusicPlayerBootstrapped = false
}
