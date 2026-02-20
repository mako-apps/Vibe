import React, { useState } from 'react';
import { View, Text, TouchableOpacity, StyleSheet, Dimensions, SafeAreaView, ScrollView } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useThemeStore } from '../src/lib/stores/theme-store';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import { ContactsIcon, CallsIcon, SettingsIcon } from '../src/components/Icons';
import DoubleChatIcon from '../src/components/icons/DoubleChatIcon';
import Animated, { useAnimatedStyle, withSpring, useSharedValue, withTiming } from 'react-native-reanimated';

const SCREEN_WIDTH = Dimensions.get('window').width;
const TAB_WIDTH = 60; // Slightly smaller to fit 5 items

const MOCK_TABS = ['contacts', 'calls', 'vibe', 'home', 'settings'];

export default function TabBarPreview() {
    const { colors, effectiveTheme } = useThemeStore();
    const router = useRouter();
    const isDark = effectiveTheme === 'dark';

    // Templates: 'glass' (Unified), 'split' (3-piece), 'dock' (Mac style), 'neon' (Glow)
    const [template, setTemplate] = useState<'glass' | 'split' | 'dock' | 'neon'>('glass');
    const [activeTab, setActiveTab] = useState('home');

    // Shared Value for indicator
    const activeIndex = useSharedValue(3); // 'home'

    const handleTabPress = (tab: string, index: number) => {
        if (tab === 'vibe') {
            console.log('Vibe pressed');
            return;
        }
        setActiveTab(tab);
        activeIndex.value = withSpring(index, { damping: 16, stiffness: 150 });
    };

    const renderIcon = (tab: string, focused: boolean, colorOverride?: string) => {
        const baseColor = isDark ? '#e5e5e5' : '#1a1a1a';
        const color = colorOverride || baseColor;

        switch (tab) {
            case 'contacts': return <ContactsIcon size={24} color={color} focused={focused} />;
            case 'calls': return <CallsIcon size={24} color={color} focused={focused} />;
            case 'home': return <DoubleChatIcon size={24} color={color} focused={focused} />;
            case 'settings': return <SettingsIcon size={24} color={color} focused={focused} imageUri={null} name="User" />;
            case 'vibe': return <Text style={{ fontSize: 18, fontWeight: '900', color: focused ? '#fff' : color }}>V</Text>;
            default: return null;
        }
    };

    // --- 1. UNIFIED GLASS PILL (Refined Current) ---
    const renderGlassBar = () => {
        // Filter out vibe for the indicator logic if needed, or include it
        const indicatorStyle = useAnimatedStyle(() => ({
            transform: [{ translateX: activeIndex.value * TAB_WIDTH }]
        }));

        return (
            <View style={styles.glassContainer}>
                <SafeLiquidGlass
                    style={[styles.glassPill, {
                        backgroundColor: isDark ? 'rgba(20,20,25,0.85)' : 'rgba(255,255,255,0.85)',
                        borderColor: isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.05)',
                        borderWidth: 1,
                    }]}
                    blurIntensity={40}
                    tint={isDark ? 'dark' : 'light'}
                >
                    {/* Animated Pill Indicator */}
                    <Animated.View style={[
                        styles.glassIndicator,
                        { backgroundColor: isDark ? 'rgba(255,255,255,0.15)' : 'rgba(0,0,0,0.05)' },
                        indicatorStyle
                    ]} />

                    {MOCK_TABS.map((tab, i) => {
                        const isVibe = tab === 'vibe';
                        if (isVibe) {
                            return (
                                <View key={tab} style={styles.glassTabButton}>
                                    <View style={[styles.vibeFabSmall, { backgroundColor: colors.text }]}>
                                        <Text style={{ color: colors.background, fontWeight: 'bold' }}>V</Text>
                                    </View>
                                </View>
                            )
                        }
                        return (
                            <TouchableOpacity
                                key={tab}
                                style={styles.glassTabButton}
                                onPress={() => handleTabPress(tab, i)}
                            >
                                <View style={[styles.iconWrapper, activeTab === tab && { transform: [{ scale: 1.1 }] }]}>
                                    {renderIcon(tab, activeTab === tab)}
                                </View>
                                {activeTab === tab && (
                                    <View style={[styles.activeDot, { backgroundColor: colors.text }]} />
                                )}
                            </TouchableOpacity>
                        )
                    })}
                </SafeLiquidGlass>
            </View>
        );
    };

    // --- 2. SPLIT DYNAMIC (Left Tabs - VIBE - Right Tabs) ---
    // User requested "Island has error" -> Replaced with Split Pill
    const renderSplitBar = () => {
        const leftTabs = ['contacts', 'calls'];
        const rightTabs = ['home', 'settings'];

        return (
            <View style={styles.splitContainer}>
                {/* Left Pill */}
                <SafeLiquidGlass
                    style={[styles.splitPill, { backgroundColor: isDark ? 'rgba(30,30,30,0.8)' : 'rgba(255,255,255,0.9)' }]}
                    blurIntensity={30}
                    tint={isDark ? 'dark' : 'light'}
                >
                    {leftTabs.map((tab, i) => (
                        <TouchableOpacity key={tab} style={styles.splitTabBtn} onPress={() => handleTabPress(tab, i)}>
                            {renderIcon(tab, activeTab === tab)}
                        </TouchableOpacity>
                    ))}
                </SafeLiquidGlass>

                {/* Center Vibe */}
                <TouchableOpacity style={[styles.vibeFabLarge, { backgroundColor: colors.primary }]}>
                    <Text style={{ fontSize: 20, fontWeight: 'bold', color: '#fff' }}>V</Text>
                </TouchableOpacity>

                {/* Right Pill */}
                <SafeLiquidGlass
                    style={[styles.splitPill, { backgroundColor: isDark ? 'rgba(30,30,30,0.8)' : 'rgba(255,255,255,0.9)' }]}
                    blurIntensity={30}
                    tint={isDark ? 'dark' : 'light'}
                >
                    {rightTabs.map((tab, i) => (
                        <TouchableOpacity key={tab} style={styles.splitTabBtn} onPress={() => handleTabPress(tab, i + 3)}>
                            {renderIcon(tab, activeTab === tab)}
                        </TouchableOpacity>
                    ))}
                </SafeLiquidGlass>
            </View>
        );
    }

    // --- 3. DOCK (Floating macOS Style) ---
    const renderDockBar = () => {
        return (
            <View style={styles.dockContainer}>
                <View style={[styles.dockBar, { backgroundColor: isDark ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.8)' }]}>
                    {MOCK_TABS.map((tab, i) => {
                        const isActive = activeTab === tab;
                        const isVibe = tab === 'vibe';

                        if (isVibe) {
                            return (
                                <View key={tab} style={styles.dockItem}>
                                    <View style={[styles.dockVibe, { backgroundColor: colors.text }]}>
                                        <Text style={{ color: colors.background, fontWeight: 'bold', fontSize: 16 }}>V</Text>
                                    </View>
                                </View>
                            )
                        }

                        return (
                            <TouchableOpacity
                                key={tab}
                                style={styles.dockItem}
                                onPress={() => handleTabPress(tab, i)}
                            >
                                <Animated.View
                                    style={[
                                        styles.dockIconBox,
                                        isActive && {
                                            backgroundColor: isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.05)',
                                            transform: [{ translateY: -5 }, { scale: 1.15 }]
                                        }
                                    ]}
                                >
                                    {renderIcon(tab, isActive)}
                                </Animated.View>
                                {isActive && <View style={[styles.dockDot, { backgroundColor: colors.primary }]} />}
                            </TouchableOpacity>
                        )
                    })}
                </View>
            </View>
        );
    }

    // --- 4. NEON (Text & Glow, Minimal) ---
    const renderNeonBar = () => {
        return (
            <View style={[styles.neonContainer, { backgroundColor: isDark ? '#000' : '#fff', borderTopColor: colors.border }]}>
                {MOCK_TABS.map((tab, i) => {
                    const isVibe = tab === 'vibe';
                    const isActive = activeTab === tab;

                    if (isVibe) return (
                        <View key={tab} style={{ width: 60, alignItems: 'center', bottom: 20 }}>
                            <View style={[styles.neonFab, { backgroundColor: colors.primary, shadowColor: colors.primary }]}>
                                <Text style={{ color: '#fff', fontWeight: 'bold' }}>V</Text>
                            </View>
                        </View>
                    );

                    return (
                        <TouchableOpacity
                            key={tab}
                            style={styles.neonButton}
                            onPress={() => handleTabPress(tab, i)}
                        >
                            <View style={isActive && styles.neonActiveBg}>
                                {renderIcon(tab, isActive, isActive ? colors.primary : colors.textSecondary)}
                            </View>
                            {isActive && <Text style={{ fontSize: 10, color: colors.primary, marginTop: 2 }}>{tab}</Text>}
                        </TouchableOpacity>
                    )
                })}
            </View>
        );
    }

    return (
        <SafeAreaView style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{
                headerShown: true,
                title: 'Vibe UI Lab',
                headerStyle: { backgroundColor: colors.background },
                headerTintColor: colors.text,
                headerShadowVisible: false
            }} />

            <ScrollView contentContainerStyle={{ padding: 20, paddingBottom: 150 }}>
                <Text style={[styles.header, { color: colors.text }]}>Bottom Bar Styles</Text>

                <View style={styles.controls}>
                    {(['glass', 'split', 'dock', 'neon'] as const).map((t) => (
                        <TouchableOpacity
                            key={t}
                            style={[
                                styles.controlBtn,
                                template === t && { backgroundColor: colors.primary, borderColor: colors.primary, opacity: 1 },
                                { borderColor: colors.border, opacity: 0.6 }
                            ]}
                            onPress={() => setTemplate(t)}
                        >
                            <Text style={{
                                color: template === t ? '#fff' : colors.text,
                                fontWeight: '600',
                                fontSize: 12
                            }}>{t.toUpperCase()}</Text>
                        </TouchableOpacity>
                    ))}
                </View>

                {/* Preview Content Area */}
                <View style={[styles.contentArea, { borderColor: colors.border }]}>
                    <Text style={{ color: colors.textTertiary }}>App Content Area</Text>
                    <View style={{ width: 100, height: 100, borderRadius: 50, backgroundColor: colors.surface, marginTop: 20 }} />
                </View>

                <View style={{ marginTop: 30 }}>
                    <Text style={{ color: colors.textSecondary, marginBottom: 10 }}>Double Chat Icon Test:</Text>
                    <View style={{ flexDirection: 'row', gap: 20, backgroundColor: colors.card, padding: 20, borderRadius: 12 }}>
                        <DoubleChatIcon size={40} color={colors.text} focused={false} />
                        <DoubleChatIcon size={40} color={colors.text} focused={true} />
                        <View style={{ justifyContent: 'center' }}>
                            <Text style={{ color: colors.text, fontSize: 12 }}>Inactive vs Active</Text>
                        </View>
                    </View>
                </View>

            </ScrollView>

            {/* Render Active Template Fixed at Bottom */}
            {template === 'glass' && renderGlassBar()}
            {template === 'split' && renderSplitBar()}
            {template === 'dock' && renderDockBar()}
            {template === 'neon' && renderNeonBar()}

        </SafeAreaView>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    header: {
        fontSize: 24,
        fontWeight: 'bold',
        marginBottom: 20,
    },
    controls: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 10,
        marginBottom: 30,
    },
    controlBtn: {
        paddingVertical: 8,
        paddingHorizontal: 12,
        borderRadius: 16,
        borderWidth: 1,
    },
    contentArea: {
        height: 300,
        borderWidth: 1,
        borderStyle: 'dashed',
        borderRadius: 20,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(128,128,128,0.05)'
    },

    // 1. GLASS
    glassContainer: {
        position: 'absolute',
        bottom: 30,
        left: 0,
        right: 0,
        alignItems: 'center',
    },
    glassPill: {
        flexDirection: 'row',
        height: 64,
        borderRadius: 32,
        padding: 4,
        alignItems: 'center',
        shadowColor: "#000",
        shadowOffset: { width: 0, height: 8 },
        shadowOpacity: 0.2,
        shadowRadius: 15,
        elevation: 10,
    },
    glassIndicator: {
        position: 'absolute',
        top: 4,
        left: 4,
        width: TAB_WIDTH,
        height: 56,
        borderRadius: 28,
    },
    glassTabButton: {
        width: TAB_WIDTH,
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
    },
    vibeFabSmall: {
        width: 44,
        height: 44,
        borderRadius: 22,
        alignItems: 'center',
        justifyContent: 'center',
    },
    iconWrapper: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    activeDot: {
        width: 4,
        height: 4,
        borderRadius: 2,
        position: 'absolute',
        bottom: 8
    },

    // 2. SPLIT
    splitContainer: {
        position: 'absolute',
        bottom: 30,
        left: 20,
        right: 20,
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center'
    },
    splitPill: {
        flexDirection: 'row',
        height: 56,
        borderRadius: 28,
        paddingHorizontal: 10,
        alignItems: 'center',
        gap: 10
    },
    splitTabBtn: {
        padding: 10,
    },
    vibeFabLarge: {
        width: 64,
        height: 64,
        borderRadius: 32,
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: "#000",
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.3,
        shadowRadius: 8,
        elevation: 5,
        marginBottom: 20
    },

    // 3. DOCK
    dockContainer: {
        position: 'absolute',
        bottom: 30,
        width: '100%',
        alignItems: 'center'
    },
    dockBar: {
        flexDirection: 'row',
        padding: 10,
        borderRadius: 24,
        gap: 10,
        backdropFilter: 'blur(20px)', // iOS only
    },
    dockItem: {
        alignItems: 'center',
        justifyContent: 'flex-end',
        height: 50,
        width: 50,
    },
    dockIconBox: {
        width: 44,
        height: 44,
        borderRadius: 12,
        alignItems: 'center',
        justifyContent: 'center',
    },
    dockVibe: {
        width: 48,
        height: 48,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center',
        marginBottom: 5,
        shadowColor: "#000",
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.2,
        shadowRadius: 4,
    },
    dockDot: {
        width: 4,
        height: 4,
        borderRadius: 2,
        marginTop: 4
    },

    // 4. NEON
    neonContainer: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: 85,
        flexDirection: 'row',
        justifyContent: 'space-around',
        alignItems: 'flex-start',
        paddingTop: 15,
        borderTopWidth: 0.5,
    },
    neonButton: {
        flex: 1,
        alignItems: 'center'
    },
    neonActiveBg: {
        position: 'absolute',
        top: -15, // Glow spills up
        width: 40,
        height: 40,
        borderRadius: 20,
        backgroundColor: 'rgba(0,0,0,0)', // placeholder
    },
    neonFab: {
        width: 48,
        height: 48,
        borderRadius: 24,
        alignItems: 'center',
        justifyContent: 'center',
        shadowOffset: { width: 0, height: 0 },
        shadowOpacity: 0.6,
        shadowRadius: 10,
        elevation: 8
    }
});
