import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import {
    View,
    Text,
    StyleSheet,
    Platform,
    FlatList,
    TouchableOpacity,
    Dimensions,
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
    useDerivedValue,
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import { ChevronLeft, Reply } from 'lucide-react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import MaskedView from '@react-native-masked-view/masked-view';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import { useLocalSearchParams, useRouter } from 'expo-router';
import * as ExpoCrypto from 'expo-crypto';
import { MessageBubbleBody } from '../src/components/chat/bubbles';
import ChatInput, { ReplyInfo } from '../src/components/chat/ChatInput';
import { Message } from '../src/lib/types';
import WallpaperBackground from '../src/components/chat/WallpaperBackground';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';
import { useHaptics } from '../src/lib/hooks/useHaptics';
import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import AuthManager from '../src/lib/AuthManager';
import { decryptMessage } from '../src/lib/crypto';

const SWIPE_REPLY_THRESHOLD = 40;
const MaskedViewAny = MaskedView as any;

// ------------------------------------------------------------------
// DEBUG LOGGING — track every re-render, store mutation, timing
// ------------------------------------------------------------------
const DEBUG = false;
const debugLog = (tag: string, ...args: any[]) => {
    if (!DEBUG) return;
    const now = performance.now();
    console.log(`[DEBUG ${now.toFixed(1)}ms] [${tag}]`, ...args);
};
let renderCount = 0;
let rowRenderCount = 0;

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

    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const resolvedTheme = useMemo(() => resolveThemeVariant(activeTheme, effectiveTheme === 'dark'), [activeTheme, effectiveTheme]);
    const bubbleTheme = useMemo(() => ({
        meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
            ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
            : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
    }), [resolvedTheme]);

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
// SwipeableMessageRow — Pure display, zero side effects
// ------------------------------------------------------------------
interface SwipeableMessageRowProps {
    item: Message;
    prevItem?: Message;
    nextItem?: Message;
    isMe: boolean;
    isHidden: boolean;
    displayContent: string;
    replyUserName?: string;
    replyContent?: string;
    onSetItemRef: (id: string, ref: View | null) => void;
    onItemLayout: (id: string) => void;
    onReply: (item: Message) => void;
}

const isSameRowItem = (a: Message, b: Message) => {
    if (a === b) return true;
    return (
        a.id === b.id &&
        a.fromId === b.fromId &&
        a.timestamp === b.timestamp &&
        a.type === b.type &&
        a.status === b.status &&
        a.replyToId === b.replyToId &&
        a.plaintext === b.plaintext &&
        a.encryptedContent === b.encryptedContent
    );
};

const isSameNeighbor = (a?: Message, b?: Message) => {
    if (a === b) return true;
    if (!a || !b) return false;
    return a.id === b.id && a.fromId === b.fromId;
};

const SwipeableMessageRow = React.memo(({
    item, prevItem, nextItem, isMe, isHidden,
    displayContent, replyUserName, replyContent,
    onSetItemRef, onItemLayout, onReply,
}: SwipeableMessageRowProps) => {
    if (DEBUG) {
        rowRenderCount++;
        debugLog('ROW_RENDER', `id=${item.id.slice(0, 8)} #${rowRenderCount} hidden=${isHidden} content="${displayContent.slice(0, 20)}"`);
    }
    const { colors } = useThemeStore();
    const haptic = useHaptics();
    const swipeX = useSharedValue(0);
    const hasTriggeredHaptic = useSharedValue(false);

    const isSequenceStart = !prevItem || prevItem.fromId !== item.fromId;
    const isSequenceEnd = !nextItem || nextItem.fromId !== item.fromId;

    const triggerHaptic = useCallback(() => { haptic.medium(); }, [haptic]);
    const triggerReply = useCallback(() => { haptic.light(); onReply(item); }, [haptic, onReply, item]);

    const swipeGesture = Gesture.Pan()
        .activeOffsetX([-15, 15])
        .failOffsetY([-10, 10])
        .onUpdate((e) => {
            const translation = isMe ? Math.min(0, e.translationX) : Math.max(0, e.translationX);
            const dampedTranslation = isMe
                ? Math.max(-SWIPE_REPLY_THRESHOLD * 1.5, translation)
                : Math.min(SWIPE_REPLY_THRESHOLD * 1.5, translation);
            swipeX.value = dampedTranslation;
            const abs = Math.abs(dampedTranslation);
            if (abs >= SWIPE_REPLY_THRESHOLD && !hasTriggeredHaptic.value) {
                hasTriggeredHaptic.value = true;
                runOnJS(triggerHaptic)();
            } else if (abs < SWIPE_REPLY_THRESHOLD && hasTriggeredHaptic.value) {
                hasTriggeredHaptic.value = false;
            }
        })
        .onEnd(() => {
            if (Math.abs(swipeX.value) >= SWIPE_REPLY_THRESHOLD) runOnJS(triggerReply)();
            swipeX.value = withTiming(0, { duration: 200, easing: Easing.bezier(0.25, 0.1, 0.25, 1) });
            hasTriggeredHaptic.value = false;
        });

    const swipeStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: swipeX.value }]
    }));

    const replyIconStyle = useAnimatedStyle(() => {
        const abs = Math.abs(swipeX.value);
        const progress = Math.min(abs / SWIPE_REPLY_THRESHOLD, 1);
        return {
            opacity: interpolate(progress, [0, 0.3, 1], [0, 0.5, 1]),
            transform: [
                { scale: interpolate(progress, [0, 1], [0.5, abs >= SWIPE_REPLY_THRESHOLD ? 1.2 : 1]) },
                { translateX: isMe ? 10 : -10 }
            ]
        };
    });

    return (
        <View style={[styles.swipeContainer, isMe ? styles.swipeContainerMe : styles.swipeContainerThem]}>
            <Animated.View style={[styles.replyIconContainer, isMe ? styles.replyIconRight : styles.replyIconLeft, replyIconStyle]}>
                <Reply size={20} color={colors.primary} />
            </Animated.View>
            <GestureDetector gesture={swipeGesture}>
                <Animated.View style={[styles.msgRow, isMe ? styles.msgRowMe : styles.msgRowThem, swipeStyle]}>
                    <View style={{ alignSelf: isMe ? 'flex-end' : 'flex-start', marginVertical: 1, maxWidth: '85%', marginHorizontal: 8 }}>
                        <View ref={(ref) => onSetItemRef(item.id, ref)} onLayout={() => onItemLayout(item.id)} collapsable={false}>
                            {(() => {
                                const { activeTheme } = useWallpaperStore();
                                const { effectiveTheme } = useThemeStore();
                                const resolvedTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
                                const bubbleGradient = isMe
                                    ? (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2 ? resolvedTheme.bubbleMeGradient : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe])
                                    : (resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length >= 2 ? resolvedTheme.bubbleThemGradient : [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem]);

                                return (
                                    <View style={{ opacity: isHidden ? 0 : 1 }}>
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
                                                    text: displayContent,
                                                    timestamp: new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }),
                                                    replyPreview: replyUserName ? { userName: replyUserName, content: replyContent || '' } : null
                                                } as any}
                                            />
                                        </LinearGradient>
                                    </View>
                                );
                            })()}
                        </View>
                    </View>
                </Animated.View>
            </GestureDetector>
        </View>
    );
}, (prev, next) => {
    return (
        isSameRowItem(prev.item, next.item) &&
        isSameNeighbor(prev.prevItem, next.prevItem) &&
        isSameNeighbor(prev.nextItem, next.nextItem) &&
        prev.isMe === next.isMe &&
        prev.isHidden === next.isHidden &&
        prev.displayContent === next.displayContent &&
        prev.replyUserName === next.replyUserName &&
        prev.replyContent === next.replyContent &&
        prev.onSetItemRef === next.onSetItemRef &&
        prev.onItemLayout === next.onItemLayout &&
        prev.onReply === next.onReply
    );
});

