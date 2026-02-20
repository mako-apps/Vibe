import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import {
    View,
    Text,
    StyleSheet,
    TouchableOpacity,
    Platform,
    FlatList,
    InteractionManager,
    Image,
} from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    useDerivedValue,
    withTiming,
    Easing,
    runOnJS,
    interpolate,
    withRepeat,
    withSequence,
} from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import Constants, { ExecutionEnvironment } from 'expo-constants';
import { Check, CheckCheck, ChevronLeft, Reply, RotateCcw } from 'lucide-react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import Svg, { Path } from 'react-native-svg';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import { useLocalSearchParams, useRouter } from 'expo-router';
import * as ExpoCrypto from 'expo-crypto';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import SoundManager from '../src/lib/SoundManager';
import WallpaperBackground from '../src/components/chat/WallpaperBackground';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import ChatInput, { ReplyInfo } from '../src/components/chat/ChatInput';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';

// Match your real theme colors
const BUBBLE_TEXT_COLOR = '#fff';
const INPUT_TEXT_COLOR = '#fff';
const BUBBLE_RADIUS = 18;
const BUBBLE_PADDING_V = 7;
const BUBBLE_PADDING_H = 10;
const BUBBLE_MIN_WIDTH = 26;
const BUBBLE_TEXT_SIZE = 16;
const BUBBLE_TEXT_LINE_HEIGHT = 20;
const BUBBLE_TIME_SIZE = 10;
const BUBBLE_TIME_OPACITY = 0.7;
const BUBBLE_INNER_RADIUS = 5;
const CROSSFADE_TARGET_Y_OFFSET = 0;
const TYPING_MASK_WIDTH = 84;
const TYPING_SHIMMER_TRAVEL = 200;
const TYPING_SHIMMER_BAND_WIDTH = 120;
const GHOST_START_LEFT_INSET = 18;
const GHOST_START_RIGHT_INSET = 92;
const GHOST_INPUT_CLEAR_LIFTOFF_MS = 70;
const EMIT_TYPING_IN_TEST = true;
const MAX_RENDER_MESSAGES = 80;
const DEBUG_FLAG_ENABLED = '1';
const PERF_FRAME_DROP_MS = 28;
const PERF_HYDRATE_WARN_MS = 8;
const PERF_MERGE_WARN_MS = 6;
const PERF_SEQUENCE_WARN_MS = 4;
const PERF_SAMPLE_WINDOW_MS = 1600;
const PERF_IDLE_LOG_THRESHOLD_MS = 150;
const PERF_LOG_COOLDOWN_MS = 220;
const SEND_AFTER_GHOST_DELAY_MS = 90;
const isExpoGoRuntime = Constants.executionEnvironment === ExecutionEnvironment.StoreClient;
const TRACE_ESSENTIAL_EVENTS = new Set([
    'tap_send',
    'send_queued',
    'send_start',
    'send_resolved',
    'send_rejected',
    'ghost_complete',
    'ghost_overlay_cleared',
    'send_queue_flush_after_ghost',
]);
const TRACE_ESSENTIAL_PHASES = new Set(['TAP', 'SEND', 'GHOST', 'RUNTIME']);

type MessageType = 'text' | 'image' | 'video' | 'voice' | 'file' | 'gif' | 'sticker' | 'call';

interface BubbleShape {
    isMe: boolean;
    showTail: boolean;
    borderTopLeftRadius: number;
    borderTopRightRadius: number;
    borderBottomLeftRadius: number;
    borderBottomRightRadius: number;
}

interface BubbleThemeSpec {
    meGradient: [string, string];
    themSolid: string;
    meTextColor: string;
    themTextColor: string;
}

const resolveBubbleShape = (
    isMe: boolean,
    isSequenceStart: boolean,
    isSequenceEnd: boolean,
    messageType: MessageType,
): BubbleShape => {
    const shape: BubbleShape = {
        isMe,
        showTail: isSequenceEnd && messageType === 'text',
        borderTopLeftRadius: BUBBLE_RADIUS,
        borderTopRightRadius: BUBBLE_RADIUS,
        borderBottomLeftRadius: BUBBLE_RADIUS,
        borderBottomRightRadius: BUBBLE_RADIUS,
    };

    if (isMe) {
        if (!isSequenceStart) shape.borderTopRightRadius = BUBBLE_INNER_RADIUS;
        if (!isSequenceEnd) shape.borderBottomRightRadius = BUBBLE_INNER_RADIUS;
    } else {
        if (!isSequenceStart) shape.borderTopLeftRadius = BUBBLE_INNER_RADIUS;
        if (!isSequenceEnd) shape.borderBottomLeftRadius = BUBBLE_INNER_RADIUS;
    }

    return shape;
};

const tailBaseStyle = (isMe: boolean) => ({
    position: 'absolute' as const,
    bottom: 0,
    [isMe ? 'right' : 'left']: -28,
    width: 29,
    height: 29,
    zIndex: -1,
    transform: [
        { rotate: isMe ? '25deg' : '-25deg' },
        { scaleX: isMe ? 1 : -1 },
    ],
});

// ------------------------------------------------------------------
// Types
// ------------------------------------------------------------------
interface Message {
    id: string;
    text: string;
    type: MessageType;
    isMe: boolean;
    timestamp: string;
    fromId?: string;
    replyToId?: string;
    status?: string;
    isOptimistic?: boolean;
    isGhostHidden?: boolean;
}

interface PendingRealSend {
    messageId: string;
    chatId: string;
    text: string;
    replyToId?: string;
    tapAt: number;
    queuedAt: number;
}

interface PendingInputClear {
    messageId: string;
    text: string;
}

interface ReplyPreview {
    userName: string;
    content: string;
    isFromMe: boolean;
}

type SoundType = 'sent' | 'received';
const MaskedViewAny = MaskedView as any;

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

const formatUiTime = (timestamp: number | string | undefined) => {
    const t = typeof timestamp === 'number' ? timestamp : new Date(timestamp || Date.now()).getTime();
    return new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
};

const formatLastSeen = (timestamp?: number) => {
    if (!timestamp) return 'last seen recently';
    const then = new Date(timestamp);
    const now = new Date();
    const hhmm = then.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    const sameDay = then.toDateString() === now.toDateString();
    if (sameDay) return `last seen today at ${hhmm}`;
    return `last seen ${then.toLocaleDateString()} ${hhmm}`;
};

const getStoreMessageText = (m: any): string => {
    const text = m?.plaintext || m?.content || m?.text || '';
    if (typeof text === 'string' && text.trim().length > 0) return text;
    if (m?.type === 'image') return '📷 Photo';
    if (m?.type === 'video') return '🎥 Video';
    if (m?.type === 'voice') return '🎤 Voice';
    if (m?.type === 'file') return '📎 File';
    return 'Message';
};

const getParamValue = (value: unknown): string | null => {
    if (Array.isArray(value)) return typeof value[0] === 'string' ? value[0] : null;
    return typeof value === 'string' ? value : null;
};

const isUiCriticalPhase = (phase: string) => (
    phase === 'tap_send' ||
    phase === 'ghost_complete' ||
    phase === 'post_ghost'
);

// ------------------------------------------------------------------
// CROSSFADE OVERLAY — The Telegram Magic
//
// Key improvements:
// 1. Uses a single `progress` value (0→1) to drive everything
// 2. Ghost bubble matches real MessageBubble styling exactly
// 3. Position is measured from the real (hidden) bubble, not guessed
// 4. Smooth spring physics, no abrupt swap
// ------------------------------------------------------------------
interface CrossfadeOverlayProps {
    text: string;
    messageType: MessageType;
    status?: string;
    startX: number;
    startY: number;
    startWidth: number;
    startHeight: number;
    targetX: number;
    targetY: number;
    targetWidth: number;
    targetHeight: number;
    shape: BubbleShape;
    bubbleTheme: BubbleThemeSpec;
    onComplete: () => void;
}

