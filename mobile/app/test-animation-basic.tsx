import React, { useState, useRef, useCallback, useEffect } from 'react';
import {
    View,
    Text,
    TextInput,
    StyleSheet,
    TouchableOpacity,
    KeyboardAvoidingView,
    Platform,
} from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    Easing,
    runOnJS,
    interpolate,
} from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowUp } from 'lucide-react-native';
import * as ExpoCrypto from 'expo-crypto';
import { FlashList } from '@shopify/flash-list';

// Match your real theme colors
const BUBBLE_GRADIENT: [string, string] = ['#7C5CE0', '#6A4FCF'];
const BUBBLE_TEXT_COLOR = '#fff';
const INPUT_TEXT_COLOR = '#fff';
const LIST_BOTTOM_THRESHOLD = 40;
const TELEGRAM_SEND_DURATION_MS = 300;
const TELEGRAM_VERTICAL_BEZIER: [number, number, number, number] = [
    0.19919472913616398,
    0.010644531250000006,
    0.27920937042459737,
    0.91025390625,
];
const TELEGRAM_HORIZONTAL_BEZIER: [number, number, number, number] = [0.23, 1.0, 0.32, 1.0];

// ------------------------------------------------------------------
// Types
// ------------------------------------------------------------------
interface Message {
    id: string;
    text: string;
    isMe: boolean;
    isGhostHidden?: boolean; // Hidden while ghost overlay is active
    timestamp: string;
}

// ------------------------------------------------------------------
// CROSSFADE OVERLAY — The Telegram Magic
//
// Key improvements:
// 1. Uses Telegram-matched horizontal/vertical timing curves
// 2. Ghost bubble matches real MessageBubble styling exactly
// 3. Position is measured from the real (hidden) bubble, not guessed
// 4. Smooth spring physics, no abrupt swap
// ------------------------------------------------------------------
interface CrossfadeOverlayProps {
    text: string;
    startX: number;
    startY: number;
    startWidth: number;
    startHeight: number;
    targetX: number;
    targetY: number;
    targetWidth: number;
    targetHeight: number;
    scrollOffsetY: SharedValue<number>;
    onComplete: () => void;
}

const CrossfadeOverlay = ({
    text,
    timestamp,
    startX, startY, startWidth, startHeight,
    targetX, targetY, targetWidth, targetHeight,
    scrollOffsetY,
    onComplete,
}: CrossfadeOverlayProps & { timestamp: string }) => {
    // Telegram animates horizontal/vertical axes with distinct curves.
    const horizontalProgress = useSharedValue(0);
    const verticalProgress = useSharedValue(0);

    useEffect(() => {
        horizontalProgress.value = withTiming(1, {
            duration: TELEGRAM_SEND_DURATION_MS,
            easing: Easing.bezier(
                TELEGRAM_HORIZONTAL_BEZIER[0],
                TELEGRAM_HORIZONTAL_BEZIER[1],
                TELEGRAM_HORIZONTAL_BEZIER[2],
                TELEGRAM_HORIZONTAL_BEZIER[3]
            ),
        });
        verticalProgress.value = withTiming(1, {
            duration: TELEGRAM_SEND_DURATION_MS,
            easing: Easing.bezier(
                TELEGRAM_VERTICAL_BEZIER[0],
                TELEGRAM_VERTICAL_BEZIER[1],
                TELEGRAM_VERTICAL_BEZIER[2],
                TELEGRAM_VERTICAL_BEZIER[3]
            ),
        }, (finished) => {
            if (finished) {
                runOnJS(onComplete)();
            }
        });
    }, []);

    const containerStyle = useAnimatedStyle(() => {
        const px = horizontalProgress.value;
        const py = verticalProgress.value;

        // Interpolate position
        const x = interpolate(px, [0, 1], [startX, targetX]);
        // Scroll offset should only affect the target (which moves with the list), 
        // not the start (which is fixed at the input bar).
        // By interpolating to (targetY + scroll), we gradually apply the scroll effect.
        const y = interpolate(py, [0, 1], [startY, targetY + scrollOffsetY.value]);
        const w = interpolate(px, [0, 1], [startWidth, targetWidth]);
        const h = interpolate(py, [0, 1], [startHeight, targetHeight]);

        return {
            position: 'absolute',
            left: x,
            top: y,
            width: w,
            height: h,
            zIndex: 9999,
        };
    });

    // Bubble background fades in (0 → 0.2 = no bg, 0.2 → 0.6 = fade in)
    const bgStyle = useAnimatedStyle(() => {
        const bgOpacity = interpolate(verticalProgress.value, [0, 0.1, 0.4], [0, 0, 1], 'clamp');
        return {
            ...StyleSheet.absoluteFillObject,
            borderRadius: 18,
            borderBottomRightRadius: 4,
            overflow: 'hidden',
            opacity: bgOpacity,
        };
    });

    // Input text fades out
    const inputTextStyle = useAnimatedStyle(() => {
        const opacity = interpolate(verticalProgress.value, [0, 0.24], [1, 0], 'clamp');
        return { opacity };
    });

    // Bubble text + time fades in
    const bubbleContentStyle = useAnimatedStyle(() => {
        const opacity = interpolate(verticalProgress.value, [0.06, 0.34], [0, 1], 'clamp');
        return { opacity };
    });

    return (
        <Animated.View style={containerStyle} pointerEvents="none">
            {/* Bubble background — gradient matching real MessageBubble */}
            <Animated.View style={bgStyle}>
                <LinearGradient
                    colors={BUBBLE_GRADIENT}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                    style={StyleSheet.absoluteFillObject}
                />
            </Animated.View>

            {/* Text container */}
            <View style={{
                flex: 1,
                padding: 7,
                paddingHorizontal: 10,
            }}>
                {/* Input-style text (fades out) - absolute positioned to match input location relative to bubble start */}
                <Animated.View style={[{ position: 'absolute', left: 10, top: 7, right: 10 }, inputTextStyle]}>
                    <Text style={{ color: INPUT_TEXT_COLOR, fontSize: 16, lineHeight: 20 }}>{text}</Text>
                </Animated.View>

                {/* Bubble-style text & time (fades in) — matches MessageBubble exactly */}
                <Animated.View style={bubbleContentStyle}>
                    <Text style={{ color: BUBBLE_TEXT_COLOR, fontSize: 16, lineHeight: 20 }}>{text}</Text>
                    <View style={styles.timeMeta}>
                        <Text style={styles.timeText}>
                            {timestamp}
                        </Text>
                    </View>
                </Animated.View>
            </View>
        </Animated.View>
    );
};

