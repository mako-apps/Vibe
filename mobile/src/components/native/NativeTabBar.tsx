/**
 * NativeTabBar - Native Bottom Tab Bar with Fallback
 *
 * Uses `react-native-bottom-tabs` TabView for production builds (native module).
 * On iOS 18+, this automatically renders the liquid glass tab bar via UITabBarController.
 * On Android, it renders Material 3 BottomNavigationView.
 *
 * Falls back to a custom glass pill UI in Expo Go / dev environments where the
 * native module isn't available.
 *
 * Usage:
 *   <NativeTabBar
 *     currentIndex={index}
 *     onIndexChange={setIndex}
 *     tabs={[
 *       { key: 'home', title: 'Home', sfSymbol: 'house', badge: '3' },
 *       { key: 'settings', title: 'Settings', sfSymbol: 'gear' },
 *     ]}
 *     activeTintColor="#007AFF"
 *     inactiveTintColor="#8E8E93"
 *     onVibePress={() => router.push('/agent')}
 *   />
 */

import React, { useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet, type ImageSourcePropType } from 'react-native';
import Animated, {
    useAnimatedStyle,
    interpolate,
    Extrapolation,
} from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import SafeLiquidGlass from './SafeLiquidGlass';

import Constants from 'expo-constants';

// ─── Dynamic import of native module ────────────────────────────────────────
let NativeTabView: React.ComponentType<any> | null = null;
let NativeSceneMap: ((scenes: Record<string, React.ComponentType<any>>) => any) | null = null;
let nativeTabsAvailable = false;

try {
    // If we are in Expo Go, forced fallback effectively
    const isExpoGo = Constants.appOwnership === 'expo';

    if (!isExpoGo) {
        const bottomTabs = require('react-native-bottom-tabs');
        if (bottomTabs?.default) {
            NativeTabView = bottomTabs.default;
            NativeSceneMap = bottomTabs.SceneMap || null;
            nativeTabsAvailable = true;
            console.log('[NativeTabBar] ✅ Native bottom tabs available');
        }
    } else {
        console.log('[NativeTabBar] ℹ️ Running in Expo Go, using fallback tabs');
    }
} catch (e) {
    nativeTabsAvailable = false;
    console.log('[NativeTabBar] ℹ️ Native bottom tabs not available, using fallback');
}

// ─── Types ──────────────────────────────────────────────────────────────────

export interface TabConfig {
    /** Unique key for the tab */
    key: string;
    /** Display title */
    title: string;
    /** SF Symbol name for iOS (e.g. 'house', 'gear', 'person.2') */
    sfSymbol?: string;
    /** SF Symbol name when unfocused (optional) */
    unfocusedSfSymbol?: string;
    /** Badge text (e.g. '3', '99+') - pass undefined for no badge */
    badge?: string;
    /** Native image icon source for focused state (native mode) */
    iconSource?: ImageSourcePropType;
    /** Native image icon source for unfocused state (native mode) */
    unfocusedIconSource?: ImageSourcePropType;
    /** Prevent default native tab selection behavior (native mode) */
    preventsDefault?: boolean;
    /** Custom icon render for fallback mode */
    renderIcon?: (props: { focused: boolean; color: string; size: number }) => React.ReactNode;
}

export interface NativeTabBarProps {
    /** Currently selected tab index */
    currentIndex: number;
    /** Callback when tab changes */
    onIndexChange: (index: number) => void;
    /** Tab configuration */
    tabs: TabConfig[];
    /** Active tab tint color (applied to icon + label) */
    activeTintColor?: string;
    /** Inactive tab tint color */
    inactiveTintColor?: string;
    /** Active indicator color (Android) */
    activeIndicatorColor?: string;
    /** Show labels below icons */
    labeled?: boolean;
    /** Enable haptic feedback */
    hapticFeedback?: boolean;
    /** Translucent tab bar */
    translucent?: boolean;
    /** Whether dark mode is active (used by fallback) */
    isDark?: boolean;
    /** Tab bar animated translateX value for syncing indicator (fallback only) */
    translateX?: SharedValue<number>;
    /** Screen width for indicator calculation (fallback only) */
    screenWidth?: number;
    /** Scene components mapped to tab keys (native only) */
    scenes?: Record<string, React.ComponentType<any>>;
    /** Handler for Vibe button press */
    onVibePress?: () => void;
    /** Renders children content (fallback mode wraps them) */
    children?: React.ReactNode;
    /** Optional tab width override for fallback mode */
    fallbackTabWidth?: number;
}

