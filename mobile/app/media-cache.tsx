import React, { useEffect, useMemo, useState } from 'react';
import {
    View,
    Text,
    TextInput,
    StyleSheet,
    TouchableOpacity,
    Image,
    Alert,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useMediaCacheStore, CachedTrack, getCacheStats } from '../src/lib/stores/media-cache-store';
import { useMusicPlayerStore } from '../src/lib/stores/music-player-store';
import { X, Trash2, HardDrive, Clock, Heart, ChevronRight, Play, Pause, Search } from 'lucide-react-native';
import * as Haptics from 'expo-haptics';
import Animated, { useAnimatedScrollHandler, useAnimatedStyle, useSharedValue, interpolate, Extrapolate, LinearTransition } from 'react-native-reanimated';
import { useRouter } from 'expo-router';
import { MusicTrack } from '../src/lib/agent/types';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

const formatBytes = (bytes: number): string => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
};

const formatDuration = (seconds?: number): string => {
    if (!seconds) return '--:--';
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
};

const toMusicTrack = (t: CachedTrack): MusicTrack => ({
    id: t.video_id,
    video_id: t.video_id,
    title: t.title,
    artist: t.artist,
    album: t.album,
    duration: t.duration,
    preview_url: t.local_uri || t.stream_url || t.preview_url,
    cover: t.cover,
    links: {
        deezer: t.links?.deezer,
        spotify: t.links?.spotify,
        youtube_music: t.links?.youtube_music,
    },
});