const CrossfadeOverlay = ({
    text,
    messageType,
    status,
    timestamp,
    startX, startY, startWidth, startHeight,
    targetX, targetY, targetWidth, targetHeight,
    shape,
    bubbleTheme,
    onComplete,
}: CrossfadeOverlayProps & { timestamp: string }) => {
    // Single progress drives everything: 0 = at input, 1 = at bubble
    const progress = useSharedValue(0);

    useEffect(() => {
        // Match the smoother legacy mock timing profile.
        progress.value = withTiming(1, {
            duration: 350,
            easing: Easing.out(Easing.exp),
        }, (finished) => {
            if (finished) {
                runOnJS(onComplete)();
            }
        });
    }, []);

    const containerStyle = useAnimatedStyle(() => {
        const p = progress.value;
        const x = interpolate(p, [0, 1], [startX, targetX]);
        const y = interpolate(p, [0, 1], [startY, targetY]);
        const w = interpolate(p, [0, 1], [startWidth, targetWidth]);
        const h = interpolate(p, [0, 1], [startHeight, targetHeight]);

        return {
            position: 'absolute',
            left: x,
            top: y,
            width: w,
            height: h,
            zIndex: 9999,
        };
    });

    // Legacy mock fade windows for smoother handoff.
    const inputTextStyle = useAnimatedStyle(() => {
        const opacity = interpolate(progress.value, [0, 0.24], [1, 0], 'clamp');
        return { opacity };
    });

    const bubbleBgStyle = useAnimatedStyle(() => {
        const opacity = interpolate(progress.value, [0, 0.1, 0.4], [0, 0, 1], 'clamp');
        return { opacity };
    });

    const bubbleTextStyle = useAnimatedStyle(() => {
        const opacity = interpolate(progress.value, [0.06, 0.34], [0, 1], 'clamp');
        return { opacity };
    });

    const tailStyle = useAnimatedStyle(() => {
        const opacity = interpolate(progress.value, [0.12, 0.38], [0, 1], 'clamp');
        return { opacity };
    });

    const timestampStyle = useAnimatedStyle(() => {
        const opacity = interpolate(progress.value, [0.1, 0.36], [0, 1], 'clamp');
        return { opacity };
    });

    return (
        <Animated.View style={containerStyle} pointerEvents="none">
            {/* Bubble background */}
            <Animated.View style={[
                styles.crossfadeBubbleBg,
                {
                    borderTopLeftRadius: shape.borderTopLeftRadius,
                    borderTopRightRadius: shape.borderTopRightRadius,
                    borderBottomLeftRadius: shape.borderBottomLeftRadius,
                    borderBottomRightRadius: shape.borderBottomRightRadius,
                },
                bubbleBgStyle,
            ]}>
                {shape.isMe ? (
                    <LinearGradient
                        colors={bubbleTheme.meGradient}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 1 }}
                        style={StyleSheet.absoluteFillObject}
                    />
                ) : (
                    <View style={[StyleSheet.absoluteFillObject, { backgroundColor: bubbleTheme.themSolid }]} />
                )}
            </Animated.View>

            {/* Text container */}
            <View style={styles.crossfadeContent}>
                {/* Input-style text (fades out instantly) */}
                <Animated.View style={[styles.crossfadeInputText, inputTextStyle]}>
                    <Text style={styles.bubbleTextInput}>{text}</Text>
                </Animated.View>

                {/* Bubble-style text (visible from start) */}
                <Animated.View style={bubbleTextStyle}>
                    <View style={styles.messageLine}>
                        <Text style={[styles.bubbleText, { color: shape.isMe ? bubbleTheme.meTextColor : bubbleTheme.themTextColor }]}>
                            {text}
                        </Text>
                        <Animated.View style={[styles.timeMetaInline, timestampStyle]}>
                            <Text style={[styles.timeText, { color: shape.isMe ? 'rgba(255,255,255,0.7)' : 'rgba(255,255,255,0.5)' }]}>
                                {timestamp}
                            </Text>
                            {shape.isMe && (
                                <View style={styles.statusSlot}>
                                    <StatusGlyph status={status} />
                                </View>
                            )}
                        </Animated.View>
                    </View>
                </Animated.View>
            </View>

            {shape.showTail && messageType === 'text' && (
                <Animated.View style={[tailBaseStyle(shape.isMe), tailStyle]}>
                    <Svg width={29} height={29} viewBox="0 0 29 29">
                        <Path
                            d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z"
                            fill={shape.isMe ? bubbleTheme.meGradient[1] : bubbleTheme.themSolid}
                        />
                    </Svg>
                </Animated.View>
            )}
        </Animated.View>
    );
};

// ------------------------------------------------------------------
// Message Bubble — matches real MessageBubble styling
// ------------------------------------------------------------------
interface MessageBubbleProps {
    item: Message;
    isSequenceStart: boolean;
    isSequenceEnd: boolean;
    bubbleTheme: BubbleThemeSpec;
    shouldTrackGhostLayout?: boolean;
    replyPreview?: ReplyPreview | null;
    onReply?: (item: Message) => void;
    onLayout?: (id: string, x: number, y: number, w: number, h: number, shape: BubbleShape) => void;
}

const StatusGlyph = ({ status }: { status?: string }) => {
    if (status === 'error') {
        return <RotateCcw size={10} color="#ff8f8f" strokeWidth={2.2} />;
    }

    if (status === 'read') {
        return <CheckCheck size={12} color="#8fd6ff" strokeWidth={2.2} />;
    }

    if (status === 'delivered') {
        return <CheckCheck size={12} color="rgba(255,255,255,0.9)" strokeWidth={2.2} />;
    }

    if (status === 'sent' || status === 'sending' || !status) {
        return <Check size={12} color="rgba(255,255,255,0.86)" strokeWidth={2.2} />;
    }

    return null;
};

const TypingShimmer = ({
    baseColor,
    sweepColor,
    shimmerX
}: {
    baseColor: string;
    sweepColor: string;
    shimmerX: SharedValue<number>;
}) => {
    const shimmerStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: shimmerX.value }],
    }));

    return (
        <MaskedViewAny
            style={styles.typingMask}
            maskElement={
                <View style={styles.typingMaskInner}>
                    <Text style={styles.typingTextMask}>typing...</Text>
                </View>
            }
        >
            <View style={[StyleSheet.absoluteFill, { backgroundColor: baseColor }]} />
            <Animated.View style={[styles.typingShimmerBand, shimmerStyle]}>
                <LinearGradient
                    colors={['transparent', sweepColor, 'transparent']}
                    start={{ x: 0, y: 0.5 }}
                    end={{ x: 1, y: 0.5 }}
                    style={styles.typingShimmerBandFill}
                />
            </Animated.View>
        </MaskedViewAny>
    );
};

const SWIPE_REPLY_THRESHOLD = 44;

// Pre-allocated style objects to avoid re-creating on every render
const BUBBLE_ALIGN_ME = { alignSelf: 'flex-end' as const, marginHorizontal: 8 };
const BUBBLE_ALIGN_THEM = { alignSelf: 'flex-start' as const, marginHorizontal: 8 };
const GHOST_HIDDEN_STYLE = { opacity: 0 };

const areReplyPreviewsEqual = (a?: ReplyPreview | null, b?: ReplyPreview | null) => (
    a?.userName === b?.userName &&
    a?.content === b?.content &&
    a?.isFromMe === b?.isFromMe
);

const areMessageBubblePropsEqual = (prev: MessageBubbleProps, next: MessageBubbleProps) => (
    prev.item.id === next.item.id &&
    prev.item.text === next.item.text &&
    prev.item.type === next.item.type &&
    prev.item.isMe === next.item.isMe &&
    prev.item.timestamp === next.item.timestamp &&
    prev.item.fromId === next.item.fromId &&
    prev.item.replyToId === next.item.replyToId &&
    prev.item.status === next.item.status &&
    prev.item.isGhostHidden === next.item.isGhostHidden &&
    prev.isSequenceStart === next.isSequenceStart &&
    prev.isSequenceEnd === next.isSequenceEnd &&
    prev.bubbleTheme === next.bubbleTheme &&
    prev.shouldTrackGhostLayout === next.shouldTrackGhostLayout &&
    areReplyPreviewsEqual(prev.replyPreview, next.replyPreview) &&
    prev.onReply === next.onReply &&
    prev.onLayout === next.onLayout
);

