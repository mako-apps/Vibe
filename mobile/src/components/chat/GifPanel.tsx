
import React, { useState, useEffect, useCallback } from 'react';
import {
    View,
    Text,
    StyleSheet,
    FlatList,
    Image,
    TextInput,
    ActivityIndicator,
    Pressable,
    Dimensions,
    TouchableOpacity,
    ScrollView,
} from 'react-native';
import Animated, {
    useAnimatedStyle,
    withTiming,
    useSharedValue,
    Easing,
    SharedValue,
} from 'react-native-reanimated';
import { Search, X, Heart, Clock3, Plus } from 'lucide-react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import AsyncStorage from '@react-native-async-storage/async-storage';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

interface GifPanelProps {
    visible: boolean;
    onSelectGif: (gif: { id: string; url: string; preview: string; width: number; height: number }) => void;
    onClose: () => void;
    height: number;
    progress?: SharedValue<number>;
}

const TENOR_API_KEY = "LIVDSRZULELA"; // Ensure this is managed securely in production

type Tab = 'gifs' | 'stickers' | 'favorites';

const STICKER_PACKS = [
    { id: 'funny', label: 'Funny', emoji: '🤣', query: 'funny stickers' },
    { id: 'cats', label: 'Cats', emoji: '🐱', query: 'cat stickers' },
    { id: 'anime', label: 'Anime', emoji: '🌸', query: 'anime stickers' },
    { id: 'love', label: 'Love', emoji: '💘', query: 'love stickers' },
    { id: 'hello', label: 'Hi', emoji: '👋', query: 'hello stickers' },
    { id: 'meme', label: 'Meme', emoji: '😎', query: 'meme stickers' },
    { id: 'party', label: 'Party', emoji: '🎉', query: 'party stickers' },
    { id: 'sad', label: 'Sad', emoji: '🥲', query: 'sad stickers' },
];

const REACTION_FILTERS = [
    { id: 'love', icon: '♡', query: 'love' },
    { id: 'like', icon: '👍', query: 'like' },
    { id: 'dislike', icon: '👎', query: 'dislike' },
    { id: 'party', icon: '🎉', query: 'party' },
    { id: 'wave', icon: '👋', query: 'hello' },
    { id: 'happy', icon: '🙂', query: 'happy' },
    { id: 'sad', icon: '😢', query: 'sad' },
    { id: 'angry', icon: '😠', query: 'angry' },
];