export default function MediaCacheScreen() {
    const insets = useSafeAreaInsets();
    const router = useRouter();
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const scrollY = useSharedValue(0);

    // Stores
    const {
        tracks,
        favorites,
        recentlyPlayed,
        clearAll,
        clearExpired,
        toggleFavorite,
        isFavorite,
        settings,
        updateSettings
    } = useMediaCacheStore();

    const { setTrack, setQueue, currentTrack, isPlaying, setIsPlaying } = useMusicPlayerStore();

    const [stats, setStats] = useState({ trackCount: 0, favoriteCount: 0, recentCount: 0, estimatedSizeKB: 0 });
    const [selectedTab, setSelectedTab] = useState<'all' | 'favorites' | 'recent'>('all');
    const [search, setSearch] = useState('');

    useEffect(() => {
        setStats(getCacheStats());
    }, [tracks, favorites, recentlyPlayed]);

    const trackList = useMemo(() => Object.values(tracks), [tracks]);
    const baseTracks = useMemo(() => {
        if (selectedTab === 'favorites') return trackList.filter(t => favorites.includes(t.video_id));
        if (selectedTab === 'recent') return recentlyPlayed.map(id => tracks[id]).filter(Boolean);
        return trackList;
    }, [selectedTab, trackList, favorites, recentlyPlayed, tracks]);

    const filteredTracks = useMemo(() => {
        const q = search.trim().toLowerCase();
        if (!q) return baseTracks;
        return baseTracks.filter((t) =>
            `${t.title} ${t.artist}`.toLowerCase().includes(q)
        );
    }, [baseTracks, search]);

    const scrollHandler = useAnimatedScrollHandler({
        onScroll: (event) => {
            scrollY.value = event.contentOffset.y;
        },
    });

    // Handlers
    const handlePlay = (track: CachedTrack) => {
        const isActive = currentTrack?.video_id === track.video_id;

        if (isActive) {
            setIsPlaying(!isPlaying);
            return;
        }

        const queue = filteredTracks.map(toMusicTrack).filter((t) => !!t.preview_url);
        const musicTrack = queue.find(t => t.video_id === track.video_id);

        if (musicTrack) {
            setQueue(queue);
            setTrack(musicTrack);
        }
    };

    const handleClearAll = () => {
        Alert.alert(
            'Clear Cache',
            'Are you sure? This will delete all downloaded content.',
            [
                { text: 'Cancel', style: 'cancel' },
                {
                    text: 'Clear All',
                    style: 'destructive',
                    onPress: () => {
                        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
                        clearAll();
                    },
                },
            ]
        );
    };

    const handleCacheLimit = () => {
        // Toggle between 100, 500, 1000 items.
        const current = settings.maxCacheSize;
        const next = current === 100 ? 500 : current === 500 ? 1000 : 100;
        updateSettings({ maxCacheSize: next });
        Haptics.selectionAsync();
    };

    const totalCap = 200 * 1024; // Used only for the bar visualization.
    const usedPercent = Math.min((stats.estimatedSizeKB / totalCap) * 100, 100);

    const headerChromeStyle = useAnimatedStyle(() => {
        const opacity = interpolate(scrollY.value, [0, 30], [0, 1], Extrapolate.CLAMP);
        return { opacity };
    });

    const sectionBg = isLight ? '#ffffff' : colors.card;
    const secondaryBg = isLight ? withAlpha('#000', 0.04) : withAlpha(colors.text, 0.06);
    const dividerColor = withAlpha(colors.text, isLight ? 0.08 : 0.12);

    const renderTrackRow = ({ item, index }: { item: CachedTrack; index: number }) => {
        const active = currentTrack?.video_id === item.video_id;
        const fav = isFavorite(item.video_id);
        const canPlay = !!(item.local_uri || item.stream_url || item.preview_url);
        const isFirst = index === 0;
        const isLast = index === filteredTracks.length - 1;

        return (
            <Animated.View
                layout={LinearTransition.springify().damping(16)}
                style={[
                    styles.trackRowContainer,
                    { backgroundColor: sectionBg },
                    isFirst && styles.trackRowFirst,
                    isLast && styles.trackRowLast,
                ]}
            >
                <TouchableOpacity
                    onPress={() => { if (canPlay) handlePlay(item); }}
                    activeOpacity={0.85}
                    disabled={!canPlay}
                    style={[styles.trackRowInner, !canPlay && { opacity: 0.55 }]}
                >
                    <View style={[styles.artwork, { backgroundColor: secondaryBg }]}>
                        {item.cover ? (
                            <Image source={{ uri: item.cover }} style={styles.artworkImg} />
                        ) : (
                            <HardDrive size={18} color={withAlpha(colors.text, 0.35)} />
                        )}
                        <View
                            style={[
                                styles.playBadge,
                                { backgroundColor: active ? withAlpha(colors.primary, 0.95) : withAlpha(colors.text, isLight ? 0.16 : 0.22) },
                            ]}
                        >
                            {active && isPlaying ? (
                                <Pause size={14} color={active ? '#fff' : colors.text} />
                            ) : (
                                <Play size={14} color={active ? '#fff' : colors.text} />
                            )}
                        </View>
                    </View>

                    <View style={{ flex: 1, minWidth: 0 }}>
                        <Text style={[styles.trackTitle, { color: active ? colors.primary : colors.text }]} numberOfLines={1}>
                            {item.title}
                        </Text>
                        <Text style={[styles.trackSubtitle, { color: colors.textSecondary }]} numberOfLines={1}>
                            {item.artist}
                        </Text>
                    </View>

                    <View style={styles.trackRight}>
                        <Text style={[styles.trackMeta, { color: colors.textSecondary }]}>
                            {formatDuration(item.duration_seconds)}
                        </Text>
                        <TouchableOpacity
                            onPress={() => { Haptics.selectionAsync(); toggleFavorite(item.video_id); }}
                            style={styles.iconBtn}
                            activeOpacity={0.8}
                            hitSlop={8}
                        >
                            <Heart
                                size={18}
                                color={fav ? '#ff4d6d' : colors.textSecondary}
                                fill={fav ? '#ff4d6d' : 'transparent'}
                                strokeWidth={fav ? 0 : 2}
                            />
                        </TouchableOpacity>
                    </View>
                </TouchableOpacity>
                {!isLast && <View style={[styles.trackDivider, { backgroundColor: dividerColor }]} />}
            </Animated.View>
        );
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* Header */}
            <View style={[styles.headerContainer, { height: insets.top + 60, zIndex: 130 }]} pointerEvents="box-none">
                <Animated.View style={[StyleSheet.absoluteFill, headerChromeStyle]} pointerEvents="none">
                    <View style={[styles.headerMaskContainer, { height: Math.max(80, insets.top + 20) }]}>
                        <MaskedView
                            style={StyleSheet.absoluteFill}
                            maskElement={
                                <LinearGradient
                                    colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']}
                                    locations={[0.6, 1]}
                                    style={StyleSheet.absoluteFill}
                                />
                            }
                        >
                            <BlurView
                                intensity={30}
                                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.85) }]}
                            />
                        </MaskedView>
                    </View>
                </Animated.View>
                <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle} activeOpacity={0.85}>
                            <X color={colors.text} size={22} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                    <Text style={[styles.headerTitle, { color: colors.text }]}>
                        Storage
                    </Text>
                    <View style={{ width: 44 }} />
                </View>
            </View>

            <Animated.FlatList
                data={filteredTracks}
                keyExtractor={(t) => t.video_id}
                renderItem={renderTrackRow}
                contentContainerStyle={{ paddingTop: insets.top + 60, paddingBottom: insets.bottom + 40 }}
                showsVerticalScrollIndicator={false}
                onScroll={scrollHandler}
                scrollEventThrottle={16}
                ListHeaderComponent={
                    <View>
                        <View style={{ paddingVertical: 24 }} />

                        {/* Stats */}
                        <View style={[styles.statsCard, { backgroundColor: sectionBg }]}>
                            <View style={styles.statsTop}>
                                <View style={[styles.statsIcon, { backgroundColor: withAlpha(colors.primary, 0.12) }]}>
                                    <HardDrive size={18} color={colors.primary} />
                                </View>
                                <View style={{ flex: 1 }}>
                                    <Text style={[styles.statsLabel, { color: colors.textSecondary }]}>Used</Text>
                                    <Text style={[styles.statsValue, { color: colors.text }]}>
                                        {formatBytes(stats.estimatedSizeKB * 1024)}
                                    </Text>
                                </View>
                                <Text style={[styles.statsCap, { color: colors.textSecondary }]}>
                                    {stats.trackCount} tracks
                                </Text>
                            </View>

                            <View style={styles.barContainer}>
                                <View style={[styles.barSegment, { flex: usedPercent || 1, backgroundColor: colors.primary, borderTopLeftRadius: 4, borderBottomLeftRadius: 4 }]} />
                                <View style={[styles.barSegment, { flex: 100 - (usedPercent || 1), backgroundColor: withAlpha(colors.text, 0.1), borderTopRightRadius: 4, borderBottomRightRadius: 4 }]} />
                            </View>

                            <View style={styles.statsGrid}>
                                <View style={styles.statsCell}>
                                    <Text style={[styles.cellValue, { color: colors.text }]}>{stats.favoriteCount}</Text>
                                    <Text style={[styles.cellLabel, { color: colors.textSecondary }]}>Favorites</Text>
                                </View>
                                <View style={[styles.cellDivider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />
                                <View style={styles.statsCell}>
                                    <Text style={[styles.cellValue, { color: colors.text }]}>{stats.recentCount}</Text>
                                    <Text style={[styles.cellLabel, { color: colors.textSecondary }]}>Recent</Text>
                                </View>
                                <View style={[styles.cellDivider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />
                                <View style={styles.statsCell}>
                                    <Text style={[styles.cellValue, { color: colors.text }]}>{settings.maxCacheSize}</Text>
                                    <Text style={[styles.cellLabel, { color: colors.textSecondary }]}>Limit</Text>
                                </View>
                            </View>
                        </View>

                        {/* Settings group */}
                        <View style={styles.sectionHeader}>
                            <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>SETTINGS</Text>
                        </View>
                        <View style={[styles.group, { backgroundColor: sectionBg }]}>
                            <TouchableOpacity onPress={handleCacheLimit} activeOpacity={0.85} style={styles.row}>
                                <Text style={[styles.rowLabel, { color: colors.text }]}>Max cache</Text>
                                <View style={styles.rowRight}>
                                    <Text style={[styles.rowValue, { color: colors.textSecondary }]}>{settings.maxCacheSize} tracks</Text>
                                    <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                                </View>
                            </TouchableOpacity>
                            <View style={[styles.groupDivider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />
                            <TouchableOpacity
                                onPress={() => { Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success); clearExpired(); }}
                                activeOpacity={0.85}
                                style={styles.row}
                            >
                                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                                    <Clock size={16} color={colors.textSecondary} />
                                    <Text style={[styles.rowLabel, { color: colors.text }]}>Clean expired</Text>
                                </View>
                                <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.35 }} />
                            </TouchableOpacity>
                            <View style={[styles.groupDivider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />
                            <TouchableOpacity onPress={handleClearAll} activeOpacity={0.85} style={styles.row}>
                                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                                    <Trash2 size={16} color="#ef4444" />
                                    <Text style={[styles.rowLabel, { color: '#ef4444' }]}>Clear all downloads</Text>
                                </View>
                                <ChevronRight size={16} color={withAlpha(colors.textSecondary, 0.7)} style={{ opacity: 0.35 }} />
                            </TouchableOpacity>
                        </View>

                        {/* Library */}
                        <View style={[styles.sectionHeader, { marginTop: 18 }]}>
                            <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>LIBRARY</Text>
                        </View>

                        <View style={[styles.searchBar, { backgroundColor: sectionBg }]}>
                            <Search size={16} color={colors.textSecondary} />
                            <TextInput
                                value={search}
                                onChangeText={setSearch}
                                placeholder="Search cached tracks"
                                placeholderTextColor={withAlpha(colors.text, 0.35)}
                                style={[styles.searchInput, { color: colors.text }]}
                            />
                            {!!search && (
                                <TouchableOpacity onPress={() => setSearch('')} style={{ padding: 6 }} activeOpacity={0.8}>
                                    <Text style={{ color: colors.textSecondary, fontSize: 14, fontWeight: '700' }}>×</Text>
                                </TouchableOpacity>
                            )}
                        </View>

                        <View style={styles.tabContainer}>
                            {(['all', 'favorites', 'recent'] as const).map((tab) => {
                                const active = selectedTab === tab;
                                return (
                                    <TouchableOpacity
                                        key={tab}
                                        onPress={() => { Haptics.selectionAsync(); setSelectedTab(tab); }}
                                        activeOpacity={0.85}
                                        style={[
                                            styles.tab,
                                            {
                                                backgroundColor: active ? sectionBg : 'transparent',
                                                borderColor: withAlpha(colors.text, active ? 0.08 : 0),
                                            }
                                        ]}
                                    >
                                        <Text style={[styles.tabText, { color: active ? colors.text : colors.textSecondary }]}>
                                            {tab.charAt(0).toUpperCase() + tab.slice(1)}
                                        </Text>
                                    </TouchableOpacity>
                                );
                            })}
                        </View>
                        {!!filteredTracks.length && (
                            <View style={[styles.sectionHeader, { marginTop: 10, marginBottom: 8 }]}>
                                <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>TRACKS</Text>
                            </View>
                        )}
                    </View>
                }
                ListEmptyComponent={
                    <View style={styles.emptyState}>
                        <HardDrive size={32} color={colors.textSecondary} style={{ opacity: 0.25, marginBottom: 10 }} />
                        <Text style={{ color: colors.textSecondary, fontWeight: '600' }}>
                            {search.trim() ? 'No matches' : 'No cached media yet'}
                        </Text>
                        {!search.trim() && (
                            <Text style={{ color: withAlpha(colors.textSecondary, 0.8), marginTop: 6, textAlign: 'center', paddingHorizontal: 20 }}>
                                Play a track or download audio to see it here.
                            </Text>
                        )}
                    </View>
                }
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0 },
    headerMaskContainer: { position: 'absolute', top: 0, left: 0, right: 0 },
    headerContentContainer: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, height: 62 },
    headerBtn: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center', borderRadius: 22 },
    headerTitle: { fontSize: 17, fontWeight: '700', letterSpacing: -0.4 },
    glassBtnCircle: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },

    paddingH: { paddingHorizontal: 20 },

    sectionHeader: { paddingHorizontal: 24, marginBottom: 8, marginTop: 10 },
    sectionTitle: { fontSize: 13, fontWeight: '700', opacity: 0.55, letterSpacing: 0.6 },

    statsCard: { marginHorizontal: 20, borderRadius: 26, padding: 18, gap: 14, marginBottom: 18, overflow: 'hidden' },
    statsTop: { flexDirection: 'row', alignItems: 'center', gap: 12 },
    statsIcon: { width: 34, height: 34, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },
    statsLabel: { fontSize: 12, fontWeight: '800', letterSpacing: 0.6, textTransform: 'uppercase', opacity: 0.75 },
    statsValue: { fontSize: 22, fontWeight: '800', marginTop: 2 },
    statsCap: { fontSize: 13, fontWeight: '700', opacity: 0.7 },

    barContainer: { flexDirection: 'row', height: 12, borderRadius: 6, overflow: 'hidden' },
    barSegment: { height: '100%' },

    statsGrid: { flexDirection: 'row', alignItems: 'stretch', borderRadius: 18, overflow: 'hidden' },
    statsCell: { flex: 1, paddingVertical: 10, alignItems: 'center', justifyContent: 'center' },
    cellValue: { fontSize: 16, fontWeight: '800' },
    cellLabel: { fontSize: 12, fontWeight: '700', opacity: 0.7, marginTop: 2 },
    cellDivider: { width: 1 },

    group: { marginHorizontal: 20, borderRadius: 26, overflow: 'hidden' },
    row: { minHeight: 56, paddingHorizontal: 18, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
    rowLabel: { fontSize: 16, fontWeight: '600' },
    rowRight: { flexDirection: 'row', alignItems: 'center', gap: 8 },
    rowValue: { fontSize: 14, fontWeight: '700', opacity: 0.75 },
    groupDivider: { height: 1, marginLeft: 18 },

    searchBar: { marginHorizontal: 20, borderRadius: 18, paddingHorizontal: 14, height: 46, flexDirection: 'row', alignItems: 'center', gap: 10 },
    searchInput: { flex: 1, fontSize: 15, fontWeight: '600' },

    tabContainer: { flexDirection: 'row', gap: 8, paddingHorizontal: 20, marginTop: 12, marginBottom: 12 },
    tab: { paddingVertical: 8, paddingHorizontal: 14, borderRadius: 18, borderWidth: 1 },
    tabText: { fontSize: 14, fontWeight: '700' },

    trackRowContainer: { marginHorizontal: 20, overflow: 'hidden' },
    trackRowFirst: { borderTopLeftRadius: 24, borderTopRightRadius: 24 },
    trackRowLast: { borderBottomLeftRadius: 24, borderBottomRightRadius: 24, marginBottom: 14 },
    trackRowInner: { minHeight: 64, paddingHorizontal: 16, paddingVertical: 12, flexDirection: 'row', alignItems: 'center', gap: 12 },
    artwork: { width: 52, height: 52, borderRadius: 14, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    artworkImg: { width: '100%', height: '100%' },
    playBadge: { position: 'absolute', right: 6, bottom: 6, width: 22, height: 22, borderRadius: 11, alignItems: 'center', justifyContent: 'center' },
    trackTitle: { fontSize: 16, fontWeight: '700' },
    trackSubtitle: { fontSize: 13, fontWeight: '600', opacity: 0.75, marginTop: 2 },
    trackRight: { alignItems: 'flex-end', justifyContent: 'center', gap: 10, marginLeft: 10 },
    trackMeta: { fontSize: 12, fontWeight: '700', opacity: 0.8 },
    iconBtn: { padding: 4 },
    trackDivider: { height: StyleSheet.hairlineWidth, marginLeft: 16 + 52 + 12 },

    emptyState: { alignItems: 'center', paddingVertical: 44 },
});
