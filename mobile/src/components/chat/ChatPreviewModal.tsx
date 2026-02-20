import React, { useEffect, useRef, useState, useMemo } from 'react';
import {
    View,
    Text,
    StyleSheet,
    Dimensions,
    Image,
    TouchableOpacity,
    BackHandler,
    FlatList,
    Modal
} from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    useDerivedValue,
    withSpring,
    withTiming,
    runOnJS,
    interpolate,
    Extrapolate,
} from 'react-native-reanimated';
import { GestureDetector, Gesture, GestureHandlerRootView } from 'react-native-gesture-handler';
import { BlurView } from 'expo-blur';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { LinearGradient } from 'expo-linear-gradient';
import MaskedView from '@react-native-masked-view/masked-view';
import { Pin, VolumeX, Trash2, ArrowLeft, ChevronLeft, Bookmark } from 'lucide-react-native';
import * as Haptics from 'expo-haptics';

import { useThemeStore } from '../../lib/stores/theme-store';
import { useAuthStore } from '../../lib/stores/auth-store';
import { useChatStore } from '../../lib/ChatStore';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { MessageBubbleBody } from './bubbles';
import WallpaperBackground from './WallpaperBackground';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { useToastStore } from '../../lib/stores/toast-store';
import * as Clipboard from 'expo-clipboard';

// Spring configs
const SPRING_OPEN = { mass: 0.8, damping: 26, stiffness: 300, overshootClamping: false };
const SPRING_CLOSE = { mass: 1, damping: 32, stiffness: 400, overshootClamping: true };
const DRAG_DISMISS_THRESHOLD = 80;

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');
const PREVIEW_WIDTH = SCREEN_WIDTH * 0.88;
const PREVIEW_HEIGHT = SCREEN_HEIGHT * 0.55;

interface ChatPreviewModalProps {
    visible: boolean;
    startLayout: { x: number; y: number; width: number; height: number } | null;
    chat: any;
    onClose: () => void;
    onPin: () => void;
    onMute: () => void;
    onDelete: () => void;
}

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16)
        const g = parseInt(color.slice(3, 5), 16)
        const b = parseInt(color.slice(5, 7), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

// Time ago helper (mirrors home.tsx)
const timeAgo = (timestamp: number | string | Date): string => {
    const now = Date.now()
    const time = typeof timestamp === 'number' ? timestamp : new Date(timestamp).getTime()
    const diff = now - time
    if (!time || isNaN(time)) return ''
    const mins = Math.floor(diff / 60000)
    if (mins < 1) return 'now'
    if (mins < 60) return `${mins}m`
    const hours = Math.floor(mins / 60)
    if (hours < 24) return `${hours}h`
    const days = Math.floor(hours / 24)
    return `${days}d`
}

const getMessageText = (msg: any): string => {
    if (!msg) return 'Start a conversation'
    if (typeof msg === 'string') return msg

    let text = msg._senderPlaintext ||
        msg.senderPlaintext ||
        msg.sender_plaintext ||
        msg.plaintext ||
        msg.content ||
        msg.text

    if (text && typeof text === 'object') {
        text = text.plaintext || text.content || text.text || ''
    }

    if (text && typeof text === 'string' && text.length > 0) {
        const trimmed = text.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
            try {
                const parsed = JSON.parse(text);
                const extracted = parsed.plaintext || parsed.content || parsed.text;
                if (extracted && typeof extracted === 'string') return extracted;
                text = '';
            } catch (e) { }
        }
    }

    if (text && typeof text === 'string' && text.length > 0) {
        return text
    }

    if (msg.type === 'image') return '📷 Photo'
    if (msg.type === 'voice') return '🎤 Voice message'
    if (msg.type === 'gif') return '🎬 GIF'
    if (msg.type === 'sticker') return '🧩 Sticker'
    if (msg.type === 'video') return '🎥 Video'

    return 'Message'
}

const getBubbleContentText = (msg: any): string => {
    let text = msg.plaintext || msg.content || msg.text || ''
    if (text && typeof text === 'string') {
        const trimmed = text.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
            try {
                const parsed = JSON.parse(text);
                return parsed.plaintext || parsed.content || parsed.text || '';
            } catch (e) { }
        }
        return text
    }
    return '';
}