export function GifPanel({ visible, onSelectGif, onClose, height, progress: externalProgress }: GifPanelProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const [activeTab, setActiveTab] = useState<Tab>('gifs');

    const [searchQuery, setSearchQuery] = useState('');
    const [items, setItems] = useState<any[]>([]);
    const [favorites, setFavorites] = useState<any[]>([]);
    const [loading, setLoading] = useState(false);
    const [nextPos, setNextPos] = useState('');

    // Internal progress handles animation if no external progress provided
    const internalProgress = useSharedValue(0);
    const progress = externalProgress ?? internalProgress;

    // We keep it rendered while animating out
    const [isRendered, setIsRendered] = useState(visible);

    useEffect(() => {
        if (visible) setIsRendered(true);
    }, [visible]);

    useEffect(() => {
        loadFavorites();
    }, []);

    const loadFavorites = async () => {
        try {
            const stored = await AsyncStorage.getItem('vibe_favorite_gifs');
            if (stored) setFavorites(JSON.parse(stored));
        } catch (e) {
            console.error('Failed to load favorite GIFs', e);
        }
    };

    const toggleFavorite = async (item: any) => {
        const isFav = favorites.some(f => f.id === item.id);
        let newFavs;
        if (isFav) {
            newFavs = favorites.filter(f => f.id !== item.id);
        } else {
            newFavs = [...favorites, item];
        }
        setFavorites(newFavs);
        await AsyncStorage.setItem('vibe_favorite_gifs', JSON.stringify(newFavs));
    };

    useEffect(() => {
        if (externalProgress) return;
        progress.value = withTiming(visible ? 1 : 0, {
            duration: 260,
            easing: Easing.bezier(0.25, 0.1, 0.25, 1),
        });
    }, [visible, externalProgress]);

    const fetchContent = useCallback(async (query: string, pos?: string, tab: Tab = 'gifs') => {
        if (loading) return;
        setLoading(true);
        try {
            if (tab === 'favorites') {
                setItems(favorites);
                setLoading(false);
                return;
            }

            // Tenor Search
            const typeParam = tab === 'stickers' ? '&searchfilter=sticker' : '';
            // Note: Tenor uses 'searchfilter=sticker' to get stickers via search endpoint, 
            // or specific endpoint. Let's try to append "sticker" to query if needed or rely on type.

            let endpoint;
            if (query) {
                endpoint = `https://g.tenor.com/v1/search?q=${encodeURIComponent(query)}&key=${TENOR_API_KEY}&limit=20&pos=${pos || ''}${typeParam}`;
            } else {
                endpoint = `https://g.tenor.com/v1/trending?key=${TENOR_API_KEY}&limit=20&pos=${pos || ''}${typeParam}`;
            }

            const response = await fetch(endpoint);
            const data = await response.json();

            if (data.results) {
                setItems(prev => pos ? [...prev, ...data.results] : data.results);
                setNextPos(data.next);
            }
        } catch (error) {
            console.error('Error fetching content:', error);
        } finally {
            setLoading(false);
        }
    }, [loading, favorites]);

    // Initial load when visible or tab changes
    useEffect(() => {
        if (visible) {
            setItems([]);
            setNextPos('');
            fetchContent(searchQuery, '', activeTab);
        }
    }, [visible, activeTab]);

    // Debounced search
    useEffect(() => {
        const timeout = setTimeout(() => {
            if (visible) {
                setItems([]);
                setNextPos('');
                fetchContent(searchQuery, '', activeTab);
            }
        }, 500);
        return () => clearTimeout(timeout);
    }, [searchQuery]);


    const getMediaBundle = (item: any) => item?.media?.[0] || {};
    const getPreviewUrl = (item: any) => {
        const media = getMediaBundle(item);
        return media?.tinygif?.url || media?.nanogif?.url || media?.gif?.preview || media?.gif?.url || '';
    };

    const handleSelect = (item: any) => {
        const media = getMediaBundle(item);
        const selected = media?.gif || media?.mediumgif || media?.tinygif || media?.nanogif;
        const dims = selected?.dims || media?.gif?.dims || [512, 512];
        if (!selected?.url) return;

        onSelectGif({
            id: item.id,
            url: selected.url,
            preview: selected.preview || getPreviewUrl(item),
            width: dims[0],
            height: dims[1],
        });
    };

    const animatedStyle = useAnimatedStyle(() => {
        return {
            transform: [{ translateY: (1 - progress.value) * height }],
            height: height,
        };
    }, [height]);

    if (!isRendered && !visible) return null;

    const safeHeight = Math.min(height, SCREEN_HEIGHT * 0.62);
    const gridColumns = activeTab === 'stickers' ? 4 : 3;
    const sectionTitle = activeTab === 'stickers' ? 'TRENDING STICKERS' : activeTab === 'favorites' ? 'RECENTLY USED' : 'TRENDING GIFS';
    const featuredRecent = favorites.slice(0, 8);

    const TabButton = ({ tab, label }: { tab: Tab, label: string }) => {
        const isActive = activeTab === tab;
        return (
            <Pressable
                onPress={() => setActiveTab(tab)}
                style={[
                    styles.tabButton,
                    isActive && styles.tabButtonActive
                ]}
            >
                <Text style={[styles.tabLabel, { color: isActive ? colors.text : colors.textSecondary }]}>{label}</Text>
            </Pressable>
        );
    };

    const renderTopStrip = activeTab === 'stickers' && (
        <View style={styles.packStripWrap}>
            <SafeLiquidGlass
                style={[styles.packStripGlass, { borderColor: colors.borderStrong }]}
                blurIntensity={20}
                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
            >
                <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.packScrollContent}>
                    <View style={styles.utilityPill}>
                        <Plus size={18} color={colors.textSecondary} />
                    </View>
                    <View style={styles.utilityPill}>
                        <Clock3 size={18} color={colors.textSecondary} />
                    </View>
                    {STICKER_PACKS.map((pack) => (
                        <Pressable
                            key={pack.id}
                            onPress={() => {
                                setActiveTab('stickers');
                                setSearchQuery(pack.query);
                            }}
                            style={styles.packItem}
                        >
                            <View style={styles.packAvatar}>
                                <Text style={styles.packEmoji}>{pack.emoji}</Text>
                            </View>
                            <View style={styles.packAddBadge}>
                                <Plus size={12} color="#fff" />
                            </View>
                        </Pressable>
                    ))}
                </ScrollView>
            </SafeLiquidGlass>
        </View>
    );

    return (
        <Animated.View style={[styles.container, animatedStyle, { height: safeHeight }]}>
            <SafeLiquidGlass
                style={[styles.glassShell, { borderColor: colors.borderStrong }]}
                blurIntensity={26}
                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
            >
                {renderTopStrip}

                <View style={styles.header}>
                    <SafeLiquidGlass
                        style={[styles.searchContainer, { borderColor: colors.borderSubtle }]}
                        blurIntensity={18}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                    >
                        <Search size={18} color={colors.textSecondary} />
                        <TextInput
                            style={[styles.input, { color: colors.text }]}
                            placeholder={activeTab === 'stickers' ? "Search stickers..." : "Search GIFs..."}
                            placeholderTextColor={colors.textSecondary}
                            value={searchQuery}
                            onChangeText={setSearchQuery}
                            returnKeyType="search"
                        />
                        {searchQuery.length > 0 && (
                            <TouchableOpacity onPress={() => setSearchQuery('')}>
                                <X size={16} color={colors.textSecondary} />
                            </TouchableOpacity>
                        )}
                    </SafeLiquidGlass>

                    <SafeLiquidGlass
                        style={[styles.reactionBar, { borderColor: colors.borderSubtle }]}
                        blurIntensity={14}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                    >
                        {REACTION_FILTERS.map((filter) => (
                            <Pressable
                                key={filter.id}
                                onPress={() => setSearchQuery(filter.query)}
                                style={styles.reactionItem}
                            >
                                <Text style={[styles.reactionText, { color: colors.textSecondary }]}>{filter.icon}</Text>
                            </Pressable>
                        ))}
                    </SafeLiquidGlass>

                    <View style={styles.sectionHeader}>
                        <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>{sectionTitle}</Text>
                        <TouchableOpacity onPress={onClose} style={styles.sectionClose}>
                            <X size={24} color={colors.textSecondary} />
                        </TouchableOpacity>
                    </View>

                    {activeTab === 'stickers' && featuredRecent.length > 0 && (
                        <>
                            <Text style={[styles.recentTitle, { color: colors.textSecondary }]}>RECENTLY USED</Text>
                            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.recentScroll}>
                                {featuredRecent.map((item) => (
                                    <Pressable key={item.id} onPress={() => handleSelect(item)} style={styles.recentSticker}>
                                        <Image source={{ uri: getPreviewUrl(item) }} style={styles.recentStickerImage} resizeMode="contain" />
                                    </Pressable>
                                ))}
                            </ScrollView>
                        </>
                    )}
                </View>

                {activeTab === 'favorites' && items.length === 0 ? (
                    <View style={styles.centerParams}>
                        <Heart size={48} color={colors.textSecondary} style={{ opacity: 0.5, marginBottom: 12 }} />
                        <Text style={{ color: colors.textSecondary }}>No favorites yet</Text>
                        <Text style={{ color: colors.textTertiary, fontSize: 13, marginTop: 4 }}>
                            Long press a GIF to add favorites
                        </Text>
                    </View>
                ) : (
                    <FlatList
                        data={items}
                        key={`panel-${gridColumns}`}
                        numColumns={gridColumns}
                        keyExtractor={(item) => item.id}
                        renderItem={({ item }) => (
                            <Pressable
                                onPress={() => handleSelect(item)}
                                onLongPress={() => toggleFavorite(item)}
                                delayLongPress={200}
                                style={styles.gifItem}
                            >
                                <Image
                                    source={{ uri: getPreviewUrl(item) }}
                                    style={styles.gifImage}
                                    resizeMode="cover"
                                />
                                {favorites.some(f => f.id === item.id) && (
                                    <View style={styles.favOverlay}>
                                        <Heart size={12} color="white" fill="white" />
                                    </View>
                                )}
                            </Pressable>
                        )}
                        onEndReached={() => {
                            if (nextPos && activeTab !== 'favorites') fetchContent(searchQuery, nextPos, activeTab);
                        }}
                        onEndReachedThreshold={0.5}
                        contentContainerStyle={styles.listContent}
                        showsVerticalScrollIndicator={false}
                        ListFooterComponent={loading ? <ActivityIndicator color={colors.primary} style={{ margin: 20 }} /> : null}
                    />
                )}

                <SafeLiquidGlass
                    style={[styles.bottomBarContainer, { borderColor: colors.borderStrong }]}
                    blurIntensity={24}
                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                >
                    <View style={styles.tabsContainer}>
                        <TabButton tab="gifs" label="GIFs" />
                        <TabButton tab="stickers" label="Stickers" />
                        <TabButton tab="favorites" label="Emoji" />
                    </View>
                </SafeLiquidGlass>
            </SafeLiquidGlass>

        </Animated.View>
    );
}

