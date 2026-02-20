import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import {
    View,
    Text,
    TextInput,
    StyleSheet,
    TouchableOpacity,
    KeyboardAvoidingView,
    Platform,
    FlatList,
    InteractionManager,
} from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    Easing,
    runOnJS,
    LinearTransition,
    interpolate,
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowUp } from 'lucide-react-native';
import Svg, { Path } from 'react-native-svg';
import { useLocalSearchParams } from 'expo-router';

import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';

// Match your real theme colors
const BUBBLE_GRADIENT: [string, string] = ['#7C5CE0', '#6A4FCF'];
const BUBBLE_TEXT_COLOR = '#fff';
const INPUT_TEXT_COLOR = '#fff';
const MAX_RENDER_MESSAGES = 80;

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

interface Message {
    id: string;
    text: string;
    isMe: boolean;
    isGhostHidden?: boolean;
    isOptimistic?: boolean;
    status?: string;
    timestamp: string;
}

interface QueuedSend {
    messageId: string;
    chatId: string;
    text: string;
}

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
    onComplete: () => void;
}

const formatUiTime = (timestamp: number | string | undefined) => {
    const t = typeof timestamp === 'number' ? timestamp : new Date(timestamp || Date.now()).getTime();
    return new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
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

const CrossfadeOverlay = ({
    text,
    timestamp,
    startX,
    startY,
    startWidth,
    startHeight,
    targetX,
    targetY,
    targetWidth,
    targetHeight,
    onComplete,
}: CrossfadeOverlayProps & { timestamp: string }) => {
    const progress = useSharedValue(0);

    useEffect(() => {
        progress.value = withTiming(
            1,
            {
                duration: 450,
                easing: Easing.out(Easing.cubic),
            },
            (finished) => {
                if (finished) runOnJS(onComplete)();
            }
        );
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

    const bgStyle = useAnimatedStyle(() => {
        const bgOpacity = interpolate(progress.value, [0, 0.1, 0.4], [0, 0, 1], 'clamp');
        return {
            ...StyleSheet.absoluteFillObject,
            borderRadius: 18,
            borderBottomRightRadius: 4,
            overflow: 'hidden',
            opacity: bgOpacity,
        };
    });



    const inputTextStyle = useAnimatedStyle(() => {
        // Text stays visible for most of the flight
        const opacity = interpolate(progress.value, [0, 0.6, 0.8], [1, 1, 0], 'clamp');
        return { opacity };
    });

    const bubbleContentStyle = useAnimatedStyle(() => {
        // Bubble content fades in towards the end
        const opacity = interpolate(progress.value, [0.7, 1], [0, 1], 'clamp');
        return { opacity };
    });

    return (
        <Animated.View style={containerStyle} pointerEvents="none">
            <Animated.View style={bgStyle}>
                <LinearGradient
                    colors={BUBBLE_GRADIENT}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                    style={StyleSheet.absoluteFillObject}
                />
            </Animated.View>

            <View style={styles.crossfadeContent}>
                <Animated.View style={[styles.crossfadeInputText, inputTextStyle, { width: startWidth }]}>
                    <Text style={styles.inputGhostText} numberOfLines={1}>{text}</Text>
                </Animated.View>

                <Animated.View style={bubbleContentStyle}>
                    <Text style={styles.bubbleTextMe}>{text}</Text>
                    <View style={styles.timeMeta}>
                        <Text style={styles.timeText}>{timestamp}</Text>
                    </View>
                </Animated.View>
            </View>
        </Animated.View>
    );
};

const MessageBubble = React.memo(({ item, onLayout }: {
    item: Message;
    onLayout?: (id: string, x: number, y: number, w: number, h: number) => void;
}) => {
    const bubbleRef = useRef<View>(null);

    useEffect(() => {
        if (!item.isGhostHidden || !onLayout) return;
        const timer = setTimeout(() => {
            bubbleRef.current?.measureInWindow((x, y, w, h) => {
                if (w > 0 && h > 0) onLayout(item.id, x, y, w, h);
            });
        }, 50);
        return () => clearTimeout(timer);
    }, [item.isGhostHidden, item.id, onLayout]);

    if (item.isMe) {
        return (
            <View
                ref={bubbleRef}
                style={[
                    styles.bubbleWrapper,
                    { alignSelf: 'flex-end', marginHorizontal: 8 },
                    item.isGhostHidden && { opacity: 0 },
                ]}
            >
                <View style={styles.messageContainer}>
                    <LinearGradient
                        colors={BUBBLE_GRADIENT}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 1 }}
                        style={[styles.bubble, { borderBottomRightRadius: 4 }]}
                    >
                        <Text style={styles.bubbleTextMe}>{item.text}</Text>
                        <View style={styles.timeMeta}>
                            <Text style={styles.timeText}>{item.timestamp}</Text>
                        </View>
                    </LinearGradient>
                    <View style={tailBaseStyle(true)}>
                        <Svg width={29} height={29} viewBox="0 0 29 29">
                            <Path d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z" fill={BUBBLE_GRADIENT[1]} />
                        </Svg>
                    </View>
                </View>
            </View>
        );
    }

    return (
        <View
            ref={bubbleRef}
            style={[styles.bubbleWrapper, { alignSelf: 'flex-start', marginHorizontal: 8 }]}
        >
            <View style={styles.messageContainer}>
                <View style={[styles.bubble, { backgroundColor: '#2a2a4a', borderBottomLeftRadius: 4 }]}>
                    <Text style={styles.bubbleTextThem}>{item.text}</Text>
                    <View style={styles.timeMeta}>
                        <Text style={styles.timeTextThem}>{item.timestamp}</Text>
                    </View>
                </View>
                <View style={tailBaseStyle(false)}>
                    <Svg width={29} height={29} viewBox="0 0 29 29">
                        <Path d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z" fill="#2a2a4a" />
                    </Svg>
                </View>
            </View>
        </View>
    );
});

export default function TelegramCrossfadeChatStoreBacked() {
    const params = useLocalSearchParams();
    const { user } = useAuthStore();
    const chats = useChatStore(s => s.chats);
    const activeChatId = useChatStore(s => s.activeChatId);
    const setActiveChat = useChatStore(s => s.setActiveChat);
    const loadMessages = useChatStore(s => s.loadMessages);
    const sendMessage = useChatStore(s => s.sendMessage);
    const isConnected = useChatStore(s => s.isConnected);

    const chatIdFromParams = typeof params?.id === 'string' ? params.id : null;
    const effectiveChatId = chatIdFromParams || activeChatId || chats[0]?.chatId || null;
    const activeChat = chats.find(c => c.chatId === effectiveChatId);
    const displayName = activeChat?.friendName || activeChat?.name || 'Chat Test';

    const [messages, setMessages] = useState<Message[]>([]);
    const [text, setText] = useState('');
    const flatListRef = useRef<FlatList>(null);
    const inputBarRef = useRef<View>(null);
    const lastStoreSyncRef = useRef<{ count: number; lastId: string | null }>({ count: -1, lastId: null });
    const queuedSendsRef = useRef<Map<string, QueuedSend>>(new Map());
    const queuedTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

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

    const [pendingGhost, setPendingGhost] = useState<{
        text: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        messageId: string;
    } | null>(null);

    useEffect(() => {
        if (chatIdFromParams && chatIdFromParams !== activeChatId) {
            setActiveChat(chatIdFromParams);
        }
    }, [chatIdFromParams, activeChatId, setActiveChat]);

    useEffect(() => {
        if (!effectiveChatId) return;
        const chat = useChatStore.getState().chats.find(c => c.chatId === effectiveChatId);
        if (!chat || chat.messages.length === 0) {
            loadMessages(effectiveChatId);
        }
    }, [effectiveChatId, loadMessages]);

    useEffect(() => {
        if (!effectiveChatId) return;
        const chat = chats.find(c => c.chatId === effectiveChatId);
        if (!chat || !Array.isArray(chat.messages)) return;

        const source = chat.messages;
        const lastMsg = source.length > 0 ? source[source.length - 1] : null;
        const lastId = lastMsg?.id || null;
        if (source.length === lastStoreSyncRef.current.count && lastId === lastStoreSyncRef.current.lastId) {
            return;
        }
        lastStoreSyncRef.current = { count: source.length, lastId };

        const windowStart = Math.max(0, source.length - MAX_RENDER_MESSAGES);
        const storeRows: Message[] = source
            .slice(windowStart)
            .sort((a: any, b: any) => (b?.timestamp || 0) - (a?.timestamp || 0))
            .map((m: any) => ({
                id: m.id,
                text: getStoreMessageText(m),
                isMe: m.fromId === user?.userId,
                timestamp: formatUiTime(m.timestamp),
                status: m.status,
                isOptimistic: false,
            }));

        setMessages(prev => {
            const optimisticLocal = prev.filter(m => m.isOptimistic && !storeRows.some(s => s.id === m.id));
            const merged = [...optimisticLocal, ...storeRows];
            if (merged.length === prev.length) {
                let same = true;
                for (let i = 0; i < merged.length; i++) {
                    const a = merged[i];
                    const b = prev[i];
                    if (
                        a.id !== b.id ||
                        a.text !== b.text ||
                        a.timestamp !== b.timestamp ||
                        a.isMe !== b.isMe ||
                        a.isGhostHidden !== b.isGhostHidden ||
                        a.status !== b.status
                    ) {
                        same = false;
                        break;
                    }
                }
                if (same) return prev;
            }
            return merged;
        });
    }, [effectiveChatId, chats, user?.userId]);

    useEffect(() => {
        return () => {
            queuedTimersRef.current.forEach((timer) => clearTimeout(timer));
            queuedTimersRef.current.clear();
        };
    }, []);

    const runQueuedSend = useCallback((queued: QueuedSend) => {
        Promise.resolve(sendMessage(queued.chatId, queued.text, 'text', {}, queued.messageId))
            .then(() => {
                setMessages(prev => prev.map(m => (m.id === queued.messageId ? { ...m, isOptimistic: false, status: 'sent' } : m)));
            })
            .catch(() => {
                setMessages(prev => prev.map(m => (m.id === queued.messageId ? { ...m, isOptimistic: false, status: 'error' } : m)));
            });
    }, [sendMessage]);

    const onBubbleLayout = useCallback((id: string, x: number, y: number, w: number, h: number) => {
        // Use a shared value approach update if we want more reactive frame sync
        // But setState here is triggered by Layout event which is frame-bound
        setPendingGhost(prev => {
            if (!prev || prev.messageId !== id) return prev;
            setGhostData({
                ...prev,
                targetX: x,
                targetY: y,
                targetWidth: w,
                targetHeight: h,
            });
            return null;
        });
    }, []);

    const handleSend = useCallback(() => {
        if (!text.trim()) return;
        if (!effectiveChatId) return;

        const currentText = text.trim();
        const messageId = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
        const timestamp = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });

        inputBarRef.current?.measureInWindow((barX, barY, barW) => {
            const startX = barX + 16;
            const startY = barY + 13;
            const startWidth = barW - 64;
            const startHeight = 40;

            setText('');

            setMessages(prev => [{
                id: messageId,
                text: currentText,
                timestamp,
                isMe: true,
                isGhostHidden: true,
                isOptimistic: true,
                status: isConnected ? 'sending' : 'pending',
            }, ...prev]);

            setPendingGhost({
                text: currentText,
                timestamp,
                startX,
                startY,
                startWidth,
                startHeight,
                messageId,
            });

            queuedSendsRef.current.set(messageId, {
                messageId,
                chatId: effectiveChatId,
                text: currentText,
            });

            const timer = setTimeout(() => {
                const queued = queuedSendsRef.current.get(messageId);
                if (!queued) return;
                if (ghostData || pendingGhost) return;
                queuedSendsRef.current.delete(messageId);
                InteractionManager.runAfterInteractions(() => {
                    setTimeout(() => runQueuedSend(queued), 0);
                });
            }, 1400);
            queuedTimersRef.current.set(messageId, timer);
        });
    }, [text, effectiveChatId, isConnected, ghostData, pendingGhost, runQueuedSend]);

    const onGhostComplete = useCallback(() => {
        if (!ghostData) return;

        const completed = ghostData;

        setMessages(prev =>
            prev.map(m =>
                m.id === completed.messageId
                    ? { ...m, isGhostHidden: false }
                    : m
            )
        );

        const queued = queuedSendsRef.current.get(completed.messageId);
        const timer = queuedTimersRef.current.get(completed.messageId);
        if (timer) {
            clearTimeout(timer);
            queuedTimersRef.current.delete(completed.messageId);
        }
        if (queued) {
            queuedSendsRef.current.delete(completed.messageId);
            InteractionManager.runAfterInteractions(() => {
                setTimeout(() => runQueuedSend(queued), 50);
            });
        }

        setTimeout(() => {
            setGhostData(null);
        }, 10);
    }, [ghostData, runQueuedSend]);

    const renderItem = useCallback(
        ({ item }: { item: Message }) => (
            <MessageBubble item={item} onLayout={onBubbleLayout} />
        ),
        [onBubbleLayout]
    );

    const subtitle = useMemo(() => {
        if (!effectiveChatId) return 'No chat selected';
        return isConnected ? 'connected' : 'offline';
    }, [effectiveChatId, isConnected]);

    return (
        <KeyboardAvoidingView
            behavior={Platform.OS === 'ios' ? 'padding' : undefined}
            style={styles.container}
        >
            <View style={styles.header}>
                <Text style={styles.headerTitle} numberOfLines={1}>{displayName}</Text>
                <Text style={styles.headerSub}>{subtitle}</Text>
            </View>

            <View style={styles.listArea}>
                <Animated.FlatList
                    ref={flatListRef}
                    data={messages}
                    renderItem={renderItem}
                    keyExtractor={(item) => item.id}
                    inverted
                    itemLayoutAnimation={LinearTransition.damping(20).stiffness(180)}
                    contentContainerStyle={styles.listContent}
                    showsVerticalScrollIndicator={false}
                    keyboardDismissMode="interactive"
                    keyboardShouldPersistTaps="handled"
                />
            </View>

            <View ref={inputBarRef} style={styles.inputBar}>
                <TextInput
                    style={styles.input}
                    placeholder={effectiveChatId ? 'Message' : 'No active chat'}
                    placeholderTextColor="#666"
                    value={text}
                    onChangeText={setText}
                    onSubmitEditing={handleSend}
                    returnKeyType="send"
                    editable={!!effectiveChatId}
                />
                <TouchableOpacity
                    style={[styles.sendBtn, (!text.trim() || !effectiveChatId) && styles.sendBtnDisabled]}
                    onPress={handleSend}
                    disabled={!text.trim() || !effectiveChatId}
                >
                    <ArrowUp size={20} color="#fff" strokeWidth={3} />
                </TouchableOpacity>
            </View>

            {!ghostData && pendingGhost && (
                <View
                    style={{
                        position: 'absolute',
                        left: pendingGhost.startX,
                        top: pendingGhost.startY,
                        width: pendingGhost.startWidth,
                        height: pendingGhost.startHeight,
                        zIndex: 9999,
                    }}
                    pointerEvents="none"
                >
                    <View style={styles.crossfadeContent}>
                        <View style={styles.crossfadeInputText}>
                            <Text style={styles.inputGhostText}>{pendingGhost.text}</Text>
                        </View>
                    </View>
                </View>
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
                    onComplete={onGhostComplete}
                />
            )}
        </KeyboardAvoidingView>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#1a1a2e',
    },
    header: {
        height: 96,
        justifyContent: 'flex-end',
        alignItems: 'center',
        paddingBottom: 12,
        backgroundColor: '#16213e',
        borderBottomWidth: 0.5,
        borderBottomColor: '#333',
        paddingHorizontal: 20,
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '600',
        color: '#fff',
        maxWidth: '92%',
    },
    headerSub: {
        marginTop: 4,
        fontSize: 12,
        color: 'rgba(255,255,255,0.62)',
    },
    listArea: {
        flex: 1,
    },
    listContent: {
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
    messageContainer: {
        position: 'relative',
        overflow: 'visible',
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
    timeTextThem: {
        fontSize: 11,
        color: 'rgba(255,255,255,0.5)',
    },
    bubbleTextMe: {
        color: BUBBLE_TEXT_COLOR,
        fontSize: 16,
        lineHeight: 20,
    },
    bubbleTextThem: {
        color: '#ddd',
        fontSize: 16,
        lineHeight: 20,
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
    crossfadeContent: {
        flex: 1,
        padding: 7,
        paddingHorizontal: 10,
    },
    crossfadeInputText: {
        position: 'absolute',
        left: 10,
        top: 7,
        // Removed right: 10 to prevent wrapping issues during shrink
    },
    inputGhostText: {
        color: INPUT_TEXT_COLOR,
        fontSize: 16,
        lineHeight: 20,
    },
});
