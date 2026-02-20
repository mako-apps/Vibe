import React, { useMemo, useCallback, useEffect, useState } from 'react';
import { View, Text, StyleSheet, Linking, Pressable, Image, TouchableOpacity, ActivityIndicator, Dimensions, Modal, SafeAreaView } from 'react-native';
import Svg, { Path, Circle } from 'react-native-svg';
import { Video as ExpoVideo, ResizeMode } from 'expo-av';
import * as WebBrowser from 'expo-web-browser';
import { LinearGradient } from 'expo-linear-gradient';
import Animated, { useAnimatedStyle, useSharedValue, withSpring, withTiming, runOnJS, Easing, ZoomIn, withRepeat, withSequence } from 'react-native-reanimated';
import { Message } from '../../lib/types';
import { CheckIcon, DoubleCheckIcon } from '../Icons';
import { Music, FileText, MapPin, Play, Pause, Clock, Image as ImageIcon, Disc, AlertCircle, Eye, EyeOff, Sparkles, Video as VideoIcon, Phone, PhoneIncoming, PhoneOutgoing, PhoneMissed, PhoneOff } from 'lucide-react-native';
import AnimatedEmoji from './AnimatedEmoji';
import { ANIMATED_EMOJIS } from '../../lib/emojiAssets';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { useMusicPlayerStore } from '../../lib/stores/music-player-store';
import { useChatStore } from '../../lib/ChatStore';
import { MusicBubble } from '../agent/MusicBubble';
import * as Haptics from 'expo-haptics';
import { AudioWaveform } from '../../lib/services/AudioWaveform';
import { useNetInfo } from '@react-native-community/netinfo';
import { useEncryptedMediaStore } from '../../lib/stores/encrypted-media-store';
import { useSavedMessagesStore } from '../../lib/stores/saved-messages-store';
import MaskedView from '@react-native-masked-view/masked-view';
import * as FileSystem from 'expo-file-system/legacy';
import { Canvas, Image as SkiaImage, Blur, useImage, Rect, rrect } from '@shopify/react-native-skia';

const MaskedViewAny = MaskedView as any;

// Hook to transparently handle encrypted media
const useEncryptedMedia = (url?: string, key?: string, fileName?: string) => {
    const [mediaUri, setMediaUri] = React.useState<string | undefined>(url);
    const [loading, setLoading] = React.useState(false);
    const getDecryptedFile = useEncryptedMediaStore(s => s.getDecryptedFile);

    React.useEffect(() => {
        let mounted = true;

        const run = async () => {
            if (!url) {
                setMediaUri(undefined);
                return;
            }

            // If no key or local file, use URL as is
            if (!key || url.startsWith('file://') || url.startsWith('/')) {
                setMediaUri(url);
                return;
            }

            // Check cache first - if cached file exists, use it immediately without loading state
            try {
                const cached = useEncryptedMediaStore.getState().cache[url];
                if (cached) {
                    const info = await FileSystem.getInfoAsync(cached);
                    if (info.exists) {
                        if (mounted) setMediaUri(cached);
                        return; // Already cached, no need to decrypt again
                    }
                }
            } catch { }

            // Not cached - need to download & decrypt
            if (mounted) setLoading(true);
            try {
                const localUri = await getDecryptedFile(url, key, fileName);
                if (mounted && localUri) setMediaUri(localUri);
            } catch (err) {
                console.warn('[MessageBubble] Decrypt failed:', err);
            } finally {
                if (mounted) setLoading(false);
            }
        };

        run();

        return () => { mounted = false; };
    }, [url, key, fileName]);

    return { mediaUri, loading };
};

interface ReplyPreview {
    userName: string;
    content: string;
}

interface MessageBubbleProps {
    item: Message;
    isMe: boolean;
    isSequenceStart: boolean;
    isSequenceEnd: boolean;
    isMiddle: boolean;
    displayContent: string;
    onLongPress?: (ref: any) => void;
    onViewOnce?: (messageId: string) => void;
    isClone?: boolean;
    isHidden?: boolean;
    replyPreview?: ReplyPreview | null;
    hideTime?: boolean;
    interactive?: boolean;
    fontSize?: number;
    forceThemeMode?: 'light' | 'dark';
    /** Telegram-style: bubble enters from below (input area) and settles into position */
    shouldEnterFromInput?: boolean;
}

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

// Skia Blurred Image Component
const SkiaBlurredImage = ({ uri, width, height, borderRadius }: { uri: string, width: number, height: number, borderRadius: number }) => {
    const image = useImage(uri);

    if (!image) {
        return (
            <View style={{ width, height, borderRadius, overflow: 'hidden', backgroundColor: '#f0f0f0' }}>
                <ActivityIndicator style={StyleSheet.absoluteFill} color="#999" />
            </View>
        );
    }

    return (
        <Canvas style={{ width, height, borderRadius, overflow: 'hidden' }}>
            <SkiaImage
                image={image}
                fit="cover"
                x={0}
                y={0}
                width={width}
                height={height}
            >
                <Blur blur={20} />
            </SkiaImage>
            <Rect x={0} y={0} width={width} height={height} color="rgba(255, 255, 255, 0.15)" />
        </Canvas>
    );
};