// ------------------------------------------------------------------
// Message Bubble — matches real MessageBubble styling
// ------------------------------------------------------------------
const MessageBubble = React.memo(({ item, shouldTrackGhostLayout, onLayout }: {
    item: Message;
    shouldTrackGhostLayout: boolean;
    onLayout?: (id: string, x: number, y: number, w: number, h: number) => void;
}) => {
    const bubbleRef = useRef<View>(null);

    const reportHiddenLayout = useCallback(() => {
        if (!item.isGhostHidden || !shouldTrackGhostLayout || !onLayout) return;
        bubbleRef.current?.measureInWindow((x, y, w, h) => {
            if (w > 0 && h > 0) {
                onLayout(item.id, x, y, w, h);
            }
        });
    }, [item.isGhostHidden, shouldTrackGhostLayout, onLayout, item.id]);

    // Measure after layout if this is the ghost-hidden message
    useEffect(() => {
        if (item.isGhostHidden && shouldTrackGhostLayout && onLayout) {
            const frameId = requestAnimationFrame(reportHiddenLayout);
            const settleTimer = setTimeout(reportHiddenLayout, 90);
            return () => {
                cancelAnimationFrame(frameId);
                clearTimeout(settleTimer);
            };
        }
    }, [item.isGhostHidden, shouldTrackGhostLayout, onLayout, reportHiddenLayout]);

    if (item.isMe) {
        return (
            <View
                ref={bubbleRef}
                collapsable={false}
                onLayout={shouldTrackGhostLayout ? reportHiddenLayout : undefined}
                style={[
                    styles.bubbleWrapper,
                    { alignSelf: 'flex-end', marginHorizontal: 8 },
                    item.isGhostHidden && { opacity: 0 },
                ]}
            >
                <LinearGradient
                    colors={BUBBLE_GRADIENT}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                    style={[styles.bubble, { borderBottomRightRadius: 4 }]}
                >
                    <Text style={{ color: BUBBLE_TEXT_COLOR, fontSize: 16, lineHeight: 20 }}>{item.text}</Text>
                    <View style={styles.timeMeta}>
                        <Text style={styles.timeText}>
                            {item.timestamp}
                        </Text>
                    </View>
                </LinearGradient>
            </View>
        );
    }

    return (
        <View
            ref={bubbleRef}
            style={[
                styles.bubbleWrapper,
                { alignSelf: 'flex-start', marginHorizontal: 8 },
            ]}
        >
            <View style={[styles.bubble, { backgroundColor: '#2a2a4a', borderBottomLeftRadius: 4 }]}>
                <Text style={{ color: '#ddd', fontSize: 16, lineHeight: 20 }}>{item.text}</Text>
                <View style={styles.timeMeta}>
                    <Text style={[styles.timeText, { color: 'rgba(255,255,255,0.5)' }]}>
                        {item.timestamp}
                    </Text>
                </View>
            </View>
        </View>
    );
});

