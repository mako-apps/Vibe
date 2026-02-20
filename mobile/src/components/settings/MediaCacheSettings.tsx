import React, { useEffect, useState } from 'react';
import {
    View,
    Text,
    StyleSheet,
    TouchableOpacity,
    ScrollView,
    Image,
    Alert,
    Dimensions,
    ActivityIndicator,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useMediaCacheStore, CachedTrack, getCacheStats } from '../../lib/stores/media-cache-store';
import { ArrowLeft, Trash2, Music, HardDrive, Clock, Heart, MoreVertical, Zap } from 'lucide-react-native';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import * as Haptics from 'expo-haptics';
import Animated, { FadeIn, FadeOut, Layout, SlideInDown, useAnimatedScrollHandler, useAnimatedStyle, useSharedValue, interpolate, Extrapolate } from 'react-native-reanimated';
import { BlurView } from 'expo-blur';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

interface MediaCacheSettingsProps {
    onClose: () => void;
}

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

const TrackItem = ({
    track,
    colors,
    onRemove,
    isFavorite,
    onToggleFavorite,
}: {
    track: CachedTrack;
    colors: any;
    onRemove: () => void;
    isFavorite: boolean;
    onToggleFavorite: () => void;
}) => {
    return (
        <Animated.View
            entering={FadeIn.duration(300)}
            exiting={FadeOut.duration(200)}
            layout={Layout.springify().damping(20).stiffness(90)}
            style={[styles.trackItem, { backgroundColor: `${colors.text}05` }]}
        >
            <Image
                source={{ uri: track.cover || 'https://via.placeholder.com/50' }}
                style={styles.trackCover}
            />
            <View style={styles.trackInfo}>
                <Text style={[styles.trackTitle, { color: colors.text }]} numberOfLines={1}>
                    {track.title}
                </Text>
                <Text style={[styles.trackArtist, { color: colors.textSecondary }]} numberOfLines={1}>
                    {track.artist}
                </Text>
                <View style={styles.trackMeta}>
                    <Text style={[styles.trackMetaText, { color: colors.textSecondary }]}>
                        {formatDuration(track.duration_seconds)} • {track.play_count} plays
                    </Text>
                </View>
            </View>
            <View style={styles.trackActions}>
                <TouchableOpacity onPress={onToggleFavorite} style={styles.actionBtn}>
                    <Heart
                        size={18}
                        color={isFavorite ? '#ff4d6d' : colors.textSecondary}
                        fill={isFavorite ? '#ff4d6d' : 'transparent'}
                        strokeWidth={isFavorite ? 0 : 2}
                    />
                </TouchableOpacity>
                <TouchableOpacity onPress={onRemove} style={styles.actionBtn}>
                    <Trash2 size={18} color={colors.textSecondary} opacity={0.5} />
                </TouchableOpacity>
            </View>
        </Animated.View>
    );
};