export default function ChatPreviewModal({
    visible,
    startLayout,
    chat,
    onClose,
    onPin,
    onMute,
    onDelete
}: ChatPreviewModalProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const { user } = useAuthStore();
    const insets = useSafeAreaInsets();
    const { onlineUsers } = useChatStore();
    const { activeTheme } = useWallpaperStore();

    const resolvedTheme = useMemo(() => {
        return resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
    }, [activeTheme, effectiveTheme]);

    const bubbleTheme = useMemo(() => ({
        meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
            ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
            : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
        themGradient: (resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length >= 2
            ? [resolvedTheme.bubbleThemGradient[0], resolvedTheme.bubbleThemGradient[1]]
            : [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem]) as [string, string],
    }), [resolvedTheme]);

    const displayName = chat ? (chat.name || chat.friendName || chat.friendId || 'Unknown User') : 'Loading...';
    const isOnline = chat && chat.friendId ? onlineUsers.has(chat.friendId.toUpperCase()) : false;
    const subtitle = isOnline ? 'online' : (chat?.type === 'channel' ? `${chat.subscribers || '25,672'} subscribers` : 'last seen recently');

    const progress = useSharedValue(0);
    const dragY = useSharedValue(0);
    const dragX = useSharedValue(0);
    const [renderContent, setRenderContent] = useState(false);

    useEffect(() => {
        if (visible) {
            setRenderContent(true);
            progress.value = withSpring(1, SPRING_OPEN);
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        } else {
            progress.value = withTiming(0, { duration: 200 });
            dragX.value = withTiming(0, { duration: 200 });
            dragY.value = withTiming(0, { duration: 200 });
            setTimeout(() => setRenderContent(false), 200);
        }
    }, [visible]);

    const pan = Gesture.Pan()
        .onChange((e) => {
            dragY.value = e.translationY;
            dragX.value = e.translationX;
        })
        .onEnd((e) => {
            const shouldDismiss =
                Math.abs(e.translationY) > DRAG_DISMISS_THRESHOLD ||
                Math.abs(e.translationX) > DRAG_DISMISS_THRESHOLD ||
                Math.abs(e.velocityY) > 500;

            if (shouldDismiss) {
                runOnJS(onClose)();
            } else {
                dragY.value = withSpring(0);
                dragX.value = withSpring(0);
            }
        });

    const cardStyle = useAnimatedStyle(() => {
        if (!startLayout) return { opacity: 0 };

        const targetWidth = PREVIEW_WIDTH;
        const targetHeight = PREVIEW_HEIGHT;
        const targetX = (SCREEN_WIDTH - targetWidth) / 2;
        const targetY = (SCREEN_HEIGHT - targetHeight) / 2 - 20;

        const currentProgress = progress.value;
        const dragScale = interpolate(Math.abs(dragY.value), [0, 400], [1, 0.85], Extrapolate.CLAMP);

        const top = interpolate(currentProgress, [0, 1], [startLayout.y, targetY]) + dragY.value;
        const left = interpolate(currentProgress, [0, 1], [startLayout.x, targetX]) + dragX.value;
        const width = interpolate(currentProgress, [0, 1], [startLayout.width, targetWidth]);
        const height = interpolate(currentProgress, [0, 1], [startLayout.height, targetHeight]);
        const radius = interpolate(currentProgress, [0, 1], [15, 28]);

        return {
            position: 'absolute',
            top,
            left,
            width,
            height,
            borderRadius: radius,
            overflow: 'hidden',
            backgroundColor: colors.background,
            transform: [{ scale: dragScale }],
            zIndex: 1000
        };
    });

    const backdropStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 1], [0, 1]),
    }));

    const menuStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: interpolate(progress.value, [0.6, 1], [40, 0], Extrapolate.CLAMP) },
            { scale: interpolate(progress.value, [0.6, 1], [0.8, 1], Extrapolate.CLAMP) },
            { translateY: dragY.value }
        ],
        opacity: interpolate(progress.value, [0.6, 0.8], [0, 1], Extrapolate.CLAMP)
    }));

    const headerProgress = useDerivedValue(() => {
        return withTiming(progress.value > 0.1 ? 1 : 0, { duration: 250 });
    });

    const headerStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: interpolate(headerProgress.value, [0, 1], [-100, 0]) }],
        opacity: interpolate(headerProgress.value, [0, 0.1], [0, 1])
    }));

    const expandedContentStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0.2, 0.8], [0, 1]),
        width: PREVIEW_WIDTH,
        height: '100%',
        transform: [{ translateY: interpolate(progress.value, [0.2, 1], [15, 0]) }]
    }));

    const originalContentStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.2], [1, 0]),
        position: 'absolute',
        top: 0,
        left: 0,
        width: '100%',
        height: '100%',
        paddingHorizontal: 16,
        paddingTop: 14,
        paddingBottom: 14,
        flexDirection: 'row',
        alignItems: 'flex-start',
    }));

    const lastMsg = chat?.lastMessage;
    const lastMsgText = useMemo(() => {
        return getMessageText(chat?.lastMessage);
    }, [chat?.lastMessage]);
    const lastMsgTime = chat?.lastMessage ? timeAgo(chat.lastMessage.timestamp || chat.updatedAt) : '';
    const previewMessages = chat?.messages ? [...chat.messages].reverse().slice(0, 15) : [];

    const showToast = useToastStore(s => s.showToast);

    const handleCopy = async (text: string) => {
        await Clipboard.setStringAsync(text);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        showToast('Message copied to clipboard', 'success');
    };

    return (
        <Modal visible={visible || renderContent} transparent animationType="none">
            <GestureHandlerRootView style={StyleSheet.absoluteFill}>
                {/* Backdrop with extreme blur and dimming */}
                <Animated.View style={[StyleSheet.absoluteFill, backdropStyle]}>
                    <BlurView
                        intensity={40}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        style={StyleSheet.absoluteFill}
                    />
                    <View style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.4)' }} />
                    <TouchableOpacity style={StyleSheet.absoluteFill} onPress={onClose} activeOpacity={1} />
                </Animated.View>

                {/* Morphing Preview Card */}
                <GestureDetector gesture={pan}>
                    <Animated.View style={cardStyle}>
                        {/* Placeholder Content (matches ChatRowCard) */}
                        <Animated.View style={originalContentStyle}>
                            <View style={{ width: 60, height: 60, marginRight: 14 }}>
                                <SafeLiquidGlass style={{ width: 60, height: 60, borderRadius: 30, overflow: 'hidden' }} blurIntensity={10} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                    {chat?.chatId === 'saved_messages' ? (
                                        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.primary + '20' }}>
                                            <Bookmark size={24} color={colors.primary} fill={colors.primary} />
                                        </View>
                                    ) : chat?.friendImage ? (
                                        <Image source={{ uri: chat.friendImage }} style={{ width: '100%', height: '100%' }} />
                                    ) : (
                                        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(127, 127, 127, 0.12)' }}>
                                            <Text style={{ fontSize: 20, fontWeight: '600', color: colors.text }}>
                                                {(chat?.friendName || chat?.username || chat?.friendId || 'U').substring(0, 1).toUpperCase()}
                                            </Text>
                                        </View>
                                    )}
                                </SafeLiquidGlass>
                                {isOnline && chat?.chatId !== 'saved_messages' && (
                                    <View style={{
                                        position: 'absolute',
                                        bottom: 2,
                                        right: 2,
                                        width: 14,
                                        height: 14,
                                        borderRadius: 7,
                                        backgroundColor: '#34d399',
                                        borderWidth: 2,
                                        borderColor: colors.background,
                                        zIndex: 10
                                    }} />
                                )}
                            </View>
                            <View style={{ flex: 1, justifyContent: 'flex-start', marginTop: 2, gap: 2 }}>
                                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                                    <View style={{ flexDirection: 'row', alignItems: 'center', flex: 1 }}>
                                        {chat?.type === 'channel' && (
                                            <View style={{ backgroundColor: colors.primary + '20', paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, marginRight: 6 }}>
                                                <Text style={{ color: colors.primary, fontSize: 9, fontWeight: '700' }}>CH</Text>
                                            </View>
                                        )}
                                        {chat?.type === 'group' && (
                                            <View style={{ backgroundColor: colors.primary + '20', paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, marginRight: 6 }}>
                                                <Text style={{ color: colors.primary, fontSize: 9, fontWeight: '700' }}>GR</Text>
                                            </View>
                                        )}
                                        <Text style={{ fontSize: 17, fontWeight: '500', color: colors.text }} numberOfLines={1}>
                                            {chat?.chatId === 'saved_messages' ? 'Saved Messages' : (chat?.name || chat?.friendName || chat?.friendId || 'Unknown')}
                                        </Text>
                                    </View>
                                    <Text style={{ fontSize: 13, color: colors.textSecondary, marginLeft: 8 }}>{lastMsgTime}</Text>
                                </View>
                                <View style={{ flexDirection: 'row', alignItems: 'flex-start', marginTop: 4 }}>
                                    <View style={{ flex: 1, height: 20, justifyContent: 'center' }}>
                                        <Text style={{ fontSize: 15, color: colors.textSecondary }} numberOfLines={1}>
                                            {lastMsgText}
                                        </Text>
                                    </View>

                                    <View style={{ alignItems: 'flex-end', marginLeft: 10 }}>
                                        {(chat?.unreadCount > 0 || chat?.markedUnread) && (
                                            <View style={{
                                                minWidth: 20,
                                                height: 20,
                                                borderRadius: 10,
                                                backgroundColor: colors.primary,
                                                alignItems: 'center',
                                                justifyContent: 'center',
                                                paddingHorizontal: 6
                                            }}>
                                                {chat?.unreadCount > 0 && (
                                                    <Text style={{ fontSize: 11, fontWeight: '700', color: '#fff' }}>{chat.unreadCount}</Text>
                                                )}
                                            </View>
                                        )}
                                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 4, justifyContent: 'flex-end' }}>
                                            {chat?.muted && <VolumeX size={15} color={withAlpha(colors.text, 0.4)} strokeWidth={2} />}
                                            {chat?.pinned && <Pin size={15} color={withAlpha(colors.text, 0.4)} fill={withAlpha(colors.text, 0.4)} style={{ transform: [{ rotate: '45deg' }] }} strokeWidth={2} />}
                                        </View>
                                    </View>
                                </View>
                            </View>
                        </Animated.View>

                        {/* Real Content (fades in) */}
                        <Animated.View style={expandedContentStyle}>
                            <View style={{ flex: 1, overflow: 'hidden' }}>
                                <WallpaperBackground />

                                {/* Floating Unified Glass Header (Slides Down) */}
                                <Animated.View style={[styles.floatingHeaderWrapper, headerStyle]}>
                                    <SafeLiquidGlass style={styles.headerGlassPill} blurIntensity={30} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                        <View style={styles.headerPillContent}>
                                            <TouchableOpacity onPress={onClose} style={styles.headerBack}>
                                                <ChevronLeft color={colors.text} size={24} />
                                                {chat?.unreadCount > 0 && (
                                                    <Text style={[styles.headerUnread, { color: colors.text }]}>{chat.unreadCount}</Text>
                                                )}
                                            </TouchableOpacity>

                                            <View style={styles.headerCenter}>
                                                <Text style={[styles.headerTitle, { color: colors.text }]} numberOfLines={1}>{displayName}</Text>
                                                <Text style={[styles.headerSubtitle, { color: withAlpha(colors.text, 0.6) }]} numberOfLines={1}>{subtitle}</Text>
                                            </View>

                                            <View style={styles.headerAvatar}>
                                                {chat?.friendImage ? (
                                                    <Image source={{ uri: chat.friendImage }} style={styles.headerAvatarImg} />
                                                ) : (
                                                    <View style={styles.headerAvatarPlaceholder}>
                                                        <Text style={{ color: colors.text, fontWeight: '700', fontSize: 16 }}>{displayName[0].toUpperCase()}</Text>
                                                    </View>
                                                )}
                                            </View>
                                        </View>
                                    </SafeLiquidGlass>
                                </Animated.View>

                                <View style={{ flex: 1, paddingTop: 70 }}>
                                    <FlatList
                                        data={previewMessages}
                                        keyExtractor={(item) => item.id}
                                        inverted
                                        renderItem={({ item }) => {
                                            const isMe = item.fromId === user?.userId || item.isMe;
                                            const textContent = getBubbleContentText(item);
                                            const mediaOnly = (item.type === 'image' || item.type === 'video' || item.type === 'gif' || item.type === 'sticker') && !textContent.trim();

                                            return (
                                                <View style={{
                                                    paddingHorizontal: 15,
                                                    marginBottom: 4,
                                                    alignItems: isMe ? 'flex-end' : 'flex-start'
                                                }}>
                                                    <LinearGradient
                                                        colors={isMe ? bubbleTheme.meGradient : bubbleTheme.themGradient}
                                                        start={{ x: 0, y: 0 }}
                                                        end={{ x: 1, y: 1 }}
                                                        style={[
                                                            {
                                                                padding: (item.type === 'image' || item.type === 'sticker') && !textContent ? 0 : 8,
                                                                paddingHorizontal: (item.type === 'image' || item.type === 'sticker') && !textContent ? 0 : 12,
                                                                borderRadius: 18,
                                                                maxWidth: '85%',
                                                            },
                                                            isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 },
                                                            mediaOnly && { backgroundColor: 'transparent', padding: 0, overflow: 'hidden' }
                                                        ]}
                                                    >
                                                        <MessageBubbleBody item={{
                                                            ...item,
                                                            isMe,
                                                            text: textContent,
                                                            timestamp: new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                                        } as any} />
                                                    </LinearGradient>
                                                </View>
                                            );
                                        }}
                                        contentContainerStyle={{ paddingTop: 80, paddingBottom: 40 }}
                                        showsVerticalScrollIndicator={false}
                                    />
                                </View>
                            </View>
                        </Animated.View>
                    </Animated.View>
                </GestureDetector>

                {/* Context Menu below modal */}
                <Animated.View style={[styles.menuWrapper, menuStyle]}>
                    <View style={styles.menuContainer}>
                        <BlurView
                            style={styles.menuBlur}
                            intensity={60}
                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        />
                        <View style={[styles.menuBg, { backgroundColor: withAlpha(colors.background, effectiveTheme === 'dark' ? 0.3 : 0.6) }]} />

                        <View style={styles.menuContent}>
                            <TouchableOpacity style={styles.menuItem} onPress={onPin}>
                                <Text style={[styles.menuText, { color: colors.text }]}>{chat?.pinned ? 'Unpin' : 'Pin'}</Text>
                                <Pin size={21} color={colors.text} strokeWidth={1.5} />
                            </TouchableOpacity>

                            <View style={[styles.separator, { backgroundColor: withAlpha(colors.text, 0.08) }]} />

                            <TouchableOpacity style={styles.menuItem} onPress={onMute}>
                                <Text style={[styles.menuText, { color: colors.text }]}>{chat?.muted ? 'Unmute' : 'Mute'}</Text>
                                <VolumeX size={21} color={colors.text} strokeWidth={1.5} />
                            </TouchableOpacity>

                            <View style={[styles.separator, { backgroundColor: withAlpha(colors.text, 0.08) }]} />

                            <TouchableOpacity style={styles.menuItem} onPress={onDelete}>
                                <Text style={[styles.menuText, { color: '#ef4444' }]}>Delete</Text>
                                <Trash2 size={21} color="#ef4444" strokeWidth={1.5} />
                            </TouchableOpacity>
                        </View>
                    </View>
                </Animated.View>
            </GestureHandlerRootView>
        </Modal>
    );
}

