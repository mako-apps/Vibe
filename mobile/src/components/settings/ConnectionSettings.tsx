import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, Switch, TouchableOpacity, useWindowDimensions, Platform } from 'react-native';
import { Server, Check, Plus, Signal, Router, ArrowLeft, Trash } from 'lucide-react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Animated, { useAnimatedStyle, useSharedValue, withTiming, interpolate, Extrapolate, SlideInRight, SlideOutRight } from 'react-native-reanimated';
import AnimatedGlassButton from '../../components/native/AnimatedGlassButton';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';

const MaskedViewAny = MaskedView as any;

interface ProxyItem {
    id: string;
    name: string;
    host: string;
    port: number;
    ping?: number;
    type: 'system' | 'custom';
}

const DEFAULT_PROXIES: ProxyItem[] = [
    { id: '1', name: 'US East (Virginia)', host: 'us-east.vibe.com', port: 443, type: 'system' },
    { id: '2', name: 'EU West (London)', host: 'eu-west.vibe.com', port: 443, type: 'system' },
    { id: '3', name: 'Asia Pacific (Tokyo)', host: 'ap-northeast.vibe.com', port: 443, type: 'system' },
];

const withAlpha = (color: string, alpha: number) => {
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

export default function ConnectionSettings() {
    const { colors, effectiveTheme } = useThemeStore();
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const [proxyEnabled, setProxyEnabled] = useState(false);
    const [selectedProxyId, setSelectedProxyId] = useState<string>('1');
    const [proxies, setProxies] = useState<ProxyItem[]>(DEFAULT_PROXIES);

    const scrollY = useSharedValue(0);

    // Simulate Ping
    useEffect(() => {
        const interval = setInterval(() => {
            setProxies(prev => prev.map(p => ({
                ...p,
                ping: Math.floor(Math.random() * 100) + 20
            })));
        }, 3000);
        return () => clearInterval(interval);
    }, []);

    const headerTitleStyle = useAnimatedStyle(() => {
        return {
            opacity: interpolate(scrollY.value, [0, 20], [0, 1], Extrapolate.CLAMP),
            transform: [{ translateY: interpolate(scrollY.value, [0, 20], [10, 0], Extrapolate.CLAMP) }]
        };
    });

    const ProxyRow = ({ item, isLast }: { item: ProxyItem, isLast: boolean }) => {
        const isSelected = selectedProxyId === item.id;
        const pingColor = (item.ping || 0) < 60 ? '#22c55e' : (item.ping || 0) < 150 ? '#f59e0b' : '#ef4444';

        return (
            <View>
                <TouchableOpacity
                    activeOpacity={0.7}
                    onPress={() => setSelectedProxyId(item.id)}
                    style={styles.settingRow}
                >
                    <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(colors.text, 0.05) }]}>
                        <Server size={18} color={item.type === 'system' ? colors.text : colors.primary} />
                    </View>

                    <View style={{ flex: 1 }}>
                        <Text style={[styles.settingLabel, { color: colors.text }]}>{item.name}</Text>
                        <Text style={{ fontSize: 11, color: colors.textSecondary, marginTop: 2 }}>{item.host}</Text>
                    </View>

                    <View style={{ alignItems: 'flex-end', flexDirection: 'row', gap: 8 }}>
                        {item.ping && (
                            <View style={{ flexDirection: 'row', alignItems: 'center', backgroundColor: withAlpha(pingColor, 0.1), paddingHorizontal: 6, paddingVertical: 2, borderRadius: 4 }}>
                                <Signal size={10} color={pingColor} />
                                <Text style={{ fontSize: 10, color: pingColor, marginLeft: 4, fontWeight: '600' }}>{item.ping}ms</Text>
                            </View>
                        )}
                        {isSelected && <Check size={18} color={colors.primary} />}
                    </View>
                </TouchableOpacity>
                {!isLast && <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />}
            </View>
        );
    };

    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            {/* MASKED HEADER */}
            <View style={[styles.headerContainer, { height: insets.top + 50, zIndex: 60, pointerEvents: 'none' }]}>
                <MaskedViewAny
                    style={StyleSheet.absoluteFill}
                    maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.85, 1]} style={StyleSheet.absoluteFill} />}
                >
                    <BlurView intensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.8) }]} />
                </MaskedViewAny>
            </View>

            {/* HEADER CONTENT */}
            <View style={[styles.headerContentContainer, { height: insets.top + 50, paddingTop: insets.top, zIndex: 130 }]} pointerEvents="box-none">
                <View style={styles.headerBtnWrapper}>
                    <AnimatedGlassButton
                        onPress={() => router.back()}
                        homeIcon={<ArrowLeft color={colors.text} size={22} />}
                        effectiveTheme={effectiveTheme}
                        size={40}
                    />
                </View>
                <View style={styles.headerCenterWrapper}>
                    <Animated.Text style={[styles.headerTitle, { color: colors.text }, headerTitleStyle]}>Connection</Animated.Text>
                </View>
                <View style={styles.headerBtnWrapper} />
            </View>

            <Animated.ScrollView
                onScroll={(e) => { scrollY.value = e.nativeEvent.contentOffset.y }}
                scrollEventThrottle={16}
                contentContainerStyle={{ paddingTop: insets.top + 60, paddingBottom: 100, paddingHorizontal: 16 }}
                showsVerticalScrollIndicator={false}
            >
                <Text style={[styles.pageTitle, { color: colors.text }]}>Connection</Text>

                {/* Configuration Section */}
                <View style={styles.sectionWrapper}>
                    <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>CONFIGURATION</Text>
                    <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                        <View style={[styles.settingRow]}>
                            <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                <Router size={18} color={colors.primary} />
                            </View>
                            <View style={{ flex: 1 }}>
                                <Text style={[styles.settingLabel, { color: colors.text }]}>Use Custom Proxy</Text>
                                <Text style={[styles.settingValue, { color: colors.textSecondary, fontSize: 13, marginTop: 2 }]}>
                                    Route traffic through a specific server
                                </Text>
                            </View>
                            <Switch
                                value={proxyEnabled}
                                onValueChange={setProxyEnabled}
                                trackColor={{ false: '#767577', true: colors.primary }}
                                thumbColor={Platform.OS === 'ios' ? '#fff' : (proxyEnabled ? colors.primary : '#f4f3f4')}
                            />
                        </View>
                    </View>
                </View>

                {proxyEnabled && (
                    <Animated.View entering={SlideInRight} exiting={SlideOutRight}>
                        <View style={styles.sectionWrapper}>
                            <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>AVAILABLE NODES</Text>
                            <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                                {proxies.map((item, index) => (
                                    <ProxyRow
                                        key={item.id}
                                        item={item}
                                        isLast={index === proxies.length - 1}
                                    />
                                ))}
                            </View>
                        </View>

                        <View style={[styles.sectionWrapper]}>
                            <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                                <TouchableOpacity
                                    style={styles.settingRow}
                                    activeOpacity={0.7}
                                    onPress={() => { }}
                                >
                                    <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                        <Plus size={18} color={colors.primary} />
                                    </View>
                                    <Text style={[styles.settingLabel, { color: colors.primary }]}>Add Custom Node</Text>
                                </TouchableOpacity>
                            </View>
                        </View>
                    </Animated.View>
                )}
            </Animated.ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16 },
    headerBtnWrapper: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    headerCenterWrapper: { flex: 1, alignItems: 'center', justifyContent: 'center' },
    headerTitle: { fontSize: 17, fontWeight: '600' },
    pageTitle: { fontSize: 32, fontWeight: 'bold', marginBottom: 24, paddingLeft: 8 },

    sectionWrapper: { marginBottom: 24 },
    sectionHeader: { fontSize: 13, fontWeight: '600', marginBottom: 8, marginLeft: 16, opacity: 0.6, letterSpacing: 0.5, textTransform: 'uppercase' },
    sectionContainer: { borderRadius: 16, overflow: 'hidden' },
    settingRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, paddingHorizontal: 16, minHeight: 56 },
    divider: { height: 1, marginLeft: 56 },
    settingIconContainer: { width: 32, height: 32, borderRadius: 8, alignItems: 'center', justifyContent: 'center', marginRight: 14 },
    settingLabel: { fontSize: 16, fontWeight: '500' },
    settingValue: { fontSize: 15, opacity: 0.7 },
});
