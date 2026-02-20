import React, { useCallback, useMemo, useRef, useState } from 'react';
import {
    Platform,
    ScrollView,
    StyleSheet,
    Text,
    TouchableOpacity,
    View,
    TextInput,
    LayoutChangeEvent,
} from 'react-native';
import * as ExpoCrypto from 'expo-crypto';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
    getNativeChatRuntimeInfo,
    mapMessagesToNativeRows,
    NativeChatSurface,
    type NativeChatAppearance,
    type NativeChatSurfaceRef,
} from '../src/native/chat';

// ---------------------------------------------------------------------------
// Test page for comparing native list insertion animation approaches.
//
// The native Swift code in ChatListView.swift uses one of these modes:
//   0 = None           — no insertion animation at all (instant)
//   1 = SlideUpNewOnly  — only the newly inserted cell slides up
//   2 = TelegramOffset  — record pre-update positions, animate deltas (current impl)
//   3 = SpringBatch     — UIView.animate with spring on the batch update itself
//
// This page sends an `insertionAnimationMode` via the appearance config
// so we can switch modes at runtime without rebuilding.
// ---------------------------------------------------------------------------

type MockMessage = {
    id: string;
    text: string;
    timestamp: string;
    timestampMs: number;
    isMe: boolean;
    status: string;
};

const LOREM_POOL = [
    'Hello there!',
    'How are you?',
    'This is a test message for insertion animation.',
    'Short msg',
    'A longer message to test how multi-line bubbles animate when they are inserted into the list view.',
    'Checking smoothness',
    'Does it shift?',
    'Native list rocks!',
    'Testing 1 2 3',
    'Another line of text to see if the list stays stable during rapid inserts.',
    'Smooth insertion is key',
    'No flicker please',
    'Telegram-style offset animation',
    'Spring batch mode test',
    'Quick brown fox jumps over the lazy dog',
];

const formatTime = (ms: number) =>
    new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });

const ANIMATION_MODES = ['None', 'SlideUp New', 'Telegram Offset', 'Spring Batch'] as const;

