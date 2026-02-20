import React from 'react';
import { View, Text, TouchableOpacity, Image, StyleSheet } from 'react-native';
import { useThemeStore } from '../../lib/stores/theme-store';

import { MusicTrack } from '../../lib/agent/types';
import { useMusicPlayerStore } from '../../lib/stores/music-player-store';
import { useMediaCacheStore } from '../../lib/stores/media-cache-store';
import { Play, Pause, Disc } from 'lucide-react-native';

interface MusicBubbleProps {
    tracks: MusicTrack[];
}

const getTrackKey = (track: MusicTrack, index: number) =>
    track.video_id || track.id || track.preview_url || `${track.title}-${index}`;

export const MusicBubble = React.memo(({ tracks }: MusicBubbleProps) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const { currentTrack, isPlaying, setTrack, setQueue, setIsPlaying, progress, duration } = useMusicPlayerStore();
    const { cacheTrack } = useMediaCacheStore();
    const [loadedCovers, setLoadedCovers] = React.useState<Record<string, boolean>>({});

    // Cache metadata on mount
    React.useEffect(() => {
        tracks.forEach(track => {
            const trackId = track.video_id || track.id || track.preview_url;
            if (trackId) {
                cacheTrack({
                    video_id: trackId,
                    title: track.title,
                    artist: track.artist,
                    cover: track.cover,
                    preview_url: track.preview_url
                });
            }
        });
    }, [tracks, cacheTrack]);

    // Prefetch covers to reduce flicker (especially on Saved Messages screen re-open)
    React.useEffect(() => {
        const covers = tracks.map(t => t.cover).filter(Boolean) as string[];
        if (covers.length === 0) return;
        covers.forEach(c => {
            Image.prefetch(c).catch(() => { });
        });
    }, [tracks]);

    const handlePlay = (track: MusicTrack) => {
        // If clicking the current track
        if (currentTrack?.preview_url === track.preview_url) {
            setIsPlaying(!isPlaying);
            return;
        }
        // Set queue and play
        setQueue(tracks);
        setTrack(track);
    };

    if (!tracks || tracks.length === 0) return null;

    return (
        <View style={styles.container}>
            {tracks.map((track, index) => {
                const isActive = currentTrack?.preview_url === track.preview_url;
                const progressPercent = isActive && duration > 0 ? (progress / duration) * 100 : 0;
                const trackKey = getTrackKey(track, index);
                const isCoverLoaded = !!loadedCovers[trackKey];

                return (
                    <View key={trackKey} style={[styles.trackRow, { marginBottom: 8 }]}>
                        {/* Bubble Container */}
                        <View style={[
                            styles.trackContainer,
                            { backgroundColor: isLight ? 'rgba(0,0,0,0.03)' : 'rgba(255,255,255,0.08)' }
                        ]}>

                            {/* Progress Fill */}
                            {isActive && (
                                <View style={{
                                    position: 'absolute',
                                    left: 0,
                                    top: 0,
                                    bottom: 0,
                                    width: `${progressPercent}%`,
                                    backgroundColor: isLight ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.1)'
                                }} />
                            )}

                            <View style={styles.contentRow}>
                                {/* Album Art with Play Button Overlay */}
                                <TouchableOpacity
                                    style={styles.artworkContainer}
                                    onPress={() => handlePlay(track)}
                                >
                                    {/* Always show a placeholder so the bubble never flashes empty */}
                                    <View
                                        style={[
                                            StyleSheet.absoluteFill,
                                            {
                                                alignItems: 'center',
                                                justifyContent: 'center',
                                                backgroundColor: isLight ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.10)',
                                            }
                                        ]}
                                    >
                                        <Disc size={18} color={isLight ? 'rgba(0,0,0,0.35)' : 'rgba(255,255,255,0.6)'} />
                                    </View>

                                    {!!track.cover && (
                                        <Image
                                            source={{ uri: track.cover }}
                                            fadeDuration={0}
                                            onLoadEnd={() => {
                                                if (isCoverLoaded) return;
                                                setLoadedCovers(s => ({ ...s, [trackKey]: true }));
                                            }}
                                            style={[
                                                styles.artworkImage,
                                                { opacity: isCoverLoaded ? 1 : 0 }
                                            ]}
                                        />
                                    )}
                                    {/* Play Overlay */}
                                    <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.2)' }]}>
                                        <View style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: 'rgba(255,255,255,0.3)', alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(255,255,255,0.6)' }}>
                                            {isActive && isPlaying ? (
                                                <Pause size={12} color="white" fill="white" />
                                            ) : (
                                                <Play size={12} color="white" fill="white" style={{ marginLeft: 1 }} />
                                            )}
                                        </View>
                                    </View>
                                </TouchableOpacity>

                                {/* Info */}
                                <TouchableOpacity style={styles.infoContainer} onPress={() => handlePlay(track)}>
                                    <Text numberOfLines={1} style={[styles.title, { color: colors.text, fontWeight: isActive ? '700' : '600' }]}>
                                        {track.title}
                                    </Text>
                                    <Text numberOfLines={1} style={[styles.artist, { color: colors.textSecondary }]}>
                                        {track.artist}
                                    </Text>
                                </TouchableOpacity>

                                {/* Duration on Right */}
                                <View style={{ alignItems: 'flex-end' }}>
                                    <Text style={{ fontSize: 12, color: colors.textSecondary, opacity: 0.6 }}>
                                        {track.duration}
                                    </Text>
                                    <Text style={{ fontSize: 10, color: colors.primary, opacity: 0.8 }}>Preview</Text>
                                </View>
                            </View>
                        </View>
                    </View>
                );
            })}
        </View>
    );
});

const styles = StyleSheet.create({
    container: {
        width: '100%',
        marginTop: 4,
    },
    trackRow: {
        width: '100%',
        height: 60,
    },
    trackContainer: {
        flex: 1,
        borderRadius: 16,
        overflow: 'hidden',
        position: 'relative',
    },
    contentRow: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
    },
    artworkContainer: {
        width: 44,
        height: 44,
        borderRadius: 8,
        overflow: 'hidden',
        marginRight: 12,
        position: 'relative',
    },
    artworkImage: {
        ...StyleSheet.absoluteFillObject,
        width: undefined,
        height: undefined,
    },
    infoContainer: {
        flex: 1,
        justifyContent: 'center',
        marginRight: 12,
    },
    title: {
        fontSize: 15,
        marginBottom: 2,
    },
    artist: {
        fontSize: 13,
        opacity: 0.7,
    },
});