// ─── Constants ──────────────────────────────────────────────────────────────
const FALLBACK_TAB_WIDTH = 70;

function normalizeImageUri(value: string): string {
    if (
        value.startsWith('http://')
        || value.startsWith('https://')
        || value.startsWith('file://')
        || value.startsWith('content://')
        || value.startsWith('data:')
    ) {
        return value;
    }
    return `data:image/jpeg;base64,${value}`;
}

function normalizeIconSource(source?: ImageSourcePropType): ImageSourcePropType | undefined {
    if (!source) {
        return undefined;
    }
    if (typeof source === 'number') {
        return source;
    }
    if (Array.isArray(source)) {
        return source.map((entry) => {
            if (!entry || typeof entry.uri !== 'string') {
                return entry;
            }
            return {
                ...entry,
                uri: normalizeImageUri(entry.uri),
            };
        });
    }

    const uri = source.uri;
    if (typeof uri !== 'string') {
        return source;
    }
    return {
        ...source,
        uri: normalizeImageUri(uri),
    };
}

function isVibeTab(tab: TabConfig): boolean {
    return tab.key.trim().toLowerCase() === 'vibe' || tab.preventsDefault === true;
}

// ─── Export availability check ──────────────────────────────────────────────
export function isNativeTabBarAvailable(): boolean {
    return nativeTabsAvailable;
}

// ─── Component ──────────────────────────────────────────────────────────────