export default function TestNativeInsertScreen() {
    const insets = useSafeAreaInsets();
    const runtime = useMemo(() => getNativeChatRuntimeInfo(), []);
    const surfaceRef = useRef<NativeChatSurfaceRef>(null);
    const viewportRef = useRef<{ distanceFromBottom: number; atBottom: boolean }>({
        distanceFromBottom: 0,
        atBottom: true,
    });
    const autoTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);

    // State
    const [messages, setMessages] = useState<MockMessage[]>(() => {
        const seed: MockMessage[] = [];
        const now = Date.now();
        for (let i = 0; i < 8; i++) {
            seed.push({
                id: `seed-${i}`,
                text: LOREM_POOL[i % LOREM_POOL.length],
                timestamp: formatTime(now - (8 - i) * 60000),
                timestampMs: now - (8 - i) * 60000,
                isMe: i % 3 !== 0,
                status: 'sent',
            });
        }
        return seed;
    });

    const [animMode, setAnimMode] = useState(2); // Default: Telegram Offset
    const [sendTransitionEnabled, setSendTransitionEnabled] = useState(true);
    const [autoSending, setAutoSending] = useState(false);
    const [eventLog, setEventLog] = useState<string[]>([]);

    // Input State
    const [inputText, setInputText] = useState('');
    const inputRef = useRef<View>(null);

    const addLog = useCallback((msg: string) => {
        setEventLog((prev) => [`[${formatTime(Date.now())}] ${msg}`, ...prev].slice(0, 30));
    }, []);

    const nativeRows = useMemo(
        () =>
            mapMessagesToNativeRows(
                messages.map((m) => ({
                    id: m.id,
                    text: m.text,
                    isMe: m.isMe,
                    timestampMs: m.timestampMs,
                    timestamp: m.timestamp,
                    status: m.status,
                    type: 'text',
                })),
            ),
        [messages],
    );

    const appearance = useMemo<NativeChatAppearance>(
        () => ({
            backgroundMode: 'gradient',
            wallpaperGradient: ['#1a1a2e', '#16213e', '#0f3460'],
            wallpaperOpacity: 1,
            bubbleMeGradient: ['#7C5CE0', '#6A4FCF'],
            bubbleThemColor: '#2a2a4a',
            textColorMe: '#FFFFFF',
            textColorThem: '#DDDDDD',
            timeColorMe: 'rgba(255,255,255,0.72)',
            timeColorThem: 'rgba(255,255,255,0.5)',
            dayTextColor: 'rgba(236,239,255,0.82)',
            dayBackgroundColor: 'rgba(26,26,46,0.42)',
            dayBorderColor: 'rgba(255,255,255,0.16)',
            // Custom field to control animation mode in Swift
            insertionAnimationMode: animMode,
        }),
        [animMode],
    );

    const handleViewportChanged = useCallback(
        (event: { nativeEvent: Record<string, unknown> }) => {
            const e = event?.nativeEvent || {};
            viewportRef.current = {
                distanceFromBottom: Number(e.distanceFromBottom || 0),
                atBottom: !!e.atBottom,
            };
        },
        [],
    );

    const handleNativeEvent = useCallback(
        (event: { nativeEvent: Record<string, unknown> }) => {
            const e = event?.nativeEvent || {};
            const type = String(e.type || '');
            if (type === 'sendTransitionStarted' || type === 'sendTransitionCompleted') {
                addLog(`${type} (${e.messageId})`);
            }
        },
        [addLog],
    );

    // --- Send Logic ---
    const handleSend = useCallback(() => {
        if (!inputText.trim()) return;

        const text = inputText.trim();
        const messageId = ExpoCrypto.randomUUID();
        const now = Date.now();
        const timestamp = formatTime(now);

        setInputText(''); // Clear immediately

        // 1. Measure the input to get start element coordinates
        inputRef.current?.measureInWindow((x, y, w, h) => {
            // 2. Start the native transition FIRST
            if (sendTransitionEnabled) {
                // Adjust for potential padding/margin differences
                // We'll pass the full input wrapper rect
                surfaceRef.current?.startSendTransition({
                    messageId,
                    text,
                    timestamp,
                    startX: x,
                    startY: y,
                    startWidth: w,
                    startHeight: h,
                });
            }

            // 3. Add message to the list
            const newMessage: MockMessage = {
                id: messageId,
                text,
                timestamp,
                timestampMs: now,
                isMe: true,
                status: 'sending',
            };

            setMessages((prev) => [...prev, newMessage]);
            addLog(`Sent: "${text.substring(0, 10)}..."`);

            // Scroll to bottom
            requestAnimationFrame(() => {
                surfaceRef.current?.scrollToBottom(true);
            });

            // Mark as sent after delay
            setTimeout(() => {
                setMessages((prev) =>
                    prev.map((m) => (m.id === messageId ? { ...m, status: 'sent' } : m))
                );
            }, 600);
        });
    }, [inputText, sendTransitionEnabled, animMode, addLog]);

    // --- Other Helpers ---
    const addIncomingMessage = useCallback(() => {
        const now = Date.now();
        const newMessage: MockMessage = {
            id: ExpoCrypto.randomUUID(),
            text: LOREM_POOL[Math.floor(Math.random() * LOREM_POOL.length)],
            timestamp: formatTime(now),
            timestampMs: now,
            isMe: false,
            status: 'sent',
        };
        setMessages((prev) => [...prev, newMessage]);
        addLog(`Received message`);

        // Auto scroll if near bottom
        const nearBottom = viewportRef.current.atBottom || viewportRef.current.distanceFromBottom < 40;
        if (nearBottom) {
            requestAnimationFrame(() => {
                surfaceRef.current?.scrollToBottom(false);
            });
        }
    }, [addLog]);

    const clearMessages = useCallback(() => {
        setMessages([]);
        addLog('Cleared all messages');
    }, [addLog]);

    return (
        <View style={[styles.screen, { paddingTop: insets.top }]}>
            {/* Header */}
            <View style={styles.header}>
                <Text style={styles.title}>Native Insert Animation Lab</Text>
                <Text style={styles.subtitle}>
                    {runtime.enabled ? '✅ Native runtime' : '❌ Fallback'} · Mode:{' '}
                    {ANIMATION_MODES[animMode]}
                </Text>
            </View>

            {/* Animation mode selector */}
            <View style={styles.modeRow}>
                {ANIMATION_MODES.map((label, idx) => (
                    <TouchableOpacity
                        key={label}
                        style={[styles.modeBtn, animMode === idx && styles.modeBtnActive]}
                        onPress={() => {
                            setAnimMode(idx);
                            addLog(`Mode → ${label}`);
                        }}
                    >
                        <Text style={[styles.modeBtnText, animMode === idx && styles.modeBtnTextActive]}>
                            {label}
                        </Text>
                    </TouchableOpacity>
                ))}
            </View>

            {/* Native chat surface */}
            <View style={styles.listContainer}>
                <NativeChatSurface
                    ref={surfaceRef}
                    surfaceId="test-native-insert-surface"
                    rows={nativeRows}
                    appearance={appearance}
                    contentPaddingBottom={20}
                    onViewportChanged={handleViewportChanged}
                    onNativeEvent={handleNativeEvent}
                />
            </View>

            {/* Chat Input Bar */}
            <View
                style={[
                    styles.inputContainer,
                    { paddingBottom: Math.max(insets.bottom, 10) },
                ]}
            >
                <View style={styles.inputRow}>
                    <TouchableOpacity style={styles.iconBtn} onPress={clearMessages}>
                        <Text style={{ fontSize: 18 }}>🗑</Text>
                    </TouchableOpacity>
                    <View
                        ref={inputRef}
                        style={styles.inputWrapper}
                        collapsable={false} // Important for measure in Android/some cases
                    >
                        <TextInput
                            style={styles.textInput}
                            value={inputText}
                            onChangeText={setInputText}
                            placeholder="Type a message..."
                            placeholderTextColor="#666"
                            multiline
                        />
                    </View>
                    <TouchableOpacity
                        style={[styles.sendBtn, !inputText.trim() && styles.sendBtnDisabled]}
                        onPress={handleSend}
                        disabled={!inputText.trim()}
                    >
                        <Text style={styles.sendBtnText}>➤</Text>
                    </TouchableOpacity>
                </View>

                {/* Toggles Footer */}
                <View style={styles.togglesRow}>
                    <TouchableOpacity
                        style={[styles.miniToggle, sendTransitionEnabled && styles.miniToggleActive]}
                        onPress={() => setSendTransitionEnabled(!sendTransitionEnabled)}
                    >
                        <Text style={[styles.miniToggleText, sendTransitionEnabled && styles.miniToggleTextActive]}>
                            {sendTransitionEnabled ? 'Trans: ON' : 'Trans: OFF'}
                        </Text>
                    </TouchableOpacity>

                    <TouchableOpacity
                        style={styles.miniToggle}
                        onPress={addIncomingMessage}
                    >
                        <Text style={styles.miniToggleText}>+1 Them</Text>
                    </TouchableOpacity>
                </View>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    screen: {
        flex: 1,
        backgroundColor: '#0d0d1a',
    },
    header: {
        paddingHorizontal: 16,
        paddingVertical: 8,
        backgroundColor: '#16213e',
        borderBottomWidth: StyleSheet.hairlineWidth,
        borderBottomColor: '#333',
    },
    title: {
        fontSize: 17,
        fontWeight: '700',
        color: '#fff',
    },
    subtitle: {
        fontSize: 12,
        color: '#888',
        marginTop: 2,
    },
    modeRow: {
        flexDirection: 'row',
        paddingHorizontal: 8,
        paddingVertical: 6,
        backgroundColor: '#111128',
        gap: 4,
    },
    modeBtn: {
        flex: 1,
        paddingVertical: 6,
        borderRadius: 8,
        backgroundColor: '#1e1e3a',
        alignItems: 'center',
    },
    modeBtnActive: {
        backgroundColor: '#7C5CE0',
    },
    modeBtnText: {
        fontSize: 10,
        fontWeight: '600',
        color: '#888',
    },
    modeBtnTextActive: {
        color: '#fff',
    },
    listContainer: {
        flex: 1,
    },
    inputContainer: {
        backgroundColor: '#16213e',
        borderTopWidth: StyleSheet.hairlineWidth,
        borderTopColor: '#333',
        paddingHorizontal: 10,
        paddingTop: 8,
    },
    inputRow: {
        flexDirection: 'row',
        alignItems: 'flex-end',
        gap: 8,
        marginBottom: 8,
    },
    iconBtn: {
        width: 36,
        height: 36,
        justifyContent: 'center',
        alignItems: 'center',
        borderRadius: 18,
        backgroundColor: '#1e1e3a',
    },
    inputWrapper: {
        flex: 1,
        minHeight: 36,
        maxHeight: 100,
        backgroundColor: '#0d0d1a',
        borderRadius: 18,
        paddingHorizontal: 12,
        paddingVertical: 8,
        justifyContent: 'center',
    },
    textInput: {
        color: '#fff',
        fontSize: 16,
        padding: 0,
        margin: 0,
    },
    sendBtn: {
        width: 36,
        height: 36,
        justifyContent: 'center',
        alignItems: 'center',
        borderRadius: 18,
        backgroundColor: '#7C5CE0',
    },
    sendBtnDisabled: {
        backgroundColor: '#333',
        opacity: 0.7,
    },
    sendBtnText: {
        color: '#fff',
        fontSize: 18,
        fontWeight: '700',
        marginTop: -2,
    },
    togglesRow: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        paddingHorizontal: 4,
    },
    miniToggle: {
        paddingVertical: 4,
        paddingHorizontal: 8,
        borderRadius: 4,
        backgroundColor: '#1e1e3a',
    },
    miniToggleActive: {
        backgroundColor: '#3a2a6a',
    },
    miniToggleText: {
        fontSize: 10,
        color: '#888',
    },
    miniToggleTextActive: {
        color: '#ccc',
        fontWeight: '600',
    },
    // Legacy styles kept to prevent crashes if I missed something, but logic replaced above
    logScroll: { height: 0 },
    logLine: { height: 0 },
});