interface ComposerInputBarProps {
    inputBarRef: React.RefObject<View | null>;
    updateInputBarMeasure: () => void;
    onSendText: (text: string) => boolean;
    currentChatId: string | null;
    replyTo: ReplyInfo | null;
    onCancelReply: () => void;
    keyboardShift: any;
    bottomInsetPadding: number;
    inputVerticalPadding: number;
}

const ComposerInputBar = React.memo(({
    inputBarRef,
    updateInputBarMeasure,
    onSendText,
    currentChatId,
    replyTo,
    onCancelReply,
    keyboardShift,
    bottomInsetPadding,
    inputVerticalPadding,
}: ComposerInputBarProps) => {
    const [text, setText] = useState('');

    const handleSend = useCallback(() => {
        const trimmed = text.trim();
        if (!trimmed) return;
        const accepted = onSendText(trimmed);
        if (accepted) setText('');
    }, [text, onSendText]);

    return (
        <View
            ref={inputBarRef}
            onLayout={updateInputBarMeasure}
            style={[styles.inputBar, { paddingBottom: bottomInsetPadding, paddingTop: inputVerticalPadding }]}
        >
            <ChatInput
                text={text}
                setText={setText}
                onSend={handleSend}
                currentChatId={currentChatId || 'test-chat'}
                replyTo={replyTo}
                onCancelReply={onCancelReply}
                keyboardProgress={keyboardShift}
            />
        </View>
    );
});

