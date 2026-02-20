import React, { useState, useEffect, useRef, useMemo } from 'react';
import {
    View, Text, FlatList, TouchableOpacity,
    StyleSheet, InteractionManager, ActivityIndicator,
    Keyboard, Platform, Dimensions, TextInput
} from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Search, Bookmark, Trash2, X } from 'lucide-react-native';
import { Swipeable, GestureHandlerRootView } from 'react-native-gesture-handler';
import Animated, {
    FadeIn,
    useSharedValue,
    useAnimatedStyle,
    withSpring,
} from 'react-native-reanimated';
import { KeyboardStickyView, useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';

import { useSavedMessagesStore } from '../src/lib/stores/saved-messages-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { Message } from '../src/lib/types';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import ChatInput from '../src/components/chat/ChatInput';
import { MessageBubbleBody } from '../src/components/chat/bubbles';
import WallpaperBackground from '../src/components/chat/WallpaperBackground';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';
import EmptyChatState from '../src/components/chat/EmptyChatState';
import * as Haptics from 'expo-haptics';
import MessageContextMenu from '../src/components/chat/MessageContextMenu';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const MaskedViewAny = MaskedView as any;

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

export default function SavedMessagesScreen() {
    const { savedMessages, sync, removeMessage, sendMessage } = useSavedMessagesStore();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const { user } = useAuthStore();
    const router = useRouter();
    const insets = useSafeAreaInsets();

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
    const [text, setText] = useState('');
    const flatListRef = useRef<FlatList>(null);

    // Context Menu State
    const [contextMenuVisible, setContextMenuVisible] = useState(false);
    const [selectedMessageInfo, setSelectedMessageInfo] = useState<any>(null);
    const [menuPosition, setMenuPosition] = useState<{ x: number, y: number, width: number, height: number } | null>(null);

    // Search state
    const [isSearching, setIsSearching] = useState(false);
    const [searchQuery, setSearchQuery] = useState('');
    const searchInputRef = useRef<TextInput>(null);

    // Keyboard handling
    const { height: keyboardHeight } = useReanimatedKeyboardAnimation();
    const footerHeight = insets.bottom + 60;

    const fakeViewStyle = useAnimatedStyle(() => {
        const kbHeight = Math.abs(keyboardHeight.value);
        return {
            height: footerHeight + kbHeight,
        };
    });

    useEffect(() => {
        sync();
    }, []);

    const handleSend = () => {
        if (!text.trim()) return;
        sendMessage(text.trim());
        setText('');
        setTimeout(() => {
            flatListRef.current?.scrollToOffset({ offset: 0, animated: true });
        }, 100);
    };

    const handleAttach = (data: any) => {
        if (data.type === 'location') {
            sendMessage(`Location`, 'location', { latitude: data.latitude, longitude: data.longitude });
        } else if (data.type === 'image') {
            sendMessage(`Image`, 'image', { mediaUrl: data.uri, width: data.width, height: data.height });
        } else if (data.type === 'contact') {
            sendMessage('Contact', 'contact', { contact: data.contact });
        } else if (data.type === 'file') {
            const isVoice = data.name.toLowerCase().endsWith('.m4a') && (data.duration !== undefined);
            if (isVoice) {
                sendMessage('Voice Message', 'voice', {
                    mediaUrl: data.uri,
                    fileName: data.name,
                    duration: data.duration
                });
            } else {
                const isMusic = data.name.toLowerCase().endsWith('.mp3') || data.name.toLowerCase().endsWith('.wav') || data.name.toLowerCase().endsWith('.m4a');
                sendMessage(data.name, isMusic ? 'music' : 'file', { mediaUrl: data.uri, fileName: data.name });
            }
        }
    };

    const messagesWithSequence = useMemo(() => {
        return savedMessages.map((item, index) => {
            const newer = savedMessages[index - 1];
            const older = savedMessages[index + 1];

            const isSameAsNewer = newer && newer.fromId === item.fromId;
            const isSameAsOlder = older && older.fromId === item.fromId;

            const isNewerClose = isSameAsNewer && (Math.abs(newer.timestamp - item.timestamp) < 60000);
            const isOlderClose = isSameAsOlder && (Math.abs(item.timestamp - older.timestamp) < 60000);

            let showDateHeader = false;
            let dateHeaderText = '';

            const itemDate = new Date(item.timestamp);
            const olderDate = older ? new Date(older.timestamp) : null;

            if (!older || (olderDate && itemDate.toDateString() !== olderDate.toDateString())) {
                showDateHeader = true;
                const today = new Date();
                const yesterday = new Date();
                yesterday.setDate(today.getDate() - 1);

                if (itemDate.toDateString() === today.toDateString()) {
                    dateHeaderText = 'Today';
                } else if (itemDate.toDateString() === yesterday.toDateString()) {
                    dateHeaderText = 'Yesterday';
                } else {
                    dateHeaderText = itemDate.toLocaleDateString('en-US', {
                        month: 'long',
                        day: 'numeric',
                        year: itemDate.getFullYear() !== today.getFullYear() ? 'numeric' : undefined
                    });
                }
            }

            return {
                ...item,
                isSequenceStart: !isOlderClose,
                isSequenceEnd: !isNewerClose,
                isMiddle: isSameAsOlder && isSameAsNewer,
                showDateHeader,
                dateHeaderText,
            };
        });
    }, [savedMessages]);

    // Filter messages based on search query
    const filteredMessages = useMemo(() => {
        if (!searchQuery.trim()) return messagesWithSequence;
        const query = searchQuery.toLowerCase().trim();
        return messagesWithSequence.filter(msg =>
            (msg.plaintext || '').toLowerCase().includes(query)
        );
    }, [messagesWithSequence, searchQuery]);

    const handleSearchToggle = () => {
        if (isSearching) {
            setIsSearching(false);
            setSearchQuery('');
        } else {
            setIsSearching(true);
            setTimeout(() => searchInputRef.current?.focus(), 100);
        }
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    };

    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            <Stack.Screen options={{ headerShown: false }} />

            <GestureHandlerRootView style={{ flex: 1 }}>
                {/* Background */}
                <WallpaperBackground />

                {/* Header Mask */}
                <View style={[styles.headerContainer, { height: insets.top + 60, zIndex: 60, pointerEvents: 'none' }]}>
                    <MaskedViewAny
                        style={StyleSheet.absoluteFill}
                        maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.6, 1]} style={StyleSheet.absoluteFill} />}
                    >
                        <BlurView intensity={10} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: 'transparent' }]} />
                    </MaskedViewAny>
                </View>

                {/* Header Content */}
                <View style={[
                    styles.headerContentContainer,
                    {
                        height: insets.top + 60,
                        paddingTop: insets.top + 10,
                        zIndex: 130,
                        flexDirection: 'row',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        paddingHorizontal: 16
                    }
                ]} pointerEvents="box-none">

                    {/* Left: Back + Badge + Title */}
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                        <SafeLiquidGlass style={{ borderRadius: 20, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                            <TouchableOpacity
                                onPress={() => router.back()}
                                style={{
                                    width: 40,
                                    height: 40,
                                    justifyContent: 'center',
                                    alignItems: 'center',
                                }}
                            >
                                <ArrowLeft color={colors.text} size={28} />
                            </TouchableOpacity>
                        </SafeLiquidGlass>

                        {/* Profile Info styled like chat.tsx */}
                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                            <View style={{ width: 40, height: 40, borderRadius: 20, overflow: 'hidden', backgroundColor: colors.primary + '20', justifyContent: 'center', alignItems: 'center' }}>
                                <Bookmark size={20} color={colors.primary} fill={colors.primary} />
                            </View>

                            {!isSearching && (
                                <View>
                                    <Text style={{ color: colors.text, fontSize: 16, fontWeight: '600' }} numberOfLines={1}>
                                        Saved Messages
                                    </Text>

                                </View>
                            )}
                        </View>
                    </View>

                    {/* Right Area: Search Icon & Input */}
                    <View style={{ flexDirection: 'row', alignItems: 'center', flex: isSearching ? 1 : 0, justifyContent: 'flex-end', marginLeft: isSearching ? 10 : 0 }}>
                        {isSearching ? (
                            <SafeLiquidGlass style={{ flex: 1, height: 40, borderRadius: 20, overflow: 'hidden', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12 }} blurIntensity={25} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <Search size={18} color={withAlpha(colors.text, 0.5)} />
                                <TextInput
                                    ref={searchInputRef}
                                    style={{ flex: 1, color: colors.text, fontSize: 15, paddingLeft: 8, height: '100%' }}
                                    placeholder="Search messages..."
                                    placeholderTextColor={withAlpha(colors.text, 0.4)}
                                    value={searchQuery}
                                    onChangeText={setSearchQuery}
                                    autoCorrect={false}
                                />
                                <TouchableOpacity onPress={() => setIsSearching(false)}>
                                    <Text style={{ color: colors.primary, fontWeight: '600' }}>Cancel</Text>
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        ) : (
                            <SafeLiquidGlass style={{ borderRadius: 20, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <TouchableOpacity
                                    onPress={handleSearchToggle}
                                    style={{ width: 40, height: 40, justifyContent: 'center', alignItems: 'center' }}
                                >
                                    <Search color={colors.text} size={22} />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        )}
                    </View>
                </View>

                {/* List */}
                <FlatList
                    ref={flatListRef}
                    data={filteredMessages}
                    keyExtractor={item => item.id}
                    renderItem={({ item, index }) => {
                        const isMe = item.fromId === user?.userId;
                        return (
                            <Animated.View entering={FadeIn.duration(200)} style={{ marginBottom: 2 }}>
                                {item.showDateHeader && (
                                    <View style={styles.dateHeaderContainer}>
                                        <SafeLiquidGlass style={styles.dateHeaderGlass} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                            <Text style={[styles.dateHeaderText, { color: colors.text }]}>{item.dateHeaderText}</Text>
                                        </SafeLiquidGlass>
                                    </View>
                                )}
                                <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: isMe ? 'flex-end' : 'flex-start', paddingHorizontal: 16 }}>
                                    <LinearGradient
                                        colors={isMe ? bubbleTheme.meGradient : bubbleTheme.themGradient}
                                        start={{ x: 0, y: 0 }}
                                        end={{ x: 1, y: 1 }}
                                        style={[
                                            {
                                                padding: (item.type === 'image' || item.type === 'sticker') && !item.plaintext ? 0 : 8,
                                                paddingHorizontal: (item.type === 'image' || item.type === 'sticker') && !item.plaintext ? 0 : 12,
                                                borderRadius: 18,
                                                maxWidth: '85%',
                                            },
                                            isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 },
                                        ]}
                                    >
                                        <MessageBubbleBody item={{
                                            ...item,
                                            isMe,
                                            text: item.plaintext || '',
                                            timestamp: new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                        } as any} />
                                    </LinearGradient>
                                </View>
                            </Animated.View>
                        );
                    }}
                    extraData={filteredMessages.length}
                    inverted
                    contentContainerStyle={{ paddingTop: insets.top + 70, paddingBottom: 10 }}
                    showsVerticalScrollIndicator={false}
                    keyboardDismissMode="interactive"
                    keyboardShouldPersistTaps="handled"
                    ListHeaderComponent={<Animated.View style={[fakeViewStyle]} />}
                    ListEmptyComponent={
                        <View style={{ flex: 1, transform: [{ scaleY: -1 }], alignItems: 'center', marginTop: 100 }}>
                            <Text style={{ color: colors.textSecondary }}>
                                {searchQuery ? 'No matching messages' : 'No saved messages yet'}
                            </Text>
                        </View>
                    }
                />

                {/* Input Container */}
                <KeyboardStickyView offset={{ closed: 0, opened: 25 }} style={{ position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 65 }}>
                    <View style={{ paddingBottom: Math.max(insets.bottom, 10), paddingTop: 10, paddingHorizontal: 16 }}>
                        <ChatInput
                            text={text}
                            setText={setText}
                            onSend={handleSend}
                            onAttach={handleAttach}
                        />
                    </View>
                </KeyboardStickyView>

                {/* Context Menu */}
                <MessageContextMenu
                    visible={contextMenuVisible}
                    onClose={() => setContextMenuVisible(false)}
                    position={menuPosition}
                    isMe={selectedMessageInfo?.item?.fromId === user?.userId}
                    messageText={selectedMessageInfo?.item?.plaintext}
                    onReply={() => setContextMenuVisible(false)}
                    onDelete={() => { removeMessage(selectedMessageInfo?.item?.id); setContextMenuVisible(false); }}
                    colors={colors}
                    displayContent={selectedMessageInfo?.displayContent}
                    item={selectedMessageInfo?.item}
                    isSequenceStart={selectedMessageInfo?.isSequenceStart}
                    isSequenceEnd={selectedMessageInfo?.isSequenceEnd}
                    isMiddle={selectedMessageInfo?.isMiddle}
                />
            </GestureHandlerRootView>
        </View>
    );
}

const styles = StyleSheet.create({
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 50 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 4 },
    headerBtnWrapper: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', zIndex: 140 },
    headerGlassBtn: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    headerTouchArea: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center', zIndex: 150 },
    headerCenterWrapper: { flex: 1, alignItems: 'center', justifyContent: 'center', marginHorizontal: 10, height: 44 },
    headerCenterGlass: { flex: 1, borderRadius: 22, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 20 },
    headerTitle: { fontSize: 16, fontWeight: '700', textAlign: 'center' },
    headerGlassGroup: { flexDirection: 'row', alignItems: 'center', borderRadius: 22, height: 44, paddingHorizontal: 4 },
    headerIconBtn: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
    separator: { width: 1, height: 20, marginHorizontal: 2 },

    dateHeaderContainer: {
        alignItems: 'center',
        marginVertical: 12,
        marginTop: 20,
    },
    dateHeaderGlass: {
        paddingHorizontal: 16,
        paddingVertical: 4,
        borderRadius: 12,
        minWidth: 80,
        alignItems: 'center',
    },
    dateHeaderText: {
        fontSize: 12,
        fontWeight: '600',
        opacity: 0.8,
    },
});