const StatusIndicator = React.memo(({ status, isMe, metaColor, isConnected, size = 12, bubbleColor, onRetry }: any) => {
    if (!isMe) return null;

    // Helper to parse color and calculate relative luminance
    const getColorLuminance = (color: string): number => {
        if (!color) return 0.5; // Default to mid-gray

        let r = 0, g = 0, b = 0;

        // Parse hex color
        if (color.startsWith('#')) {
            const hex = color.slice(1);
            if (hex.length === 3) {
                r = parseInt(hex[0] + hex[0], 16);
                g = parseInt(hex[1] + hex[1], 16);
                b = parseInt(hex[2] + hex[2], 16);
            } else if (hex.length >= 6) {
                r = parseInt(hex.slice(0, 2), 16);
                g = parseInt(hex.slice(2, 4), 16);
                b = parseInt(hex.slice(4, 6), 16);
            }
        }
        // Parse rgba/rgb color
        else if (color.includes('rgb')) {
            const match = color.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
            if (match) {
                r = parseInt(match[1], 10);
                g = parseInt(match[2], 10);
                b = parseInt(match[3], 10);
            }
        }

        // Calculate relative luminance (0 = black, 1 = white)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    };

    // Dynamically compute check icon color based on bubble background
    const getCheckColor = () => {
        if (!bubbleColor) {
            return metaColor;
        }

        const luminance = getColorLuminance(bubbleColor);
        const isDarkBubble = luminance < 0.5; // Dark if luminance is less than 50%

        // For dark bubbles, use white; for light bubbles, use dark
        if (isDarkBubble) {
            return 'rgba(255,255,255,0.7)';
        } else {
            return 'rgba(0,0,0,0.5)';
        }
    };

    const iconColor = getCheckColor();

    if (status === 'read') {
        return <DoubleCheckIcon size={size} color="#34B7F1" strokeWidth={1.5} />;
    }
    if (status === 'delivered') {
        return <DoubleCheckIcon size={size} color={iconColor} strokeWidth={1.5} />;
    }
    if (status === 'sent') {
        return <CheckIcon size={size} color={iconColor} strokeWidth={1.5} />;
    }


    if (status === 'error') {
        if (onRetry) {
            return (
                <TouchableOpacity onPress={onRetry} hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
                    <AlertCircle size={size} color="#ef4444" />
                </TouchableOpacity>
            );
        }
        return <AlertCircle size={size} color="#ef4444" />;
    }

    // Pending/Sending
    return <Clock size={Math.max(10, size - 2)} color={iconColor} />;
});

const VoiceMessagePlayer = React.memo(({ item, isMe, textColor, metaColor, hideTime, colors, bubbleColor }: any) => {
    // Decrypt media
    const { mediaUri } = useEncryptedMedia(item.mediaUrl, item.mediaKey, item.fileName);
    const displayUrl = mediaUri || item.mediaUrl;

    // Selectors to avoid re-rendering on every progress update unless this track is playing
    const currentTrack = useMusicPlayerStore(s => s.currentTrack);
    // Use the potentially local URI for matching if that's what we play?
    // Actually, `setTrack` uses displayUrl as preview_url. So we match against displayUrl.
    const isThisPlaying = useMusicPlayerStore(s => s.currentTrack?.preview_url === displayUrl && s.isPlaying);
    const storeProgress = useMusicPlayerStore(s => (s.currentTrack?.preview_url === displayUrl ? s.progress : 0));
    const { setTrack, setIsPlaying } = useMusicPlayerStore();

    // Reanimated shared value for smooth animation
    const animatedProgress = useSharedValue(0);

    // Reset progress when this track is not the current track
    useEffect(() => {
        if (!currentTrack || currentTrack.preview_url !== displayUrl) {
            // Not our track, reset to 0
            animatedProgress.value = withTiming(0, { duration: 150 });
        }
    }, [currentTrack?.preview_url, displayUrl]);

    // Sync shared value with store updates smoothly
    useEffect(() => {
        if (!item.duration) return;
        const totalMs = item.duration * 1000;
        const target = storeProgress / totalMs;
        const clamped = Math.min(Math.max(target, 0), 1);

        // Animate to the new progress over 250ms (simulating linear playback betwen updates)
        // If not playing, snap to it faster.
        if (isThisPlaying) {
            animatedProgress.value = withTiming(clamped, { duration: 250, easing: Easing.linear });
        } else {
            animatedProgress.value = withTiming(clamped, { duration: 100 });
        }
    }, [storeProgress, item.duration, isThisPlaying]);

    const handlePlay = useCallback(() => {
        if (isThisPlaying) {
            setIsPlaying(false);
        } else {
            setTrack({
                title: 'Voice Message',
                artist: 'Chat',
                cover: '',
                preview_url: displayUrl!,
                links: {}
            });
            setIsPlaying(true);
        }
    }, [isThisPlaying, displayUrl, setTrack, setIsPlaying]);

    // Dynamic width calculation
    const { containerWidth, barCount } = useMemo(() => {
        const minWidth = 60; // Minimum width for very short messages (e.g. 1s)
        const maxWidth = 220; // Max width for long messages
        const duration = item.duration || 5;

        // Calculate dynamic width: 10px per second, clamped
        const contentWidth = Math.min(maxWidth, Math.max(minWidth, duration * 10));

        // Calculate number of bars: Bar width 2px + Gap 1.5px = 3.5px per unit
        const count = Math.floor(contentWidth / 3.5);

        return { containerWidth: contentWidth, barCount: count };
    }, [item.duration]);

    // Waveform Data State
    const [bars, setBars] = React.useState<number[]>([]);

    // Fetch Waveform Data
    useEffect(() => {
        if (!displayUrl) return;
        let mounted = true;
        const fetchWaveform = async () => {
            // 1. Get raw normalized data (0-1) from service
            const rawData = await AudioWaveform.getWaveform(displayUrl, item.duration || 5, barCount);

            if (mounted) {
                // 2. Map to visual height: base 3px + variable up to 18px (Total max ~21px)
                const heightMapped = rawData.map((v: number) => 3 + (v * 18));
                setBars(heightMapped);
            }
        };
        fetchWaveform();
        return () => { mounted = false; };
    }, [displayUrl, item.duration, barCount]);

    const [waveformWidth, setWaveformWidth] = React.useState(0);

    const maskStyle = useAnimatedStyle(() => ({
        width: `${animatedProgress.value * 100}%`,
    }));

    return (
        <View style={{
            flexDirection: 'row',
            alignItems: 'center',
            width: containerWidth + 60, // Add space for play button (42) + margin (12) + padding
            maxWidth: '100%',
            paddingVertical: 0,
            paddingHorizontal: 0
        }}>
            {/* Play Button */}
            <TouchableOpacity
                onPress={handlePlay}
                style={{
                    width: 42,
                    height: 42,
                    borderRadius: 21,
                    backgroundColor: isMe ? '#ffffff' : bubbleColor,
                    alignItems: 'center',
                    justifyContent: 'center',
                    marginRight: 12
                }}
            >
                {isThisPlaying ? (
                    <Pause size={20} color={isMe ? bubbleColor : colors.bubbleThemText} fill={isMe ? bubbleColor : colors.bubbleThemText} />
                ) : (
                    <Play size={20} color={isMe ? bubbleColor : colors.bubbleThemText} fill={isMe ? bubbleColor : colors.bubbleThemText} style={{ marginLeft: 3 }} />
                )}
            </TouchableOpacity>

            {/* Column: Waveform + Duration */}
            <View style={{ flex: 1, justifyContent: 'center' }}>
                {/* Waveform Visualization */}
                <View
                    style={{ height: 22, justifyContent: 'center', width: '100%' }}
                    onLayout={(e) => setWaveformWidth(e.nativeEvent.layout.width)}
                >
                    {/* Background Layer (Unplayed) */}
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 1.5, width: '100%', height: '100%' }}>
                        {bars.map((height, i) => (
                            <View
                                key={i}
                                style={{
                                    width: 2,
                                    height: height,
                                    backgroundColor: isMe ? 'rgba(255,255,255,0.35)' : 'rgba(150, 150, 150, 0.3)',
                                    borderRadius: 1
                                }}
                            />
                        ))}
                    </View>

                    {/* Foreground Layer (Played) - Smooth Animated Mask */}
                    <Animated.View style={[
                        {
                            position: 'absolute',
                            left: 0,
                            top: 0,
                            bottom: 0,
                            overflow: 'hidden',
                        },
                        maskStyle
                    ]}>
                        {/* 
                           Inner Content must be fixed width (equal to parent) to ensure bars align perfectly.
                        */}
                        <View style={{
                            flexDirection: 'row',
                            alignItems: 'center',
                            gap: 1.5,
                            width: waveformWidth, // Force pixel width matching parent
                            height: '100%'
                        }}>
                            {bars.map((height, i) => (
                                <View
                                    key={i}
                                    style={{
                                        width: 2,
                                        height: height,
                                        backgroundColor: isMe ? '#ffffff' : bubbleColor,
                                        borderRadius: 1
                                    }}
                                />
                            ))}
                        </View>
                    </Animated.View>
                </View>

                {/* Duration Text */}
                <Text style={{ fontSize: 13, color: isMe ? 'rgba(255,255,255,0.7)' : metaColor, fontWeight: '400', marginTop: 4 }}>
                    {item.duration ? `${Math.floor(item.duration / 60)}:${(item.duration % 60).toString().padStart(2, '0')}` : '0:00'}
                </Text>
            </View>
        </View>
    );
});

const { width: SCREEN_WIDTH } = Dimensions.get('window');