// ------------------------------------------------------------------
// Selective store hook — only re-renders when message COUNT changes
// for the active chat, NOT on status/content updates.
// This is the key to preventing sendMessage's 3-4 store mutations
// from killing the animation (each set({chats}) also triggers
// AsyncStorage persist which is heavy serialization on the JS thread).
// ------------------------------------------------------------------
function useStableMessages(chatId: string | null) {
    const countRef = useRef(0);
    const snapshotRef = useRef<Message[]>([]);
    const friendNameRef = useRef<string>('');
    const [revision, setRevision] = useState(0);

    useEffect(() => {
        if (!chatId) {
            snapshotRef.current = [];
            countRef.current = 0;
            friendNameRef.current = '';
            setRevision(r => r + 1);
            return;
        }

        // Subscribe to store changes, but only bump revision
        // when the message count actually changes
        const unsub = useChatStore.subscribe((state) => {
            const chat = state.chats.find(c => c.chatId === chatId);
            if (!chat) return;

            const newCount = chat.messages.length;
            const newName = chat.friendName || chat.name || '';

            debugLog('STORE_SUB', `count=${newCount} prev=${countRef.current} name="${newName}" — ${newCount !== countRef.current ? 'WILL UPDATE' : 'SKIP (count same)'}`);

            if (newCount !== countRef.current || newName !== friendNameRef.current) {
                countRef.current = newCount;
                friendNameRef.current = newName;
                // Take a snapshot — reversed for inverted FlatList
                snapshotRef.current = [...chat.messages].reverse();
                debugLog('STORE_SUB', `>>> REVISION BUMP — snapshot size=${snapshotRef.current.length}`);
                setRevision(r => r + 1);
            }
        });

        // Initial snapshot
        const state = useChatStore.getState();
        const chat = state.chats.find(c => c.chatId === chatId);
        if (chat) {
            countRef.current = chat.messages.length;
            friendNameRef.current = chat.friendName || chat.name || '';
            snapshotRef.current = [...chat.messages].reverse();
            setRevision(r => r + 1);
        }

        return unsub;
    }, [chatId]);

    return {
        messages: snapshotRef.current,
        friendName: friendNameRef.current,
        revision,
    };
}

// ------------------------------------------------------------------
// Main Test Screen — Real chat integration
// ------------------------------------------------------------------
// Global store change counter — logs EVERY set({chats}) to show frequency
let storeChangeCount = 0;
if (DEBUG) {
    useChatStore.subscribe((state, prevState) => {
        if (state.chats !== prevState.chats) {
            storeChangeCount++;
            const activeChatId = state.activeChatId;
            const chat = activeChatId ? state.chats.find(c => c.chatId === activeChatId) : null;
            const prevChat = activeChatId ? prevState.chats.find(c => c.chatId === activeChatId) : null;
            const countChanged = (chat?.messages.length || 0) !== (prevChat?.messages.length || 0);
            debugLog('STORE_CHANGE', `#${storeChangeCount} activeChat msgs: ${prevChat?.messages.length || 0} → ${chat?.messages.length || 0} countChanged=${countChanged}`);
            // Log status of last message to see status-only updates
            if (chat && chat.messages.length > 0) {
                const last = chat.messages[chat.messages.length - 1];
                debugLog('STORE_CHANGE', `  lastMsg id=${last.id.slice(0, 8)} status=${last.status} plaintext=${!!last.plaintext} encrypted=${!!last.encryptedContent}`);
            }
        }
    });
}