// ------------------------------------------------------------------
// MAIN CHAT SCREEN
// ------------------------------------------------------------------
export default function TelegramCrossfadeChat() {
    const [messages, setMessages] = useState<Message[]>([
        { id: '1', text: 'Hey there!', isMe: false, timestamp: '10:01' },
        { id: '2', text: 'Hello! How are you?', isMe: true, timestamp: '10:02' },
        { id: '3', text: 'Testing Telegram crossfade.', isMe: false, timestamp: '10:03' },
        { id: '4', text: 'Text morphs from input to bubble!', isMe: true, timestamp: '10:04' },
    ]);
    const [text, setText] = useState('');
    const flatListRef = useRef<FlashList<Message>>(null);
    const inputBarRef = useRef<View>(null);
    const listMetricsRef = useRef({
        contentHeight: 0,
        layoutHeight: 0,
        offsetY: 0,
    });
    const shouldAutoScrollRef = useRef(true);
    const prevScrollOffsetRef = useRef(0);
    const pendingGhostSafetyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const listScrollY = useSharedValue(0);

    // Ghost state
    const [ghostData, setGhostData] = useState<{
        text: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        targetX: number;
        targetY: number;
        targetWidth: number;
        targetHeight: number;
        messageId: string;
    } | null>(null);

    // Pending ghost — waiting for the real bubble to measure itself
    const [pendingGhost, setPendingGhost] = useState<{
        text: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        messageId: string;
    } | null>(null);

    const pendingGhostOffsetStyle = useAnimatedStyle(() => ({
        // We want the pending ghost to scroll with the list until it's replaced.
        // It's positioned at startX/startY (Root coords).
        // If the list scrolls, we don't want the ghost to move?? 
        // Wait, pending ghost is at the INPUT bar (fixed). 
        // It "lifts off" from input. Input is Fixed.
        // So pending ghost should NOT scroll.
        transform: [{ translateY: 0 }],
    }));

    useEffect(() => {
        return () => {
            if (pendingGhostSafetyTimerRef.current) {
                clearTimeout(pendingGhostSafetyTimerRef.current);
                pendingGhostSafetyTimerRef.current = null;
            }
        };
    }, []);

    const rootRef = useRef<View>(null);
    const rootOffsetRef = useRef({ x: 0, y: 0 });

    const measureRoot = useCallback(() => {
        rootRef.current?.measureInWindow((x, y) => {
            rootOffsetRef.current = { x, y };
        });
    }, []);

    // Called when the hidden real bubble measures itself
    const onBubbleLayout = useCallback((id: string, x: number, y: number, w: number, h: number) => {
        // Compensate for scroll offset AND container offset.
        // x, y are Window coordinates.
        // rootOffsetRef is Window coordinate of container.
        // listScrollY is current scroll offset.

        // VisualY (in Root) = y - ry.
        // ContentY (Absolute List Space) = VisualY + scrollY.

        const currentScroll = listScrollY.value;
        const { x: rx, y: ry } = rootOffsetRef.current;

        const adjustedX = x - rx;
        const adjustedY = y - ry + currentScroll;

        setPendingGhost(prev => {
            if (!prev || prev.messageId !== id) return prev;

            if (pendingGhostSafetyTimerRef.current) {
                clearTimeout(pendingGhostSafetyTimerRef.current);
                pendingGhostSafetyTimerRef.current = null;
            }

            // Now we know the exact target — launch the ghost
            setGhostData({
                ...prev,
                targetX: adjustedX,
                targetY: adjustedY,
                targetWidth: w,
                targetHeight: h,
            });

            return null; // Clear pending
        });

        setGhostData(prev => {
            if (!prev || prev.messageId !== id) return prev;
            // Check if Content positions changed
            const moved =
                Math.abs(prev.targetX - adjustedX) > 0.5 ||
                Math.abs(prev.targetY - adjustedY) > 0.5 ||
                Math.abs(prev.targetWidth - w) > 0.5 ||
                Math.abs(prev.targetHeight - h) > 0.5;
            if (!moved) return prev;
            return {
                ...prev,
                targetX: adjustedX,
                targetY: adjustedY,
                targetWidth: w,
                targetHeight: h,
            };
        });
    }, [listScrollY]);

    const handleSend = useCallback(() => {
        if (!text.trim()) return;
        const currentText = text.trim();
        const messageId = ExpoCrypto.randomUUID();
        const timestamp = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });

        inputBarRef.current?.measureInWindow((barX, barY, barW) => {
            // Adjust for root offset
            const { x: rx, y: ry } = rootOffsetRef.current;

            // Start position: text inside the input field
            // relativeX: (barX - rx) + 16
            // relativeY: (barY - ry) + 13

            const startX = barX - rx + 16;
            const startY = barY - ry + 13;
            const startWidth = barW - 64;
            const startHeight = 40;

            // Clear input — text "lifts off"
            setText('');

            // Add hidden message to list so FlashList lays it out
            setMessages(prev => [...prev, {
                id: messageId,
                text: currentText,
                timestamp,
                isMe: true,
                isGhostHidden: true,
            }]);

            // Set pending ghost — will fire once bubble measures
            setPendingGhost({
                text: currentText,
                timestamp,
                startX,
                startY,
                startWidth,
                startHeight,
                messageId,
            });

            if (pendingGhostSafetyTimerRef.current) {
                clearTimeout(pendingGhostSafetyTimerRef.current);
            }
            pendingGhostSafetyTimerRef.current = setTimeout(() => {
                setPendingGhost(prev => (prev?.messageId === messageId ? null : prev));
                setMessages(prev => prev.map((m) => (
                    m.id === messageId ? { ...m, isGhostHidden: false } : m
                )));
                pendingGhostSafetyTimerRef.current = null;
            }, 700);
        });
    }, [text]);

    const onGhostComplete = useCallback(() => {
        if (!ghostData) return;

        if (pendingGhostSafetyTimerRef.current) {
            clearTimeout(pendingGhostSafetyTimerRef.current);
            pendingGhostSafetyTimerRef.current = null;
        }

        // Reveal the real bubble
        setMessages(prev =>
            prev.map(m => m.id === ghostData.messageId
                ? { ...m, isGhostHidden: false }
                : m
            )
        );

        // Single-frame handoff avoids subtle opacity/brightness wobble at the end.
        setGhostData(null);

    }, [ghostData]);

    const simulateReceive = useCallback(() => {
        const responses = ['Nice!', 'That looks great!', 'How did you do that?', 'Smooth!', 'Love it'];
        setMessages(prev => [...prev, {
            id: ExpoCrypto.randomUUID(),
            text: responses[Math.floor(Math.random() * responses.length)],
            isMe: false,
            timestamp: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }),
        }]);
    }, []);

    const renderItem = useCallback(
        ({ item, target }: { item: Message; target: 'Cell' | 'StickyHeader' | 'Measurement' }) => (
            <MessageBubble item={item} shouldTrackGhostLayout={target === 'Cell'} onLayout={onBubbleLayout} />
        ),
        [onBubbleLayout]
    );

    return (
        <KeyboardAvoidingView
            behavior={Platform.OS === 'ios' ? 'padding' : undefined}
            style={styles.container}
        >
            <View
                ref={rootRef}
                style={{ flex: 1 }}
                onLayout={measureRoot}
                collapsable={false}
            >
                {/* Header */}
                <View style={styles.header}>
                    <Text style={styles.headerTitle}>Telegram Crossfade Test</Text>
                    <TouchableOpacity onPress={simulateReceive} style={styles.simBtn}>
                        <Text style={styles.simBtnText}>Simulate Reply</Text>
                    </TouchableOpacity>
                </View>

                {/* Messages — non-inverted, bottom-anchored */}
                <View style={styles.listArea}>
                    <FlashList
                        ref={flatListRef}
                        data={messages}
                        renderItem={renderItem}
                        keyExtractor={(item) => item.id}
                        estimatedItemSize={64}
                        maintainVisibleContentPosition={{
                            autoscrollToBottomThreshold: LIST_BOTTOM_THRESHOLD,
                            animateAutoScrollToBottom: false,
                            startRenderingFromBottom: true,
                        }}
                        contentContainerStyle={styles.listContent}
                        showsVerticalScrollIndicator={false}
                        keyboardDismissMode="interactive"
                        keyboardShouldPersistTaps="handled"
                        onLayout={(event) => {
                            listMetricsRef.current.layoutHeight = event.nativeEvent.layout.height;
                        }}
                        onContentSizeChange={(_w, h) => {
                            listMetricsRef.current.contentHeight = h;
                        }}
                        onScroll={(event) => {
                            const { contentOffset, layoutMeasurement, contentSize } = event.nativeEvent;
                            // Track absolute scroll unconditionally
                            listScrollY.value = contentOffset.y;

                            prevScrollOffsetRef.current = contentOffset.y;
                            listMetricsRef.current.offsetY = contentOffset.y;
                            listMetricsRef.current.layoutHeight = layoutMeasurement.height;
                            listMetricsRef.current.contentHeight = contentSize.height;
                            const distanceFromBottom = contentSize.height - (contentOffset.y + layoutMeasurement.height);
                            shouldAutoScrollRef.current = distanceFromBottom < LIST_BOTTOM_THRESHOLD;
                        }}
                        scrollEventThrottle={16}
                    />
                </View>

                {/* Input Bar */}
                <View ref={inputBarRef} style={styles.inputBar}>
                    <TextInput
                        style={styles.input}
                        placeholder="Message"
                        placeholderTextColor="#666"
                        value={text}
                        onChangeText={setText}
                        onSubmitEditing={handleSend}
                        returnKeyType="send"
                    />
                    <TouchableOpacity
                        style={[styles.sendBtn, !text.trim() && styles.sendBtnDisabled]}
                        onPress={handleSend}
                        disabled={!text.trim()}
                    >
                        <ArrowUp size={20} color="#fff" strokeWidth={3} />
                    </TouchableOpacity>
                </View>

                {/* CROSSFADE GHOST OVERLAY */}
                {!ghostData && pendingGhost && (
                    <Animated.View style={[{
                        position: 'absolute',
                        left: pendingGhost.startX,
                        top: pendingGhost.startY,
                        width: pendingGhost.startWidth,
                        height: pendingGhost.startHeight,
                        zIndex: 9999,
                    }, pendingGhostOffsetStyle]} pointerEvents="none">
                        <View style={{
                            flex: 1,
                            padding: 7,
                            paddingHorizontal: 10,
                        }}>
                            <View style={{ position: 'absolute', left: 10, top: 7, right: 10 }}>
                                <Text style={{ color: INPUT_TEXT_COLOR, fontSize: 16, lineHeight: 20 }}>{pendingGhost.text}</Text>
                            </View>
                        </View>
                    </Animated.View>
                )}

                {ghostData && (
                    <CrossfadeOverlay
                        text={ghostData.text}
                        timestamp={ghostData.timestamp}
                        startX={ghostData.startX}
                        startY={ghostData.startY}
                        startWidth={ghostData.startWidth}
                        startHeight={ghostData.startHeight}
                        targetX={ghostData.targetX}
                        targetY={ghostData.targetY}
                        targetWidth={ghostData.targetWidth}
                        targetHeight={ghostData.targetHeight}
                        scrollOffsetY={listScrollY}
                        onComplete={onGhostComplete}
                    />
                )}
            </View>
        </KeyboardAvoidingView>
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
    header: {
        height: 100,
        justifyContent: 'flex-end',
        alignItems: 'center',
        paddingBottom: 12,
        backgroundColor: '#16213e',
        borderBottomWidth: 0.5,
        borderBottomColor: '#333',
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '600',
        color: '#fff',
    },
    simBtn: {
        marginTop: 4,
        paddingHorizontal: 12,
        paddingVertical: 4,
        backgroundColor: 'rgba(255,255,255,0.1)',
        borderRadius: 12,
    },
    simBtnText: {
        fontSize: 12,
        color: '#7C5CE0',
        fontWeight: '600',
    },
    listArea: {
        flex: 1,
    },
    listContent: {
        flexGrow: 1,
        paddingHorizontal: 16,
        paddingTop: 25,
        paddingBottom: 10,
    },
    bubbleWrapper: {
        maxWidth: '85%',
        marginTop: 1,
        marginBottom: 1,
    },
    bubble: {
        borderRadius: 18,
        padding: 7,
        paddingHorizontal: 10,
        minWidth: 35,
    },
    timeMeta: {
        flexDirection: 'row',
        justifyContent: 'flex-end',
        alignItems: 'center',
        marginTop: 2,
        opacity: 0.8,
    },
    timeText: {
        fontSize: 11,
        color: 'rgba(255,255,255,0.7)',
    },
    inputBar: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 10,
        backgroundColor: '#16213e',
        borderTopWidth: 0.5,
        borderTopColor: '#333',
    },
    input: {
        flex: 1,
        height: 40,
        backgroundColor: '#2a2a4a',
        borderRadius: 20,
        paddingHorizontal: 16,
        fontSize: 16,
        marginRight: 8,
        color: '#fff',
    },
    sendBtn: {
        width: 36,
        height: 36,
        borderRadius: 18,
        backgroundColor: '#7C5CE0',
        justifyContent: 'center',
        alignItems: 'center',
    },
    sendBtnDisabled: {
        opacity: 0.3,
    },
});