const MessageBubbleComponent = ({ item, isSequenceStart, isSequenceEnd, bubbleTheme, shouldTrackGhostLayout, replyPreview, onReply, onLayout }: MessageBubbleProps) => {
    const bubbleBodyRef = useRef<View>(null);
    const swipeX = useSharedValue(0);
    const shape = useMemo(
        () => resolveBubbleShape(item.isMe, isSequenceStart, isSequenceEnd, item.type),
        [item.isMe, isSequenceStart, isSequenceEnd, item.type]
    );

    const reportHiddenLayout = useCallback(() => {
        if (!item.isGhostHidden || !onLayout || !shouldTrackGhostLayout) return;
        bubbleBodyRef.current?.measureInWindow((x, y, w, h) => {
            if (w > 0 && h > 0) {
                onLayout(item.id, x, y, w, h, shape);
            }
        });
    }, [item.isGhostHidden, onLayout, item.id, shape, shouldTrackGhostLayout]);

    useEffect(() => {
        if (!item.isGhostHidden || !onLayout || !shouldTrackGhostLayout) return;
        const frameId = requestAnimationFrame(reportHiddenLayout);
        const settleTimer = setTimeout(reportHiddenLayout, 90);
        return () => {
            clearTimeout(settleTimer);
            cancelAnimationFrame(frameId);
        };
    }, [item.isGhostHidden, onLayout, reportHiddenLayout, shouldTrackGhostLayout]);

    const swipeGesture = Gesture.Pan()
        .activeOffsetX([-12, 12])
        .failOffsetY([-10, 10])
        .onUpdate((e) => {
            const translation = item.isMe ? Math.min(0, e.translationX) : Math.max(0, e.translationX);
            const clamped = item.isMe
                ? Math.max(-SWIPE_REPLY_THRESHOLD * 1.4, translation)
                : Math.min(SWIPE_REPLY_THRESHOLD * 1.4, translation);
            swipeX.value = clamped;
        })
        .onEnd(() => {
            if (Math.abs(swipeX.value) >= SWIPE_REPLY_THRESHOLD && onReply) {
                runOnJS(onReply)(item);
            }
            swipeX.value = withTiming(0, { duration: 170, easing: Easing.out(Easing.quad) });
        });

    const swipeStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: swipeX.value }],
    }));

    const replyGlyphStyle = useAnimatedStyle(() => {
        const p = Math.min(Math.abs(swipeX.value) / SWIPE_REPLY_THRESHOLD, 1);
        return {
            opacity: interpolate(p, [0, 0.2, 1], [0, 0.45, 1], 'clamp'),
            transform: [{ scale: interpolate(p, [0, 1], [0.72, 1], 'clamp') }],
        };
    });

    if (item.isGhostHidden) {
        return (
            <View style={[styles.swipeContainer, item.isMe ? styles.swipeContainerMe : styles.swipeContainerThem]}>
                <View style={[styles.bubbleWrapper, item.isMe ? BUBBLE_ALIGN_ME : BUBBLE_ALIGN_THEM, GHOST_HIDDEN_STYLE]}>
                    <View style={styles.messageContainer}>
                        <View
                            ref={bubbleBodyRef}
                            collapsable={false}
                            onLayout={shouldTrackGhostLayout ? reportHiddenLayout : undefined}
                            style={[
                                styles.bubble,
                                {
                                    borderTopLeftRadius: shape.borderTopLeftRadius,
                                    borderTopRightRadius: shape.borderTopRightRadius,
                                    borderBottomLeftRadius: shape.borderBottomLeftRadius,
                                    borderBottomRightRadius: shape.borderBottomRightRadius,
                                    backgroundColor: item.isMe ? bubbleTheme.meGradient[0] : bubbleTheme.themSolid,
                                },
                            ]}
                        >
                            <View style={styles.messageLine}>
                                <Text style={[styles.bubbleText, { color: item.isMe ? bubbleTheme.meTextColor : bubbleTheme.themTextColor }]}>
                                    {item.text}
                                </Text>
                                <View style={styles.timeMetaInline}>
                                    <Text style={[styles.timeText, { color: item.isMe ? 'rgba(255,255,255,0.7)' : 'rgba(255,255,255,0.5)' }]}>
                                        {item.timestamp}
                                    </Text>
                                </View>
                            </View>
                        </View>
                    </View>
                </View>
            </View>
        );
    }

    return (
        <View style={[styles.swipeContainer, item.isMe ? styles.swipeContainerMe : styles.swipeContainerThem]}>
            <Animated.View style={[
                styles.replyIconContainer,
                item.isMe ? styles.replyIconRight : styles.replyIconLeft,
                replyGlyphStyle,
            ]}>
                <Reply size={14} color={withAlpha('#ffffff', 0.9)} strokeWidth={2.2} />
            </Animated.View>

            <GestureDetector gesture={swipeGesture}>
                <Animated.View
                    style={[
                        styles.bubbleWrapper,
                        item.isMe ? BUBBLE_ALIGN_ME : BUBBLE_ALIGN_THEM,
                        item.isGhostHidden && GHOST_HIDDEN_STYLE,
                        swipeStyle,
                    ]}
                >
                    <View style={styles.messageContainer}>
                        <View ref={bubbleBodyRef} collapsable={false} onLayout={shouldTrackGhostLayout ? reportHiddenLayout : undefined}>
                            {item.isMe ? (
                                <LinearGradient
                                    colors={bubbleTheme.meGradient}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                    style={[
                                        styles.bubble,
                                        {
                                            borderTopLeftRadius: shape.borderTopLeftRadius,
                                            borderTopRightRadius: shape.borderTopRightRadius,
                                            borderBottomLeftRadius: shape.borderBottomLeftRadius,
                                            borderBottomRightRadius: shape.borderBottomRightRadius,
                                        },
                                    ]}
                                >
                                    {replyPreview && (
                                        <View style={styles.replyPreview}>
                                            <View style={[styles.replyPreviewBar, { backgroundColor: 'rgba(255,255,255,0.65)' }]} />
                                            <View style={styles.replyPreviewBody}>
                                                <Text style={[styles.replyPreviewAuthor, { color: 'rgba(255,255,255,0.88)' }]} numberOfLines={1}>{replyPreview.userName}</Text>
                                                <Text style={[styles.replyPreviewText, { color: 'rgba(255,255,255,0.72)' }]} numberOfLines={1}>{replyPreview.content}</Text>
                                            </View>
                                        </View>
                                    )}
                                    <View style={styles.messageLine}>
                                        <Text style={[styles.bubbleText, { color: bubbleTheme.meTextColor }]}>{item.text}</Text>
                                        <View style={styles.timeMetaInline}>
                                            <Text style={styles.timeText}>
                                                {item.timestamp}
                                            </Text>
                                            <View style={styles.statusSlot}>
                                                <StatusGlyph status={item.status} />
                                            </View>
                                        </View>
                                    </View>
                                </LinearGradient>
                            ) : (
                                <View
                                    style={[
                                        styles.bubble,
                                        {
                                            backgroundColor: bubbleTheme.themSolid,
                                            borderTopLeftRadius: shape.borderTopLeftRadius,
                                            borderTopRightRadius: shape.borderTopRightRadius,
                                            borderBottomLeftRadius: shape.borderBottomLeftRadius,
                                            borderBottomRightRadius: shape.borderBottomRightRadius,
                                        },
                                    ]}
                                >
                                    {replyPreview && (
                                        <View style={styles.replyPreview}>
                                            <View style={[styles.replyPreviewBar, { backgroundColor: withAlpha(bubbleTheme.meGradient[0], 0.8) }]} />
                                            <View style={styles.replyPreviewBody}>
                                                <Text style={[styles.replyPreviewAuthor, { color: withAlpha(bubbleTheme.meGradient[0], 0.95) }]} numberOfLines={1}>{replyPreview.userName}</Text>
                                                <Text style={[styles.replyPreviewText, { color: withAlpha(bubbleTheme.themTextColor, 0.8) }]} numberOfLines={1}>{replyPreview.content}</Text>
                                            </View>
                                        </View>
                                    )}
                                    <View style={styles.messageLine}>
                                        <Text style={[styles.bubbleText, { color: bubbleTheme.themTextColor }]}>{item.text}</Text>
                                        <View style={styles.timeMetaInline}>
                                            <Text style={[styles.timeText, { color: 'rgba(255,255,255,0.5)' }]}>
                                                {item.timestamp}
                                            </Text>
                                        </View>
                                    </View>
                                </View>
                            )}
                        </View>

                        {shape.showTail && item.type === 'text' && (
                            <View style={tailBaseStyle(item.isMe)}>
                                <Svg width={29} height={29} viewBox="0 0 29 29">
                                    <Path
                                        d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z"
                                        fill={item.isMe ? bubbleTheme.meGradient[1] : bubbleTheme.themSolid}
                                    />
                                </Svg>
                            </View>
                        )}
                    </View>
                </Animated.View>
            </GestureDetector>
        </View>
    );
};

const MessageBubble = React.memo(MessageBubbleComponent, areMessageBubblePropsEqual);