export default function NativeTabBar({
    currentIndex,
    onIndexChange,
    tabs,
    activeTintColor = '#007AFF',
    inactiveTintColor = '#8E8E93',
    activeIndicatorColor,
    labeled = true,
    hapticFeedback = true,
    translucent = true,
    isDark = false,
    translateX,
    screenWidth,
    scenes,
    onVibePress,
    children,
    fallbackTabWidth,
}: NativeTabBarProps) {
    const vibeIndex = tabs.findIndex(isVibeTab);
    const vibeTab = vibeIndex >= 0 ? tabs[vibeIndex] : undefined;
    const mainTabs = vibeIndex >= 0 ? tabs.filter((_, index) => index !== vibeIndex) : tabs;
    const mappedCurrentIndex = vibeIndex >= 0 && currentIndex > vibeIndex
        ? currentIndex - 1
        : currentIndex;
    const nativeCurrentIndex = mainTabs.length > 0
        ? Math.max(0, Math.min(mainTabs.length - 1, mappedCurrentIndex))
        : 0;
    const mapMainIndexToOriginal = (index: number) =>
        (vibeIndex >= 0 && index >= vibeIndex ? index + 1 : index);
    const handleSeparateVibePress = () => {
        if (onVibePress) {
            onVibePress();
            return;
        }
        if (vibeIndex >= 0) {
            onIndexChange(vibeIndex);
        }
    };

    // ═══════════════════════════════════════════════════════════════
    // NATIVE MODE: Use react-native-bottom-tabs TabView
    // ═══════════════════════════════════════════════════════════════
    if (nativeTabsAvailable && NativeTabView && scenes && mainTabs.length > 0) {
        const nativeTabs = useMemo(() => {
            return mainTabs.map(tab => ({
                key: tab.key,
                title: tab.title,
                focusedIcon: normalizeIconSource(tab.iconSource)
                    || (tab.sfSymbol ? { sfSymbol: tab.sfSymbol } : undefined),
                unfocusedIcon: normalizeIconSource(tab.unfocusedIconSource)
                    || normalizeIconSource(tab.iconSource)
                    || (tab.unfocusedSfSymbol ? { sfSymbol: tab.unfocusedSfSymbol } : undefined),
                badge: tab.badge,
                preventsDefault: tab.preventsDefault,
            }));
        }, [mainTabs]);

        const handleNativeIndexChange = (index: number) => {
            onIndexChange(mapMainIndexToOriginal(index));
        };

        const renderScene = NativeSceneMap
            ? NativeSceneMap(scenes)
            : ({ route }: { route: { key: string } }) => {
                const Scene = scenes[route.key];
                return Scene ? <Scene /> : null;
            };

        return (
            <View style={styles.nativeShell}>
                <NativeTabView
                    navigationState={{ index: nativeCurrentIndex, routes: nativeTabs }}
                    renderScene={renderScene}
                    onIndexChange={handleNativeIndexChange}
                    labeled={labeled}
                    hapticFeedbackEnabled={hapticFeedback}
                    translucent={translucent}
                    tabBarActiveTintColor={activeTintColor}
                    tabBarInactiveTintColor={inactiveTintColor}
                    activeIndicatorColor={activeIndicatorColor}
                />
                {vibeTab && (
                    <View pointerEvents="box-none" style={styles.nativeVibeOverlay}>
                        <TouchableOpacity
                            activeOpacity={0.85}
                            style={fallbackStyles.vibeButtonContainer}
                            onPress={handleSeparateVibePress}
                        >
                            <SafeLiquidGlass
                                style={[
                                    fallbackStyles.vibeButtonPill,
                                    {
                                        backgroundColor: isDark ? 'rgba(18,20,28,0.6)' : 'rgba(244,248,255,0.66)',
                                        borderColor: isDark ? 'rgba(255,255,255,0.13)' : 'rgba(10,18,32,0.11)',
                                        borderWidth: 1,
                                    },
                                ]}
                                blurIntensity={18}
                                tint={isDark ? 'dark' : 'light'}
                            >
                                {vibeTab.renderIcon
                                    ? vibeTab.renderIcon({
                                        focused: false,
                                        color: isDark ? '#fff' : '#000',
                                        size: 22,
                                    })
                                    : (
                                        <Text style={[fallbackStyles.vibeText, { color: isDark ? '#fff' : '#000' }]}>
                                            {vibeTab.title || 'Vibe'}
                                        </Text>
                                    )}
                            </SafeLiquidGlass>
                        </TouchableOpacity>
                    </View>
                )}
            </View>
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // FALLBACK MODE: Custom glass pill tab bar
    // ═══════════════════════════════════════════════════════════════
    // If nativeTabsAvailable is false, or scenes not provided (Expo Go usually)

    return (
        <FallbackTabBar
            currentIndex={currentIndex}
            onIndexChange={onIndexChange}
            tabs={tabs}
            activeTintColor={activeTintColor}
            inactiveTintColor={inactiveTintColor}
            isDark={isDark}
            translateX={translateX}
            screenWidth={screenWidth}
            labeled={labeled}
            onVibePress={onVibePress}
            fallbackTabWidth={fallbackTabWidth}
        />
    );
}

// ─── Fallback Glass Pill Tab Bar ────────────────────────────────────────────

type FallbackTabBarProps = NativeTabBarProps;

function FallbackTabBar({
    currentIndex,
    onIndexChange,
    activeTintColor,
    inactiveTintColor,
    isDark,
    translateX,
    screenWidth = 1,
    labeled = true,
    tabs,
    onVibePress,
    fallbackTabWidth,
}: FallbackTabBarProps) {
    const tabWidth = fallbackTabWidth ?? FALLBACK_TAB_WIDTH;
    const vibeIndex = tabs.findIndex(isVibeTab);
    const vibeTab = vibeIndex >= 0 ? tabs[vibeIndex] : undefined;
    const mainTabs = vibeIndex >= 0 ? tabs.filter((_, index) => index !== vibeIndex) : tabs;
    const mainTabCount = mainTabs.length;
    const shiftedCurrentIndex = vibeIndex >= 0 && currentIndex > vibeIndex
        ? currentIndex - 1
        : currentIndex;
    const hasFocusedMainTab = shiftedCurrentIndex >= 0 && shiftedCurrentIndex < mainTabCount;
    const focusedMainIndex = hasFocusedMainTab ? shiftedCurrentIndex : 0;

    const indicatorStyle = useAnimatedStyle(() => {
        if (mainTabCount <= 0) {
            return { transform: [{ translateX: 0 }] };
        }
        if (!translateX) {
            return { transform: [{ translateX: focusedMainIndex * tabWidth }] };
        }

        const inputRange = Array.from({ length: mainTabCount }, (_, i) => i * screenWidth);
        const outputRange = Array.from({ length: mainTabCount }, (_, i) => i);

        const index = interpolate(
            Math.abs(translateX.value),
            inputRange,
            outputRange,
            Extrapolation.CLAMP
        );

        return {
            transform: [{ translateX: index * tabWidth }]
        };
    }, [focusedMainIndex, mainTabCount, screenWidth, tabWidth, translateX]);

    const handleVibePress = () => {
        if (onVibePress) {
            onVibePress();
            return;
        }
        if (vibeIndex >= 0) {
            onIndexChange(vibeIndex);
        }
    };

    return (
        <View style={fallbackStyles.row}>
            {mainTabs.length > 0 && (
                <SafeLiquidGlass
                    style={[
                        fallbackStyles.pill,
                        {
                            backgroundColor: isDark ? 'rgba(30,30,30,0.85)' : 'rgba(255,255,255,0.85)',
                            borderColor: isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)',
                            borderWidth: 0.5,
                        }
                    ]}
                    blurIntensity={25}
                    tint={isDark ? 'dark' : 'light'}
                >
                    <Animated.View
                        style={[
                            fallbackStyles.indicator,
                            {
                                backgroundColor: isDark ? 'rgba(255,255,255,0.1)' : '#fff',
                                width: tabWidth,
                            },
                            indicatorStyle
                        ]}
                    />

                    {mainTabs.map((tab, i) => {
                        const isFocused = hasFocusedMainTab && shiftedCurrentIndex === i;
                        const color = isFocused
                            ? (activeTintColor || (isDark ? '#e5e5e5' : '#000'))
                            : (inactiveTintColor || '#8E8E93');
                        const originalIndex = vibeIndex >= 0 && i >= vibeIndex ? i + 1 : i;

                        return (
                            <TouchableOpacity
                                key={tab.key}
                                style={[fallbackStyles.tabButton, { width: tabWidth }]}
                                onPress={() => onIndexChange(originalIndex)}
                            >
                                <View style={{ alignItems: 'center' }}>
                                    {tab.renderIcon
                                        ? tab.renderIcon({ focused: isFocused, color, size: 20 })
                                        : null
                                    }
                                    {tab.badge && (
                                        <View style={fallbackStyles.badge}>
                                            <Text style={fallbackStyles.badgeText}>
                                                {tab.badge}
                                            </Text>
                                        </View>
                                    )}
                                </View>
                                {labeled && (
                                    <Text style={[fallbackStyles.label, { color }]}>
                                        {tab.title}
                                    </Text>
                                )}
                            </TouchableOpacity>
                        );
                    })}
                </SafeLiquidGlass>
            )}

            {vibeTab && (
                <TouchableOpacity
                    activeOpacity={0.85}
                    style={fallbackStyles.vibeButtonContainer}
                    onPress={handleVibePress}
                >
                    <SafeLiquidGlass
                        style={[
                            fallbackStyles.vibeButtonPill,
                            {
                                backgroundColor: isDark ? 'rgba(18,20,28,0.6)' : 'rgba(244,248,255,0.66)',
                                borderColor: isDark ? 'rgba(255,255,255,0.13)' : 'rgba(10,18,32,0.11)',
                                borderWidth: 1,
                            },
                        ]}
                        blurIntensity={18}
                        tint={isDark ? 'dark' : 'light'}
                    >
                        {vibeTab.renderIcon
                            ? vibeTab.renderIcon({
                                focused: false,
                                color: isDark ? '#fff' : '#000',
                                size: 22,
                            })
                            : (
                                <Text style={[fallbackStyles.vibeText, { color: isDark ? '#fff' : '#000' }]}>
                                    {vibeTab.title || 'Vibe'}
                                </Text>
                            )}
                    </SafeLiquidGlass>
                </TouchableOpacity>
            )}
        </View>
    );
}

// ─── Fallback Styles ────────────────────────────────────────────────────────

const styles = StyleSheet.create({
    nativeShell: {
        flex: 1,
    },
    nativeVibeOverlay: {
        position: 'absolute',
        right: 12,
        bottom: 25,
    },
});

const fallbackStyles = StyleSheet.create({
    row: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    pill: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 5,
        borderRadius: 32,
        height: 64,
        overflow: 'hidden',
        position: 'relative',
    },
    indicator: {
        position: 'absolute',
        top: 5,
        left: 5,
        height: 54,
        borderRadius: 27,
    },
    tabButton: {
        borderRadius: 32,
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 4,
        zIndex: 10,
    },
    label: {
        fontSize: 10,
        fontWeight: '600',
        marginTop: 2,
    },
    badge: {
        position: 'absolute',
        top: -6,
        right: -10,
        backgroundColor: '#ef4444',
        borderRadius: 10,
        paddingHorizontal: 5,
        paddingVertical: 1,
        minWidth: 18,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 1.5,
        borderColor: '#fff',
    },
    badgeText: {
        color: '#fff',
        fontSize: 10,
        fontWeight: 'bold',
    },
    vibeButtonContainer: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    vibeButtonPill: {
        width: 64,
        height: 64,
        borderRadius: 32,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
    },
    vibeText: {
        fontSize: 16,
        fontWeight: '800',
        textTransform: 'lowercase',
        letterSpacing: -0.5,
    }
});