export default function TestBubbleIntegration() {
    renderCount++;
    const renderStart = performance.now();
    debugLog('RENDER', `=== MAIN RENDER #${renderCount} ===`);

    const insets = useSafeAreaInsets();
    const router = useRouter();
    const params = useLocalSearchParams();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const { user } = useAuthStore();

    const chatIdParam = typeof params?.id === 'string' ? params.id : undefined;

    // Store actions only — these don't cause re-renders (functions are stable refs)
    const setActiveChat = useChatStore(s => s.setActiveChat);
    const loadMessages = useChatStore(s => s.loadMessages);
    const sendMessage = useChatStore(s => s.sendMessage);
    const activeChatId = useChatStore(s => s.activeChatId);
    debugLog('RENDER', `chatIdParam=${chatIdParam} activeChatId=${activeChatId}`);

    // Set active chat from params
    useEffect(() => {
        if (chatIdParam && chatIdParam !== activeChatId) {
            setActiveChat(chatIdParam);
        }
    }, [chatIdParam]);

    // Load messages on mount
    useEffect(() => {
        if (!activeChatId) return;
        const chat = useChatStore.getState().chats.find(c => c.chatId === activeChatId);
        if (!chat || chat.messages.length === 0) {
            loadMessages(activeChatId);
        }
    }, [activeChatId]);

    // STABLE messages — only updates when message count changes
    // Ignores status updates (sending→sent→delivered) that sendMessage triggers
    const { messages: storeMessages, friendName, revision } = useStableMessages(activeChatId);
    debugLog('RENDER', `activeChatId=${activeChatId} storeMessages=${storeMessages.length} revision=${revision}`);

    // My user ID
    const myId = useMemo(() => {
        const auth = AuthManager.getInstance().getSession();
        return auth?.userId || user?.userId || 'me';
    }, [user?.userId]);

    // ---------------------------------------------------------------
    // LOCAL PLAINTEXT MAP — decryption writes here, not to store
    // ---------------------------------------------------------------
    const [localPlaintext, setLocalPlaintext] = useState<Record<string, string>>({});
    const decryptedIdsRef = useRef<Set<string>>(new Set());
    const isDecryptingRef = useRef(false);
    const animatingRef = useRef(false);

    useEffect(() => {
        setLocalPlaintext({});
        decryptedIdsRef.current = new Set();
    }, [activeChatId]);

    // Sync existing plaintext from store into local map
    useEffect(() => {
        debugLog('SYNC_PLAINTEXT', `revision=${revision} storeMessages=${storeMessages.length}`);
        const updates: Record<string, string> = {};
        for (const m of storeMessages) {
            if (m.plaintext && !decryptedIdsRef.current.has(m.id)) {
                updates[m.id] = m.plaintext;
                decryptedIdsRef.current.add(m.id);
            }
        }
        if (Object.keys(updates).length > 0) {
            debugLog('SYNC_PLAINTEXT', `>>> Setting ${Object.keys(updates).length} plaintext entries`);
            setLocalPlaintext(prev => ({ ...prev, ...updates }));
        }
    }, [revision]);

    // Decrypt loop — writes to localPlaintext only, never store
    useEffect(() => {
        debugLog('DECRYPT_EFFECT', `activeChatId=${activeChatId} isDecrypting=${isDecryptingRef.current} revision=${revision}`);
        if (!activeChatId || isDecryptingRef.current) {
            debugLog('DECRYPT_EFFECT', `SKIP: chatId=${!!activeChatId} isDecrypting=${isDecryptingRef.current}`);
            return;
        }

        const sess = AuthManager.getInstance().getSession();
        if (!sess?.keyPair?.privateKey) {
            debugLog('DECRYPT_EFFECT', 'SKIP: no private key');
            return;
        }

        const needDecrypt = storeMessages.filter(
            m => !m.plaintext && m.encryptedContent && !decryptedIdsRef.current.has(m.id)
        );
        debugLog('DECRYPT_EFFECT', `needDecrypt=${needDecrypt.length} total=${storeMessages.length}`);
        if (needDecrypt.length === 0) return;

        for (const m of needDecrypt) decryptedIdsRef.current.add(m.id);

        let cancelled = false;
        isDecryptingRef.current = true;

        const sorted = [...needDecrypt].sort((a, b) => b.timestamp - a.timestamp);

        const run = async () => {
            // Wait for animation to finish
            while (animatingRef.current && !cancelled) {
                await new Promise(r => setTimeout(r, 50));
            }

            let batch: Record<string, string> = {};
            let count = 0;

            for (const msg of sorted) {
                if (cancelled) break;
                try {
                    const text = await decryptMessage(
                        sess.keyPair.privateKey, msg.encryptedContent,
                        msg.fromId === sess.userId
                    );
                    batch[msg.id] = text;
                } catch {
                    batch[msg.id] = '[Decryption Error]';
                }
                count++;

                if (count % 2 === 0) {
                    if (!cancelled) {
                        const snapshot = { ...batch };
                        setLocalPlaintext(prev => ({ ...prev, ...snapshot }));
                        batch = {};
                    }
                    // Yield 2 frames
                    await new Promise<void>(r => requestAnimationFrame(() => requestAnimationFrame(() => r())));
                }
            }
            if (!cancelled && Object.keys(batch).length > 0) {
                setLocalPlaintext(prev => ({ ...prev, ...batch }));
            }
            isDecryptingRef.current = false;
        };

        const timer = setTimeout(run, 600);
        return () => { cancelled = true; clearTimeout(timer); isDecryptingRef.current = false; };
    }, [revision, activeChatId]);

    // Theme
    const resolvedTheme = useMemo(() => {
        const theme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
        if (!theme.backgroundGradient) return { ...theme, backgroundGradient: [colors.background, colors.background] };
        return theme;
    }, [activeTheme, effectiveTheme, colors.background]);
    const wallpaperGradient = resolvedTheme.backgroundGradient;
    const inputVerticalPadding = 6;
    const bottomInsetPadding = Platform.OS === 'ios' ? Math.max(insets.bottom, 8) : Math.max(insets.bottom, 16);
    const footerHeight = 60 + bottomInsetPadding + inputVerticalPadding * 2;
    const { height: keyboardHeight } = useReanimatedKeyboardAnimation();
    const keyboardShift = useDerivedValue(() => Math.max(Math.abs(keyboardHeight.value), 0));
    const pageShiftStyle = useAnimatedStyle(() => ({ transform: [{ translateY: -keyboardShift.value }] }));

    const [replyTo, setReplyTo] = useState<ReplyInfo | null>(null);

    // Ghost state
    const [ghostData, setGhostData] = useState<any>(null);
    const [pendingGhost, setPendingGhost] = useState<any>(null);
    const [hiddenMessageIds, setHiddenMessageIds] = useState<Set<string>>(new Set());

    const inputBarRef = useRef<View>(null);
    const flatListRef = useRef<FlatList>(null);
    const inputBarMeasureRef = useRef<{ x: number; y: number; w: number; h: number } | null>(null);
    const pendingGhostRef = useRef<any>(null);
    const sendLockRef = useRef(false);
    pendingGhostRef.current = pendingGhost;

    // Draft messages — shown instantly before store picks them up
    const [draftMessages, setDraftMessages] = useState<Message[]>([]);

    useEffect(() => {
        if (storeMessages.length > 0 && draftMessages.length > 0) {
            const storeIds = new Set(storeMessages.map(m => m.id));
            const remaining = draftMessages.filter(m => !storeIds.has(m.id));
            debugLog('DRAFT_SYNC', `storeLen=${storeMessages.length} draftLen=${draftMessages.length} remaining=${remaining.length}`);
            if (remaining.length !== draftMessages.length) {
                debugLog('DRAFT_SYNC', `>>> Removing ${draftMessages.length - remaining.length} drafts absorbed by store`);
                setDraftMessages(remaining);
            }
        }
    }, [revision, draftMessages.length]);

    // Final message list — stable, only changes on structural changes
    const messages = useMemo(() => {
        const storeIds = new Set(storeMessages.map(m => m.id));
        const validDrafts = draftMessages.filter(m => !storeIds.has(m.id));
        // Reverse drafts so newest is first (index 0), followed by store messages (already reversed)
        const result = [...validDrafts.reverse(), ...storeMessages];
        debugLog('MESSAGES_MEMO', `storeMessages=${storeMessages.length} pendingDrafts=${validDrafts.length} total=${result.length} revision=${revision}`);
        return result;
    }, [revision, draftMessages, storeMessages]);

    // ------------------------------------------------------------------
    // REF SYNC — For stable renderItem
    // ------------------------------------------------------------------
    const messagesRef = useRef(messages);
    messagesRef.current = messages;

    const hiddenMessageIdsRef = useRef(hiddenMessageIds);
    hiddenMessageIdsRef.current = hiddenMessageIds;

    const localPlaintextRef = useRef(localPlaintext);
    localPlaintextRef.current = localPlaintext;

    const friendNameRef = useRef(friendName);
    friendNameRef.current = friendName;

    const myIdRef = useRef(myId);
    myIdRef.current = myId;

    // Layout measurement
    const itemRefs = useRef<Map<string, View>>(new Map());
    const setItemRef = useCallback((id: string, ref: View | null) => {
        if (ref) itemRefs.current.set(id, ref);
        else itemRefs.current.delete(id);
    }, []);

    const updateInputBarMeasure = useCallback(() => {
        inputBarRef.current?.measureInWindow((x, y, w, h) => {
            if (w > 0 && h > 0) inputBarMeasureRef.current = { x, y, w, h };
        });
    }, []);

    const measureAndLaunchGhost = useCallback((id: string) => {
        const view = itemRefs.current.get(id);
        const pg = pendingGhostRef.current;
        if (view && pg && pg.messageId === id) {
            view.measureInWindow((x, y, w, h) => {
                if (w > 0 && h > 0) {
                    setGhostData({ ...pg, targetX: x, targetY: y, targetWidth: w, targetHeight: h });
                    setPendingGhost(null);
                }
            });
        }
    }, []);

    useEffect(() => {
        if (!pendingGhost) return;
        const timer = setTimeout(() => measureAndLaunchGhost(pendingGhost.messageId), 50);
        return () => clearTimeout(timer);
    }, [pendingGhost, messages.length, measureAndLaunchGhost]);

    const handleSendText = useCallback((messageText: string) => {
        const sendStart = performance.now();
        debugLog('SEND', `=== handleSend START === locked=${sendLockRef.current}`);
        if (sendLockRef.current) {
            debugLog('SEND', 'BLOCKED by sendLock');
            return false;
        }
        if (!messageText || !activeChatId) {
            debugLog('SEND', `BLOCKED: text="${messageText}" chatId=${activeChatId}`);
            return false;
        }

        const replySnapshot = replyTo;
        const msgId = ExpoCrypto.randomUUID();
        const now = Date.now();
        sendLockRef.current = true;
        debugLog('SEND', `msgId=${msgId.slice(0, 8)} text="${messageText.slice(0, 30)}"`);

        const optimisticMsg: Message = {
            id: msgId, fromId: myId, chatId: activeChatId,
            encryptedContent: '', type: 'text', timestamp: now,
            plaintext: messageText, status: 'sending',
            replyToId: replySnapshot?.messageId,
        };

        const prevLatestMsg = messages[0];
        const isSequenceStart = !prevLatestMsg || prevLatestMsg.fromId !== myId;

        const applySendTransition = (barX: number, barY: number, barW: number) => {
            debugLog('SEND', `applySendTransition bar=(${barX.toFixed(0)},${barY.toFixed(0)},${barW.toFixed(0)})`);
            // Mark animating — decryption loop will wait
            animatingRef.current = true;

            const t1 = performance.now();
            setDraftMessages(prev => [...prev, optimisticMsg]);
            setHiddenMessageIds(prev => new Set(prev).add(msgId));
            if (replySnapshot) setReplyTo(null);

            setPendingGhost({
                item: optimisticMsg, isSequenceStart, isSequenceEnd: true, isMiddle: false,
                startX: barX + 16, startY: barY + 13,
                startWidth: barW - 64, startHeight: 40,
                messageId: msgId,
            });
            debugLog('SEND', `State updates queued in ${(performance.now() - t1).toFixed(1)}ms`);

            // Commit to store after UI/gesture work is idle.
            // This prevents sendMessage's store + crypto work from competing with the ghost/input animation.
            setTimeout(() => {
                InteractionManager.runAfterInteractions(() => {
                    debugLog('SEND', `>>> Delayed Send: calling sendMessage (${(performance.now() - sendStart).toFixed(1)}ms after handleSend)`);
                    const opts = replySnapshot ? { replyToId: replySnapshot.messageId } : {};
                    sendMessage(activeChatId, messageText, 'text', opts, msgId);
                    debugLog('SEND', `>>> sendMessage call returned (${(performance.now() - sendStart).toFixed(1)}ms total)`);
                });
            }, 180);

            setTimeout(() => { sendLockRef.current = false; }, 300);
        };

        const cached = inputBarMeasureRef.current;
        if (cached) {
            applySendTransition(cached.x, cached.y, cached.w);
            return true;
        }

        if (inputBarRef.current) {
            inputBarRef.current.measureInWindow((x, y, w, h) => {
                if (w > 0) { inputBarMeasureRef.current = { x, y, w, h }; applySendTransition(x, y, w); }
                else { const fw = Dimensions.get('window').width - 32; applySendTransition(16, Dimensions.get('window').height - 80, fw); }
            });
        } else {
            const fw = Dimensions.get('window').width - 32;
            applySendTransition(16, Dimensions.get('window').height - 80, fw);
        }
        return true;
    }, [activeChatId, messages, myId, replyTo, sendMessage]);

    const onGhostComplete = useCallback(() => {
        debugLog('GHOST', `onGhostComplete ghostData=${!!ghostData} msgId=${ghostData?.messageId?.slice(0, 8)}`);
        if (!ghostData) return;
        setHiddenMessageIds(prev => { const next = new Set(prev); next.delete(ghostData.messageId); return next; });
        animatingRef.current = false;
        setTimeout(() => setGhostData(null), 10);
    }, [ghostData]);

    const handleItemLayout = useCallback((id: string) => {
        if (hiddenMessageIdsRef.current.has(id)) measureAndLaunchGhost(id);
    }, [measureAndLaunchGhost]);

    const getDisplayContent = useCallback((msg: Message): string => {
        if (localPlaintextRef.current[msg.id]) return localPlaintextRef.current[msg.id];
        if (msg.plaintext) return msg.plaintext;
        return '···';
    }, []);

    const handleReply = useCallback((msg: Message) => {
        const myId = myIdRef.current;
        const fname = friendNameRef.current;
        setReplyTo({
            messageId: msg.id,
            userName: msg.fromId === myId ? 'You' : (fname || 'Other'),
            userHandle: msg.fromId === myId ? 'you' : 'other',
            content: getDisplayContent(msg),
        });
    }, [getDisplayContent]);

    const renderItem = useCallback(({ item, index }: { item: Message, index: number }) => {
        // debugLog('RENDER_ITEM', `index=${index} id=${item.id.slice(0,8)}`);
        const msgs = messagesRef.current;
        const prevItem = msgs[index + 1];
        const nextItem = msgs[index - 1];
        const isMe = item.fromId === myIdRef.current;
        const isHidden = hiddenMessageIdsRef.current.has(item.id);
        const displayContent = getDisplayContent(item);

        const repliedMessage = item.replyToId ? messageByIdRef.current.get(item.replyToId) : null;
        let replyPreview = null;
        if (repliedMessage) {
            const rContent = getDisplayContent(repliedMessage);
            const rName = repliedMessage.fromId === myIdRef.current ? 'You' : (friendNameRef.current || 'Other');
            replyPreview = { userName: rName, content: rContent };
        }

        return (
            <SwipeableMessageRow
                item={item} prevItem={prevItem} nextItem={nextItem}
                isMe={isMe} isHidden={isHidden} displayContent={displayContent}
                replyUserName={replyPreview?.userName} replyContent={replyPreview?.content}
                onSetItemRef={setItemRef}
                onItemLayout={handleItemLayout}
                onReply={handleReply}
            />
        );
    }, [getDisplayContent, handleItemLayout, handleReply, setItemRef]);

    const displayName = friendName || 'Chat';
    const hiddenCount = hiddenMessageIds.size;
    const localPlaintextCount = useMemo(() => Object.keys(localPlaintext).length, [localPlaintext]);
    const listExtraData = useMemo(
        () => [revision, hiddenCount, localPlaintextCount],
        [revision, hiddenCount, localPlaintextCount]
    );
    const messageById = useMemo(() => {
        const map = new Map<string, Message>();
        for (const m of messages) map.set(m.id, m);
        return map;
    }, [messages]);
    const messageByIdRef = useRef(messageById);
    messageByIdRef.current = messageById;

    debugLog('RENDER', `=== RENDER #${renderCount} complete in ${(performance.now() - renderStart).toFixed(1)}ms === messages=${messages.length} hidden=${hiddenMessageIds.size} ghost=${!!ghostData} pendingGhost=${!!pendingGhost}`);

    return (
        <View style={styles.container}>
            <LinearGradient colors={wallpaperGradient as any} style={StyleSheet.absoluteFill} />
            <WallpaperBackground theme={resolvedTheme} />

            <Animated.View style={[styles.pageBody, pageShiftStyle]}>
                <View style={styles.listArea}>
                    <Animated.FlatList
                        ref={flatListRef} data={messages} renderItem={renderItem}
                        keyExtractor={(item) => item.id} inverted
                        itemLayoutAnimation={LinearTransition.damping(20).stiffness(180)}
                        contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 40, paddingBottom: footerHeight + 12 }]}
                        showsVerticalScrollIndicator={false}
                        keyboardDismissMode="interactive" keyboardShouldPersistTaps="handled"
                        removeClippedSubviews={false}
                        initialNumToRender={14}
                        maxToRenderPerBatch={12}
                        updateCellsBatchingPeriod={16}
                        windowSize={11}
                        extraData={listExtraData}
                    />
                </View>

                <View pointerEvents="none" style={[styles.footerMask, { height: footerHeight + 44 }]}>
                    <MaskedViewAny style={StyleSheet.absoluteFill}
                        maskElement={<LinearGradient colors={['rgba(0,0,0,0)', 'rgba(0,0,0,0.34)', 'rgba(0,0,0,0.84)']} locations={[0, 0.86, 1]} style={StyleSheet.absoluteFill} />}>
                        <BlurView style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(wallpaperGradient[wallpaperGradient.length - 1], 0.78) }]}
                            intensity={18} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} />
                    </MaskedViewAny>
                </View>

                <Animated.View style={styles.inputSticky}>
                    <ComposerInputBar
                        inputBarRef={inputBarRef}
                        updateInputBarMeasure={updateInputBarMeasure}
                        onSendText={handleSendText}
                        currentChatId={activeChatId}
                        replyTo={replyTo}
                        onCancelReply={() => setReplyTo(null)}
                        keyboardShift={keyboardShift}
                        bottomInsetPadding={bottomInsetPadding}
                        inputVerticalPadding={inputVerticalPadding}
                    />
                </Animated.View>
            </Animated.View>

            <View style={[styles.headerMask, { height: insets.top + 80 }]}>
                <MaskedViewAny style={StyleSheet.absoluteFill}
                    maskElement={<LinearGradient colors={['rgba(0,0,0,0.9)', 'rgba(0,0,0,0)']} locations={[0.56, 1]} style={StyleSheet.absoluteFill} />}>
                    <BlurView intensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(wallpaperGradient[0], 0.85) }]} />
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
                        <Text style={[styles.headerStatus, { color: colors.primary }]}>Test Integration</Text>
                    </View>
                </SafeLiquidGlass>
                <View style={{ position: 'absolute', right: 14, top: insets.top + 8 }}>
                    <SafeLiquidGlass style={{ height: 44, width: 44, borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <View style={[styles.avatarFallback, { backgroundColor: colors.primary }]}>
                            <Text style={styles.avatarLetter}>{displayName[0]?.toUpperCase() || 'T'}</Text>
                        </View>
                    </SafeLiquidGlass>
                </View>
            </View>

            {ghostData && (
                <CrossfadeOverlay
                    item={ghostData.item}
                    startX={ghostData.startX} startY={ghostData.startY} startWidth={ghostData.startWidth} startHeight={ghostData.startHeight}
                    targetX={ghostData.targetX} targetY={ghostData.targetY} targetWidth={ghostData.targetWidth} targetHeight={ghostData.targetHeight}
                    onComplete={onGhostComplete}
                />
            )}
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: '#1a1a2e' },
    headerTitle: { fontSize: 15, fontWeight: '600' },
    headerStatus: { fontSize: 12, marginTop: 1 },
    listArea: { flex: 1 },
    pageBody: { flex: 1 },
    listContent: { paddingHorizontal: 0 },
    headerMask: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 60, pointerEvents: 'none' },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 130, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 14 },
    headerCircleBtn: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    avatarFallback: { flex: 1, alignItems: 'center', justifyContent: 'center' },
    avatarLetter: { color: '#fff', fontSize: 18, fontWeight: '600' },
    footerMask: { position: 'absolute', bottom: -10, left: 0, right: 0, zIndex: 50 },
    inputBar: { paddingHorizontal: 16 },
    inputSticky: { position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 70, overflow: 'visible' },
    msgRow: { width: '100%', flexDirection: 'row' },
    msgRowMe: { justifyContent: 'flex-end' },
    msgRowThem: { justifyContent: 'flex-start' },
    swipeContainer: { position: 'relative', width: '100%' },
    swipeContainerMe: { alignItems: 'flex-end' },
    swipeContainerThem: { alignItems: 'flex-start' },
    replyIconContainer: { position: 'absolute', top: '50%', marginTop: -10, zIndex: 2 },
    replyIconLeft: { left: 18 },
    replyIconRight: { right: 18 },
});
