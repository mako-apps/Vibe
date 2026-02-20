import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import {
    View,
    Text,
    TextInput,
    StyleSheet,
    TouchableOpacity,
    KeyboardAvoidingView,
    Platform,
    Dimensions,
    FlatList,
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
import * as ExpoCrypto from 'expo-crypto';
import { MessageBubbleBody } from '../src/components/chat/bubbles';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { Message } from '../src/lib/types';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

// ------------------------------------------------------------------
// CROSSFADE OVERLAY — The Telegram Magic
// ------------------------------------------------------------------
interface CrossfadeOverlayProps {
    item: Message;
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

const CrossfadeOverlay = ({
    item,
    startX, startY, startWidth, startHeight,
    targetX, targetY, targetWidth, targetHeight,
    onComplete,
}: CrossfadeOverlayProps) => {
    const progress = useSharedValue(0);

    useEffect(() => {
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

    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const resolvedTheme = useMemo(() => resolveThemeVariant(activeTheme, effectiveTheme === 'dark'), [activeTheme, effectiveTheme]);
    const bubbleTheme = useMemo(() => ({
        meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
            ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
            : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
    }), [resolvedTheme]);

    return (
        <Animated.View style={containerStyle}>
            <LinearGradient
                colors={bubbleTheme.meGradient}
                start={{ x: 0, y: 0 }}
                end={{ x: 1, y: 1 }}
                style={{
                    padding: 8,
                    paddingHorizontal: 12,
                    borderRadius: 18,
                    width: '100%',
                    height: '100%',
                    borderBottomRightRadius: 4
                }}
            >
                <MessageBubbleBody
                    item={{
                        ...item,
                        isMe: true,
                        text: item.plaintext || '',
                        timestamp: new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                    } as any}
                />
            </LinearGradient>
        </Animated.View>
    );
};

// ------------------------------------------------------------------
// Main Test Screen
// ------------------------------------------------------------------
export default function TestBubbleIntegration() {
    const [text, setText] = useState('');
    const [messages, setMessages] = useState<Message[]>([
        createMockMessage('1', 'Welcome to the test!', false),
        createMockMessage('2', 'This uses the real MessageBubble component.', true),
    ]);

    // Ghost state
    const [ghostData, setGhostData] = useState<any>(null);
    const [pendingGhost, setPendingGhost] = useState<any>(null);

    const inputBarRef = useRef<View>(null);
    const flatListRef = useRef<FlatList>(null);

    function createMockMessage(id: string, text: string, isMe: boolean, isHidden = false): Message {
        return {
            id,
            fromId: isMe ? 'me' : 'other',
            chatId: 'test-chat',
            encryptedContent: 'encrypted',
            type: 'text',
            plaintext: text, // Critical for real MessageBubble or it won't show text
            timestamp: Date.now(),
            status: 'read',
            extra: { isGhostHidden: isHidden }, // Store our hidden state in extra or handle externally
        } as Message;
    }

    // We need to track hidden status externally because we can't easily modify the Message type 
    // without affecting the whole app, although we could use `extra`.
    // The real MessageBubble component accepts `isHidden` as a prop.
    const [hiddenMessageIds, setHiddenMessageIds] = useState<Set<string>>(new Set());

    const onBubbleLayout = useCallback((event: any, messageId: string) => {
        // If this message is waiting for a ghost
        if (pendingGhost && pendingGhost.messageId === messageId) {
            // event.nativeEvent.layout gives x, y, width, height relative to parent
            // But we need screen coordinates.
            // Since onLayout doesn't give absolute coordinates easily in FlatList without refs,
            // we might need a different approach or assume the FlatList item ref.
            // 
            // In test-animation.tsx, the mock bubble used `measureInWindow` via a ref.
            // The real MessageBubble does NOT expose a ref or measure method via props easily 
            // unless we modify it to forward ref or use `onLayout` smartly.
            //
            // However, `MessageBubble.tsx` DOES have an `onLayout` prop:
            // `onLayout?: (event: any) => void;`
            //
            // We need screen coordinates. `event.nativeEvent.layout` is relative to the list item container.

            // To get screen coordinates, we really need the view ref.
            // The real MessageBubble uses `onLongPress` which passes `bubbleRef`.
            // But we can't trigger long press to get the ref.

            // Temporary workaround:
            // We'll rely on the `onLayout` prop passed to MessageBubble. 
            // But getting screen coordinates from just onLayout event in a list is hard.

            // Wait! In `test-animation.tsx`, the inline MessageBubble did:
            // ref={bubbleRef} ... measureInWindow ...

            // Does the REAL MessageBubble allow us to get the ref?
            // No, it handles its own ref.

            // We might need to wrap MessageBubble in a View that WE control, 
            // and measure that View.
        }
    }, [pendingGhost]);

    // Better strategy for measuring: 
    // Wrap the MessageBubble in a view that we can ref.
    // Since we render the item in `renderItem`, we can wrap it.

    // START: Layout Measurement Logic
    const itemRefs = useRef<Map<string, View>>(new Map());

    const setItemRef = (id: string, ref: View | null) => {
        if (ref) itemRefs.current.set(id, ref);
        else itemRefs.current.delete(id);
    };

    const measureAndLaunchGhost = (id: string) => {
        const view = itemRefs.current.get(id);
        if (view && pendingGhost && pendingGhost.messageId === id) {
            view.measureInWindow((x, y, w, h) => {
                if (w > 0 && h > 0) {
                    setGhostData({
                        ...pendingGhost,
                        targetX: x,
                        targetY: y,
                        targetWidth: w,
                        targetHeight: h, // We might need to adjust height if title/time is different
                    });
                    setPendingGhost(null);
                }
            });
        }
    };

    // Trigger measurement when message list updates or layout happens
    useEffect(() => {
        if (pendingGhost) {
            // Try to measure immediately in case it's already there
            // But usually we need to wait for layout
            const timer = setTimeout(() => {
                measureAndLaunchGhost(pendingGhost.messageId);
            }, 50);
            return () => clearTimeout(timer);
        }
    }, [pendingGhost, messages]);

    const handleSend = () => {
        if (!text.trim()) return;

        const currentText = text.trim();
        const messageId = ExpoCrypto.randomUUID();
        const timestamp = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });

        inputBarRef.current?.measureInWindow((barX, barY, barW, barH) => {
            const startX = barX + 16;
            const startY = barY + 13;
            const startWidth = barW - 64;
            const startHeight = 40;

            setText('');

            // 1. Add formatted message
            const newMessage = createMockMessage(messageId, currentText, true, true);

            // 2. Hide it initially
            setHiddenMessageIds(prev => new Set(prev).add(messageId));

            // 3. Update list
            setMessages(prev => [newMessage, ...prev]);

            // 4. Set pending ghost
            setPendingGhost({
                item: newMessage,
                startX,
                startY,
                startWidth,
                startHeight,
                messageId,
            });
        });
    };

    const onGhostComplete = () => {
        if (!ghostData) return;
        // Reveal the real bubble
        setHiddenMessageIds(prev => {
            const next = new Set(prev);
            next.delete(ghostData.messageId);
            return next;
        });

        setTimeout(() => {
            setGhostData(null);
        }, 10);
    };

    const renderItem = useCallback(({ item, index }: { item: Message, index: number }) => {
        const prevItem = messages[index + 1];
        const nextItem = messages[index - 1];

        const isMe = item.fromId === 'me';
        const isSequenceStart = !prevItem || prevItem.fromId !== item.fromId;
        const isSequenceEnd = !nextItem || nextItem.fromId !== item.fromId;

        // Is hidden?
        const isHidden = hiddenMessageIds.has(item.id);

        return (
            <View
                ref={(ref) => setItemRef(item.id, ref)}
                onLayout={() => {
                    if (isHidden) measureAndLaunchGhost(item.id);
                }}
                style={{
                    alignSelf: isMe ? 'flex-end' : 'flex-start',
                    marginVertical: 1,
                    maxWidth: '85%',
                    marginHorizontal: 8,
                    opacity: isHidden ? 0 : 1
                }}
                collapsable={false} // Important for measureInWindow on Android sometimes
            >
                {(() => {
                    const { activeTheme } = useWallpaperStore();
                    const { effectiveTheme } = useThemeStore();
                    const resolvedTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
                    const bubbleGradient = isMe
                        ? (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2 ? resolvedTheme.bubbleMeGradient : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe])
                        : (resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length >= 2 ? resolvedTheme.bubbleThemGradient : [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem]);

                    return (
                        <LinearGradient
                            colors={bubbleGradient as any}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 1 }}
                            style={[
                                {
                                    padding: 8,
                                    paddingHorizontal: 12,
                                    borderRadius: 18,
                                },
                                isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 }
                            ]}
                        >
                            <MessageBubbleBody
                                item={{
                                    ...item,
                                    isMe,
                                    text: item.plaintext || '',
                                    timestamp: new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                } as any}
                            />
                        </LinearGradient>
                    );
                })()}
            </View>
        );
    }, [hiddenMessageIds, messages]);

    return (
        <KeyboardAvoidingView
            behavior={Platform.OS === 'ios' ? 'padding' : undefined}
            style={styles.container}
        >
            <LinearGradient
                colors={['#1a1a2e', '#16213e']}
                style={StyleSheet.absoluteFill}
            />

            <View style={styles.header}>
                <Text style={styles.headerTitle}>Integration Test</Text>
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
                />
            </View>

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

            {/* Ghost Overlay */}
            {ghostData && (
                <CrossfadeOverlay
                    item={ghostData.item}
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
        height: 100,
        justifyContent: 'flex-end',
        alignItems: 'center',
        paddingBottom: 12,
        backgroundColor: 'rgba(22, 33, 62, 0.8)',
        borderBottomWidth: 0.5,
        borderBottomColor: '#333',
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '600',
        color: '#fff',
    },
    listArea: {
        flex: 1,
    },
    listContent: {
        paddingHorizontal: 0,
        paddingTop: 25,
        paddingBottom: 10,
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
