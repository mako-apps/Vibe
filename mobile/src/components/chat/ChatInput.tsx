import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { View, TextInput, Pressable, StyleSheet, Text, TouchableOpacity, Dimensions, Keyboard, FlatList, Image, ActivityIndicator, LayoutAnimation, Platform, LayoutChangeEvent } from 'react-native';
import { ArrowUp, Mic, X, Lock, Unlock, Search, Sparkles, ChevronLeft, ChevronUp, Pause, Plus, Camera, Video as VideoIcon } from 'lucide-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import Animated, {
    useSharedValue,
    useDerivedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    interpolate,
    Extrapolate,
    withRepeat,
    Easing,
    withSpring,
    withSequence
} from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import { GestureDetector, Gesture } from 'react-native-gesture-handler';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { AttachmentIcon, AnimatedGifToSmileIcon, SendFilledIcon } from '../Icons';
import { useHaptics } from '../../lib/hooks/useHaptics';
import axios from 'axios';
import { useChatStore } from '../../lib/ChatStore';
import { AttachmentMenu, SelectedMediaItem } from './AttachmentMenu';
import { ImagePreviewEditor } from './ImagePreviewEditor';
import LottieView from 'lottie-react-native';
import { Audio } from 'expo-av';
import { Canvas, Circle, BlurMask, Rect, LinearGradient as SkiaLinearGradient, vec } from '@shopify/react-native-skia';

import { CameraView, useCameraPermissions, useMicrophonePermissions } from 'expo-camera';
import { VideoNoteOverlay } from './VideoNoteOverlay';

