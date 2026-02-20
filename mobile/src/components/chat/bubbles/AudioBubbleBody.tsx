import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Pause, Play } from 'lucide-react-native';
import Animated, {
    Easing,
    useAnimatedStyle,
    useSharedValue,
    withTiming,
} from 'react-native-reanimated';

import { useMusicPlayerStore } from '../../../lib/stores/music-player-store';
import { useThemeStore } from '../../../lib/stores/theme-store';
import { resolveThemeVariant, useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { BubbleMeta } from './BubbleMeta';
import { formatDuration } from './format';
import type { ChatListBubbleMessage } from './types';

const BAR_MIN_HEIGHT = 4;
const BAR_MAX_HEIGHT = 24;
const MIN_BAR_COUNT = 26;
const MAX_BAR_COUNT = 44;

const clamp01 = (value: number) => Math.max(0, Math.min(1, value));

const toHeights = (source: number[], count: number) => {
    const safe = source.length > 0 ? source : [0.4];
    const max = Math.max(...safe, 1);
    const normalized = safe.map((v) => clamp01(Math.abs(v) / max));

    const sampled = Array.from({ length: count }, (_, index) => {
        const at = (index / Math.max(1, count - 1)) * (normalized.length - 1);
        const left = Math.floor(at);
        const right = Math.min(normalized.length - 1, left + 1);
        const ratio = at - left;
        const mixed = normalized[left] * (1 - ratio) + normalized[right] * ratio;
        return mixed;
    });

    return sampled.map((v) => BAR_MIN_HEIGHT + v * (BAR_MAX_HEIGHT - BAR_MIN_HEIGHT));
};

const fallbackWaveform = (seed: string, count: number) => {
    const chars = seed || 'voice';
    const values = Array.from({ length: count }, (_, i) => {
        const c = chars.charCodeAt(i % chars.length);
        const harmonic = Math.abs(Math.sin((i + 1) * 0.48 + c * 0.05));
        const envelope = Math.sin((i / Math.max(1, count - 1)) * Math.PI);
        return clamp01(0.15 + harmonic * 0.85) * Math.max(0.35, envelope);
    });
    return values;
};

const useAudioColors = (isMe: boolean) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = isMe ? theme.textColorMe : theme.textColorThem;
    const isLightText = textColor.toLowerCase().includes('#f') || textColor.toLowerCase().includes('white');

    // Use theme-derived colors instead of hardcoded hex codes
    const accentColor = effectiveTheme === 'dark' ? '#4DD9E5' : '#007A7C'; // Fallback to theme-like colors if needed, but better to use theme.bubbleMe/Them

    return {
        textColor,
        buttonBg: isLightText ? 'rgba(255,255,255,0.95)' : 'rgba(0,0,0,0.1)',
        iconColor: isLightText ? (isMe ? (theme.bubbleMeGradient?.[1] || theme.bubbleMe) : (effectiveTheme === 'dark' ? '#8FEEFF' : '#007A7C')) : textColor,
        idleBar: isLightText ? 'rgba(255,255,255,0.3)' : 'rgba(0,0,0,0.12)',
        playedBar: isLightText ? (isMe ? '#FFFFFF' : (effectiveTheme === 'dark' ? '#FFFFFF' : '#007A7C')) : (isMe ? 'rgba(0,0,0,0.7)' : '#000000'),
    };
};

const AudioBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const mediaUrl = item.mediaUrl || '';
    const audioColors = useAudioColors(item.isMe);
    const textColor = audioColors.textColor;
    const bubbleStatus = item.isMe ? (item.status || 'sent') : item.status;

    const setTrack = useMusicPlayerStore((s) => s.setTrack);
    const setIsPlaying = useMusicPlayerStore((s) => s.setIsPlaying);
    const activePreviewUrl = useMusicPlayerStore((s) => s.currentTrack?.preview_url);
    const isPlayingGlobal = useMusicPlayerStore((s) => s.isPlaying);
    const storeProgressMs = useMusicPlayerStore((s) => (
        s.currentTrack?.preview_url === mediaUrl ? s.progress : 0
    ));
    const storeDurationMs = useMusicPlayerStore((s) => (
        s.currentTrack?.preview_url === mediaUrl ? s.duration : 0
    ));

    const isActiveTrack = activePreviewUrl === mediaUrl;
    const isPlaying = isActiveTrack && isPlayingGlobal;

    const baseDurationMs = Math.max(0, Math.round((item.duration || 0) * 1000));
    const durationMs = storeDurationMs > 0 ? storeDurationMs : Math.max(baseDurationMs, 1);
    const ratio = isActiveTrack ? clamp01(storeProgressMs / durationMs) : 0;
    const [waveWidth, setWaveWidth] = useState(0);

    const progress = useSharedValue(0);
    useEffect(() => {
        progress.value = withTiming(ratio, {
            duration: isPlaying ? 120 : 90,
            easing: Easing.linear,
        });
    }, [isPlaying, progress, ratio]);

    const barCount = useMemo(() => {
        const estimated = Math.round(Math.max(item.duration || 4, 2) * 4.2);
        return Math.max(MIN_BAR_COUNT, Math.min(MAX_BAR_COUNT, estimated));
    }, [item.duration]);

    const heights = useMemo(() => {
        const src = Array.isArray(item.extra?.waveform) && item.extra.waveform.length > 0
            ? item.extra.waveform.filter((v): v is number => typeof v === 'number')
            : fallbackWaveform(item.id, barCount);
        return toHeights(src, barCount);
    }, [barCount, item.extra?.waveform, item.id]);

    const playedMaskStyle = useAnimatedStyle(() => ({
        width: waveWidth * progress.value,
    }), [waveWidth]);

    const handleToggle = useCallback(() => {
        if (!mediaUrl) return;

        if (isActiveTrack) {
            setIsPlaying(!isPlayingGlobal);
            return;
        }

        setTrack({
            title: item.type === 'voice' ? 'Voice Message' : (item.fileName || 'Audio Track'),
            artist: 'Chat',
            cover: '',
            preview_url: mediaUrl,
            links: {},
        });
        setIsPlaying(true);
    }, [isActiveTrack, isPlayingGlobal, item.fileName, item.type, mediaUrl, setIsPlaying, setTrack]);

    const durationLabel = formatDuration(durationMs / 1000);

    return (
        <View style={styles.wrap}>
            <View style={styles.topRow}>
                <Pressable
                    onPress={handleToggle}
                    style={[
                        styles.playButton,
                        { backgroundColor: audioColors.buttonBg }
                    ]}
                    hitSlop={8}
                >
                    {isPlaying ? (
                        <Pause
                            size={20}
                            color={audioColors.iconColor}
                            fill={audioColors.iconColor}
                        />
                    ) : (
                        <Play
                            size={20}
                            color={audioColors.iconColor}
                            fill={audioColors.iconColor}
                            style={styles.playIcon}
                        />
                    )}
                </Pressable>

                <View style={styles.waveWrap}>
                    <View
                        style={styles.waveTrack}
                        onLayout={(event) => {
                            const next = event.nativeEvent.layout.width;
                            if (Math.abs(next - waveWidth) > 0.5) {
                                setWaveWidth(next);
                            }
                        }}
                    >
                        <View style={[styles.waveRow, waveWidth > 0 ? { width: waveWidth } : null]}>
                            {heights.map((h, index) => (
                                <View
                                    key={`idle-${item.id}-${index}`}
                                    style={[
                                        styles.bar,
                                        { height: h, backgroundColor: audioColors.idleBar },
                                    ]}
                                />
                            ))}
                        </View>
                        <Animated.View style={[styles.wavePlayedMask, playedMaskStyle]}>
                            <View style={[styles.waveRow, waveWidth > 0 ? { width: waveWidth } : null]}>
                                {heights.map((h, index) => (
                                    <View
                                        key={`played-${item.id}-${index}`}
                                        style={[
                                            styles.bar,
                                            { height: h, backgroundColor: audioColors.playedBar },
                                        ]}
                                    />
                                ))}
                            </View>
                        </Animated.View>
                    </View>
                </View>
            </View>

            <View style={styles.bottomRow}>
                <Text style={[styles.durationLabel, { color: textColor }]}>{durationLabel}</Text>
                <BubbleMeta timestamp={item.timestamp} status={bubbleStatus} isMe={item.isMe} isPinned={item.isPinned} />
            </View>
        </View>
    );
});

const styles = StyleSheet.create({
    wrap: {
        minWidth: 168,
        maxWidth: 232,
        paddingVertical: 1,
    },
    topRow: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    playButton: {
        width: 38,
        height: 38,
        borderRadius: 19,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 10,
    },
    playIcon: {
        marginLeft: 1.8,
    },
    waveWrap: {
        flex: 1,
        minHeight: 28,
        justifyContent: 'center',
    },
    waveTrack: {
        minHeight: 28,
        position: 'relative',
    },
    waveRow: {
        height: 24,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 1.4,
    },
    wavePlayedMask: {
        position: 'absolute',
        left: 0,
        top: 0,
        bottom: 0,
        overflow: 'hidden',
    },
    bar: {
        width: 2.6,
        borderRadius: 1.4,
    },
    bottomRow: {
        marginTop: 4,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
    },
    durationLabel: {
        fontSize: 12,
        marginLeft: 48,
    },
});

export default AudioBubbleBody;