// ------------------------------------------------------------------
// MAIN CHAT SCREEN
// ------------------------------------------------------------------
export default function ChatPerformanceScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const params = useLocalSearchParams();
    const traceParam = getParamValue((params as any)?.trace);
    const traceEnabled = traceParam === DEBUG_FLAG_ENABLED || traceParam === '2';
    const verboseTraceEnabled = traceParam === '2';
    const perfDiagEnabled = getParamValue((params as any)?.perf) === DEBUG_FLAG_ENABLED;
    const { user } = useAuthStore();
    const chats = useChatStore(s => s.chats);
    const sendMessage = useChatStore(s => s.sendMessage);
    const setActiveChat = useChatStore(s => s.setActiveChat);
    const activeChatId = useChatStore(s => s.activeChatId);
    const loadMessages = useChatStore(s => s.loadMessages);
    const isConnected = useChatStore(s => s.isConnected);
    const onlineUsers = useChatStore(s => s.onlineUsers);
    const typingUsers = useChatStore(s => s.typingUsers);
    const sendTyping = useChatStore(s => s.sendTyping);
    const sendStopTyping = useChatStore(s => s.sendStopTyping);
    const chatIdFromParams = typeof params?.id === 'string' ? params.id : null;
    const effectiveChatId = chatIdFromParams || activeChatId || chats[0]?.chatId || null;

    const [messages, setMessages] = useState<Message[]>([
        { id: '4', text: 'Text morphs from input to bubble!', type: 'text', isMe: true, timestamp: '10:04' },
        { id: '3', text: 'Testing chat crossfade.', type: 'text', isMe: false, timestamp: '10:03' },
        { id: '2', text: 'Hello! How are you?', type: 'text', isMe: true, timestamp: '10:02' },
        { id: '1', text: 'Hey there!', type: 'text', isMe: false, timestamp: '10:01' },
    ]);
    const [text, setText] = useState('');
    const [replyTo, setReplyTo] = useState<ReplyInfo | null>(null);
    const muteSentSound = false;
    const flatListRef = useRef<FlatList>(null);
    const inputBarRef = useRef<View>(null);
    const tracedMessageIdRef = useRef<string | null>(null);
    const perfPhaseRef = useRef<string>('idle');
    const messageCountRef = useRef<number>(0);
    const ghostVisibleRef = useRef(false);
    const pendingGhostVisibleRef = useRef(false);
    const trackedStatusRef = useRef<string | null>(null);
    const trackedCountRef = useRef<number>(0);
    const queuedSendsRef = useRef<Map<string, PendingRealSend>>(new Map());
    const queuedSendTimeoutsRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
    const pendingInputClearRef = useRef<PendingInputClear | null>(null);
    const inputClearLiftoffTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const inputClearFallbackTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const phaseResetTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const suppressStoreSyncUntilRef = useRef<number>(0);
    const syncResumeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const [syncTick, setSyncTick] = useState(0);
    const [perfLoopVersion, setPerfLoopVersion] = useState(0);
    const basePlayRef = useRef<((type: SoundType) => void) | null>(null);
    const hydratedCountRef = useRef<number>(-1);
    const latestLayoutRef = useRef<Map<string, { x: number; y: number; w: number; h: number; shape: BubbleShape }>>(new Map());
    const pendingGhostIdRef = useRef<string | null>(null);
    const perfSamplingUntilRef = useRef<number>(0);
    const perfLoopRunningRef = useRef(false);
    const lastPerfLogAtRef = useRef<number>(0);
    const typingShimmerX = useSharedValue(0);

    const logSend = useCallback((event: string, data?: Record<string, unknown>) => {
        if (!traceEnabled) return;
        if (!verboseTraceEnabled) {
            if (!TRACE_ESSENTIAL_EVENTS.has(event)) return;
        }
        if (data) {
            console.log('[TEST-SEND]', event, data);
            return;
        }
        console.log('[TEST-SEND]', event);
    }, [traceEnabled, verboseTraceEnabled]);

    const addTrace = useCallback((phase: string, message: string) => {
        if (!traceEnabled) return;
        if (!verboseTraceEnabled) {
            if (!TRACE_ESSENTIAL_PHASES.has(phase)) return;
        }
        console.log(`[TEST-TRACE] [${phase}] ${message}`);
    }, [traceEnabled, verboseTraceEnabled]);

    const logPerf = useCallback((event: string, data?: Record<string, unknown>) => {
        if (!perfDiagEnabled) return;
        if (data) {
            console.log('[TEST-PERF]', event, data);
            return;
        }
        console.log('[TEST-PERF]', event);
    }, [perfDiagEnabled]);

    const startPerfSampling = useCallback((phase: string, durationMs: number = PERF_SAMPLE_WINDOW_MS) => {
        if (!perfDiagEnabled) return;
        const nextUntil = performance.now() + durationMs;
        if (nextUntil > perfSamplingUntilRef.current) {
            perfSamplingUntilRef.current = nextUntil;
        }
        if (!perfLoopRunningRef.current) {
            perfLoopRunningRef.current = true;
            setPerfLoopVersion(v => v + 1);
        }
        if (verboseTraceEnabled) {
            logPerf('sample_window', { phase, durationMs });
        }
    }, [logPerf, perfDiagEnabled, verboseTraceEnabled]);

    const suppressStoreSyncFor = useCallback((ms: number) => {
        const now = Date.now();
        const nextUntil = now + ms;
        if (nextUntil > suppressStoreSyncUntilRef.current) {
            suppressStoreSyncUntilRef.current = nextUntil;
        }
        if (syncResumeTimerRef.current) {
            clearTimeout(syncResumeTimerRef.current);
        }
        const delay = Math.max(0, suppressStoreSyncUntilRef.current - now + 8);
        syncResumeTimerRef.current = setTimeout(() => {
            syncResumeTimerRef.current = null;
            // Trigger one catch-up hydration pass after critical animation window.
            setSyncTick((v) => v + 1);
        }, delay);
    }, []);

    const runRealSend = useCallback((payload: PendingRealSend, reason: string) => {
        const existingTimer = queuedSendTimeoutsRef.current.get(payload.messageId);
        if (existingTimer) {
            clearTimeout(existingTimer);
            queuedSendTimeoutsRef.current.delete(payload.messageId);
        }
        perfPhaseRef.current = `send:${reason}`;
        startPerfSampling(`send:${reason}`, 2400);
        suppressStoreSyncFor(700);
        tracedMessageIdRef.current = payload.messageId;
        trackedStatusRef.current = null;
        addTrace('SEND', `sendMessage start(${reason}) chat=${payload.chatId.slice(0, 8)} msg=${payload.messageId.slice(0, 8)} connected=${isConnected}`);
        logSend('send_start', {
            reason,
            messageId: payload.messageId,
            chatId: payload.chatId,
            connected: isConnected,
            queueDelayMs: Number((performance.now() - payload.queuedAt).toFixed(1)),
        });
        const sendStart = performance.now();
        const metadata = payload.replyToId ? { replyToId: payload.replyToId } : {};
        Promise.resolve(sendMessage(payload.chatId, payload.text, 'text', metadata, payload.messageId))
            .then(() => {
                perfPhaseRef.current = 'send_resolved';
                startPerfSampling('send_resolved', 700);
                suppressStoreSyncFor(180);
                if (phaseResetTimerRef.current) clearTimeout(phaseResetTimerRef.current);
                phaseResetTimerRef.current = setTimeout(() => {
                    perfPhaseRef.current = 'idle';
                    phaseResetTimerRef.current = null;
                }, 900);
                addTrace('SEND', `sendMessage resolved(${reason}) (+${(performance.now() - sendStart).toFixed(1)}ms)`);
                logSend('send_resolved', {
                    reason,
                    messageId: payload.messageId,
                    sendDeltaMs: Number((performance.now() - sendStart).toFixed(1)),
                    tapDeltaMs: Number((performance.now() - payload.tapAt).toFixed(1)),
                });
            })
            .catch((e: any) => {
                perfPhaseRef.current = 'send_rejected';
                startPerfSampling('send_rejected', 700);
                suppressStoreSyncFor(180);
                if (phaseResetTimerRef.current) clearTimeout(phaseResetTimerRef.current);
                phaseResetTimerRef.current = setTimeout(() => {
                    perfPhaseRef.current = 'idle';
                    phaseResetTimerRef.current = null;
                }, 900);
                addTrace('SEND', `sendMessage rejected(${reason}): ${e?.message || String(e)}`);
                logSend('send_rejected', {
                    reason,
                    messageId: payload.messageId,
                    error: e?.message || String(e),
                    sendDeltaMs: Number((performance.now() - sendStart).toFixed(1)),
                    tapDeltaMs: Number((performance.now() - payload.tapAt).toFixed(1)),
                });
            });
    }, [addTrace, isConnected, logSend, sendMessage, startPerfSampling, suppressStoreSyncFor]);

    useEffect(() => {
        const manager = SoundManager as any;
        if (!basePlayRef.current) {
            basePlayRef.current = manager.play.bind(manager);
        }
        const basePlay = basePlayRef.current;
        if (!basePlay) return;

        manager.play = (type: SoundType) => {
            if (muteSentSound && type === 'sent') {
                addTrace('SOUND', 'suppressed sent');
                logSend('sound_sent_suppressed');
                return;
            }
            basePlay(type);
        };

        if (traceEnabled) {
            addTrace('SOUND', `muteSentSound=${muteSentSound}`);
            logSend('sound_mode_changed', { muteSentSound });
        }

        return () => {
            manager.play = basePlay;
        };
    }, [muteSentSound, addTrace, logSend, traceEnabled]);

    useEffect(() => {
        if (chatIdFromParams && chatIdFromParams !== activeChatId) {
            addTrace('CHAT', `setActiveChat(${chatIdFromParams.slice(0, 8)})`);
            setActiveChat(chatIdFromParams);
        }
    }, [chatIdFromParams, activeChatId, setActiveChat, addTrace]);

    useEffect(() => {
        if (!traceEnabled) return;
        addTrace('NOTE', 'Baseline step: UI pipeline until this point is smooth (no lag)');
        logSend('baseline_step_recorded');
    }, [addTrace, logSend, traceEnabled]);

    useEffect(() => {
        if (!traceEnabled) return;
        addTrace(
            'RUNTIME',
            isExpoGoRuntime
                ? 'Expo Go detected: crypto will use Forge fallback; UI is isolated and send work is deferred.'
                : 'Development/runtime build detected: native crypto path should reduce send-time JS pressure.',
        );
    }, [addTrace, traceEnabled]);

    useEffect(() => {
        if (!effectiveChatId) return;
        if (verboseTraceEnabled) {
            addTrace('CHAT', `active chat ${effectiveChatId.slice(0, 8)} connected=${isConnected}`);
        }
        const chat = useChatStore.getState().chats.find(c => c.chatId === effectiveChatId);
        if (!chat || chat.messages.length === 0) {
            if (verboseTraceEnabled) {
                addTrace('CHAT', `loadMessages(${effectiveChatId.slice(0, 8)})`);
            }
            loadMessages(effectiveChatId);
        }
    }, [effectiveChatId, loadMessages, addTrace, isConnected, verboseTraceEnabled]);

    const lastSyncedRef = useRef<{ count: number; lastId: string | null }>({ count: 0, lastId: null });

    useEffect(() => {
        messageCountRef.current = messages.length;
    }, [messages.length]);

    useEffect(() => {
        if (!perfDiagEnabled || !perfLoopRunningRef.current) return;
        let rafId = 0;
        let last = performance.now();
        const loop = () => {
            const now = performance.now();
            if (now >= perfSamplingUntilRef.current) {
                perfLoopRunningRef.current = false;
                perfPhaseRef.current = 'idle';
                return;
            }
            const delta = now - last;
            const phase = perfPhaseRef.current;
            const canLogNow = now - lastPerfLogAtRef.current >= PERF_LOG_COOLDOWN_MS;
            const shouldLogIdle = phase !== 'idle' || delta >= PERF_IDLE_LOG_THRESHOLD_MS;
            if (delta > PERF_FRAME_DROP_MS && shouldLogIdle && canLogNow) {
                lastPerfLogAtRef.current = now;
                logPerf('frame_drop', {
                    deltaMs: Number(delta.toFixed(1)),
                    phase,
                    messageCount: messageCountRef.current,
                    hasGhost: ghostVisibleRef.current,
                    hasPendingGhost: pendingGhostVisibleRef.current,
                    queuedSends: queuedSendsRef.current.size,
                });
            }
            last = now;
            rafId = requestAnimationFrame(loop);
        };
        rafId = requestAnimationFrame(loop);
        return () => cancelAnimationFrame(rafId);
    }, [logPerf, perfDiagEnabled, perfLoopVersion]);

    useEffect(() => {
        return () => {
            if (syncResumeTimerRef.current) {
                clearTimeout(syncResumeTimerRef.current);
                syncResumeTimerRef.current = null;
            }
            if (inputClearLiftoffTimerRef.current) {
                clearTimeout(inputClearLiftoffTimerRef.current);
                inputClearLiftoffTimerRef.current = null;
            }
            if (inputClearFallbackTimerRef.current) {
                clearTimeout(inputClearFallbackTimerRef.current);
                inputClearFallbackTimerRef.current = null;
            }
            if (phaseResetTimerRef.current) {
                clearTimeout(phaseResetTimerRef.current);
                phaseResetTimerRef.current = null;
            }
            queuedSendTimeoutsRef.current.forEach((timer) => clearTimeout(timer));
            queuedSendTimeoutsRef.current.clear();
        };
    }, []);

    useEffect(() => {
        if (!effectiveChatId) return;
        if (Date.now() < suppressStoreSyncUntilRef.current) return;
        if (isUiCriticalPhase(perfPhaseRef.current)) return;
        const chat = chats.find(c => c.chatId === effectiveChatId);
        if (!chat || !Array.isArray(chat.messages)) return;

        // Quick bail-out: if count and newest message ID haven't changed, skip the expensive sort+map.
        const lastMsg = chat.messages.length > 0 ? chat.messages[chat.messages.length - 1] : null;
        const lastId = lastMsg?.id || null;
        if (
            chat.messages.length === lastSyncedRef.current.count &&
            lastId === lastSyncedRef.current.lastId
        ) {
            return;
        }
        lastSyncedRef.current = { count: chat.messages.length, lastId };

        const hydrateStart = perfDiagEnabled ? performance.now() : 0;
        const sourceMessages = Array.isArray(chat.messages) ? chat.messages : [];
        const windowStart = Math.max(0, sourceMessages.length - MAX_RENDER_MESSAGES);
        const renderWindow = sourceMessages.slice(windowStart);
        const storeMessages = renderWindow
            .sort((a: any, b: any) => (b?.timestamp || 0) - (a?.timestamp || 0))
            .map((m: any) => ({
                id: m.id,
                text: getStoreMessageText(m),
                type: (m?.type || 'text') as MessageType,
                status: m?.status,
                fromId: m?.fromId,
                replyToId: m?.replyToId,
                isMe: m.fromId === user?.userId,
                timestamp: formatUiTime(m.timestamp),
                isOptimistic: false,
            }));
        const hydrateCost = perfDiagEnabled ? performance.now() - hydrateStart : 0;
        if (perfDiagEnabled && hydrateCost > PERF_HYDRATE_WARN_MS) {
            logPerf('hydrate_cost', {
                costMs: Number(hydrateCost.toFixed(1)),
                totalMessages: sourceMessages.length,
                windowMessages: renderWindow.length,
                phase: perfPhaseRef.current,
            });
        }

        setMessages(prev => {
            const mergeStart = perfDiagEnabled ? performance.now() : 0;
            if (storeMessages.length === 0) return prev;

            const localById = new Map(prev.map(m => [m.id, m] as const));
            const localIds = new Set(localById.keys());
            let changed = false;

            // Keep local row identity whenever possible to avoid visual flicker during send status transitions.
            const mergedFromStore = storeMessages.map((storeMsg) => {
                const local = localById.get(storeMsg.id);
                if (!local) {
                    changed = true;
                    return storeMsg;
                }

                const sameCore =
                    local.text === storeMsg.text &&
                    local.type === storeMsg.type &&
                    local.status === storeMsg.status &&
                    local.fromId === storeMsg.fromId &&
                    local.replyToId === storeMsg.replyToId &&
                    local.timestamp === storeMsg.timestamp &&
                    local.isMe === storeMsg.isMe &&
                    local.isOptimistic === false;

                if (sameCore) return local;

                changed = true;
                return {
                    ...local,
                    text: storeMsg.text,
                    type: storeMsg.type,
                    status: storeMsg.status,
                    fromId: storeMsg.fromId,
                    replyToId: storeMsg.replyToId,
                    isMe: storeMsg.isMe,
                    timestamp: storeMsg.timestamp,
                    isOptimistic: false,
                };
            });

            // Keep local optimistic-only messages that are not in store yet.
            const optimisticOnly = prev.filter(m => m.isOptimistic && !storeMessages.some(s => s.id === m.id));
            if (optimisticOnly.length > 0) changed = true;

            // Fast no-op path: no structural changes and no updated rows.
            if (!changed && prev.length === mergedFromStore.length && mergedFromStore.every((m, i) => m.id === prev[i]?.id)) {
                return prev;
            }

            const merged = [...optimisticOnly, ...mergedFromStore];
            // Preserve previous array when IDs/order are identical to avoid extra FlatList work.
            if (merged.length === prev.length && merged.every((m, i) => m.id === prev[i]?.id && m === prev[i])) {
                return prev;
            }

            // If store did not introduce any new IDs and we only refreshed fields, keep local ordering.
            const hasNewIdFromStore = storeMessages.some(m => !localIds.has(m.id));
            if (!hasNewIdFromStore && merged.length === prev.length) {
                const mergedById = new Map(merged.map(m => [m.id, m] as const));
                const remapped = prev.map((row) => mergedById.get(row.id) || row);
                const mergeCost = perfDiagEnabled ? performance.now() - mergeStart : 0;
                if (perfDiagEnabled && mergeCost > PERF_MERGE_WARN_MS) {
                    logPerf('merge_cost', {
                        costMs: Number(mergeCost.toFixed(1)),
                        prevCount: prev.length,
                        nextCount: remapped.length,
                        sourceCount: storeMessages.length,
                        phase: perfPhaseRef.current,
                    });
                }
                return remapped;
            }
            const mergeCost = perfDiagEnabled ? performance.now() - mergeStart : 0;
            if (perfDiagEnabled && mergeCost > PERF_MERGE_WARN_MS) {
                logPerf('merge_cost', {
                    costMs: Number(mergeCost.toFixed(1)),
                    prevCount: prev.length,
                    nextCount: merged.length,
                    sourceCount: storeMessages.length,
                    phase: perfPhaseRef.current,
                });
            }
            return merged;
        });

        if (traceEnabled && hydratedCountRef.current !== storeMessages.length) {
            hydratedCountRef.current = storeMessages.length;
            addTrace('CHAT', `hydrated from store: ${storeMessages.length} messages`);
            logSend('hydrated_messages', { count: storeMessages.length, chatId: effectiveChatId });
        }
    }, [effectiveChatId, chats, user?.userId, addTrace, logSend, syncTick, logPerf, perfDiagEnabled, traceEnabled]);

    useEffect(() => {
        if (!verboseTraceEnabled) return;
        const unsubscribe = useChatStore.subscribe((state, prevState) => {
            if (state.chats === prevState.chats) return;
            const chatId = effectiveChatId;
            if (!chatId) return;
            const chat = state.chats.find(c => c.chatId === chatId);
            if (!chat) return;

            if (chat.messages.length !== trackedCountRef.current) {
                addTrace('STORE', `messages ${trackedCountRef.current} -> ${chat.messages.length}`);
                trackedCountRef.current = chat.messages.length;
            }

            const msgId = tracedMessageIdRef.current;
            if (!msgId) return;
            const msg = chat.messages.find(m => m.id === msgId);
            const nextStatus = msg?.status || 'missing';
            if (nextStatus !== trackedStatusRef.current) {
                addTrace('STATUS', `${msgId.slice(0, 8)}: ${trackedStatusRef.current || 'none'} -> ${nextStatus}`);
                trackedStatusRef.current = nextStatus;
            }
        });
        return unsubscribe;
    }, [effectiveChatId, addTrace, verboseTraceEnabled]);

    // Ghost state
    const [ghostData, setGhostData] = useState<{
        text: string;
        messageType: MessageType;
        status?: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        targetX: number;
        targetY: number;
        targetWidth: number;
        targetHeight: number;
        shape: BubbleShape;
        bubbleTheme: BubbleThemeSpec;
        messageId: string;
    } | null>(null);
    const [pendingGhost, setPendingGhost] = useState<{
        text: string;
        messageType: MessageType;
        status?: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        messageId: string;
        bubbleTheme: BubbleThemeSpec;
    } | null>(null);

    useEffect(() => {
        ghostVisibleRef.current = !!ghostData;
        pendingGhostVisibleRef.current = !!pendingGhost;
        pendingGhostIdRef.current = pendingGhost?.messageId || null;
    }, [ghostData, pendingGhost]);

    useEffect(() => {
        if (!ghostData) return;
        setPendingGhost(prev => (prev?.messageId === ghostData.messageId ? null : prev));
        pendingGhostIdRef.current = null;
    }, [ghostData]);

    const resolvedTheme = useMemo(() => {
        const theme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
        if (!theme.backgroundGradient) {
            return {
                ...theme,
                backgroundGradient: [colors.background, colors.background]
            };
        }
        return theme;
    }, [activeTheme, effectiveTheme, colors.background]);
    const wallpaperGradient = resolvedTheme.backgroundGradient;
    const bubbleTheme = useMemo<BubbleThemeSpec>(() => ({
        meGradient: (
            resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
                ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
                : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]
        ) as [string, string],
        themSolid: resolvedTheme.bubbleThem,
        meTextColor: resolvedTheme.textColorMe || BUBBLE_TEXT_COLOR,
        themTextColor: resolvedTheme.textColorThem || '#ddd',
    }), [resolvedTheme]);
    const isIOS = Platform.OS === 'ios';
    const inputVerticalPadding = isIOS ? 3 : 4;
    const bottomInsetPadding = isIOS ? Math.min(insets.bottom, 20) : Math.max(insets.bottom, 6);
    const footerHeight = (isIOS ? 58 : 60) + bottomInsetPadding + inputVerticalPadding * 2;
    const { height: keyboardHeight } = useReanimatedKeyboardAnimation();
    const keyboardShift = useDerivedValue(() => Math.max(Math.abs(keyboardHeight.value), 0));
    const pageShiftStyle = useAnimatedStyle(() => ({ transform: [{ translateY: -keyboardShift.value }] }));
    const activeChat = chats.find(c => c.chatId === effectiveChatId);
    const displayName = activeChat?.friendName || activeChat?.name || 'Unknown User';
    const friendIdUpper = (activeChat?.friendId || '').toUpperCase();
    const isFriendOnline = !!friendIdUpper && onlineUsers.has(friendIdUpper);
    const isFriendTyping = !!friendIdUpper && typingUsers.has(friendIdUpper);
    const showTypingInline = isFriendTyping || (typingUsers.size > 0 && chats.length <= 1);
    const lastFriendSeenAt = useMemo(() => {
        if (!activeChat) return undefined;
        if (!friendIdUpper) return activeChat.lastMessage?.timestamp;
        const msgs = activeChat.messages || [];
        for (let i = msgs.length - 1; i >= 0; i--) {
            const m = msgs[i];
            if ((m.fromId || '').toUpperCase() === friendIdUpper) return m.timestamp;
        }
        return activeChat.lastMessage?.timestamp;
    }, [activeChat, friendIdUpper]);
    const headerStatusText = isFriendOnline ? 'online' : formatLastSeen(lastFriendSeenAt);
    const avatarUri = activeChat?.friendImage || undefined;

    useEffect(() => {
        // Keep shimmer phase stable across list rerenders.
        typingShimmerX.value = withRepeat(
            withTiming(TYPING_SHIMMER_TRAVEL * 2, { duration: 2500, easing: Easing.linear }),
            -1,
            false
        );
    }, []);

    const onBubbleLayout = useCallback((
        id: string,
        x: number,
        y: number,
        w: number,
        h: number,
        shape: BubbleShape,
    ) => {
        const previous = latestLayoutRef.current.get(id);
        latestLayoutRef.current.set(id, { x, y, w, h, shape });

        const adjustedY = y + CROSSFADE_TARGET_Y_OFFSET;
        setPendingGhost(prev => {
            if (!prev || prev.messageId !== id) return prev;
            if (ghostData?.messageId === id) return prev;
            const startXAligned = Math.min(prev.startX, x - 8);
            setGhostData({
                text: prev.text,
                messageType: prev.messageType,
                status: prev.status,
                timestamp: prev.timestamp,
                startX: startXAligned,
                startY: prev.startY,
                startWidth: prev.startWidth,
                startHeight: prev.startHeight,
                targetX: x,
                targetY: adjustedY,
                targetWidth: w,
                targetHeight: h,
                shape,
                bubbleTheme: prev.bubbleTheme,
                messageId: prev.messageId,
            });
            return prev;
        });

        // Do not mutate active ghost target mid-flight; it causes visible jitter.
        // We still store latest layout and apply final correction right before reveal.

        const layoutChangedEnough = !previous ||
            Math.abs(previous.x - x) > 0.75 ||
            Math.abs(previous.y - y) > 0.75 ||
            Math.abs(previous.w - w) > 0.75 ||
            Math.abs(previous.h - h) > 0.75;

        if (layoutChangedEnough && (verboseTraceEnabled || perfDiagEnabled)) {
            logSend('bubble_layout_measured', {
                messageId: id,
                x: Number(x.toFixed(1)),
                y: Number(adjustedY.toFixed(1)),
                w: Number(w.toFixed(1)),
                h: Number(h.toFixed(1)),
                showTail: shape.showTail,
            });
        }
    }, [ghostData?.messageId, logSend, perfDiagEnabled, verboseTraceEnabled]);

    const handleSend = useCallback(() => {
        if (!text.trim()) return;
        perfPhaseRef.current = 'tap_send';
        startPerfSampling('tap_send', 1800);
        suppressStoreSyncFor(900);
        const tapAt = performance.now();
        const currentText = text.trim();
        const replySnapshot = replyTo;
        const messageType: MessageType = 'text';
        const messageId = ExpoCrypto.randomUUID();
        const timestamp = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
        addTrace('TAP', `send pressed msg=${messageId.slice(0, 8)} text="${currentText.slice(0, 32)}"`);
        logSend('tap_send', {
            messageId,
            chatId: effectiveChatId,
            textLength: currentText.length,
            connected: isConnected,
            tapAt: Number(tapAt.toFixed(1)),
        });

        if (verboseTraceEnabled) {
            requestAnimationFrame(() => {
                addTrace('FRAME', `rAF #1 after tap (+${(performance.now() - tapAt).toFixed(1)}ms)`);
                logSend('raf_1', { messageId, deltaMs: Number((performance.now() - tapAt).toFixed(1)) });
                requestAnimationFrame(() => {
                    addTrace('FRAME', `rAF #2 after tap (+${(performance.now() - tapAt).toFixed(1)}ms)`);
                    logSend('raf_2', { messageId, deltaMs: Number((performance.now() - tapAt).toFixed(1)) });
                });
            });
            InteractionManager.runAfterInteractions(() => {
                addTrace('INTERACTION', `runAfterInteractions fired (+${(performance.now() - tapAt).toFixed(1)}ms)`);
                logSend('run_after_interactions', {
                    messageId,
                    deltaMs: Number((performance.now() - tapAt).toFixed(1)),
                });
            });
        }

        let didMeasure = false;
        inputBarRef.current?.measureInWindow((barX, barY, barW, barH) => {
            didMeasure = true;
            addTrace('MEASURE', `input bar (${barX.toFixed(0)},${barY.toFixed(0)}) ${barW.toFixed(0)}x${barH.toFixed(0)}`);
            logSend('input_measured', {
                messageId,
                barX: Number(barX.toFixed(1)),
                barY: Number(barY.toFixed(1)),
                barW: Number(barW.toFixed(1)),
                barH: Number(barH.toFixed(1)),
                deltaMs: Number((performance.now() - tapAt).toFixed(1)),
            });
            // Lift from the input text area but bias toward right so trajectory matches outgoing bubble direction.
            const maxStartWidth = Math.max(70, barW - 138);
            const estimatedTextWidth = Math.max(18, Math.min(maxStartWidth - BUBBLE_PADDING_H * 2, currentText.length * 8));
            const startWidth = Math.max(BUBBLE_MIN_WIDTH, estimatedTextWidth + BUBBLE_PADDING_H * 2);
            const rightBiasedStartX = barX + barW - GHOST_START_RIGHT_INSET - startWidth;
            const startX = Math.max(barX + GHOST_START_LEFT_INSET, rightBiasedStartX);
            const startY = barY + 2;
            const startHeight = 34;

            // Reserve final slot immediately so list moves with native layout animation.
            setMessages(prev => ([
                {
                    id: messageId,
                    text: currentText,
                    type: messageType,
                    timestamp,
                    status: 'sending',
                    fromId: user?.userId,
                    replyToId: replySnapshot?.messageId,
                    isMe: true,
                    isOptimistic: true,
                    isGhostHidden: true,
                },
                ...prev,
            ]));
            logSend('hidden_message_inserted', { messageId });

            pendingGhostIdRef.current = messageId;
            setPendingGhost({
                text: currentText,
                messageType,
                status: 'sending',
                timestamp,
                startX,
                startY,
                startWidth,
                startHeight,
                messageId,
                bubbleTheme,
            });
            pendingInputClearRef.current = { messageId, text: currentText };
            if (inputClearLiftoffTimerRef.current) {
                clearTimeout(inputClearLiftoffTimerRef.current);
            }
            if (inputClearFallbackTimerRef.current) {
                clearTimeout(inputClearFallbackTimerRef.current);
            }
            inputClearLiftoffTimerRef.current = setTimeout(() => {
                const pendingClear = pendingInputClearRef.current;
                if (!pendingClear || pendingClear.messageId !== messageId) return;
                setText(prev => (prev === pendingClear.text ? '' : prev));
                logSend('input_cleared', { messageId, phase: 'liftoff' });
                pendingInputClearRef.current = null;
            }, GHOST_INPUT_CLEAR_LIFTOFF_MS);
            inputClearFallbackTimerRef.current = setTimeout(() => {
                const pendingClear = pendingInputClearRef.current;
                if (!pendingClear || pendingClear.messageId !== messageId) return;
                setText(prev => (prev === pendingClear.text ? '' : prev));
                logSend('input_cleared', { messageId, phase: 'fallback' });
                pendingInputClearRef.current = null;
            }, 1200);
            logSend('pending_ghost_set', {
                messageId,
                startX: Number(startX.toFixed(1)),
                startY: Number(startY.toFixed(1)),
                startWidth: Number(startWidth.toFixed(1)),
                startHeight,
            });

            if (!effectiveChatId) {
                addTrace('SEND', 'No active chat id, skipped real send');
                logSend('send_skipped_no_chat', { messageId });
                return;
            }
            const pendingRealSend: PendingRealSend = {
                messageId,
                chatId: effectiveChatId,
                text: currentText,
                replyToId: replySnapshot?.messageId,
                tapAt,
                queuedAt: performance.now(),
            };

            queuedSendsRef.current.set(messageId, pendingRealSend);
            addTrace('SEND', `queued until ghost complete msg=${messageId.slice(0, 8)}`);
            logSend('send_queued', {
                messageId,
                chatId: effectiveChatId,
            });

            const scheduleFallbackFlush = (attempt: number, delayMs: number) => {
                const existingTimer = queuedSendTimeoutsRef.current.get(messageId);
                if (existingTimer) {
                    clearTimeout(existingTimer);
                }
                const timer = setTimeout(() => {
                    queuedSendTimeoutsRef.current.delete(messageId);
                    const queued = queuedSendsRef.current.get(messageId);
                    if (!queued) return;

                    if (
                        (ghostVisibleRef.current || pendingGhostVisibleRef.current || isUiCriticalPhase(perfPhaseRef.current)) &&
                        attempt < 6
                    ) {
                        scheduleFallbackFlush(attempt + 1, 180);
                        return;
                    }

                    queuedSendsRef.current.delete(messageId);
                    addTrace('SEND', `queued fallback flush msg=${messageId.slice(0, 8)} attempt=${attempt}`);
                    logSend('send_queue_timeout_flush', { messageId, attempt });
                    InteractionManager.runAfterInteractions(() => {
                        setTimeout(() => {
                            runRealSend(queued, 'queue_timeout');
                        }, 0);
                    });
                }, delayMs);
                queuedSendTimeoutsRef.current.set(messageId, timer);
            };

            scheduleFallbackFlush(0, 900);
            if (replySnapshot) {
                setReplyTo(null);
            }
        });
        setTimeout(() => {
            if (!didMeasure) {
                addTrace('MEASURE', `input measure timeout msg=${messageId.slice(0, 8)}`);
                logSend('input_measure_timeout', {
                    messageId,
                    deltaMs: Number((performance.now() - tapAt).toFixed(1)),
                });
            }
        }, 180);
    }, [text, replyTo, user?.userId, addTrace, effectiveChatId, isConnected, logSend, runRealSend, bubbleTheme, startPerfSampling, suppressStoreSyncFor, verboseTraceEnabled]);

    const onGhostComplete = useCallback(() => {
        if (!ghostData) return;
        perfPhaseRef.current = 'ghost_complete';
        startPerfSampling('ghost_complete', 1400);
        suppressStoreSyncFor(700);
        const completedGhost = ghostData;
        addTrace('GHOST', `complete msg=${completedGhost.messageId.slice(0, 8)}`);
        logSend('ghost_complete', {
            messageId: completedGhost.messageId,
            targetX: Number(completedGhost.targetX.toFixed(1)),
            targetY: Number(completedGhost.targetY.toFixed(1)),
            targetWidth: Number(completedGhost.targetWidth.toFixed(1)),
            targetHeight: Number(completedGhost.targetHeight.toFixed(1)),
        });

        const latest = latestLayoutRef.current.get(completedGhost.messageId);
        if (latest) {
            const correctedY = latest.y + CROSSFADE_TARGET_Y_OFFSET;
            if (
                Math.abs(completedGhost.targetX - latest.x) > 0.5 ||
                Math.abs(completedGhost.targetY - correctedY) > 0.5 ||
                Math.abs(completedGhost.targetWidth - latest.w) > 0.5 ||
                Math.abs(completedGhost.targetHeight - latest.h) > 0.5
            ) {
                setGhostData(prev => {
                    if (!prev || prev.messageId !== completedGhost.messageId) return prev;
                    return {
                        ...prev,
                        targetX: latest.x,
                        targetY: correctedY,
                        targetWidth: latest.w,
                        targetHeight: latest.h,
                        shape: latest.shape,
                    };
                });
                logSend('ghost_target_corrected_before_reveal', {
                    messageId: completedGhost.messageId,
                    targetX: Number(latest.x.toFixed(1)),
                    targetY: Number(correctedY.toFixed(1)),
                });
            }
        }

        requestAnimationFrame(() => {
            const pendingClear = pendingInputClearRef.current;
            if (pendingClear && pendingClear.messageId === completedGhost.messageId) {
                setText(prev => (prev === pendingClear.text ? '' : prev));
                logSend('input_cleared', { messageId: completedGhost.messageId, phase: 'ghost_complete' });
                pendingInputClearRef.current = null;
            }
            if (inputClearLiftoffTimerRef.current) {
                clearTimeout(inputClearLiftoffTimerRef.current);
                inputClearLiftoffTimerRef.current = null;
            }
            if (inputClearFallbackTimerRef.current) {
                clearTimeout(inputClearFallbackTimerRef.current);
                inputClearFallbackTimerRef.current = null;
            }

            // Reveal reserved hidden row once ghost lands.
            setMessages(prev =>
                prev.map(m => m.id === completedGhost.messageId
                    ? { ...m, isGhostHidden: false, status: m.status || completedGhost.status || 'sending' }
                    : m
                )
            );
            logSend('hidden_message_revealed', { messageId: completedGhost.messageId });

            const queued = queuedSendsRef.current.get(completedGhost.messageId);
            const pendingTimer = queuedSendTimeoutsRef.current.get(completedGhost.messageId);
            if (pendingTimer) {
                clearTimeout(pendingTimer);
                queuedSendTimeoutsRef.current.delete(completedGhost.messageId);
            }
            if (queued) {
                queuedSendsRef.current.delete(completedGhost.messageId);
                addTrace('SEND', `queued send flush after ghost msg=${completedGhost.messageId.slice(0, 8)}`);
                logSend('send_queue_flush_after_ghost', { messageId: completedGhost.messageId });
            }

            requestAnimationFrame(() => {
                setGhostData(null);
                perfPhaseRef.current = 'post_ghost';
                startPerfSampling('post_ghost', 1200);
                logSend('ghost_overlay_cleared', { messageId: completedGhost.messageId });
            });

            if (queued) {
                InteractionManager.runAfterInteractions(() => {
                    setTimeout(() => {
                        runRealSend(queued, 'after_ghost');
                    }, SEND_AFTER_GHOST_DELAY_MS);
                });
            }
        });
    }, [ghostData, addTrace, logSend, runRealSend, startPerfSampling, suppressStoreSyncFor]);

    const sequenceMetaById = useMemo(() => {
        const start = perfDiagEnabled ? performance.now() : 0;
        const visible = messages.filter(m => !m.isGhostHidden);
        const meta = new Map<string, { isSequenceStart: boolean; isSequenceEnd: boolean }>();

        for (let i = 0; i < visible.length; i++) {
            const item = visible[i];
            const newer = i > 0 ? visible[i - 1] : undefined;
            const older = i < visible.length - 1 ? visible[i + 1] : undefined;
            meta.set(item.id, {
                isSequenceStart: !older || older.isMe !== item.isMe,
                isSequenceEnd: !newer || newer.isMe !== item.isMe,
            });
        }

        const findVisibleNeighbor = (from: number, dir: 1 | -1) => {
            let i = from + dir;
            while (i >= 0 && i < messages.length) {
                if (!messages[i].isGhostHidden) return messages[i];
                i += dir;
            }
            return undefined;
        };

        // Hidden placeholders should get sequence shape, but must not mutate visible neighbors.
        for (let i = 0; i < messages.length; i++) {
            const item = messages[i];
            if (!item.isGhostHidden || meta.has(item.id)) continue;
            const newer = findVisibleNeighbor(i, -1);
            const older = findVisibleNeighbor(i, 1);
            meta.set(item.id, {
                isSequenceStart: !older || older.isMe !== item.isMe,
                isSequenceEnd: !newer || newer.isMe !== item.isMe,
            });
        }

        const cost = perfDiagEnabled ? performance.now() - start : 0;
        if (perfDiagEnabled && cost > PERF_SEQUENCE_WARN_MS) {
            logPerf('sequence_cost', {
                costMs: Number(cost.toFixed(1)),
                totalMessages: messages.length,
                phase: perfPhaseRef.current,
            });
        }
        return meta;
    }, [messages, logPerf, perfDiagEnabled]);

    const messageById = useMemo(() => {
        const map = new Map<string, Message>();
        for (const msg of messages) map.set(msg.id, msg);
        return map;
    }, [messages]);

    // Use refs for lookup maps so renderItem callback stays stable across re-renders.
    // This is critical: without this, every message change invalidates renderItem,
    // which forces FlatList to re-render ALL visible cells.
    const sequenceMetaByIdRef = useRef(sequenceMetaById);
    sequenceMetaByIdRef.current = sequenceMetaById;
    const messageByIdRef = useRef(messageById);
    messageByIdRef.current = messageById;
    const displayNameRef = useRef(displayName);
    displayNameRef.current = displayName;

    const handleReply = useCallback((msg: Message) => {
        const author = msg.isMe ? 'You' : displayNameRef.current;
        setReplyTo({
            messageId: msg.id,
            userName: author,
            userHandle: undefined,
            content: msg.text || 'Message',
        });
    }, []);

    const renderItem = useCallback(
        ({ item }: { item: Message }) => {
            const seq = sequenceMetaByIdRef.current.get(item.id) || { isSequenceStart: true, isSequenceEnd: true };
            const replied = item.replyToId ? messageByIdRef.current.get(item.replyToId) : undefined;
            const replyPreview = replied ? {
                userName: replied.isMe ? 'You' : displayNameRef.current,
                content: replied.text || 'Message',
                isFromMe: replied.isMe,
            } : null;
            const shouldTrackGhostLayout = pendingGhostIdRef.current === item.id;
            return (
                <MessageBubble
                    item={item}
                    isSequenceStart={seq.isSequenceStart}
                    isSequenceEnd={seq.isSequenceEnd}
                    bubbleTheme={bubbleTheme}
                    shouldTrackGhostLayout={shouldTrackGhostLayout}
                    replyPreview={replyPreview}
                    onReply={handleReply}
                    onLayout={onBubbleLayout}
                />
            );
        },
        [bubbleTheme, handleReply, onBubbleLayout]
    );

    const keyExtractor = useCallback((item: Message) => item.id, []);

    const handleTestAttach = useCallback((data: any) => {
        addTrace('ATTACH', `type=${data?.type || 'unknown'}`);
    }, [addTrace]);

    const handleTestGif = useCallback(() => {
        addTrace('GIF', 'gif action tap');
    }, [addTrace]);

    const handleTestCamera = useCallback(() => {
        addTrace('CAMERA', 'camera action tap');
    }, [addTrace]);

    const typingInlineIndicator = useMemo(() => {
        if (!showTypingInline) return null;
        const typingBaseColor = effectiveTheme === 'dark'
            ? withAlpha(colors.textSecondary || colors.text, 0.4)
            : withAlpha(colors.textSecondary || colors.text, 0.5);
        const typingSweepColor = effectiveTheme === 'dark'
            ? 'rgba(255,255,255,0.92)'
            : 'rgba(255,255,255,0.84)';
        return (
            <View pointerEvents="none" style={styles.typingInlineRow}>
                <TypingShimmer
                    baseColor={typingBaseColor}
                    sweepColor={typingSweepColor}
                    shimmerX={typingShimmerX}
                />
            </View>
        );
    }, [showTypingInline, effectiveTheme, colors.text, colors.textSecondary]);

    return (
        <View style={styles.container}>
            <LinearGradient colors={wallpaperGradient as any} style={StyleSheet.absoluteFill} />
            <WallpaperBackground theme={resolvedTheme} />

            <Animated.View style={[styles.pageBody, pageShiftStyle]}>
                <View style={styles.listArea}>
                    <FlatList
                        ref={flatListRef}
                        data={messages}
                        renderItem={renderItem}
                        keyExtractor={keyExtractor}
                        ListHeaderComponent={typingInlineIndicator}
                        inverted
                        contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 40, paddingBottom: footerHeight + (isIOS ? 6 : 4) }]}
                        showsVerticalScrollIndicator={false}
                        keyboardDismissMode="interactive"
                        keyboardShouldPersistTaps="handled"
                        // ── Performance tuning for large lists ──
                        maxToRenderPerBatch={8}
                        updateCellsBatchingPeriod={50}
                        initialNumToRender={15}
                        windowSize={7}
                        removeClippedSubviews={Platform.OS !== 'ios'}
                    />
                </View>

                <View pointerEvents="none" style={[styles.footerMask, { height: footerHeight + (isIOS ? 34 : 44) }]}>
                    <MaskedViewAny
                        style={StyleSheet.absoluteFill}
                        maskElement={<LinearGradient colors={['rgba(0,0,0,0)', 'rgba(0,0,0,0.34)', 'rgba(0,0,0,0.84)']} locations={[0, 0.86, 1]} style={StyleSheet.absoluteFill} />}
                    >
                        <BlurView
                            style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(wallpaperGradient[wallpaperGradient.length - 1], 0.78) }]}
                            intensity={18}
                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        />
                    </MaskedViewAny>
                </View>

                <Animated.View style={styles.inputSticky}>
                    <View ref={inputBarRef} style={[styles.inputBar, { paddingBottom: bottomInsetPadding, paddingTop: inputVerticalPadding }]}>
                        <ChatInput
                            text={text}
                            setText={setText}
                            onSend={handleSend}
                            onAttach={handleTestAttach}
                            onGif={handleTestGif}
                            onCamera={handleTestCamera}
                            currentChatId={effectiveChatId || undefined}
                            keyboardProgress={keyboardShift}
                            replyTo={replyTo}
                            onCancelReply={() => setReplyTo(null)}
                            manualClear={true}
                            onTypingStatusChange={(isTyping) => {
                                if (!EMIT_TYPING_IN_TEST) return;
                                if (!effectiveChatId) return;
                                if (isTyping) sendTyping(effectiveChatId);
                                else sendStopTyping(effectiveChatId);
                            }}
                        />
                    </View>
                </Animated.View>
            </Animated.View>

            <View style={[styles.headerMask, { height: insets.top + 80 }]}>
                <MaskedViewAny
                    style={StyleSheet.absoluteFill}
                    maskElement={<LinearGradient colors={['rgba(0,0,0,0.9)', 'rgba(0,0,0,0)']} locations={[0.56, 1]} style={StyleSheet.absoluteFill} />}
                >
                    <BlurView
                        intensity={20}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(wallpaperGradient[0], 0.85) }]}
                    />
                </MaskedViewAny>
            </View>

            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]} pointerEvents="box-none">
                <View style={{ position: 'absolute', left: 14, top: insets.top + 8 }}>
                    <SafeLiquidGlass style={{ borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity style={styles.headerCircleBtn} onPress={() => router.back()}>
                            <ChevronLeft color={colors.text} size={30} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                </View>
                <SafeLiquidGlass style={{ maxWidth: '60%', minWidth: 170, height: 44, borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 12 }}>
                        <Text style={[styles.headerTitle, { color: colors.text }]} numberOfLines={1}>{displayName}</Text>
                        <Text style={[styles.headerStatus, { color: isFriendOnline ? '#53E08A' : withAlpha(colors.text, 0.68) }]} numberOfLines={1}>
                            {headerStatusText}
                        </Text>
                    </View>
                </SafeLiquidGlass>
                <View style={{ position: 'absolute', right: 14, top: insets.top + 8 }}>
                    <SafeLiquidGlass style={{ height: 44, width: 44, borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        {avatarUri ? (
                            <Image source={{ uri: avatarUri }} style={styles.avatarImage} />
                        ) : (
                            <LinearGradient
                                colors={bubbleTheme.meGradient}
                                start={{ x: 0, y: 0 }}
                                end={{ x: 1, y: 1 }}
                                style={styles.avatarFallback}
                            >
                                <Text style={styles.avatarLetter}>{displayName[0]?.toUpperCase() || 'U'}</Text>
                            </LinearGradient>
                        )}
                    </SafeLiquidGlass>
                </View>
            </View>

            {!ghostData && pendingGhost && (
                <View
                    pointerEvents="none"
                    style={{
                        position: 'absolute',
                        left: pendingGhost.startX,
                        top: pendingGhost.startY,
                        width: pendingGhost.startWidth,
                        height: pendingGhost.startHeight,
                        zIndex: 9998,
                    }}
                >
                    <View style={styles.crossfadeContent}>
                        <View style={styles.crossfadeInputText}>
                            <Text style={styles.bubbleTextInput}>{pendingGhost.text}</Text>
                        </View>
                    </View>
                </View>
            )}

            {ghostData && (
                <CrossfadeOverlay
                    text={ghostData.text}
                    messageType={ghostData.messageType}
                    status={ghostData.status}
                    timestamp={ghostData.timestamp}
                    startX={ghostData.startX}
                    startY={ghostData.startY}
                    startWidth={ghostData.startWidth}
                    startHeight={ghostData.startHeight}
                    targetX={ghostData.targetX}
                    targetY={ghostData.targetY}
                    targetWidth={ghostData.targetWidth}
                    targetHeight={ghostData.targetHeight}
                    shape={ghostData.shape}
                    bubbleTheme={ghostData.bubbleTheme}
                    onComplete={onGhostComplete}
                />
            )}
        </View>
    );
}

// ------------------------------------------------------------------
// STYLES — matching real MessageBubble
// ------------------------------------------------------------------
const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#1a1a2e',
    },
    headerTitle: {
        fontSize: 15,
        fontWeight: '600',
    },
    headerStatus: {
        fontSize: 12,
        marginTop: 1,
    },
    listArea: {
        flex: 1,
    },
    pageBody: {
        flex: 1,
    },
    listContent: {
        paddingHorizontal: 0,
    },
    bubbleWrapper: {
        maxWidth: '85%',
        marginTop: 1,
        marginBottom: 1,
    },
    swipeContainer: {
        position: 'relative',
        width: '100%',
    },
    swipeContainerMe: {
        alignItems: 'flex-end',
    },
    swipeContainerThem: {
        alignItems: 'flex-start',
    },
    replyIconContainer: {
        position: 'absolute',
        top: '50%',
        marginTop: -14,
        width: 28,
        height: 28,
        borderRadius: 14,
        backgroundColor: 'rgba(20,20,26,0.46)',
        borderWidth: StyleSheet.hairlineWidth,
        borderColor: 'rgba(255,255,255,0.2)',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 4,
    },
    replyIconLeft: {
        left: 18,
    },
    replyIconRight: {
        right: 18,
    },
    messageContainer: {
        position: 'relative',
        overflow: 'visible',
    },
    bubble: {
        borderRadius: BUBBLE_RADIUS,
        padding: BUBBLE_PADDING_V,
        paddingHorizontal: BUBBLE_PADDING_H,
        minWidth: BUBBLE_MIN_WIDTH,
    },
    replyPreview: {
        flexDirection: 'row',
        alignItems: 'stretch',
        marginBottom: 5,
        borderRadius: 8,
        overflow: 'hidden',
    },
    replyPreviewBar: {
        width: 3,
    },
    replyPreviewBody: {
        flex: 1,
        paddingHorizontal: 7,
        paddingVertical: 4,
        backgroundColor: 'rgba(0,0,0,0.14)',
    },
    replyPreviewAuthor: {
        fontSize: 11,
        fontWeight: '600',
        lineHeight: 13,
    },
    replyPreviewText: {
        fontSize: 11,
        marginTop: 1,
        lineHeight: 13,
    },
    bubbleText: {
        color: BUBBLE_TEXT_COLOR,
        fontSize: BUBBLE_TEXT_SIZE,
        lineHeight: BUBBLE_TEXT_LINE_HEIGHT,
        flexShrink: 1,
    },
    bubbleTextInput: {
        color: INPUT_TEXT_COLOR,
        fontSize: BUBBLE_TEXT_SIZE,
        lineHeight: BUBBLE_TEXT_LINE_HEIGHT,
        textAlign: 'right',
    },
    crossfadeBubbleBg: {
        ...StyleSheet.absoluteFillObject,
        borderRadius: BUBBLE_RADIUS,
        overflow: 'hidden',
    },
    crossfadeContent: {
        flex: 1,
        padding: BUBBLE_PADDING_V,
        paddingHorizontal: BUBBLE_PADDING_H,
    },
    crossfadeInputText: {
        position: 'absolute',
        left: BUBBLE_PADDING_H,
        top: BUBBLE_PADDING_V,
        right: BUBBLE_PADDING_H,
        alignItems: 'flex-end',
        justifyContent: 'flex-start',
    },
    messageLine: {
        flexDirection: 'row',
        alignItems: 'flex-end',
    },
    timeMetaInline: {
        flexDirection: 'row',
        alignItems: 'center',
        marginLeft: 6,
        marginBottom: 0,
        flexShrink: 0,
        opacity: BUBBLE_TIME_OPACITY,
    },
    statusSlot: {
        width: 14,
        marginLeft: 2,
        alignItems: 'center',
        justifyContent: 'center',
    },
    timeText: {
        fontSize: BUBBLE_TIME_SIZE,
        color: 'rgba(255,255,255,0.7)',
    },
    headerMask: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 60,
        pointerEvents: 'none',
    },
    headerContentContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 130,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: 14,
    },
    headerCircleBtn: {
        width: 44,
        height: 44,
        alignItems: 'center',
        justifyContent: 'center',
    },
    avatarFallback: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    avatarImage: {
        width: '100%',
        height: '100%',
    },
    avatarLetter: {
        color: '#fff',
        fontSize: 18,
        fontWeight: '600',
    },
    footerMask: {
        position: 'absolute',
        bottom: -10,
        left: 0,
        right: 0,
        zIndex: 50,
    },
    inputBar: {
        paddingHorizontal: 16,
        overflow: 'visible',
    },
    inputSticky: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        zIndex: 70,
        overflow: 'visible',
    },
    typingInlineRow: {
        width: '100%',
        alignItems: 'flex-start',
        paddingLeft: 14,
        marginTop: 0,
        marginBottom: 0,
    },
    typingMask: {
        width: TYPING_MASK_WIDTH,
        height: 16,
    },
    typingMaskInner: {
        flex: 1,
        justifyContent: 'center',
    },
    typingTextMask: {
        fontSize: 13,
        fontWeight: '600',
        letterSpacing: 0.2,
        color: '#000',
    },
    typingShimmerBand: {
        position: 'absolute',
        top: 0,
        bottom: 0,
        left: -TYPING_SHIMMER_TRAVEL,
        width: 100,
    },
    typingShimmerBandFill: {
        flex: 1,
    },
});