const styles = StyleSheet.create({
    floatingHeaderWrapper: {
        position: 'absolute',
        top: 12,
        left: 0,
        right: 0,
        alignItems: 'center',
        zIndex: 100,
        paddingHorizontal: 12,
    },
    headerGlassPill: {
        borderRadius: 25,
        height: 50,
        width: '100%',
        overflow: 'hidden',
    },
    headerPillContent: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 8,
    },
    headerBack: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingRight: 12,
        height: '100%',
    },
    headerUnread: {
        fontSize: 16,
        fontWeight: '500',
        marginLeft: -2,
    },
    headerCenter: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: 8,
    },
    headerTitle: {
        fontSize: 15,
        fontWeight: '700',
    },
    headerSubtitle: {
        fontSize: 11,
        fontWeight: '500',
        marginTop: -1,
    },
    headerAvatar: {
        width: 38,
        height: 38,
        borderRadius: 19,
        overflow: 'hidden',
    },
    headerAvatarImg: {
        width: '100%',
        height: '100%',
    },
    headerAvatarPlaceholder: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(127,127,127,0.1)',
    },
    menuWrapper: {
        position: 'absolute',
        top: (SCREEN_HEIGHT - PREVIEW_HEIGHT) / 2 + PREVIEW_HEIGHT + 2,
        right: (SCREEN_WIDTH - PREVIEW_WIDTH) / 2,
        width: 210,
        zIndex: 2000,
    },
    menuContainer: {
        borderRadius: 20,
        overflow: 'hidden',
    },
    menuBlur: {
        ...StyleSheet.absoluteFillObject,
    },
    menuBg: {
        ...StyleSheet.absoluteFillObject,
    },
    menuContent: {
        paddingVertical: 4,
    },
    menuItem: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingVertical: 14,
        paddingHorizontal: 20,
    },
    menuText: {
        fontSize: 17,
        fontWeight: '400',
    },
    separator: {
        height: 0.5,
        marginHorizontal: 0,
    },
});