const styles = StyleSheet.create({
    container: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        zIndex: 100,
        overflow: 'hidden',
        borderRadius: 26,

    },
    glassShell: {
        flex: 1,
        borderRadius: 26,
        borderWidth: 1,
        overflow: 'hidden',
    },
    header: {
        paddingHorizontal: 12,
        paddingTop: 10,
        gap: 10,
    },
    searchContainer: {
        flexDirection: 'row',
        alignItems: 'center',
        borderRadius: 24,
        paddingHorizontal: 12,
        borderWidth: 1,
        height: 52,
        gap: 8,
    },
    input: {
        flex: 1,
        fontSize: 16,
        paddingVertical: 0,
        fontWeight: '400',
    },
    listContent: {
        paddingHorizontal: 8,
        paddingBottom: 96,
        paddingTop: 6,
    },
    gifItem: {
        flex: 1,
        aspectRatio: 1.02,
        padding: 4,
    },
    gifImage: {
        flex: 1,
        borderRadius: 12,
        backgroundColor: 'rgba(0,0,0,0.12)',
    },
    favOverlay: {
        position: 'absolute',
        top: 10,
        right: 10,
        backgroundColor: 'rgba(0,0,0,0.5)',
        borderRadius: 10,
        padding: 4,
    },
    centerParams: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
        paddingBottom: 40
    },
    bottomBarContainer: {
        position: 'absolute',
        bottom: 10,
        alignSelf: 'center',
        width: SCREEN_WIDTH * 0.42,
        borderRadius: 30,
        borderWidth: 1,
        overflow: 'hidden',
    },
    tabsContainer: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        paddingHorizontal: 6,
        paddingVertical: 6,
    },
    tabButton: {
        paddingVertical: 9,
        borderRadius: 22,
        minWidth: 58,
        alignItems: 'center',
        justifyContent: 'center',
    },
    tabButtonActive: {
        backgroundColor: 'rgba(255,255,255,0.2)',
    },
    tabLabel: {
        fontSize: 14,
        fontWeight: '600',
    },
    packStripWrap: {
        paddingHorizontal: 12,
        paddingTop: 10,
        paddingBottom: 8,
    },
    packStripGlass: {
        borderRadius: 18,
        borderWidth: 1,
        overflow: 'hidden',
    },
    packScrollContent: {
        paddingHorizontal: 10,
        paddingVertical: 10,
        gap: 10,
        alignItems: 'center',
    },
    utilityPill: {
        width: 44,
        height: 44,
        borderRadius: 22,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(255,255,255,0.08)',
    },
    packItem: {
        width: 44,
        height: 44,
        justifyContent: 'center',
        alignItems: 'center',
    },
    packAvatar: {
        width: 40,
        height: 40,
        borderRadius: 20,
        backgroundColor: 'rgba(255,255,255,0.15)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    packEmoji: {
        fontSize: 22,
    },
    packAddBadge: {
        position: 'absolute',
        right: -4,
        bottom: -4,
        width: 18,
        height: 18,
        borderRadius: 9,
        backgroundColor: '#6f3f19',
        alignItems: 'center',
        justifyContent: 'center',
    },
    reactionBar: {
        borderRadius: 24,
        borderWidth: 1,
        height: 52,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-around',
        paddingHorizontal: 8,
    },
    reactionItem: {
        width: 34,
        alignItems: 'center',
        justifyContent: 'center',
    },
    reactionText: {
        fontSize: 20,
        lineHeight: 24,
    },
    sectionHeader: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        marginTop: 4,
    },
    sectionTitle: {
        fontSize: 14,
        letterSpacing: 1.4,
        fontWeight: '600',
    },
    sectionClose: {
        position: 'absolute',
        right: 0,
        paddingHorizontal: 4,
        paddingVertical: 4,
    },
    recentTitle: {
        fontSize: 14,
        letterSpacing: 1.2,
        fontWeight: '600',
        textAlign: 'center',
        marginTop: 4,
    },
    recentScroll: {
        paddingVertical: 8,
        gap: 10,
    },
    recentSticker: {
        width: 72,
        height: 72,
        borderRadius: 14,
        backgroundColor: 'rgba(255,255,255,0.08)',
        overflow: 'hidden',
    },
    recentStickerImage: {
        width: '100%',
        height: '100%',
    },
});
