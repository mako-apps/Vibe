import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Dimensions, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { EyeOff } from 'lucide-react-native';
import Svg, { Circle, Path } from 'react-native-svg';
import * as FileSystem from 'expo-file-system';
import MaskedView from '@react-native-masked-view/masked-view';

import { BubbleMeta, BubbleStatusIcon } from './BubbleMeta';
import type { ChatListBubbleMessage } from './types';
import { useChatStore } from '../../../lib/ChatStore';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';
import { useEncryptedMediaStore } from '../../../lib/stores/encrypted-media-store';

const SCREEN_WIDTH = Dimensions.get('window').width;
const MAX_WIDTH = SCREEN_WIDTH * 0.72;
const MAX_HEIGHT = SCREEN_WIDTH * 0.9;
const DEFAULT_WIDTH = 255;
const DEFAULT_HEIGHT = 190;

// Hook to transparently handle encrypted media
const useEncryptedMedia = (url?: string, key?: string, fileName?: string) => {
    const [mediaUri, setMediaUri] = useState<string | undefined>(url);
    const [loading, setLoading] = useState(false);
    const getDecryptedFile = useEncryptedMediaStore(s => s.getDecryptedFile);

    useEffect(() => {
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

            // Check cache first
            try {
                const cached = useEncryptedMediaStore.getState().cache[url];
                if (cached) {
                    const info = await FileSystem.getInfoAsync(cached);
                    if (info.exists) {
                        if (mounted) setMediaUri(cached);
                        return;
                    }
                }
            } catch { }

            // Not cached - need to download & decrypt
            if (mounted) setLoading(true);
            try {
                const localUri = await getDecryptedFile(url, key, fileName);
                if (mounted && localUri) setMediaUri(localUri);
            } catch (err) {
                console.warn('[ImageBubbleBody] Decrypt failed:', err);
            } finally {
                if (mounted) setLoading(false);
            }
        };

        run();
        return () => { mounted = false; };
    }, [url, key, fileName]);

    return { mediaUri, loading };
};

const ImageBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;
    const [viewOnceRevealed, setViewOnceRevealed] = useState(false);

    // Decrypt media if needed
    const { mediaUri, loading: mediaLoading } = useEncryptedMedia(item.mediaUrl, (item as any).mediaKey, item.fileName);
    const displayMediaUrl = mediaUri || item.mediaUrl;

    const uploadProgress = useChatStore(state => state.uploadProgress?.[item.id] || 0);
    const downloadProgress = useEncryptedMediaStore(s => (item.mediaUrl ? (s.downloadProgress?.[item.mediaUrl] || 0) : 0));

    const size = useMemo(() => {
        const w = item.extra?.width || 0;
        const h = item.extra?.height || 0;
        if (!w || !h) {
            return { width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT };
        }

        const ratio = h / w;
        return {
            width: MAX_WIDTH,
            height: Math.min(MAX_HEIGHT, MAX_WIDTH * ratio),
        };
    }, [item.extra?.width, item.extra?.height]);

    const caption = item.caption || ((item.type === 'gif' && item.text !== 'GIF') ? item.text : '');
    const viewedBy = Array.isArray(item.viewedBy) ? item.viewedBy : [];
    const senderOpened = !!item.viewOnce && item.isMe && viewedBy.length > 0;
    const receiverOpened = !!item.viewOnce && !item.isMe && (viewOnceRevealed || viewedBy.includes('self'));
    const isViewOnceOpened = senderOpened || receiverOpened;

    const onRevealViewOnce = useCallback(() => {
        if (!item.viewOnce || item.isMe) return;
        setViewOnceRevealed(true);
        if (item.chatId) {
            useChatStore.getState().markViewOnceViewed(item.chatId, item.id);
        }
    }, [item.chatId, item.id, item.isMe, item.viewOnce]);

    const showBadge = !caption && !(item.viewOnce && (!item.isMe || senderOpened));
    const mediaRadius = caption ? 12 : 18;

    // Show tail if no caption (standalone image) and media available
    const showTail = !caption && !!displayMediaUrl && !item.viewOnce;

    return (
        <View style={styles.wrap}>
            <View style={[styles.mediaWrap, caption ? styles.mediaCaptionWrap : null]}>
                {item.viewOnce && isViewOnceOpened ? (
                    <View style={styles.openedPill}>
                        <EyeOff size={14} color={textColor} strokeWidth={2.4} opacity={0.7} />
                        <Text style={[styles.openedText, { color: textColor }]}>Opened</Text>
                    </View>
                ) : item.viewOnce && !item.isMe ? (
                    <Pressable
                        onPress={onRevealViewOnce}
                        style={[styles.frame, { width: size.width, height: size.height, borderRadius: mediaRadius }]}
                    >
                        {displayMediaUrl ? (
                            <Image
                                source={{ uri: displayMediaUrl }}
                                style={[styles.image, { borderRadius: mediaRadius }]}
                                resizeMode="cover"
                                blurRadius={18}
                            />
                        ) : (
                            <View style={[styles.placeholder, { borderRadius: mediaRadius }]}>
                                <Text style={styles.placeholderText}>Image unavailable</Text>
                            </View>
                        )}
                        <View style={styles.tapOverlay}>
                            <View style={styles.tapPill}>
                                <Text style={styles.tapPillText}>Tap to view</Text>
                            </View>
                        </View>
                    </Pressable>
                ) : displayMediaUrl ? (
                    <View style={[styles.frame, { width: size.width, height: size.height, borderRadius: mediaRadius }]}>
                        <Image
                            source={{
                                uri: mediaLoading && item.extra?.thumbnailBase64
                                    ? `data:image/jpeg;base64,${item.extra.thumbnailBase64}`
                                    : displayMediaUrl
                            }}
                            style={[styles.image, { borderRadius: mediaRadius }]}
                            resizeMode="cover"
                            blurRadius={mediaLoading && item.extra?.thumbnailBase64 ? 3 : 0}
                        />

                        {/* Download/Decrypt Overlay */}
                        {mediaLoading && !item.viewOnce && (
                            <View style={[StyleSheet.absoluteFill, styles.centered, { borderRadius: mediaRadius }]}>
                                {downloadProgress > 0 ? (
                                    <View style={styles.progressCircle}>
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
                        {item.isMe && (item.status === 'sending' || item.status === 'pending') && !item.viewOnce && (
                            <View style={[StyleSheet.absoluteFill, styles.centered, { borderRadius: mediaRadius }]}>
                                {uploadProgress > 0 ? (
                                    <View style={styles.progressCircle}>
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
                    </View>
                ) : (
                    <View style={[styles.frame, styles.placeholder, { width: size.width, height: size.height, borderRadius: mediaRadius, backgroundColor: effectiveTheme === 'dark' ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.03)' }]}>
                        <Text style={[styles.placeholderText, { color: textColor, opacity: 0.6 }]}>Image unavailable</Text>
                    </View>
                )}

                {showBadge && (
                    <View style={styles.overlayBadgeWrap}>
                        <View style={styles.overlayBadge}>
                            <Text style={styles.overlayTime}>{item.timestamp}</Text>
                            {item.isMe && <BubbleStatusIcon status={item.status} isMe color="#FFF" />}
                        </View>
                    </View>
                )}
            </View>

            {/* Telegram-style image tail - masked extension of the image */}
            {showTail && (
                <View style={{
                    position: 'absolute',
                    bottom: 0,
                    [item.isMe ? 'right' : 'left']: -28, // Adjusted offset to align with border radius
                    width: 29,
                    height: 29,
                    zIndex: -1,
                    transform: [
                        { rotate: item.isMe ? '25deg' : '-25deg' },
                        { scaleX: item.isMe ? 1 : -1 }
                    ]
                }}>
                    <MaskedView
                        style={{ width: 29, height: 29 }}
                        maskElement={
                            <Svg width={29} height={29} viewBox="0 0 29 29">
                                <Path d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z" fill="black" />
                            </Svg>
                        }
                    >
                        <Image source={{ uri: displayMediaUrl! }} style={{ width: 29, height: 29 }} resizeMode="cover" />
                    </MaskedView>
                </View>
            )}

            {!!caption && (
                <View style={styles.captionWrap}>
                    <Text style={[styles.caption, { color: textColor }]}>{caption}</Text>
                    <View style={styles.metaRow}>
                        <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isPinned={item.isPinned} />
                    </View>
                </View>
            )}
        </View>
    );
});

const styles = StyleSheet.create({
    wrap: {
        minWidth: 0,
        alignSelf: 'flex-start',
    },
    mediaWrap: {
        marginTop: 0,
        marginBottom: 0,
        overflow: 'hidden',
    },
    mediaCaptionWrap: {
        borderRadius: 12,
    },
    frame: {
        overflow: 'hidden',
    },
    image: {
        width: '100%',
        height: '100%',
    },
    placeholder: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    placeholderText: {
        fontSize: 12,
        fontWeight: '600',
    },
    openedPill: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 5,
        paddingHorizontal: 10,
        paddingVertical: 8,
    },
    openedText: {
        fontSize: 13,
        fontWeight: '500',
    },
    tapOverlay: {
        ...StyleSheet.absoluteFillObject,
        justifyContent: 'center',
        alignItems: 'center',
        backgroundColor: 'rgba(0,0,0,0.1)',
    },
    tapPill: {
        paddingHorizontal: 12,
        paddingVertical: 6,
        backgroundColor: 'rgba(0,0,0,0.4)',
        borderRadius: 16,
    },
    tapPillText: {
        color: '#FFFFFF',
        fontSize: 13,
        fontWeight: '600',
    },
    overlayBadgeWrap: {
        position: 'absolute',
        right: 8,
        bottom: 8,
    },
    overlayBadge: {
        backgroundColor: 'rgba(0,0,0,0.3)',
        borderRadius: 10,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 6,
        paddingVertical: 2,
        gap: 3,
    },
    overlayTime: {
        color: '#FFFFFF',
        fontSize: 9,
    },
    captionWrap: {
        paddingHorizontal: 10,
        paddingTop: 6,
        paddingBottom: 4,
    },
    caption: {
        fontSize: 14,
        lineHeight: 19,
    },
    metaRow: {
        marginTop: 2,
        alignItems: 'flex-end',
    },
    centered: {
        justifyContent: 'center',
        alignItems: 'center',
        backgroundColor: 'rgba(0,0,0,0.25)',
    },
    progressCircle: {
        width: 36,
        height: 36,
        justifyContent: 'center',
        alignItems: 'center',
    }
});

export default ImageBubbleBody;