export default function MediaCacheSettings({ onClose }: MediaCacheSettingsProps) {
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const scrollY = useSharedValue(0);

    const {
        tracks,
        favorites,
        recentlyPlayed,
        clearAll,
        clearExpired,
        toggleFavorite,
        isFavorite,
    } = useMediaCacheStore();

    const [stats, setStats] = useState({ trackCount: 0, favoriteCount: 0, recentCount: 0, estimatedSizeKB: 0 });
    const [selectedTab, setSelectedTab] = useState<'all' | 'favorites' | 'recent'>('all');

    useEffect(() => {
        setStats(getCacheStats());
    }, [tracks, favorites, recentlyPlayed]);

    const trackList = Object.values(tracks);
    const filteredTracks = selectedTab === 'favorites'
        ? trackList.filter(t => favorites.includes(t.video_id))
        : selectedTab === 'recent'
            ? recentlyPlayed.map(id => tracks[id]).filter(Boolean)
            : trackList;

    const scrollHandler = useAnimatedScrollHandler({
        onScroll: (event) => {
            scrollY.value = event.contentOffset.y;
        },
    });

    const headerTitleStyle = useAnimatedStyle(() => {
        const opacity = interpolate(scrollY.value, [40, 70], [0, 1], Extrapolate.CLAMP);
        return { opacity };
    });

    const floatHeaderStyle = useAnimatedStyle(() => {
        const opacity = interpolate(scrollY.value, [10, 30], [0, 1], Extrapolate.CLAMP);
        return {
            opacity,
            backgroundColor: isLight ? 'rgba(255,255,255,0.8)' : 'rgba(0,0,0,0.6)'
        };
    });

    const handleClearAll = () => {
        Alert.alert(
            'Purge Media Cache',
            'All temporary audio files and metadata will be permanently deleted.',
            [
                { text: 'Cancel', style: 'cancel' },
                {
                    text: 'Purge',
                    style: 'destructive',
                    onPress: () => {
                        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
                        clearAll();
                    },
                },
            ]
        );
    };

    const handleClearExpired = () => {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        clearExpired();
    };

    const handleRemoveTrack = (videoId: string) => {
        Haptics.selectionAsync();
        // Future: implement specific track removal
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* Minimal Floating Header */}
            <Animated.View style={[styles.floatingHeader, { paddingTop: insets.top }, floatHeaderStyle]}>
                <View style={styles.headerContent}>
                    <View style={{ width: 44 }} />
                    <Animated.Text style={[styles.headerTitle, { color: colors.text }, headerTitleStyle]}>
                        Media Cache
                    </Animated.Text>
                    <View style={{ width: 44 }} />
                </View>
            </Animated.View>

            {/* Back Button */}
            <TouchableOpacity
                onPress={onClose}
                style={[styles.floatingBack, { top: insets.top + 8 }]}
                activeOpacity={0.7}
            >
                <BlurView intensity={20} tint={isLight ? 'light' : 'dark'} style={styles.backBlur}>
                    <ArrowLeft size={22} color={colors.text} />
                </BlurView>
            </TouchableOpacity>

            <Animated.ScrollView
                style={styles.content}
                onScroll={scrollHandler}
                scrollEventThrottle={16}
                contentContainerStyle={{ paddingTop: insets.top + 60, paddingBottom: insets.bottom + 100 }}
                showsVerticalScrollIndicator={false}
            >
                {/* Large Content Header */}
                <View style={styles.largeHeader}>
                    <Text style={[styles.largeTitle, { color: colors.text }]}>Media Cache</Text>
                    <Text style={[styles.largeSubtitle, { color: colors.textSecondary }]}>
                        Manage your local audio storage and cached metadata.
                    </Text>
                </View>

                {/* Modern Stats Display */}
                <View style={styles.statsContainer}>
                    <SafeLiquidGlass
                        style={styles.statsGlass}
                        blurIntensity={25}
                        tint={isLight ? 'light' : 'dark'}
                    >
                        <View style={styles.mainStat}>
                            <HardDrive size={24} color={colors.accent} strokeWidth={1.5} />
                            <View style={styles.mainStatText}>
                                <Text style={[styles.mainStatLabel, { color: colors.textSecondary }]}>Used Storage</Text>
                                <Text style={[styles.mainStatValue, { color: colors.text }]}>
                                    {formatBytes(stats.estimatedSizeKB * 1024)}
                                </Text>
                            </View>
                            <Zap size={20} color="#f59e0b" style={styles.zapIcon} />
                        </View>

                        <View style={styles.statsGrid}>
                            <View style={styles.gridItem}>
                                <Text style={[styles.gridValue, { color: colors.text }]}>{stats.trackCount}</Text>
                                <Text style={[styles.gridLabel, { color: colors.textSecondary }]}>Tracks</Text>
                            </View>
                            <View style={styles.gridDivider} />
                            <View style={styles.gridItem}>
                                <Text style={[styles.gridValue, { color: colors.text }]}>{stats.favoriteCount}</Text>
                                <Text style={[styles.gridLabel, { color: colors.textSecondary }]}>Loved</Text>
                            </View>
                            <View style={styles.gridDivider} />
                            <View style={styles.gridItem}>
                                <Text style={[styles.gridValue, { color: colors.text }]}>{stats.recentCount}</Text>
                                <Text style={[styles.gridLabel, { color: colors.textSecondary }]}>Recent</Text>
                            </View>
                        </View>
                    </SafeLiquidGlass>
                </View>

                {/* Sophisticated Tabs */}
                <View style={styles.tabContainer}>
                    <BlurView intensity={10} tint={isLight ? 'light' : 'dark'} style={styles.tabBar}>
                        {(['all', 'favorites', 'recent'] as const).map((tab) => {
                            const active = selectedTab === tab;
                            return (
                                <TouchableOpacity
                                    key={tab}
                                    onPress={() => {
                                        Haptics.selectionAsync();
                                        setSelectedTab(tab);
                                    }}
                                    style={[
                                        styles.tab,
                                        active && { backgroundColor: isLight ? '#fff' : 'rgba(255,255,255,0.1)' }
                                    ]}
                                >
                                    <Text
                                        style={[
                                            styles.tabText,
                                            { color: active ? colors.text : colors.textSecondary, fontWeight: active ? '600' : '400' }
                                        ]}
                                    >
                                        {tab.charAt(0).toUpperCase() + tab.slice(1)}
                                    </Text>
                                </TouchableOpacity>
                            );
                        })}
                    </BlurView>
                </View>

                {/* Track List */}
                <View style={styles.tracksSection}>
                    {filteredTracks.length === 0 ? (
                        <Animated.View entering={FadeIn} style={styles.emptyState}>
                            <View style={[styles.emptyIconContainer, { backgroundColor: `${colors.text}08` }]}>
                                <Music size={32} color={colors.textSecondary} strokeWidth={1} />
                            </View>
                            <Text style={[styles.emptyText, { color: colors.text }]}>Pure Silence</Text>
                            <Text style={[styles.emptySubtext, { color: colors.textSecondary }]}>
                                Your cache is as empty as a vacuum.
                            </Text>
                        </Animated.View>
                    ) : (
                        <View style={styles.trackList}>
                            {filteredTracks.map((track) => (
                                <TrackItem
                                    key={track.video_id}
                                    track={track}
                                    colors={colors}
                                    isFavorite={isFavorite(track.video_id)}
                                    onToggleFavorite={() => toggleFavorite(track.video_id)}
                                    onRemove={() => handleRemoveTrack(track.video_id)}
                                />
                            ))}
                        </View>
                    )}
                </View>

                {/* Global Actions */}
                <View style={styles.globalActions}>
                    <TouchableOpacity
                        onPress={handleClearExpired}
                        style={[styles.secondaryAction, { borderColor: `${colors.text}10` }]}
                    >
                        <Clock size={16} color={colors.textSecondary} />
                        <Text style={[styles.secondaryActionText, { color: colors.textSecondary }]}>Clean Expired</Text>
                    </TouchableOpacity>

                    <TouchableOpacity
                        onPress={handleClearAll}
                        style={[styles.primaryAction, { backgroundColor: '#ef444415' }]}
                    >
                        <Trash2 size={16} color="#ef4444" />
                        <Text style={[styles.primaryActionText, { color: '#ef4444' }]}>Clear All Data</Text>
                    </TouchableOpacity>
                </View>
            </Animated.ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    floatingHeader: {
        position: 'absolute',
        left: 0,
        right: 0,
        zIndex: 100,
        height: 100,
        justifyContent: 'center',
    },
    headerContent: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '700',
    },
    floatingBack: {
        position: 'absolute',
        left: 16,
        zIndex: 110,
        width: 44,
        height: 44,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.15,
        shadowRadius: 10,
        elevation: 5,
    },
    backBlur: {
        width: 44,
        height: 44,
        borderRadius: 22,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center',
    },
    content: {
        flex: 1,
    },
    largeHeader: {
        paddingHorizontal: 24,
        marginBottom: 32,
    },
    largeTitle: {
        fontSize: 34,
        fontWeight: '800',
        letterSpacing: -0.5,
    },
    largeSubtitle: {
        fontSize: 15,
        lineHeight: 22,
        marginTop: 8,
        opacity: 0.8,
    },
    statsContainer: {
        paddingHorizontal: 20,
        marginBottom: 32,
    },
    statsGlass: {
        borderRadius: 28,
        padding: 24,
        overflow: 'hidden',
    },
    mainStat: {
        flexDirection: 'row',
        alignItems: 'center',
        marginBottom: 24,
    },
    mainStatText: {
        marginLeft: 16,
        flex: 1,
    },
    mainStatLabel: {
        fontSize: 13,
        fontWeight: '500',
        textTransform: 'uppercase',
        letterSpacing: 0.5,
        opacity: 0.6,
    },
    mainStatValue: {
        fontSize: 28,
        fontWeight: '800',
        marginTop: 2,
    },
    zapIcon: {
        opacity: 0.8,
    },
    statsGrid: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingTop: 20,
        borderTopWidth: 1,
        borderTopColor: 'rgba(150,150,150,0.1)',
    },
    gridItem: {
        flex: 1,
        alignItems: 'center',
    },
    gridValue: {
        fontSize: 18,
        fontWeight: '700',
    },
    gridLabel: {
        fontSize: 12,
        marginTop: 4,
        opacity: 0.6,
    },
    gridDivider: {
        width: 1,
        height: 24,
        backgroundColor: 'rgba(150,150,150,0.1)',
    },
    tabContainer: {
        paddingHorizontal: 20,
        marginBottom: 20,
    },
    tabBar: {
        flexDirection: 'row',
        padding: 4,
        borderRadius: 16,
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.05)',
    },
    tab: {
        flex: 1,
        paddingVertical: 10,
        alignItems: 'center',
        borderRadius: 12,
    },
    tabText: {
        fontSize: 14,
    },
    tracksSection: {
        paddingHorizontal: 16,
    },
    trackList: {
        gap: 10,
    },
    trackItem: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 10,
        borderRadius: 18,
    },
    trackCover: {
        width: 52,
        height: 52,
        borderRadius: 12,
        marginRight: 14,
        backgroundColor: 'rgba(150,150,150,0.1)',
    },
    trackInfo: {
        flex: 1,
    },
    trackTitle: {
        fontSize: 16,
        fontWeight: '600',
        letterSpacing: -0.2,
    },
    trackArtist: {
        fontSize: 13,
        opacity: 0.7,
        marginTop: 1,
    },
    trackMeta: {
        marginTop: 4,
    },
    trackMetaText: {
        fontSize: 11,
        fontWeight: '500',
    },
    trackActions: {
        flexDirection: 'row',
        gap: 4,
    },
    actionBtn: {
        width: 36,
        height: 36,
        alignItems: 'center',
        justifyContent: 'center',
    },
    emptyState: {
        alignItems: 'center',
        paddingVertical: 80,
    },
    emptyIconContainer: {
        width: 72,
        height: 72,
        borderRadius: 36,
        alignItems: 'center',
        justifyContent: 'center',
        marginBottom: 20,
    },
    emptyText: {
        fontSize: 20,
        fontWeight: '700',
    },
    emptySubtext: {
        fontSize: 14,
        textAlign: 'center',
        marginTop: 8,
        paddingHorizontal: 40,
        lineHeight: 20,
    },
    globalActions: {
        flexDirection: 'row',
        paddingHorizontal: 20,
        marginTop: 40,
        gap: 12,
    },
    secondaryAction: {
        flex: 1,
        height: 48,
        borderRadius: 14,
        borderWidth: 1,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
    },
    secondaryActionText: {
        fontSize: 14,
        fontWeight: '600',
    },
    primaryAction: {
        flex: 1.2,
        height: 48,
        borderRadius: 14,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
    },
    primaryActionText: {
        fontSize: 14,
        fontWeight: '700',
    },
});