// Helper for alpha colors
const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`)
    }
    return color
}

// Reply info interface
export interface ReplyInfo {
    messageId: string;
    userName: string;
    userHandle?: string;
    content: string;
}

interface ChatInputProps {
    text: string;
    setText: (text: string) => void;
    onSend: () => void | Promise<void>;
    onAttach?: (file:
        | { type: 'image' | 'file' | 'videoNote', uri: string, mimeType?: string, name?: string, size?: number, duration?: number, width?: number, height?: number, caption?: string, hdMode?: boolean, viewOnce?: boolean }
        | { type: 'location', latitude: number, longitude: number }
        | { type: 'contact', contact: any }
    ) => void;
    onGif?: () => void;
    onCamera?: () => void;
    onMic?: () => void;
    currentChatId?: string; // For saving drafts
    isRecordingLocked?: boolean;
    manualClear?: boolean; // If true, parent must clear text manually
    onInputFocus?: () => void;
    onTypingStatusChange?: (isTyping: boolean) => void;
    onVibeQuery?: (query: string) => void;
    keyboardProgress?: SharedValue<number>;
    // Reply props
    replyTo?: ReplyInfo | null;
    onCancelReply?: () => void;
}

const AnimatedView = Animated.createAnimatedComponent(View);
const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const CANCEL_DISTANCE = 120;
const LOCK_DISTANCE = -100;
const DEFAULT_KEYBOARD_HEIGHT = 300;
const TENOR_API_KEY = 'AIzaSyBXWzVxYjR6bJ3yblI9rWP4g8Ps5TPHvQ0';
const HOLD_TO_RECORD_DELAY_MS = 80;
const VAD_UPDATE_INTERVAL_MS = 48;
const VAD_DB_FLOOR = -60;
const INPUT_SIDE_PADDING_CLOSED = 8;
const INPUT_SIDE_PADDING_OPEN = 4;
const INPUT_SIDE_PADDING_RECORDING_CLOSED = 12;
const INPUT_SIDE_PADDING_RECORDING_OPEN = 4;

// Smooth easing for all animations
const SMOOTH_EASING = Easing.bezier(0.25, 0.1, 0.25, 1);
const ANIMATION_DURATION = 250;

// Telegram-style mic button sizes
const MIC_BUTTON_SIZE = 44;
const MIC_BUTTON_RECORDING_SIZE = 96; // Reduced to avoid oversized scaling artifacts
const METALLIC_STRIP_HEIGHT = 88;
const METALLIC_SHEEN_WIDTH = 210;

// Global recorder coordination so multiple ChatInput instances cannot prepare concurrently.
let globalRecordingOperation: Promise<void> = Promise.resolve();
let globalPreparedRecording: Audio.Recording | null = null;

const withGlobalRecordingOperation = async <T,>(operation: () => Promise<T>): Promise<T> => {
    const previous = globalRecordingOperation;
    let release: () => void = () => { };
    globalRecordingOperation = new Promise<void>((resolve) => {
        release = resolve;
    });
    await previous;
    try {
        return await operation();
    } finally {
        release();
    }
};

const safelyReleaseRecording = async (recording: Audio.Recording | null | undefined): Promise<void> => {
    if (!recording) return;
    try {
        (recording as any).setOnRecordingStatusUpdate?.(null);
    } catch { }
    try {
        await recording.stopAndUnloadAsync();
        return;
    } catch { }
    try {
        await (recording as any).stopAsync?.();
    } catch { }
    try {
        await (recording as any).unloadAsync?.();
    } catch { }
};

interface GifResult {
    id: string;
    url: string;
    preview: string;
    width: number;
    height: number;
}

interface OptionalNativeVadModule {
    start?: () => Promise<void> | void;
    stop?: () => Promise<void> | void;
    getLevel?: () => Promise<number> | number;
}

const ChatInput = React.memo(({
    text,
    setText,
    onSend,
    onAttach,
    onGif,
    onCamera,
    onMic,
    currentChatId, // For saving drafts
    isRecordingLocked,
    manualClear = false, // If true, parent must clear text manually
    onInputFocus,
    onTypingStatusChange,
    onVibeQuery,
    keyboardProgress,
    replyTo,
    onCancelReply
}: ChatInputProps) => {
    const { colors, effectiveTheme } = useThemeStore();
    // Theme based tint
    const liquidTint = withAlpha(colors.card, 0.75);
    const { activeTheme } = useWallpaperStore();
    const resolvedTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
    const bubbleTone = resolvedTheme.bubbleMe || colors.primary;
    const metalGradientColors = useMemo(() => ([
        withAlpha(bubbleTone, 0),
        withAlpha(bubbleTone, 0.06),
        withAlpha(bubbleTone, 0.16),
        withAlpha(bubbleTone, 0.24),
    ]), [bubbleTone]);
    const metalMidlineColors = useMemo(() => ([
        withAlpha('#ffffff', 0),
        withAlpha('#ffffff', 0.08),
        withAlpha('#ffffff', 0.14),
        withAlpha('#ffffff', 0.08),
        withAlpha('#ffffff', 0),
    ]), []);
    const metalEdgeVignetteColors = useMemo(() => ([
        withAlpha('#000000', 0.2),
        withAlpha('#000000', 0),
        withAlpha('#000000', 0.2),
    ]), []);
    const metalSheenColors = useMemo(() => ([
        withAlpha('#ffffff', 0),
        withAlpha('#ffffff', 0.18),
        withAlpha('#ffffff', 0),
    ]), []);
    const inputRef = useRef<TextInput>(null);
    const haptic = useHaptics();
    const lottieRef = useRef<LottieView>(null);
    const recordingRef = useRef<Audio.Recording | null>(null);
    const isStartingRecordingRef = useRef(false);
    const isStoppingRecordingRef = useRef(false);
    const pendingStopAfterStartRef = useRef(false);
    const isInputFocusedRef = useRef(false);
    const keyboardRestoreTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const keyboardVisibleRef = useRef(false);
    const vadSmoothingRef = useRef(0);
    const nativeVadModuleRef = useRef<OptionalNativeVadModule | null | undefined>(undefined);
    const nativeVadPollRef = useRef<NodeJS.Timeout | null>(null);
    const recordingTickerRef = useRef<ReturnType<typeof setInterval> | null>(null);

    // Store for recording status
    const { sendRecording, sendStopRecording, activeChatId } = useChatStore();

    // State
    const [isRecording, setIsRecording] = useState(false);
    const [isLocked, setIsLocked] = useState(false);
    const [recordingDuration, setRecordingDuration] = useState(0);
    const [recordingElapsedMs, setRecordingElapsedMs] = useState(0);
    const [keyboardHeight, setKeyboardHeight] = useState(DEFAULT_KEYBOARD_HEIGHT);
    const [metalStripSize, setMetalStripSize] = useState({ width: SCREEN_WIDTH, height: METALLIC_STRIP_HEIGHT });
    const [showAttachmentMenu, setShowAttachmentMenu] = useState(false);
    const [previewImages, setPreviewImages] = useState<{ uri: string; width?: number; height?: number }[]>([]);
    const [showImagePreview, setShowImagePreview] = useState(false);

    // Recording mode: 'voice' = audio, 'video' = circular video note
    const [recordingMode, setRecordingMode] = useState<'voice' | 'video'>('voice');

    // Vibe mode - separate from reply
    const [isVibeActive, setIsVibeActive] = useState(false);
    const [showVibeSuggestion, setShowVibeSuggestion] = useState(false);
    const [vibeQuery, setVibeQuery] = useState('');
    const lastTypingStatusRef = useRef(false);

    const [micPermission, requestMicPermission] = useMicrophonePermissions();
    const [cameraPermission, requestCameraPermission] = useCameraPermissions();
    const [recordingCanceled, setRecordingCanceled] = useState(false);

    // Shared Values
    const typingProgress = useSharedValue(0);
    const focusProgress = useSharedValue(0);
    const replyExpandProgress = useSharedValue(0);
    const vibeExpandProgress = useSharedValue(0);


    // Recording animation values
    const recordingProgress = useSharedValue(0); // 0 = not recording, 1 = recording
    const dragX = useSharedValue(0);
    const dragY = useSharedValue(0);
    const vadLevel = useSharedValue(0);
    const micPressScale = useSharedValue(1);
    const micAuraPhase = useSharedValue(0);

    // Animated arrow values
    const arrowUpAnim = useSharedValue(0);
    const arrowLeftAnim = useSharedValue(0);

    // Delete animation progress (0 = dot, 1 = bin)
    const deleteProgress = useSharedValue(0);

    const hasReply = !!replyTo;
    const isExpanded = isVibeActive;

    // Start animations and recording UI
    useEffect(() => {
        recordingProgress.value = withTiming(isRecording ? 1 : 0, {
            duration: 200,
            easing: SMOOTH_EASING
        });

        // Start arrow animations when recording
        if (isRecording && !isLocked) {
            // Repeating arrow animations
            arrowUpAnim.value = withRepeat(
                withTiming(1, { duration: 800, easing: Easing.inOut(Easing.ease) }),
                -1, // infinite
                true // reverse
            );
            arrowLeftAnim.value = withRepeat(
                withTiming(1, { duration: 800, easing: Easing.inOut(Easing.ease) }),
                -1,
                true
            );
        } else {
            arrowUpAnim.value = withTiming(0);
            arrowLeftAnim.value = withTiming(0);
        }
    }, [isRecording, isLocked]);

    useEffect(() => {
        replyExpandProgress.value = withTiming(hasReply ? 1 : 0, {
            duration: ANIMATION_DURATION,
            easing: SMOOTH_EASING
        });

        if (hasReply) {
            inputRef.current?.focus();
        }
    }, [hasReply]);

    useEffect(() => {
        vibeExpandProgress.value = withTiming((isVibeActive || showVibeSuggestion) ? 1 : 0, {
            duration: ANIMATION_DURATION,
            easing: SMOOTH_EASING
        });
    }, [isVibeActive, showVibeSuggestion]);

    useEffect(() => {
        // Keep press scale normalized when recording state flips.
        micPressScale.value = withTiming(1, {
            duration: 110,
            easing: Easing.out(Easing.quad)
        });
    }, [isRecording, micPressScale]);

    useEffect(() => {
        if (isRecording) {
            micAuraPhase.value = withRepeat(
                withTiming(1, { duration: 1250, easing: Easing.inOut(Easing.quad) }),
                -1,
                true
            );
        } else {
            micAuraPhase.value = withTiming(0, { duration: 180, easing: Easing.out(Easing.quad) });
        }
    }, [isRecording, micAuraPhase]);

    useEffect(() => {
        // Keyboard listeners removed as keyboardHeight state is unused in render/styles
        // and keyboardProgress is passed as shared value.
    }, []);

    // Clean up typing status when text is cleared externally (e.g. after send)
    useEffect(() => {
        if (text.length === 0 && lastTypingStatusRef.current) {
            lastTypingStatusRef.current = false;
            typingProgress.value = withTiming(0, {
                duration: 200,
                easing: SMOOTH_EASING
            });
            onTypingStatusChange?.(false);
        }
    }, [text]);

    const applyVadLevel = useCallback((rawLevel: number) => {
        if (!Number.isFinite(rawLevel)) return;

        // Accept either normalized [0..1] or dB [-160..0] sources.
        const normalized = rawLevel <= 1 && rawLevel >= 0
            ? rawLevel
            : (Math.max(VAD_DB_FLOOR, Math.min(0, rawLevel)) - VAD_DB_FLOOR) / Math.abs(VAD_DB_FLOOR);

        // Smooth for stable visual response without lag.
        const prev = vadSmoothingRef.current;
        const smoothed = prev + (normalized - prev) * 0.35;
        vadSmoothingRef.current = smoothed;
        vadLevel.value = withTiming(smoothed, {
            duration: VAD_UPDATE_INTERVAL_MS,
            easing: Easing.out(Easing.quad)
        });
    }, [vadLevel]);

    const resolveNativeVadModule = useCallback((): OptionalNativeVadModule | null => {
        if (nativeVadModuleRef.current !== undefined) {
            return nativeVadModuleRef.current ?? null;
        }
        try {
            const { requireNativeModule } = require('expo-modules-core');
            nativeVadModuleRef.current =
                requireNativeModule?.('VibeVad') ||
                requireNativeModule?.('LiveVad') ||
                requireNativeModule?.('VoiceVad') ||
                null;
        } catch {
            nativeVadModuleRef.current = null;
        }
        return nativeVadModuleRef.current ?? null;
    }, []);

    const stopNativeVad = useCallback(async () => {
        if (nativeVadPollRef.current) {
            clearInterval(nativeVadPollRef.current);
            nativeVadPollRef.current = null;
        }
        const nativeVad = nativeVadModuleRef.current || null;
        if (nativeVad?.stop) {
            try {
                await nativeVad.stop();
            } catch (err) {
                console.warn('Failed to stop native VAD', err);
            }
        }
    }, []);

    const stopRecordingTicker = useCallback(() => {
        if (recordingTickerRef.current) {
            clearInterval(recordingTickerRef.current);
            recordingTickerRef.current = null;
        }
    }, []);

    const startRecordingTicker = useCallback(() => {
        stopRecordingTicker();
        const start = Date.now();
        setRecordingElapsedMs(0);
        setRecordingDuration(0);
        recordingTickerRef.current = setInterval(() => {
            const elapsed = Math.max(0, Date.now() - start);
            setRecordingElapsedMs(elapsed);
            setRecordingDuration(Math.floor(elapsed / 1000));
        }, 42);
    }, [stopRecordingTicker]);

    const startNativeVad = useCallback(async () => {
        const nativeVad = resolveNativeVadModule();
        if (!nativeVad) return;

        try {
            await nativeVad.start?.();

            if (nativeVad.getLevel) {
                if (nativeVadPollRef.current) clearInterval(nativeVadPollRef.current);
                nativeVadPollRef.current = setInterval(async () => {
                    try {
                        const next = await nativeVad.getLevel?.();
                        if (typeof next === 'number') applyVadLevel(next);
                    } catch {
                        // Keep fallback metering active even if native module polling fails.
                    }
                }, VAD_UPDATE_INTERVAL_MS);
            }
        } catch (err) {
            console.warn('Failed to start native VAD', err);
        }
    }, [applyVadLevel, resolveNativeVadModule]);

    const handleRecordingStatusUpdate = useCallback((status: Audio.RecordingStatus) => {
        if (typeof status.durationMillis === 'number') {
            const elapsed = Math.max(0, status.durationMillis);
            setRecordingElapsedMs(elapsed);
            setRecordingDuration(Math.floor(elapsed / 1000));
        }
        const metering = (status as Audio.RecordingStatus & { metering?: number }).metering;
        if (typeof metering === 'number') {
            applyVadLevel(metering);
        }
    }, [applyVadLevel]);

    useEffect(() => {
        if (!isRecording) {
            setRecordingDuration(0);
            setRecordingElapsedMs(0);
            vadSmoothingRef.current = 0;
            vadLevel.value = withTiming(0, { duration: 120 });
        }
    }, [isRecording, vadLevel]);

    useEffect(() => {
        return () => {
            void stopNativeVad();
            stopRecordingTicker();
            isStartingRecordingRef.current = false;
            isStoppingRecordingRef.current = false;
            pendingStopAfterStartRef.current = false;
            void withGlobalRecordingOperation(async () => {
                const current = recordingRef.current;
                if (current) {
                    await safelyReleaseRecording(current);
                    if (globalPreparedRecording === current) {
                        globalPreparedRecording = null;
                    }
                    recordingRef.current = null;
                }
            });
            if (keyboardRestoreTimerRef.current) {
                clearTimeout(keyboardRestoreTimerRef.current);
                keyboardRestoreTimerRef.current = null;
            }
        };
    }, [stopNativeVad, stopRecordingTicker]);

    const formatDuration = (elapsedMs: number) => {
        const totalSeconds = Math.floor(elapsedMs / 1000);
        const m = Math.floor(totalSeconds / 60);
        const s = totalSeconds % 60;
        const ms = Math.floor((elapsedMs % 1000) / 10);
        return `${m}:${s.toString().padStart(2, '0')},${ms.toString().padStart(2, '0')}`;
    };

    // Combined expand progress for hiding attach/mic
    const combinedExpandProgress = useSharedValue(0);
    useEffect(() => {
        combinedExpandProgress.value = withTiming(isExpanded ? 1 : 0, {
            duration: ANIMATION_DURATION,
            easing: SMOOTH_EASING
        });
    }, [isExpanded]);

    // === RECORDING FUNCTIONS ===
    const startRecording = useCallback(async () => {
        if (isRecording || isStartingRecordingRef.current || isStoppingRecordingRef.current) return;
        isStartingRecordingRef.current = true;
        pendingStopAfterStartRef.current = false;

        haptic.medium();
        // Keep keyboard state stable:
        // - If keyboard is currently visible, re-focus after recording starts to prevent accidental dismiss.
        // - If keyboard is currently hidden (even if TextInput is technically still focused), do not open it.
        const restoreKeyboardAfterStart = keyboardVisibleRef.current;
        setRecordingDuration(0);
        setRecordingElapsedMs(0);
        vadSmoothingRef.current = 0;
        vadLevel.value = withTiming(0, { duration: 80 });

        try {
            if (recordingMode === 'video') {
                // Check permissions
                if (!cameraPermission?.granted || !micPermission?.granted) {
                    const cam = await requestCameraPermission();
                    const mic = await requestMicPermission();
                    if (!cam.granted || !mic.granted) return;
                }

                // Stop may have been requested while waiting for permissions.
                if (pendingStopAfterStartRef.current) return;

                // Video note: just switch state, overlay handles camera logic
                setRecordingCanceled(false);
                setIsRecording(true);
                startRecordingTicker();
                dragX.value = 0;
                dragY.value = 0;
                if (restoreKeyboardAfterStart) {
                    if (keyboardRestoreTimerRef.current) clearTimeout(keyboardRestoreTimerRef.current);
                    keyboardRestoreTimerRef.current = setTimeout(() => inputRef.current?.focus(), 16);
                }
                return;
            }

            // Voice recording
            const perm = await Audio.requestPermissionsAsync();
            if (perm.status !== 'granted') {
                return;
            }

            await withGlobalRecordingOperation(async () => {
                if (pendingStopAfterStartRef.current) return;

                if (globalPreparedRecording && globalPreparedRecording !== recordingRef.current) {
                    await safelyReleaseRecording(globalPreparedRecording);
                    globalPreparedRecording = null;
                }

                if (recordingRef.current) {
                    const stale = recordingRef.current;
                    await safelyReleaseRecording(stale);
                    if (globalPreparedRecording === stale) {
                        globalPreparedRecording = null;
                    }
                    recordingRef.current = null;
                }

                await Audio.setAudioModeAsync({
                    allowsRecordingIOS: true,
                    playsInSilentModeIOS: true,
                });

                const recordingOptions: Audio.RecordingOptions = {
                    ...Audio.RecordingOptionsPresets.HIGH_QUALITY,
                    isMeteringEnabled: true,
                };
                const nextRecording = new Audio.Recording();
                (nextRecording as any).setOnRecordingStatusUpdate?.(handleRecordingStatusUpdate);
                (nextRecording as any).setProgressUpdateInterval?.(VAD_UPDATE_INTERVAL_MS);

                await nextRecording.prepareToRecordAsync(recordingOptions);
                if (pendingStopAfterStartRef.current) {
                    await safelyReleaseRecording(nextRecording);
                    return;
                }

                await nextRecording.startAsync();
                if (pendingStopAfterStartRef.current) {
                    await safelyReleaseRecording(nextRecording);
                    return;
                }

                recordingRef.current = nextRecording;
                globalPreparedRecording = nextRecording;

                setIsRecording(true);
                startRecordingTicker();
                dragX.value = 0;
                dragY.value = 0;
                if (restoreKeyboardAfterStart) {
                    if (keyboardRestoreTimerRef.current) clearTimeout(keyboardRestoreTimerRef.current);
                    keyboardRestoreTimerRef.current = setTimeout(() => inputRef.current?.focus(), 16);
                }
                void startNativeVad();

                // Notify backend
                if (activeChatId) sendRecording(activeChatId);
            });
        } catch (err) {
            console.error('Failed to start recording', err);
        } finally {
            isStartingRecordingRef.current = false;
        }
    }, [
        haptic,
        activeChatId,
        sendRecording,
        recordingMode,
        handleRecordingStatusUpdate,
        startNativeVad,
        cameraPermission?.granted,
        micPermission?.granted,
        requestCameraPermission,
        requestMicPermission,
        vadLevel,
        inputRef,
        startRecordingTicker,
        isRecording,
    ]);

    const stopRecording = useCallback(async (canceled = false) => {
        if (isStoppingRecordingRef.current) return;
        if (isStartingRecordingRef.current) {
            pendingStopAfterStartRef.current = true;
        }
        isStoppingRecordingRef.current = true;
        const hadActiveRecording =
            Boolean(recordingRef.current) ||
            Boolean(globalPreparedRecording) ||
            isRecording ||
            isStartingRecordingRef.current;

        setRecordingCanceled(canceled);
        setIsRecording(false);
        setIsLocked(false);
        dragX.value = withSpring(0);
        dragY.value = withSpring(0);
        stopRecordingTicker();
        vadSmoothingRef.current = 0;
        vadLevel.value = withTiming(0, { duration: 120 });
        await stopNativeVad();

        let uri: string | null = null;

        try {
            await withGlobalRecordingOperation(async () => {
                const activeRecording = recordingRef.current || globalPreparedRecording;
                if (activeRecording) {
                    try {
                        uri = activeRecording.getURI() ?? null;
                    } catch {
                        uri = null;
                    }
                    await safelyReleaseRecording(activeRecording);
                    if (recordingRef.current === activeRecording) {
                        recordingRef.current = null;
                    }
                    if (globalPreparedRecording === activeRecording) {
                        globalPreparedRecording = null;
                    }
                }
                try {
                    await Audio.setAudioModeAsync({
                        allowsRecordingIOS: false,
                        playsInSilentModeIOS: true,
                    });
                } catch { }
            });

            // Notify backend
            if (hadActiveRecording && activeChatId) sendStopRecording(activeChatId);

            if (!canceled && uri) {
                haptic.success();
                onAttach?.({ type: 'file', uri, name: 'Voice Message.m4a', mimeType: 'audio/m4a', duration: recordingDuration });
            } else if (hadActiveRecording) {
                haptic.light();
                // Play delete animation
                lottieRef.current?.play();
            }
        } catch (err) {
            console.warn('Failed to stop recording', err);
        } finally {
            pendingStopAfterStartRef.current = false;
            isStoppingRecordingRef.current = false;
        }
    }, [haptic, onAttach, recordingDuration, activeChatId, sendStopRecording, stopNativeVad, stopRecordingTicker, vadLevel, isRecording]);

    const lockRecording = useCallback(() => {
        haptic.heavy();
        setIsLocked(true);
        dragX.value = withSpring(0);
        dragY.value = withSpring(0);
    }, [haptic]);

    // === GESTURE HANDLER ===
    const recordGesture = Gesture.Pan()
        .activateAfterLongPress(HOLD_TO_RECORD_DELAY_MS) // Faster hold-to-record
        .minDistance(0) // Activate immediately after long-press delay
        .onStart(() => {
            runOnJS(startRecording)();
        })
        .onUpdate((e) => {
            // Only allow negative X (left) and negative Y (up)
            dragX.value = Math.min(0, e.translationX);
            dragY.value = Math.min(0, e.translationY);
        })
        .onEnd((e) => {
            if (e.translationX < -CANCEL_DISTANCE) {
                runOnJS(stopRecording)(true); // Cancel
            } else if (e.translationY < LOCK_DISTANCE) {
                runOnJS(lockRecording)();
            } else {
                runOnJS(stopRecording)(false); // Send
            }
        });

    // === ANIMATED STYLES ===

    // Attach button - hides when recording or expanded
    const attachContainerStyle = useAnimatedStyle(() => {
        const hideForExpand = interpolate(combinedExpandProgress.value, [0, 1], [1, 0], Extrapolate.CLAMP);
        return {
            opacity: hideForExpand,
            transform: [{ scale: hideForExpand }],
        };
    });

    // Input bar expands when recording
    const inputBarStyle = useAnimatedStyle(() => {
        return {
            flex: 1
        };
    });

    // Recording overlay inside input bar (kept mounted; only animated in/out)
    const recordingOverlayStyle = useAnimatedStyle(() => ({
        opacity: recordingProgress.value,
        transform: [{ translateY: interpolate(recordingProgress.value, [0, 1], [10, 0], Extrapolate.CLAMP) }]
    }));

    // Normal input content fades out when recording (no position switching to avoid flicker)
    const inputContentStyle = useAnimatedStyle(() => ({
        opacity: interpolate(recordingProgress.value, [0, 0.5], [1, 0], Extrapolate.CLAMP),
    }));

    // Mic button container - hides when typing, but shows when recording
    const micContainerStyle = useAnimatedStyle(() => {
        const p = typingProgress.value;
        return {
            width: interpolate(p, [0, 1], [44, 0], Extrapolate.CLAMP),
            marginLeft: interpolate(p, [0, 1], [6, 0], Extrapolate.CLAMP),
            opacity: interpolate(p, [0, 1], [1, 0], Extrapolate.CLAMP),
            transform: [{ scale: 1 }],
        };
    });

    const rowPaddingStyle = useAnimatedStyle(() => {
        const kb = keyboardProgress ? keyboardProgress.value : focusProgress.value;
        const basePad = interpolate(kb, [0, 1], [INPUT_SIDE_PADDING_CLOSED, INPUT_SIDE_PADDING_OPEN], Extrapolate.CLAMP);
        const recordingPad = interpolate(kb, [0, 1], [INPUT_SIDE_PADDING_RECORDING_CLOSED, INPUT_SIDE_PADDING_RECORDING_OPEN], Extrapolate.CLAMP);
        const pad = basePad + (recordingPad - basePad) * recordingProgress.value;
        return {
            paddingHorizontal: pad,
        };
    });

    // Mic frame stays stable; glass itself performs the small -> expanded transition.
    const micFrameStyle = useAnimatedStyle(() => {
        return {
            width: MIC_BUTTON_SIZE,
            height: MIC_BUTTON_SIZE,
            left: 0,
            top: 0,
            position: 'absolute',
        };
    });

    const micGlassMotionStyle = useAnimatedStyle(() => {
        const kb = keyboardProgress ? keyboardProgress.value : focusProgress.value;
        const safeLift = interpolate(kb, [0, 1], [-8, 0], Extrapolate.CLAMP) * recordingProgress.value;
        const safeLeft = interpolate(kb, [0, 1], [-4, 0], Extrapolate.CLAMP) * recordingProgress.value;
        const expandScale = interpolate(
            recordingProgress.value,
            [0, 1],
            [1, MIC_BUTTON_RECORDING_SIZE / MIC_BUTTON_SIZE],
            Extrapolate.CLAMP
        );
        const followX = interpolate(-dragX.value, [0, CANCEL_DISTANCE], [0, -5], Extrapolate.CLAMP);
        const followY = interpolate(-dragY.value, [0, Math.abs(LOCK_DISTANCE)], [0, -5], Extrapolate.CLAMP);
        const translateX = followX + safeLeft;
        const translateY = followY + safeLift;

        return {
            transform: [
                { translateX },
                { translateY },
                { scale: micPressScale.value * expandScale },
            ]
        };
    });

    const metallicStripStyle = useAnimatedStyle(() => {
        const active = recordingProgress.value;
        const voice = vadLevel.value;
        const breathe = interpolate(micAuraPhase.value, [0, 1], [0.98, 1.02], Extrapolate.CLAMP);
        return {
            opacity: interpolate(active, [0, 1], [0, 0.96], Extrapolate.CLAMP),
            transform: [
                { translateY: interpolate(active, [0, 1], [18, 0], Extrapolate.CLAMP) },
                { scaleY: (0.95 + (voice * 0.12)) * breathe },
            ]
        };
    });

    const metallicSheenStyle = useAnimatedStyle(() => {
        const active = recordingProgress.value;
        const voice = vadLevel.value;
        const drift = interpolate(micAuraPhase.value, [0, 1], [-26, 26], Extrapolate.CLAMP);
        return {
            opacity: interpolate(active, [0, 1], [0, 1], Extrapolate.CLAMP) * (0.55 + (voice * 0.45)),
            transform: [
                { translateX: drift + (voice * 10) }
            ]
        };
    });

    const cancelSwipeProgress = useDerivedValue(() => {
        return interpolate(-dragX.value, [0, CANCEL_DISTANCE], [0, 1], Extrapolate.CLAMP);
    });

    const lockDragProgress = useDerivedValue(() => {
        return interpolate(-dragY.value, [0, Math.abs(LOCK_DISTANCE)], [0, 1], Extrapolate.CLAMP);
    });

    const cancelBlobLeadRadius = useDerivedValue(() => {
        return 4.8 + cancelSwipeProgress.value * 2.8;
    });

    const cancelBlobTrailRadius = useDerivedValue(() => {
        return 3 + cancelSwipeProgress.value * 2.2;
    });

    const cancelBlobTrailX = useDerivedValue(() => {
        return 7.5 + cancelSwipeProgress.value * 9;
    });

    // Lock pill indicator above mic
    const lockPillStyle = useAnimatedStyle(() => {
        const progressScale = interpolate(recordingProgress.value, [0, 1], [0, 1], Extrapolate.CLAMP);
        // Only use scale for visibility, no opacity
        const scale = progressScale * (isLocked ? 0 : 1);

        const lockBounce = interpolate(lockDragProgress.value, [0, 1], [0.9, 1.1], Extrapolate.CLAMP);

        return {
            transform: [
                { scale: scale * lockBounce },
                { translateY: interpolate(lockDragProgress.value, [0, 1], [0, -10], Extrapolate.CLAMP) }
            ],
            // Dynamic absolute bottom positioning relative to container (to stay above growing circle)
            // Interpolate from near container (50) to high up (130) as circle grows
            bottom: interpolate(recordingProgress.value, [0, 1], [50, 130], Extrapolate.CLAMP)
        };
    }, [isLocked, lockDragProgress]);

    const lockHintGroupStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: interpolate(arrowUpAnim.value, [0, 1], [0, -4], Extrapolate.CLAMP) }]
    }));

    const lockClosedIconStyle = useAnimatedStyle(() => {
        const p = lockDragProgress.value;
        const pulse = interpolate(arrowUpAnim.value, [0, 1], [0.96, 1.04], Extrapolate.CLAMP);
        return {
            opacity: interpolate(p, [0, 1], [1, 0], Extrapolate.CLAMP),
            transform: [{ scale: pulse }]
        };
    });

    const lockOpenIconStyle = useAnimatedStyle(() => {
        const p = lockDragProgress.value;
        return {
            opacity: interpolate(p, [0, 1], [0, 1], Extrapolate.CLAMP),
            transform: [
                { translateY: interpolate(p, [0, 1], [3, -1], Extrapolate.CLAMP) },
                { rotate: `${interpolate(p, [0, 1], [0, -14], Extrapolate.CLAMP)}deg` },
            ]
        };
    });

    // Animated up arrow for lock indicator
    const lockArrowStyle = useAnimatedStyle(() => {
        const bounce = interpolate(arrowUpAnim.value, [0, 1], [0, -8], Extrapolate.CLAMP);
        const scale = interpolate(arrowUpAnim.value, [0, 0.5, 1], [0.94, 1.08, 0.94], Extrapolate.CLAMP);
        return {
            transform: [{ translateY: bounce }, { scale }]
        };
    });

    const slideHintStyle = useAnimatedStyle(() => {
        const pulse = interpolate(arrowLeftAnim.value, [0, 1], [0.98, 1.02], Extrapolate.CLAMP);
        return {
            transform: [{ translateX: -8 }, { scale: pulse }],
        };
    });

    // Red dot transforms to delete bin as you drag left
    const redDotStyle = useAnimatedStyle(() => {
        const progress = interpolate(-dragX.value, [0, CANCEL_DISTANCE * 0.5], [0, 1], Extrapolate.CLAMP);
        return {
            transform: [
                { scale: interpolate(progress, [0, 1], [1, 1.5], Extrapolate.CLAMP) },
                { rotate: `${interpolate(progress, [0, 1], [0, 18])}deg` },
                { translateX: interpolate(progress, [0, 1], [0, 4], Extrapolate.CLAMP) }
            ]
        };
    });

    // Delete icon appears as dot fades
    const deleteIconStyle = useAnimatedStyle(() => {
        const progress = interpolate(-dragX.value, [CANCEL_DISTANCE * 0.3, CANCEL_DISTANCE * 0.6], [0, 1], Extrapolate.CLAMP);
        return {
            transform: [
                { scale: interpolate(progress, [0, 1], [0.5, 1.2], Extrapolate.CLAMP) }
            ]
        };
    });

    // Delete bin animation opacity
    const deleteBinStyle = useAnimatedStyle(() => {
        const progress = interpolate(-dragX.value, [CANCEL_DISTANCE * 0.5, CANCEL_DISTANCE], [0, 1], Extrapolate.CLAMP);

        return {
            transform: [{ scale: interpolate(progress, [0, 1], [0.5, 1.2], Extrapolate.CLAMP) }]
        };
    });



    // Keep input width stable; animate icons only.
    const inputInnerStyle = useAnimatedStyle(() => {
        return {
            paddingRight: 0
        };
    });

    const rightActionsStyle = useAnimatedStyle(() => {
        return {
            opacity: 1,
            transform: [{ scale: 1 }],
        };
    });

    const cameraFadeStyle = useAnimatedStyle(() => {
        const p = typingProgress.value;
        return {
            opacity: interpolate(p, [0, 1], [1, 0], Extrapolate.CLAMP),
            transform: [{ scale: 1 }],
        };
    });

    const rightSlotStyle = useAnimatedStyle(() => ({ width: 84 }));

    const sendButtonStyle = useAnimatedStyle(() => {
        const p = typingProgress.value;
        return {
            opacity: interpolate(p, [0.3, 1], [0, 1], Extrapolate.CLAMP),
            width: 32,
            transform: [
                { translateX: interpolate(p, [0, 1], [6, 0], Extrapolate.CLAMP) },
                { scale: interpolate(p, [0, 1], [0.85, 1], Extrapolate.CLAMP) },
            ],
        };
    });

    // Reply header style
    const replyHeaderStyle = useAnimatedStyle(() => ({
        height: interpolate(replyExpandProgress.value, [0, 1], [0, 48], Extrapolate.CLAMP),
        opacity: replyExpandProgress.value,
        overflow: 'hidden' as const
    }));

    // Vibe header style
    const vibeHeaderStyle = useAnimatedStyle(() => ({
        height: interpolate(vibeExpandProgress.value, [0, 1], [0, 48], Extrapolate.CLAMP),
        opacity: vibeExpandProgress.value,
        overflow: 'hidden' as const
    }));


    // === HELPER FUNCTIONS ===

    const handleTextChange = useCallback((newText: string) => {
        setText(newText);

        if (isVibeActive) {
            setShowVibeSuggestion(false);
            return;
        }

        const lastAtIndex = newText.lastIndexOf('@');
        if (lastAtIndex !== -1) {
            const afterAt = newText.slice(lastAtIndex + 1).toLowerCase();
            if ((lastAtIndex === 0 || newText[lastAtIndex - 1] === ' ') && !afterAt.includes(' ')) {
                if ('vibe'.startsWith(afterAt) || afterAt === '') {
                    setShowVibeSuggestion(true);
                    return;
                }
            }
        }
        setShowVibeSuggestion(false);
    }, [setText, isVibeActive]);

    useEffect(() => {
        const nextTyping = (text?.trim().length || 0) > 0;
        if (nextTyping !== lastTypingStatusRef.current) {
            lastTypingStatusRef.current = nextTyping;
            typingProgress.value = withTiming(nextTyping ? 1 : 0, {
                duration: 90,
                easing: Easing.out(Easing.quad),
            });
            onTypingStatusChange?.(nextTyping);
        }
    }, [text, typingProgress, onTypingStatusChange]);

    const handleVibeSelect = useCallback(() => {
        haptic.selection();
        setIsVibeActive(true);
        setText('');
        setShowVibeSuggestion(false);
        inputRef.current?.focus();
    }, [setText, haptic]);

    const handleCancelVibe = useCallback(() => {
        haptic.light();
        setIsVibeActive(false);
        setShowVibeSuggestion(false);
    }, [haptic]);

    const handleCancelReply = useCallback(() => {
        haptic.light();
        if (onCancelReply) {
            onCancelReply();
        }
    }, [onCancelReply, haptic]);

    const handleSend = useCallback(() => {
        if (!text.trim()) return;

        haptic.light();

        if (isVibeActive) {
            if (onVibeQuery) onVibeQuery(text);
            setText('');
        } else {
            // Fire send immediately
            onSend();

            // Clear text immediately only if not handled manually
            if (!manualClear) {
                setText('');
            }
        }
    }, [isVibeActive, text, onVibeQuery, onSend, setText, haptic, manualClear]);

    const handleInputFocus = useCallback(() => {
        isInputFocusedRef.current = true;
        focusProgress.value = withTiming(1, { duration: 170, easing: SMOOTH_EASING });
        onInputFocus?.();
    }, [focusProgress, onInputFocus]);

    const handleInputBlur = useCallback(() => {
        isInputFocusedRef.current = false;
        focusProgress.value = withTiming(0, { duration: 170, easing: SMOOTH_EASING });
    }, [focusProgress]);


    const handleAttachPress = useCallback(() => {
        haptic.light();
        setShowAttachmentMenu(true);
    }, [haptic]);

    // Toggle between voice and video recording mode
    const handleToggleRecordingMode = useCallback(() => {
        haptic.selection();
        setRecordingMode(prev => prev === 'voice' ? 'video' : 'voice');
    }, [haptic]);

    const handleMicPressIn = useCallback(() => {
        micPressScale.value = withTiming(0.92, {
            duration: 90,
            easing: Easing.out(Easing.quad)
        });
    }, [micPressScale]);

    const handleMicPressOut = useCallback(() => {
        micPressScale.value = withTiming(1, {
            duration: 120,
            easing: Easing.out(Easing.quad)
        });
    }, [micPressScale]);

    const handleMetalStripLayout = useCallback((event: LayoutChangeEvent) => {
        const { width, height } = event.nativeEvent.layout;
        if (width <= 0 || height <= 0) return;
        if (Math.abs(width - metalStripSize.width) < 1 && Math.abs(height - metalStripSize.height) < 1) return;
        setMetalStripSize({ width, height });
    }, [metalStripSize.width, metalStripSize.height]);



    const getVibeHeader = () => {
        if (showVibeSuggestion && !isVibeActive) {
            return (
                <TouchableOpacity
                    style={styles.vibeSuggestionInline}
                    onPress={handleVibeSelect}
                    activeOpacity={0.7}
                >
                    <View style={[styles.vibeIconSmall, { backgroundColor: withAlpha(colors.primary, 0.15) }]}>
                        <Sparkles size={14} color={colors.primary} />
                    </View>
                    <Text style={[styles.vibeSuggestionText, { color: colors.primary }]}>@vibe</Text>
                    <Text style={[styles.vibeSuggestionDesc, { color: colors.textSecondary }]}>Ask AI</Text>
                </TouchableOpacity>
            );
        }

        if (isVibeActive) {
            return (
                <View style={styles.expandedHeaderContent}>
                    <View style={[styles.replyIndicator, { backgroundColor: colors.primary }]} />
                    <View style={styles.expandedHeaderText}>
                        <Text style={[styles.expandedLabel, { color: colors.primary }]}>
                            Ask Vibe
                        </Text>
                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                            <TouchableOpacity onPress={() => setShowAttachmentMenu(true)} style={styles.actionBtn}>
                                <Plus size={24} color={colors.text} />
                            </TouchableOpacity>
                        </View>
                    </View>
                    <TouchableOpacity onPress={handleCancelVibe} style={styles.expandedClose}>
                        <X size={20} color={colors.textSecondary} />
                    </TouchableOpacity>
                </View>
            );
        }

        return null;
    };

    return (
        <View style={styles.wrapper}>
            <View style={styles.container}>
                <AnimatedView style={[styles.row, rowPaddingStyle]}>
                    <AnimatedView style={[styles.singleRowHost, inputBarStyle]}>
                        <SafeLiquidGlass
                            style={[
                                styles.singleRowGlass,
                                isExpanded && { borderWidth: 1, borderColor: withAlpha(colors.primary, 0.25) }
                            ]}
                            blurIntensity={15}
                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        >
                            {replyTo && (
                                <AnimatedView style={replyHeaderStyle}>
                                    <View style={styles.replyHeaderContent}>
                                        <View style={[styles.replyIndicator, { backgroundColor: colors.primary }]} />
                                        <View style={styles.replyHeaderText}>
                                            <Text style={[styles.replyToLabel, { color: colors.primary }]} numberOfLines={1}>
                                                {replyTo.userName}
                                            </Text>
                                            <Text style={[styles.replyMessageContent, { color: colors.textSecondary }]} numberOfLines={1}>
                                                {replyTo.content}
                                            </Text>
                                        </View>
                                        <TouchableOpacity onPress={handleCancelReply} style={styles.replyCloseBtn}>
                                            <X size={18} color={colors.textSecondary} />
                                        </TouchableOpacity>
                                    </View>
                                </AnimatedView>
                            )}

                            {!replyTo && (showVibeSuggestion || isVibeActive) && (
                                <AnimatedView style={vibeHeaderStyle}>
                                    {getVibeHeader()}
                                </AnimatedView>
                            )}

                            <View style={styles.singleRowContent}>
                                <AnimatedView style={attachContainerStyle}>
                                    <TouchableOpacity onPress={handleAttachPress} style={styles.inlineActionBtn} activeOpacity={0.75}>
                                        <AttachmentIcon size={20} color={colors.text} />
                                    </TouchableOpacity>
                                </AnimatedView>

                                <AnimatedView style={[styles.singleInputHost, inputInnerStyle]}>
                                    {isRecording ? (
                                        <View style={styles.recordingInlineRow}>
                                            <View style={styles.recordingDot} />
                                            <Text style={[styles.recordingTimeText, { color: colors.text }]}>
                                                {formatDuration(recordingElapsedMs)}
                                            </Text>
                                            <Text style={[styles.recordingHintText, { color: withAlpha(colors.text, 0.58) }]}>
                                                {isLocked ? 'Tap mic to send' : 'Slide left to cancel'}
                                            </Text>
                                        </View>
                                    ) : (
                                        <TextInput
                                            ref={inputRef}
                                            style={[styles.input, { color: colors.text }]}
                                            placeholder={isVibeActive ? "Ask anything..." : (replyTo ? "Reply..." : "Message")}
                                            placeholderTextColor={colors.textSecondary || '#9896A8'}
                                            value={text}
                                            onChangeText={handleTextChange}
                                            onFocus={handleInputFocus}
                                            onBlur={handleInputBlur}
                                            multiline
                                            maxLength={2000}
                                        />
                                    )}
                                </AnimatedView>

                                <AnimatedView style={[styles.inlineRightSlot, rightSlotStyle]}>
                                    <AnimatedView
                                        pointerEvents={isRecording ? 'none' : 'auto'}
                                        style={[styles.rightToolsRow, rightActionsStyle]}
                                    >
                                        {onGif && !isRecording && (
                                            <TouchableOpacity onPress={onGif} style={styles.inlineActionBtn} activeOpacity={0.75}>
                                                <AnimatedGifToSmileIcon progress={typingProgress} size={24} color={colors.text} />
                                            </TouchableOpacity>
                                        )}
                                        {onCamera && !isRecording && (
                                            <AnimatedView style={cameraFadeStyle}>
                                                <TouchableOpacity
                                                    onPress={onCamera}
                                                    style={[styles.cameraPill, { backgroundColor: isVibeActive ? colors.primary : (resolvedTheme.bubbleMe || colors.primary) }]}
                                                    activeOpacity={0.75}
                                                >
                                                    <Camera size={16} color="#fff" />
                                                </TouchableOpacity>
                                            </AnimatedView>
                                        )}
                                    </AnimatedView>

                                    <AnimatedView
                                        pointerEvents={text.trim().length > 0 && !isRecording ? 'auto' : 'none'}
                                        style={[styles.sendFloating, sendButtonStyle]}
                                    >
                                        <Pressable
                                            onPress={handleSend}
                                            style={[styles.sendBtn, { backgroundColor: isVibeActive ? colors.primary : (resolvedTheme.bubbleMe || colors.primary) }]}
                                        >
                                            <SendFilledIcon size={18} color="#fff" />
                                        </Pressable>
                                    </AnimatedView>
                                </AnimatedView>
                            </View>
                        </SafeLiquidGlass>
                    </AnimatedView>

                    <AnimatedView pointerEvents={text.trim().length > 0 && !isRecording ? 'none' : 'auto'} style={[styles.inlineMicSlot, micContainerStyle]}>
                        <GestureDetector gesture={recordGesture}>
                            <View style={styles.micGestureHost} collapsable={false}>
                                <AnimatedView style={[styles.micBtnScalable, micFrameStyle]}>
                                    <Pressable
                                        onPress={isRecording ? undefined : handleToggleRecordingMode}
                                        onPressIn={handleMicPressIn}
                                        onPressOut={handleMicPressOut}
                                        style={styles.micPressable}
                                    >
                                        <AnimatedView
                                            style={[
                                                styles.micGlassShell,
                                                micGlassMotionStyle,
                                                isRecording
                                                    ? { backgroundColor: withAlpha(bubbleTone, 0.22) }
                                                    : {
                                                        backgroundColor: effectiveTheme === 'dark'
                                                            ? 'rgba(24,24,28,0.82)'
                                                            : 'rgba(255,255,255,0.86)',
                                                    }
                                            ]}
                                        >
                                            <SafeLiquidGlass
                                                style={styles.micGlassFill}
                                                blurIntensity={15}
                                                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                            >
                                                <View style={styles.touchArea}>
                                                    {isRecording ? (
                                                        isLocked ? (
                                                            <Pressable onPress={() => stopRecording(false)} style={styles.touchArea}>
                                                                <ArrowUp size={24} color="#fff" strokeWidth={2.5} />
                                                            </Pressable>
                                                        ) : (
                                                            recordingMode === 'video'
                                                                ? <VideoIcon size={22} color="#fff" />
                                                                : <Mic size={22} color="#fff" />
                                                        )
                                                    ) : (
                                                        recordingMode === 'video'
                                                            ? <VideoIcon size={20} color={bubbleTone} />
                                                            : <Mic size={20} color={colors.text} />
                                                    )}
                                                </View>
                                            </SafeLiquidGlass>
                                        </AnimatedView>
                                    </Pressable>
                                </AnimatedView>
                            </View>
                        </GestureDetector>
                    </AnimatedView>
                </AnimatedView>
            </View >

            <AttachmentMenu
                visible={showAttachmentMenu}
                onClose={() => setShowAttachmentMenu(false)}
                onSelectImage={(uri, w, h) => onAttach?.({ type: 'image', uri, width: w, height: h })}
                onSelectFile={(uri, name) => onAttach?.({ type: 'file', uri, name })}
                onSelectLocation={(coords) => onAttach?.({ type: 'location', ...coords })}
                onSelectContact={(contact) => onAttach?.({ type: 'contact', contact })}
                onSelectImages={(items) => {
                    // Batch send without preview
                    for (const item of items) {
                        onAttach?.({ type: 'image', uri: item.uri, width: item.width, height: item.height });
                    }
                    setShowAttachmentMenu(false);
                }}
                onOpenPreview={(items) => {
                    setPreviewImages(items.map(i => ({ uri: i.uri, width: i.width, height: i.height })));
                    setShowImagePreview(true);
                    setShowAttachmentMenu(false);
                }}
            />

            <ImagePreviewEditor
                visible={showImagePreview}
                images={previewImages}
                onClose={() => {
                    setShowImagePreview(false);
                    setPreviewImages([]);
                }}
                onSend={(results) => {
                    for (const r of results) {
                        onAttach?.({
                            type: 'image',
                            uri: r.uri,
                            width: r.width,
                            height: r.height,
                            caption: r.caption,
                            hdMode: r.hdMode,
                        });
                    }
                    setShowImagePreview(false);
                    setPreviewImages([]);
                }}
            />

            <VideoNoteOverlay
                visible={isRecording && recordingMode === 'video'}
                onVideoRecorded={(file) => {
                    // Only attach if not canceled
                    if (!recordingCanceled) {
                        onAttach?.({
                            type: 'videoNote',
                            uri: file.uri,
                            duration: file.duration
                        });
                    }
                }}
            />
        </View >
    );
});

export default ChatInput;

const styles = StyleSheet.create({
    wrapper: {
        width: '100%',
        position: 'relative',
        overflow: 'visible'
    },
    container: { width: '100%', overflow: 'visible' },
    row: { flexDirection: 'row', alignItems: 'flex-end', paddingHorizontal: 0, overflow: 'visible' },
    singleRowHost: { flex: 1, overflow: 'visible' },
    singleRowGlass: {
        borderRadius: 22,
        overflow: 'visible',
        minHeight: 42,
        justifyContent: 'center',
        paddingHorizontal: 6,
        paddingVertical: 1,
    },
    singleRowContent: {
        minHeight: 38,
        flexDirection: 'row',
        alignItems: 'center',
        overflow: 'visible',
    },
    inlineActionBtn: {
        width: 36,
        height: 36,
        alignItems: 'center',
        justifyContent: 'center',
        marginBottom: 2,
    },
    singleInputHost: {
        flex: 1,
        minHeight: 38,
        justifyContent: 'center',
    },
    inlineRightSlot: {
        width: 112,
        height: 38,
        marginLeft: 4,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'visible',
    },
    rightToolsRow: {
        position: 'absolute',
        right: 0,
        top: 0,
        bottom: 0,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-end',
    },
    sendFloating: {
        position: 'absolute',
        right: 6,
        top: 3,
        width: 32,
        height: 32,
        alignItems: 'center',
        justifyContent: 'center',
    },
    cameraPill: {
        width: 32,
        height: 32,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center',
        marginLeft: 2,
        marginRight: 2,
    },
    inlineMicSlot: {
        width: 44,
        height: 44,
        marginLeft: 6,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'visible',
    },
    recordingInlineRow: {
        minHeight: 40,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 8,
    },
    recordingDot: {
        width: 8,
        height: 8,
        borderRadius: 4,
        backgroundColor: '#ef4444',
        marginRight: 8,
    },
    recordingTimeText: {
        fontSize: 14,
        fontWeight: '600',
        marginRight: 10,
        fontVariant: ['tabular-nums'],
    },
    recordingHintText: {
        fontSize: 12,
        flexShrink: 1,
    },
    attachBtnWrapper: { marginRight: 0, overflow: 'hidden' },
    circleBtn: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden' },
    touchable: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center', position: 'relative' },
    iconAbsolute: { position: 'absolute' },
    touchArea: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center' },
    micPressable: { width: '100%', height: '100%', borderRadius: 9999, overflow: 'hidden' },
    micGlassShell: {
        width: '100%',
        height: '100%',
        borderRadius: 9999,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    micGlassFill: {
        width: '100%',
        height: '100%',
        borderRadius: 9999,
        overflow: 'hidden'
    },
    inputGlass: { borderRadius: 22, overflow: 'hidden', minHeight: 44, justifyContent: 'center' },
    metalStripContainer: {
        position: 'absolute',
        left: -6,
        right: -6,
        bottom: -10,
        height: METALLIC_STRIP_HEIGHT,
        zIndex: 1,
        overflow: 'hidden'
    },
    metalStripCanvas: {
        width: '100%',
        height: '100%'
    },
    metalSheenLayer: {
        position: 'absolute',
        left: -12,
        top: 0,
        bottom: 0,
        width: METALLIC_SHEEN_WIDTH,
    },
    metalSheenCanvas: {
        width: '100%',
        height: '100%'
    },

    // Recording UI inside input bar
    recordingUI: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16,
        height: 44,
        position: 'absolute',
        left: 0,
        right: 0,
        top: 0,
        zIndex: 4
    },
    inputContentLayer: {
        position: 'relative',
        zIndex: 2
    },
    recordingLeft: {
        position: 'absolute',
        left: 16,
        flexDirection: 'row',
        alignItems: 'center',
        zIndex: 10
    },
    centeredCancelContainer: {
        flex: 1,
        alignItems: 'flex-start',
        justifyContent: 'center'
    },
    redDotFluid: {
        width: 18,
        height: 22,
        marginRight: 10,
        alignItems: 'center',
        justifyContent: 'center'
    },
    redDotCanvas: {
        width: '100%',
        height: '100%'
    },
    recTime: {
        fontSize: 17,
        fontWeight: '600',
        fontVariant: ['tabular-nums']
    },
    slideToCancel: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingLeft: 10
    },
    slideCancelText: {
        fontSize: 15,
        fontWeight: '400',
        marginLeft: 4
    },
    cancelText: {
        fontSize: 16,
        fontWeight: '600'
    },

    // Floating mic button container
    floatingContainer: {
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 0,
        top: -200,
        zIndex: 1000,
        alignItems: 'flex-end',
        justifyContent: 'flex-end',
        paddingRight: 16,
        paddingBottom: 60
    },
    floatingMicBtn: {
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.3,
        shadowRadius: 8,
        elevation: 10
    },
    floatingMicInner: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center'
    },

    // Lock pill
    lockPill: {
        position: 'absolute',
        right: 46,
        bottom: 180,
        width: 48,
        height: 80,
        borderRadius: 24,
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 12
    },

    // Delete bin
    deleteBin: {
        position: 'absolute',
        left: 20,
        bottom: 80
    },

    // Pause button when locked
    pauseButtonContainer: {
        position: 'absolute',
        right: 80,
        bottom: 140,
        zIndex: 1001
    },
    pauseButton: {
        width: 48,
        height: 48,
        borderRadius: 24,
        alignItems: 'center',
        justifyContent: 'center'
    },

    // Mic container - holds the scalable button, overflow visible for scaling
    micContainer: {
        overflow: 'visible',
        width: 44,
        height: 44,
        marginLeft: 8,
        zIndex: 1000,
        alignItems: 'center',
        justifyContent: 'center'
    },
    micGestureHost: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'visible'
    },

    // Scalable mic button - grows when recording
    micBtnScalable: {
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'visible',
        // Shadow is handled by parent or internal glass if needed, but glass usually doesn't shadow well without a wrapper
    },

    // Lock pill positioned above the mic button
    lockPillAbove: {
        position: 'absolute',
        // Bottom is dynamically set in animation
        alignSelf: 'center',
        zIndex: 10
    },
    lockPillInner: {
        width: 44,
        height: 72,
        borderRadius: 22,
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 10,
        overflow: 'hidden'
    },
    lockHintGroup: {
        alignItems: 'center',
        justifyContent: 'center'
    },
    lockIconStack: {
        width: 22,
        height: 22,
        alignItems: 'center',
        justifyContent: 'center'
    },
    lockIconLayer: {
        position: 'absolute',
        alignItems: 'center',
        justifyContent: 'center'
    },



    // Expanded header (vibe active mode)
    expandedHeaderContent: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingTop: 10,
        paddingBottom: 6,
        height: 48
    },
    replyIndicator: {
        width: 3,
        height: 28,
        borderRadius: 2,
        marginRight: 10
    },
    expandedHeaderText: {
        flex: 1
    },
    expandedLabel: {
        fontSize: 14,
        fontWeight: '600'
    },
    expandedHandle: {
        fontSize: 12,
        marginTop: 1
    },
    expandedClose: {
        padding: 4
    },

    // Reply header
    replyHeaderContent: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingTop: 8,
        paddingBottom: 4,
        height: 48
    },
    replyHeaderText: {
        flex: 1
    },
    replyToLabel: {
        fontSize: 13,
        fontWeight: '600'
    },
    replyMessageContent: {
        fontSize: 13,
        marginTop: 2
    },
    replyCloseBtn: {
        padding: 6
    },

    // Vibe suggestion inline
    vibeSuggestionInline: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingVertical: 10,
        height: 48
    },
    vibeIconSmall: {
        width: 28,
        height: 28,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 8
    },
    vibeSuggestionText: {
        fontSize: 15,
        fontWeight: '600',
        marginRight: 8
    },
    vibeSuggestionDesc: {
        fontSize: 13
    },

    // Input area
    // Input area
    inputFlexContainer: { flexDirection: 'row', alignItems: 'flex-end', width: '100%' },
    inputInner: { flex: 1, flexDirection: 'row', alignItems: 'flex-end' },
    input: { flex: 1, minHeight: 38, fontSize: 16, lineHeight: 20, paddingHorizontal: 10, paddingTop: 8, paddingBottom: 8, maxHeight: 120 },
    // Absolute positioning for actions to prevent flex jitters
    inputActions: {
        position: 'absolute',
        right: 0,
        bottom: 0,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-end',
        paddingRight: 4,
    },
    actionBtn: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    sendBtn: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
});