const MessageBubble = React.memo(({ item, isMe, isSequenceStart, isSequenceEnd, isMiddle, displayContent, onLongPress, onViewOnce, isClone = false, isHidden = false, replyPreview, hideTime = false, interactive = true, fontSize = 16, forceThemeMode, shouldEnterFromInput = false }: MessageBubbleProps) => {
    const { effectiveTheme, colors } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const { isConnected } = useNetInfo();

    // Telegram-style crossfade enter: synced with ChatInput text fading out.
    // The bubble fades in + slight rise, matching the 200ms input text exit.
    const enterProgress = useSharedValue(shouldEnterFromInput ? 0 : 1);

    useEffect(() => {
        if (shouldEnterFromInput) {
            enterProgress.value = withTiming(1, {
                duration: 200,
                easing: Easing.out(Easing.ease),
            });
        }
    }, [shouldEnterFromInput]);

    // View-once state
    const [viewOnceRevealed, setViewOnceRevealed] = useState(false);
    const viewOnceOpacity = useSharedValue(1);
    const viewOncePulse = useSharedValue(1);

    // Sparkle pulse animation for view-once
    useEffect(() => {
        if (item.viewOnce && !viewOnceRevealed) {
            viewOncePulse.value = withRepeat(
                withSequence(
                    withTiming(1.15, { duration: 1200, easing: Easing.inOut(Easing.ease) }),
                    withTiming(1, { duration: 1200, easing: Easing.inOut(Easing.ease) })
                ),
                -1,
                true
            );
        }
    }, [item.viewOnce, viewOnceRevealed]);

    const [isFullScreen, setIsFullScreen] = useState(false);

    const handleViewOnceReveal = useCallback(() => {
        if (!item.viewOnce || viewOnceRevealed) return;
        if (!isMe && item.viewedBy?.includes('self')) return; // Already viewed

        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        setIsFullScreen(true);
        setViewOnceRevealed(true);
        onViewOnce?.(item.id);
    }, [item.viewOnce, viewOnceRevealed, isMe, item.viewedBy, item.id, onViewOnce]);

    const viewOnceOverlayStyle = useAnimatedStyle(() => ({
        opacity: viewOnceOpacity.value,
    }));

    const viewOncePulseStyle = useAnimatedStyle(() => ({
        transform: [{ scale: viewOncePulse.value }],
    }));

    // Decrypt media
    const { mediaUri, loading: mediaLoading } = useEncryptedMedia(item.mediaUrl, item.mediaKey, item.fileName);
    const displayMediaUrl = mediaUri || item.mediaUrl;
    const uploadProgress = useChatStore(state => state.uploadProgress?.[item.id] || 0);
    const downloadProgress = useEncryptedMediaStore(s => (item.mediaUrl ? (s.downloadProgress?.[item.mediaUrl] || 0) : 0));

    const handleRetry = useCallback(() => {
        if (item.chatId === 'saved_messages') {
            useSavedMessagesStore.getState().retryMessage(item.id);
        }
    }, [item.id, item.chatId]);

    const [imgSize, setImgSize] = React.useState<{ width: number, height: number } | null>(null);

    // Fetch actual image size if not provided
    useEffect(() => {
        if ((item.type === 'image' || item.type === 'sticker') && mediaUri) {
            if (item.extra?.width && item.extra?.height) {
                setImgSize({ width: item.extra.width, height: item.extra.height });
            } else {
                Image.getSize(mediaUri, (w, h) => {
                    setImgSize({ width: w, height: h });
                }, () => {
                    setImgSize({ width: 4, height: 3 }); // Fallback aspect ratio
                });
            }
        }
    }, [mediaUri, item.type, item.extra?.width, item.extra?.height]);

    // Parse JSON content if present (fix for production build issue)
    const messageContent = useMemo(() => {
        if (typeof displayContent === 'string' && displayContent.trim().startsWith('{')) {
            try {
                const parsed = JSON.parse(displayContent);
                return parsed.plaintext || parsed.content || parsed.text || displayContent;
            } catch (e) {
                // Ignore
            }
        }
        return displayContent;
    }, [displayContent]);
    const { setTrack, setIsPlaying, currentTrack, isPlaying } = useMusicPlayerStore();
    const bubbleRef = React.useRef<View>(null);

    const isSystemDark = forceThemeMode ? forceThemeMode === 'dark' : effectiveTheme === 'dark';

    // Resolve the theme to the correct light/dark variant
    const resolvedTheme = useMemo(() => {
        return resolveThemeVariant(activeTheme, isSystemDark);
    }, [activeTheme, isSystemDark]);

    const scale = useSharedValue(1);

    const animatedStyle = useAnimatedStyle(() => {
        // enterProgress: 0 = at input (hidden), 1 = settled in list (visible)
        const p = enterProgress.value;
        const entryScale = 0.9 + p * 0.1;

        return {
            transform: [
                { translateY: (1 - p) * 35 },
                { scale: isHidden ? 0 : (entryScale * scale.value) },
            ],
            opacity: isHidden ? 0 : p,
        };
    });

    // Only scale on hold, NOT on click
    const handleLongPress = useCallback(() => {
        'worklet';
        // Use timing as requested
        if (!interactive) return;
        scale.value = withTiming(0.96, { duration: 150, easing: Easing.out(Easing.ease) });
        runOnJS(Haptics.impactAsync)(Haptics.ImpactFeedbackStyle.Medium);
        if (onLongPress) {
            runOnJS(onLongPress)(bubbleRef);
        }
    }, [onLongPress]);

    const handlePressOut = useCallback(() => {
        scale.value = withTiming(1, { duration: 150, easing: Easing.out(Easing.ease) });
    }, []);

    const hasText = useMemo(() => {
        if (item.type === 'voice') return false;
        const trimmed = (messageContent || '').trim();
        if (!trimmed) return false;
        if (item.type === 'text') return true;

        const placeholders = new Set(['Image', 'Location', 'GIF', 'Sticker', 'Contact']);
        if (placeholders.has(trimmed)) return false;
        if (item.fileName && trimmed === item.fileName) return false;
        return true;
    }, [item.type, messageContent, item.fileName]);

    const musicToolResult = item.toolResults?.find((t: any) => t.tool === 'search_music');
    const tracks = musicToolResult?.data?.tracks;
    const hasTracks = tracks && tracks.length > 0;
    const contactData = (item as any).contact || (item as any).extra?.contact;

    // Use the resolved theme's colors directly
    const bubbleColor = useMemo(() => {
        return isMe ? resolvedTheme.bubbleMe : resolvedTheme.bubbleThem;
    }, [isMe, resolvedTheme]);

    const textColor = useMemo(() => {
        return isMe ? resolvedTheme.textColorMe : resolvedTheme.textColorThem;
    }, [isMe, resolvedTheme]);

    const metaColor = useMemo(() => {
        // Check if text color is light (works for various white/light shades)
        const lowerText = textColor.toLowerCase();
        const isLightText = lowerText.includes('fff') ||
            lowerText.includes('fef') ||
            lowerText.includes('faf') ||
            lowerText.includes('f4f') ||
            lowerText.includes('f8f') ||
            lowerText.includes('f5f') ||
            lowerText.includes('f0f');
        return isLightText
            ? 'rgba(255,255,255,0.7)'
            : 'rgba(0,0,0,0.5)';
    }, [textColor]);

    const showTail = isSequenceEnd;
    const showImageTail = showTail && item.type === 'image' && !hasText && !!displayMediaUrl;


    const borderRadiusStyle: any = {
        borderRadius: 18,
    };

    if (isMe) {
        if (!isSequenceStart) borderRadiusStyle.borderTopRightRadius = 18;
        if (!isSequenceEnd) borderRadiusStyle.borderBottomRightRadius = 18;
    } else {
        if (!isSequenceStart) borderRadiusStyle.borderTopLeftRadius = 18;
        if (!isSequenceEnd) borderRadiusStyle.borderBottomLeftRadius = 18;
    }

    const isEmojiOnly = useMemo(() => {
        const trimmed = messageContent.trim();
        if (!trimmed) return false;
        if (ANIMATED_EMOJIS[trimmed]) return true;
        return (
            /^(\p{Emoji}|\u200d)+$/u.test(trimmed) &&
            [...trimmed].length <= 3
        );
    }, [messageContent]);

    const handleLinkPress = async (url: string) => {
        try {
            await WebBrowser.openBrowserAsync(url, {
                presentationStyle: WebBrowser.WebBrowserPresentationStyle.FULL_SCREEN,
                toolbarColor: '#000000',
                controlsColor: '#ffffff',
                showTitle: true
            });
        } catch (e) {
            Linking.openURL(url);
        }
    };

    const renderTextWithLinks = (text: string) => {
        const urlRegex = /(https?:\/\/[^\s]+)/g;
        const parts = text.split(urlRegex);

        return parts.map((part, index) => {
            if (part.match(urlRegex)) {
                return (
                    <Text
                        key={index}
                        style={{ textDecorationLine: 'underline', color: isMe ? '#ffffff' : colors.accent }}
                        onPress={() => handleLinkPress(part)}
                    >
                        {part}
                    </Text>
                );
            }
            return <Text key={index}>{part}</Text>;
        });
    };

    const animatedSource = ANIMATED_EMOJIS[messageContent.trim()];

    if (animatedSource) {
        return (
            <View style={{ maxWidth: '75%', alignSelf: isMe ? 'flex-end' : 'flex-start', alignItems: isMe ? 'flex-end' : 'flex-start', marginBottom: 10, paddingHorizontal: 12 }}>
                <AnimatedEmoji source={animatedSource} size={160} />
                {!hideTime && (
                    <View style={{ flexDirection: 'row', alignItems: 'center', alignSelf: isMe ? 'flex-end' : 'flex-start', marginTop: -35, backgroundColor: 'rgba(0,0,0,0.4)', paddingHorizontal: 8, paddingVertical: 4, borderRadius: 12, marginBottom: 5 }}>
                        <Text style={[styles.msgTime, { fontSize: 11, color: '#fff' }]}>
                            {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                        </Text>
                        {isMe && (
                            <View style={{ marginLeft: 4 }}>
                                <StatusIndicator status={item.status} isMe={isMe} metaColor="#fff" isConnected={isConnected} size={12} bubbleColor="rgba(0,0,0,0.4)" onRetry={handleRetry} />
                            </View>
                        )}
                    </View>
                )}
            </View>
        );
    }

    if (isEmojiOnly && [...messageContent.trim()].length <= 3) {
        return (
            <View style={{ maxWidth: '75%', alignSelf: isMe ? 'flex-end' : 'flex-start', marginBottom: 6, paddingHorizontal: 10 }}>
                <Text style={{ fontSize: 64, lineHeight: 72, textAlign: 'center' }}>{messageContent}</Text>
                {!hideTime && (
                    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', alignSelf: isMe ? 'flex-end' : 'flex-start', marginTop: -15, backgroundColor: 'rgba(0,0,0,0.4)', paddingHorizontal: 8, paddingVertical: 4, borderRadius: 12 }}>
                        <Text style={[styles.msgTime, { fontSize: 11, color: '#fff' }]}>
                            {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                        </Text>
                        {isMe && (
                            <View style={{ marginLeft: 4 }}>
                                <StatusIndicator status={item.status} isMe={isMe} metaColor="#fff" isConnected={isConnected} size={13} bubbleColor="rgba(0,0,0,0.4)" onRetry={handleRetry} />
                            </View>
                        )}
                    </View>
                )}
            </View>
        );
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

    const isMediaOnly = useMemo(() => {
        if (item.type === 'music') return true;
        if (item.isVideoNote) return true; // Video notes are always standalone
        return !hasText && (item.type === 'gif' || item.type === 'sticker');
    }, [item.type, hasText, item.isVideoNote]);

    const handlePlayMusic = () => {
        const isCurrent = currentTrack?.preview_url === displayMediaUrl;
        if (isCurrent) {
            setIsPlaying(!isPlaying);
        } else {
            setTrack({
                title: item.fileName || 'Audio Track',
                artist: 'Shared Audio',
                cover: 'https://via.placeholder.com/300/000000/FFFFFF/?text=Music',
                preview_url: displayMediaUrl!,
                links: {}
            });
            setIsPlaying(true);
        }
    };

    const isMusicPlaying = currentTrack?.preview_url === displayMediaUrl && isPlaying;

    const renderBubbleContent = () => {
        const isSticker = item.type === 'sticker';
        const isVisualMedia = item.type === 'image' || item.type === 'video' || isSticker;

        return (
            <View style={{ minWidth: (isVisualMedia && !hasText) ? 0 : 35 }}>
                {/* Reply Preview - shows when message is a reply */}
                {replyPreview && (
                    <View style={[
                        styles.replyPreview,
                        {
                            backgroundColor: withAlpha(textColor, 0.08),
                            borderLeftColor: isMe ? 'rgba(255,255,255,0.5)' : colors.primary
                        }
                    ]}>
                        <Text
                            style={[styles.replyPreviewName, { color: isMe ? 'rgba(255,255,255,0.9)' : colors.primary }]}
                            numberOfLines={1}
                        >
                            {replyPreview.userName}
                        </Text>
                        <Text
                            style={[styles.replyPreviewContent, { color: withAlpha(textColor, 0.7) }]}
                            numberOfLines={1}
                        >
                            {replyPreview.content}
                        </Text>
                    </View>
                )}
                {/* Image message */}
                {item.type === 'image' && displayMediaUrl && (
                    <View style={{
                        marginBottom: hasText ? 6 : 0,
                        marginTop: 0,
                        ...((hasText || item.caption) ? { borderRadius: 12, overflow: 'hidden' } : { ...borderRadiusStyle, overflow: 'hidden' })
                    }}>
                        {item.viewOnce && !isMe ? (
                            // RECEIVER VIEW
                            (viewOnceRevealed || item.viewedBy?.includes('self')) ? (
                                // OPENED STATE — compact pill, no border
                                <View style={{
                                    flexDirection: 'row',
                                    alignItems: 'center',
                                    gap: 5,
                                    paddingHorizontal: 10,
                                    paddingVertical: 8,
                                }}>
                                    <EyeOff size={14} color={colors.textSecondary} />
                                    <Text style={{ fontSize: 13, color: colors.textSecondary, fontWeight: '500' }}>Opened</Text>
                                </View>
                            ) : (
                                // BLURRED STATE - Skia full-size
                                <View style={{ borderRadius: hasText ? 12 : 0, overflow: 'hidden' }}>
                                    <SkiaBlurredImage
                                        uri={displayMediaUrl}
                                        width={(function () {
                                            const maxW = SCREEN_WIDTH * 0.72;
                                            if (!imgSize) return 255;
                                            return maxW;
                                        })()}
                                        height={(function () {
                                            const maxW = SCREEN_WIDTH * 0.72;
                                            if (!imgSize) return 190;
                                            const ratio = imgSize.height / imgSize.width;
                                            return Math.min(SCREEN_WIDTH * 0.9, maxW * ratio);
                                        })()}
                                        borderRadius={hasText ? 12 : 0}
                                    />
                                    {/* Tap to view overlay - Static Text, No Animation */}
                                    <TouchableOpacity
                                        onPress={handleViewOnceReveal}
                                        activeOpacity={0.8}
                                        style={[StyleSheet.absoluteFillObject, { justifyContent: 'center', alignItems: 'center', backgroundColor: 'rgba(0,0,0,0.1)' }]}
                                    >
                                        <View style={{ paddingHorizontal: 12, paddingVertical: 6, backgroundColor: 'rgba(0,0,0,0.4)', borderRadius: 16 }}>
                                            <Text style={{ color: '#fff', fontSize: 13, fontWeight: '600' }}>Tap to view</Text>
                                        </View>
                                    </TouchableOpacity>
                                </View>
                            )
                        ) : (
                            // SENDER or Normal image
                            (item.viewOnce && isMe && item.viewedBy && item.viewedBy.length > 0) ? (
                                // SENDER OPENED STATE — matches receiver opened state
                                <View style={{
                                    flexDirection: 'row',
                                    alignItems: 'center',
                                    gap: 5,
                                    paddingHorizontal: 10,
                                    paddingVertical: 8,
                                }}>
                                    <EyeOff size={14} color={colors.textSecondary} />
                                    <Text style={{ fontSize: 13, color: colors.textSecondary, fontWeight: '500' }}>Opened</Text>
                                </View>
                            ) : (
                                // Normal Image rendering or Unopened Sender ViewOnce
                                <Image
                                    source={{
                                        uri: mediaLoading && item.extra?.thumbnailBase64
                                            ? `data:image/jpeg;base64,${item.extra.thumbnailBase64}`
                                            : displayMediaUrl
                                    }}
                                    style={{
                                        width: (function () {
                                            const maxW = SCREEN_WIDTH * 0.72;
                                            if (!imgSize) return 255;
                                            return maxW;
                                        })(),
                                        height: (function () {
                                            const maxW = SCREEN_WIDTH * 0.72;
                                            if (!imgSize) return 190;
                                            const ratio = imgSize.height / imgSize.width;
                                            return Math.min(SCREEN_WIDTH * 0.9, maxW * ratio);
                                        })(),
                                        borderRadius: hasText || !!item.caption ? 12 : 0,
                                    }}
                                    resizeMode="cover"
                                    blurRadius={mediaLoading && item.extra?.thumbnailBase64 ? 2 : 0}
                                />
                            )
                        )}
                        {/* Download/Decrypt Overlay */}
                        {mediaLoading && !item.viewOnce && (
                            <View style={{
                                ...StyleSheet.absoluteFillObject,
                                justifyContent: 'center',
                                alignItems: 'center',
                                borderRadius: hasText ? 12 : 0,
                            }}>
                                {downloadProgress > 0 ? (
                                    <View style={{ width: 36, height: 36, justifyContent: 'center', alignItems: 'center' }}>
                                        <Svg width={36} height={36}>
                                            <Circle stroke="rgba(255,255,255,0.25)" cx={18} cy={18} r={14} strokeWidth={2.5} fill="none" />
                                            <Circle
                                                stroke="white"
                                                cx={18}
                                                cy={18}
                                                r={14}
                                                strokeWidth={2.5}
                                                strokeDasharray={`${14 * 2 * Math.PI}`}
                                                strokeDashoffset={`${14 * 2 * Math.PI * (1 - (Math.max(0.02, downloadProgress || 0)))}`}
                                                strokeLinecap="round"
                                                fill="none"
                                                rotation="-90"
                                                origin="18, 18"
                                            />
                                        </Svg>
                                    </View>
                                ) : (
                                    <ActivityIndicator color="rgba(255,255,255,0.85)" size="small" />
                                )}
                            </View>
                        )}
                        {/* Upload Progress Overlay */}
                        {isMe && (item.status === 'sending' || item.status === 'pending') && !item.viewOnce && (
                            <View style={{
                                ...StyleSheet.absoluteFillObject,
                                justifyContent: 'center',
                                alignItems: 'center',
                                borderRadius: hasText ? 12 : 0,
                            }}>
                                {uploadProgress > 0 ? (
                                    <View style={{ width: 36, height: 36, justifyContent: 'center', alignItems: 'center' }}>
                                        <Svg width={36} height={36}>
                                            <Circle stroke="rgba(255,255,255,0.25)" cx={18} cy={18} r={14} strokeWidth={2.5} fill="none" />
                                            <Circle
                                                stroke="white"
                                                cx={18}
                                                cy={18}
                                                r={14}
                                                strokeWidth={2.5}
                                                strokeDasharray={`${14 * 2 * Math.PI}`}
                                                strokeDashoffset={`${14 * 2 * Math.PI * (1 - (Math.max(0.02, uploadProgress || 0)))}`}
                                                strokeLinecap="round"
                                                fill="none"
                                                rotation="-90"
                                                origin="18, 18"
                                            />
                                        </Svg>
                                    </View>
                                ) : (
                                    <ActivityIndicator color="rgba(255,255,255,0.85)" size="small" />
                                )}
                            </View>
                        )}
                        {/* Timestamp badge — shown for all images (viewOnce sender included), except receiver viewOnce or opened sender viewOnce */}
                        {!hasText && !item.caption && !hideTime && !(item.viewOnce && (!isMe || (isMe && item.viewedBy && item.viewedBy.length > 0))) && (
                            <View style={{ position: 'absolute', bottom: 8, right: 8 }}>
                                <View style={{ backgroundColor: 'rgba(0,0,0,0.4)', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 6, paddingVertical: 2, borderRadius: 10 }}>
                                    <Text style={[styles.msgTime, { color: '#fff', fontSize: 9 }]}>
                                        {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                    </Text>
                                    {isMe && (
                                        <View style={{ marginLeft: 3 }}>
                                            <StatusIndicator status={item.status} isMe={isMe} metaColor="#fff" isConnected={isConnected} size={11} bubbleColor="rgba(0,0,0,0.5)" onRetry={handleRetry} />
                                        </View>
                                    )}
                                </View>
                            </View>
                        )}
                        {/* Caption below image */}
                        {item.caption && (
                            <View style={{ paddingHorizontal: 10, paddingTop: 6, paddingBottom: 4 }}>
                                <Text style={{ color: textColor, fontSize: 14, lineHeight: 19 }}>{item.caption}</Text>
                                {!hideTime && (
                                    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'flex-end', marginTop: 2 }}>
                                        <Text style={[styles.msgTime, { color: metaColor, fontSize: 10 }]}>
                                            {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                        </Text>
                                        {isMe && (
                                            <View style={{ marginLeft: 3 }}>
                                                <StatusIndicator status={item.status} isMe={isMe} metaColor={metaColor} isConnected={isConnected} size={11} bubbleColor={bubbleColor} onRetry={handleRetry} />
                                            </View>
                                        )}
                                    </View>
                                )}
                            </View>
                        )}
                    </View>
                )}

                {/* Video message (non-video-note) */}
                {item.type === 'video' && !item.isVideoNote && displayMediaUrl && (
                    <View style={{
                        marginBottom: hasText ? 6 : 0,
                        marginTop: 0,
                        ...(hasText ? { borderRadius: 12 } : { ...borderRadiusStyle, overflow: 'hidden' })
                    }}>
                        <ExpoVideo
                            source={{ uri: displayMediaUrl }}
                            style={{
                                width: SCREEN_WIDTH * 0.72,
                                height: SCREEN_WIDTH * 0.72 * 0.5625, // 16:9 aspect ratio
                                borderRadius: hasText ? 12 : 0,
                            }}
                            resizeMode={ResizeMode.COVER}
                            useNativeControls
                            isLooping={false}
                        />
                        {/* View-once overlay for video */}
                        {item.viewOnce && (
                            <Animated.View style={[
                                StyleSheet.absoluteFillObject,
                                { justifyContent: 'center', alignItems: 'center', borderRadius: hasText ? 12 : 0 },
                                viewOnceOverlayStyle
                            ]}>
                                <TouchableOpacity
                                    onPress={handleViewOnceReveal}
                                    activeOpacity={0.7}
                                    style={StyleSheet.absoluteFillObject}
                                >
                                    <LinearGradient
                                        colors={isMe ? ['rgba(99,102,241,0.85)', 'rgba(139,92,246,0.9)'] : ['rgba(0,0,0,0.7)', 'rgba(30,30,50,0.85)']}
                                        start={{ x: 0, y: 0 }}
                                        end={{ x: 1, y: 1 }}
                                        style={[StyleSheet.absoluteFillObject, { justifyContent: 'center', alignItems: 'center', borderRadius: hasText ? 12 : 0 }]}
                                    >
                                        <Animated.View style={viewOncePulseStyle}>
                                            <View style={{ width: 56, height: 56, borderRadius: 28, backgroundColor: 'rgba(255,255,255,0.15)', alignItems: 'center', justifyContent: 'center', borderWidth: 1.5, borderColor: 'rgba(255,255,255,0.3)' }}>
                                                <VideoIcon size={24} color="#fff" />
                                            </View>
                                        </Animated.View>
                                    </LinearGradient>
                                </TouchableOpacity>
                            </Animated.View>
                        )}
                        {!hasText && !hideTime && !item.viewOnce && (
                            <View style={{ position: 'absolute', bottom: 8, right: 8 }}>
                                <View style={{ backgroundColor: 'rgba(0,0,0,0.4)', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 6, paddingVertical: 2, borderRadius: 10 }}>
                                    <Text style={[styles.msgTime, { color: '#fff', fontSize: 9 }]}>
                                        {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                    </Text>
                                    {isMe && (
                                        <View style={{ marginLeft: 3 }}>
                                            <StatusIndicator status={item.status} isMe={isMe} metaColor="#fff" isConnected={isConnected} size={11} bubbleColor="rgba(0,0,0,0.5)" onRetry={handleRetry} />
                                        </View>
                                    )}
                                </View>
                            </View>
                        )}
                    </View>
                )}

                {isSticker && displayMediaUrl && (
                    <View style={{
                        marginBottom: 0,
                        marginTop: 0,
                        ...borderRadiusStyle,
                        overflow: 'visible'
                    }}>
                        <Image
                            source={{ uri: displayMediaUrl }}
                            style={{
                                width: (function () {
                                    const maxW = SCREEN_WIDTH * 0.5;
                                    if (!imgSize) return 180;
                                    return Math.min(maxW, 220);
                                })(),
                                height: (function () {
                                    const maxW = Math.min(SCREEN_WIDTH * 0.5, 220);
                                    if (!imgSize) return 180;
                                    const ratio = imgSize.height / imgSize.width;
                                    return Math.min(240, maxW * ratio);
                                })(),
                            }}
                            resizeMode="contain"
                        />
                        {!hideTime && (
                            <View style={{ position: 'absolute', bottom: 8, right: 8 }}>
                                <View style={{ backgroundColor: 'rgba(0,0,0,0.4)', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 6, paddingVertical: 2, borderRadius: 10 }}>
                                    <Text style={[styles.msgTime, { color: '#fff', fontSize: 9 }]}>
                                        {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                    </Text>
                                    {isMe && (
                                        <View style={{ marginLeft: 3 }}>
                                            <StatusIndicator status={item.status} isMe={isMe} metaColor="#fff" isConnected={isConnected} size={11} bubbleColor="rgba(0,0,0,0.5)" onRetry={handleRetry} />
                                        </View>
                                    )}
                                </View>
                            </View>
                        )}
                    </View>
                )}

                {item.type === 'location' && (
                    <TouchableOpacity
                        onPress={() => Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${item.latitude},${item.longitude}`)}
                        style={{ flexDirection: 'row', alignItems: 'center', backgroundColor: withAlpha(textColor, 0.1), padding: 8, borderRadius: 12, marginBottom: hasText ? 6 : 2, marginTop: 2 }}
                    >
                        <View style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: colors.accent, alignItems: 'center', justifyContent: 'center', marginRight: 10 }}>
                            <MapPin size={20} color="#fff" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={{ color: textColor, fontWeight: '600', fontSize: 13 }}>Location</Text>
                            <Text style={{ color: metaColor, fontSize: 11 }}>{item.latitude?.toFixed(4)}, {item.longitude?.toFixed(4)}</Text>
                        </View>
                    </TouchableOpacity>
                )}

                {item.type === 'contact' && (
                    <View style={{ flexDirection: 'row', alignItems: 'center', backgroundColor: withAlpha(textColor, 0.1), padding: 8, borderRadius: 12, marginBottom: hasText ? 6 : 2, marginTop: 2 }}>
                        <View style={{ width: 42, height: 42, borderRadius: 21, backgroundColor: colors.accent, alignItems: 'center', justifyContent: 'center', marginRight: 10, overflow: 'hidden' }}>
                            {contactData?.profileImage ? (
                                <Image source={{ uri: contactData.profileImage }} style={{ width: '100%', height: '100%' }} />
                            ) : (
                                <Text style={{ color: '#fff', fontWeight: '700' }}>
                                    {(contactData?.username || contactData?.name || contactData?.id || '?').substring(0, 1).toUpperCase()}
                                </Text>
                            )}
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={{ color: textColor, fontWeight: '600', fontSize: 13 }} numberOfLines={1}>
                                {contactData?.username || contactData?.name || contactData?.id || 'Contact'}
                            </Text>
                            <Text style={{ color: metaColor, fontSize: 11 }} numberOfLines={1}>
                                {contactData?.phoneNumber || contactData?.id || 'Contact card'}
                            </Text>
                        </View>
                    </View>
                )}

                {item.type === 'file' && (
                    <View style={{ flexDirection: 'row', alignItems: 'center', backgroundColor: withAlpha(textColor, 0.1), padding: 8, borderRadius: 12, marginBottom: hasText ? 6 : 2, marginTop: 2 }}>
                        <View style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: colors.accent, alignItems: 'center', justifyContent: 'center', marginRight: 10 }}>
                            <FileText size={20} color="#fff" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={{ color: textColor, fontWeight: '600', fontSize: 13 }} numberOfLines={1}>{item.fileName || 'File'}</Text>
                            <Text style={{ color: metaColor, fontSize: 11 }}>{item.fileSize ? (item.fileSize / 1024).toFixed(1) + ' KB' : 'Document'}</Text>
                        </View>
                    </View>
                )}

                {item.type === 'voice' && (
                    <View>
                        <VoiceMessagePlayer
                            item={item}
                            isMe={isMe}
                            textColor={textColor}
                            metaColor={metaColor}
                            hideTime={hideTime}
                            colors={colors}
                            bubbleColor={bubbleColor}
                        />
                        {/* Timestamp at bottom right of bubble */}
                        {!hideTime && (
                            <View style={{ flexDirection: 'row', justifyContent: 'flex-end', alignItems: 'center', marginTop: 2 }}>
                                <Text style={{ color: isMe ? 'rgba(255,255,255,0.7)' : metaColor, fontSize: 11 }}>
                                    {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                </Text>
                                {isMe && (
                                    <View style={{ marginLeft: 4 }}>
                                        <StatusIndicator status={item.status} isMe={isMe} metaColor={metaColor} isConnected={isConnected} size={12} bubbleColor={bubbleColor} onRetry={handleRetry} />
                                    </View>
                                )}
                            </View>
                        )}
                    </View>
                )}

                {/* Legacy Music Type (for files) */}
                {item.type === 'music' && (
                    <View style={{
                        flexDirection: 'row',
                        alignItems: 'center',
                        padding: 10,
                        backgroundColor: withAlpha(textColor, 0.08),
                        borderRadius: 14,
                        minWidth: 240,
                        maxWidth: 280,
                        marginTop: 2,
                        marginBottom: hasText ? 6 : 2
                    }}>
                        {/* Artwork Container */}
                        <View style={{ width: 48, height: 48, borderRadius: 12, marginRight: 12, position: 'relative', overflow: 'hidden', backgroundColor: isMe ? 'rgba(255,255,255,0.2)' : colors.primary }}>
                            <View style={{ ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center' }}>
                                {item.status === 'sending' || item.status === 'pending' ? (
                                    <ActivityIndicator size="small" color={isMe ? '#fff' : '#fff'} />
                                ) : (
                                    <View style={{ width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.2)' }}>
                                        {isMusicPlaying ? (
                                            <Pause size={16} color="white" fill="white" />
                                        ) : (
                                            <Play size={16} color="white" fill="white" style={{ marginLeft: 2 }} />
                                        )}
                                    </View>
                                )}
                            </View>
                            {item.status !== 'sending' && item.status !== 'pending' && (
                                <Pressable
                                    onPress={handlePlayMusic}
                                    style={({ pressed }) => [StyleSheet.absoluteFill, { backgroundColor: pressed ? 'rgba(0,0,0,0.1)' : 'transparent' }]}
                                />
                            )}
                        </View>

                        <View style={{ flex: 1, justifyContent: 'center', paddingRight: 4 }}>
                            <Text style={{ color: textColor, fontWeight: '600', fontSize: 14, marginBottom: 2 }} numberOfLines={1}>
                                {item.fileName || 'Audio File'}
                            </Text>
                            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                <Disc size={12} color={metaColor} style={{ marginRight: 4 }} />
                                <Text style={{ color: metaColor, fontSize: 12, fontWeight: '400' }} numberOfLines={1}>
                                    {item.fileSize ? `${(item.fileSize / 1024 / 1024).toFixed(1)} MB` : 'Audio'}
                                </Text>
                            </View>
                        </View>

                        {/* Time & Status */}
                        {!hideTime && (
                            <View style={{ alignItems: 'flex-end', justifyContent: 'flex-end', marginLeft: 4 }}>
                                <Text style={{ color: metaColor, fontSize: 10, marginBottom: 4 }}>
                                    {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                </Text>
                                {isMe && (
                                    <View>
                                        <StatusIndicator status={item.status} isMe={isMe} metaColor={metaColor} isConnected={isConnected} size={12} bubbleColor={bubbleColor} onRetry={handleRetry} />
                                    </View>
                                )}
                            </View>
                        )}
                    </View>
                )}

                {hasTracks && (
                    <View style={{ marginBottom: 4, marginTop: 4 }}>
                        <MusicBubble tracks={tracks} />
                    </View>
                )}

                {item.type === 'call' && (
                    <View style={{
                        flexDirection: 'row',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        paddingVertical: 4,
                        paddingHorizontal: 2,
                        minWidth: 180,
                    }}>
                        <View style={{ flex: 1 }}>
                            <Text style={{
                                color: textColor,
                                fontSize: 22,
                                fontWeight: '700',
                                marginBottom: 4,
                                letterSpacing: -0.5
                            }}>
                                {item.extra?.callStatus === 'missed' ? 'Missed Call' :
                                    item.extra?.callStatus === 'declined' ? 'Declined' :
                                        item.extra?.callStatus === 'canceled' ? 'Canceled Call' :
                                            item.extra?.callType === 'video' ? 'Video Call' : 'Voice Call'}
                            </Text>
                            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
                                {item.extra?.callStatus === 'missed' ? (
                                    <PhoneMissed size={14} color="#FF3B30" />
                                ) : item.extra?.callStatus === 'canceled' ? (
                                    <PhoneOutgoing size={14} color="#FF3B30" />
                                ) : isMe ? (
                                    <PhoneOutgoing size={14} color={metaColor} />
                                ) : (
                                    <PhoneIncoming size={14} color={metaColor} />
                                )}
                                <Text style={{ color: metaColor, fontSize: 13, fontWeight: '500' }}>
                                    {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                    {item.extra?.duration > 0 && ` · ${Math.floor(item.extra.duration / 60)}:${(item.extra.duration % 60).toString().padStart(2, '0')}`}
                                </Text>
                            </View>
                        </View>
                        <View style={{
                            width: 36,
                            height: 36,
                            borderRadius: 18,
                            backgroundColor: 'transparent',
                            alignItems: 'center',
                            justifyContent: 'center',
                            marginLeft: 12
                        }}>
                            <Phone size={24} color={textColor} />
                        </View>
                    </View>
                )}

                {hasText && (
                    <View>
                        <Text
                            selectable={true}
                            style={[styles.msgText, { color: textColor, fontSize: fontSize, flexShrink: 1 }]}
                        >
                            {renderTextWithLinks(messageContent)}
                        </Text>
                        {!hideTime && (
                            <View style={{ flexDirection: 'row', justifyContent: 'flex-end', alignItems: 'center', marginTop: 2, marginRight: 0, opacity: 0.8 }}>
                                <Text style={[styles.msgTime, { color: metaColor, fontSize: 11 }]}>
                                    {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                                </Text>
                                {isMe && (
                                    <View style={{ marginLeft: 4 }}>
                                        <StatusIndicator status={item.status} isMe={isMe} metaColor={metaColor} isConnected={isConnected} size={12} bubbleColor={bubbleColor} onRetry={handleRetry} />
                                    </View>
                                )}
                            </View>
                        )}
                    </View>
                )}
            </View>
        );
    };

    const gradientColors = useMemo(() => {
        if (resolvedTheme.bubbleMeGradient) {
            return resolvedTheme.bubbleMeGradient as [string, string];
        }
        // Fallback: create subtle gradient from bubble color
        return [bubbleColor, bubbleColor] as [string, string];
    }, [resolvedTheme.bubbleMeGradient, bubbleColor]);

    const handlePress = () => {
        if (item.type === 'music' || item.type === 'voice') {
            handlePlayMusic();
        } else if (item.type === 'image' && item.viewOnce) {
            if (isMe) {
                setIsFullScreen(true);
            } else {
                handleViewOnceReveal();
            }
        }
    };

    // === CIRCULAR VIDEO NOTE (Telegram-style) ===
    if (item.isVideoNote && item.type === 'video') {
        const VIDEO_NOTE_SIZE = 200;

        return (
            <AnimatedPressable
                ref={bubbleRef}
                onLongPress={handleLongPress}
                onPressOut={handlePressOut}
                delayLongPress={200}
                style={[{
                    maxWidth: isClone ? '100%' : '85%',
                    alignSelf: isMe ? 'flex-end' : 'flex-start',
                    marginTop: isClone ? 0 : 1,
                    marginBottom: isClone ? 0 : 1,
                    marginHorizontal: isClone ? 0 : 8,
                }, animatedStyle]}
            >
                <View style={{ alignItems: isMe ? 'flex-end' : 'flex-start' }}>
                    {/* Gradient ring around the circle */}
                    <LinearGradient
                        colors={isMe ? (gradientColors as any) : [colors.elevated, colors.elevated]}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 1 }}
                        style={{
                            width: VIDEO_NOTE_SIZE + 6,
                            height: VIDEO_NOTE_SIZE + 6,
                            borderRadius: (VIDEO_NOTE_SIZE + 6) / 2,
                            padding: 3,
                        }}
                    >
                        <View style={{
                            width: VIDEO_NOTE_SIZE,
                            height: VIDEO_NOTE_SIZE,
                            borderRadius: VIDEO_NOTE_SIZE / 2,
                            overflow: 'hidden',
                            backgroundColor: '#000',
                        }}>
                            {displayMediaUrl ? (
                                <ExpoVideo
                                    source={{ uri: displayMediaUrl }}
                                    style={{
                                        width: VIDEO_NOTE_SIZE,
                                        height: VIDEO_NOTE_SIZE,
                                    }}
                                    resizeMode={ResizeMode.COVER}
                                    shouldPlay={false}
                                    isLooping={false}
                                    isMuted
                                />
                            ) : (
                                <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}>
                                    <ActivityIndicator color="#fff" />
                                </View>
                            )}

                            {/* Play button overlay */}
                            <View style={{
                                ...StyleSheet.absoluteFillObject,
                                justifyContent: 'center',
                                alignItems: 'center',
                            }}>
                                <View style={{
                                    width: 44,
                                    height: 44,
                                    borderRadius: 22,
                                    backgroundColor: 'rgba(0,0,0,0.45)',
                                    justifyContent: 'center',
                                    alignItems: 'center',
                                }}>
                                    <Play size={22} color="#fff" fill="#fff" />
                                </View>
                            </View>

                            {/* Duration badge */}
                            {item.duration && (
                                <View style={{
                                    position: 'absolute',
                                    bottom: 8,
                                    left: 0,
                                    right: 0,
                                    alignItems: 'center',
                                }}>
                                    <View style={{
                                        backgroundColor: 'rgba(0,0,0,0.5)',
                                        paddingHorizontal: 8,
                                        paddingVertical: 2,
                                        borderRadius: 10,
                                    }}>
                                        <Text style={{ color: '#fff', fontSize: 11, fontWeight: '600' }}>
                                            {Math.floor(item.duration / 60)}:{String(Math.floor(item.duration % 60)).padStart(2, '0')}
                                        </Text>
                                    </View>
                                </View>
                            )}
                        </View>
                    </LinearGradient>

                    {/* Timestamp below the circle */}
                    {!hideTime && (
                        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: isMe ? 'flex-end' : 'flex-start', marginTop: 4, paddingHorizontal: 4 }}>
                            <Text style={{ fontSize: 10, color: colors.textSecondary, opacity: 0.7 }}>
                                {new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}
                            </Text>
                            {isMe && (
                                <View style={{ marginLeft: 3 }}>
                                    <StatusIndicator status={item.status} isMe={isMe} metaColor={colors.textSecondary} isConnected={isConnected} size={11} bubbleColor="transparent" onRetry={handleRetry} />
                                </View>
                            )}
                        </View>
                    )}
                </View>
            </AnimatedPressable>
        );
    }

    return (
        <>
            <AnimatedPressable
                ref={bubbleRef}
                onPress={handlePress}
                onLongPress={handleLongPress}
                onPressOut={handlePressOut}
                delayLongPress={200}
                // If it's a clone, we don't want margins or layout shifts, just the bubble content size
                style={[{
                    maxWidth: isClone ? '100%' : '85%',
                    alignSelf: isMe ? 'flex-end' : 'flex-start',
                    marginTop: isClone ? 0 : 1,
                    marginBottom: isClone ? 0 : 1,
                    marginHorizontal: isClone ? 0 : 8,
                }, animatedStyle]}
            >
                <View style={styles.messageContainer}>
                    {isMe ? (
                        <LinearGradient
                            colors={gradientColors}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 1 }}
                            style={[
                                styles.bubble,
                                item.type === 'call' ? { borderRadius: 24 } : borderRadiusStyle,
                                {
                                    padding: (item.type === 'image' || item.type === 'sticker') && !hasText ? 0 : 7,
                                    paddingHorizontal: (item.type === 'image' || item.type === 'sticker' || item.type === 'call') && !hasText ? (item.type === 'call' ? 16 : 0) : 10,
                                    minWidth: (item.type === 'image' || item.type === 'sticker') && !hasText ? 0 : 35,
                                },
                                isMediaOnly && { backgroundColor: 'transparent', padding: 0, overflow: 'visible', borderWidth: 0 }
                            ]}
                        >
                            {renderBubbleContent()}
                        </LinearGradient>
                    ) : (
                        <View
                            style={[
                                styles.bubble,
                                item.type === 'call' ? { borderRadius: 24 } : borderRadiusStyle,
                                {
                                    backgroundColor: hasTracks
                                        ? 'transparent'
                                        : bubbleColor,
                                    padding: (item.type === 'image' || item.type === 'sticker') && !hasText ? 0 : 7,
                                    paddingHorizontal: (item.type === 'image' || item.type === 'sticker' || item.type === 'call') && !hasText ? (item.type === 'call' ? 16 : 0) : 10,
                                    minWidth: (item.type === 'image' || item.type === 'sticker') && !hasText ? 0 : 35,
                                },
                                isMediaOnly && { padding: 0, overflow: 'visible', backgroundColor: 'transparent', borderWidth: 0 }
                            ]}
                        >
                            {renderBubbleContent()}
                        </View>
                    )}


                    {showTail && (
                        <View style={{
                            position: 'absolute',
                            bottom: 0,
                            [isMe ? 'right' : 'left']: -28,
                            width: 29,
                            height: 29,
                            zIndex: -1,
                            transform: [
                                { rotate: isMe ? '25deg' : '-25deg' },
                                { scaleX: isMe ? 1 : -1 }
                            ]
                        }}>
                            {showImageTail ? (
                                <MaskedViewAny
                                    style={{ width: 29, height: 29 }}
                                    maskElement={
                                        <Svg width={29} height={29} viewBox="0 0 29 29">
                                            <Path d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z" fill="black" />
                                        </Svg>
                                    }
                                >
                                    <Image source={{ uri: displayMediaUrl! }} style={{ width: 29, height: 29 }} resizeMode="cover" />
                                </MaskedViewAny>
                            ) : (
                                <Svg width={29} height={29} viewBox="0 0 29 29">
                                    <Path
                                        d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z"
                                        fill={isMe ? gradientColors[1] : bubbleColor}
                                    />
                                </Svg>
                            )}
                        </View>
                    )}
                    {/* Reaction Badge */}
                    {item.extra?.reactions && item.extra.reactions.length > 0 && (
                        <Animated.View
                            entering={ZoomIn.duration(200)}
                            style={{
                                position: 'absolute',
                                bottom: -12,
                                right: isMe ? 12 : undefined,
                                left: !isMe ? 12 : undefined,
                                backgroundColor: '#ffffff',
                                paddingHorizontal: 8,
                                paddingVertical: 4,
                                borderRadius: 20,
                                borderWidth: 1.5,
                                borderColor: '#FF3B30',
                                shadowColor: '#000',
                                shadowOffset: { width: 0, height: 2 },
                                shadowOpacity: 0.15,
                                shadowRadius: 3,
                                elevation: 3,
                                flexDirection: 'row',
                                alignItems: 'center',
                                zIndex: 10,
                            }}
                        >
                            {item.extra.reactions.map((r: string, idx: number) => (
                                <Text key={idx} style={{ fontSize: 13, fontWeight: '600', color: '#000' }}>
                                    {r === 'HAHA' ? '😂' : r === '!!' ? '‼️' : r === '?' ? '❓' : r}
                                </Text>
                            ))}
                        </Animated.View>
                    )}
                </View>
            </AnimatedPressable>

            {/* Full Screen View Once Modal */}
            <Modal
                visible={isFullScreen}
                transparent={false}
                animationType="fade"
                onRequestClose={() => setIsFullScreen(false)}
            >
                <View style={{ flex: 1, backgroundColor: 'black' }}>
                    <SafeAreaView style={{ flex: 1 }}>
                        <TouchableOpacity
                            style={{ position: 'absolute', top: 50, right: 20, zIndex: 10, padding: 10, backgroundColor: 'rgba(0,0,0,0.5)', borderRadius: 20 }}
                            onPress={() => setIsFullScreen(false)}
                        >
                            <Text style={{ color: 'white', fontWeight: 'bold' }}>Close</Text>
                        </TouchableOpacity>
                        <Image
                            source={{ uri: displayMediaUrl }}
                            style={{ flex: 1, width: '100%', height: '100%' }}
                            resizeMode="contain"
                        />
                    </SafeAreaView>
                </View>
            </Modal>
        </>
    );
});

const styles = StyleSheet.create({
    messageContainer: {
        position: 'relative',
        overflow: 'visible',
    },
    bubble: {
        minWidth: 35,
    },
    msgText: {
        fontSize: 16,
        lineHeight: 20,
    },
    msgTime: {
        fontSize: 10,
        opacity: 0.7,
    },
    // Reply preview styles
    replyPreview: {
        borderLeftWidth: 3,
        borderRadius: 4,
        paddingLeft: 8,
        paddingRight: 8,
        paddingVertical: 6,
        marginBottom: 6,
    },
    replyPreviewName: {
        fontSize: 13,
        fontWeight: '600',
        marginBottom: 2,
    },
    replyPreviewContent: {
        fontSize: 13,
    },
});

export default MessageBubble;
