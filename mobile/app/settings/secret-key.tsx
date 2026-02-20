import React, { useState, useEffect } from 'react';
import {
    View,
    Text,
    StyleSheet,
    TouchableOpacity,
    Alert,
    Platform,
    ScrollView,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { X, Copy, Eye, EyeOff, ShieldAlert, ArrowLeft } from 'lucide-react-native';
import * as Clipboard from 'expo-clipboard';
import QRCode from 'react-native-qrcode-svg';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import AuthManager from '../../src/lib/AuthManager';
import Animated, {
    useAnimatedScrollHandler,
    useAnimatedStyle,
    useSharedValue,
    interpolate,
    Extrapolate,
    FadeIn
} from 'react-native-reanimated';
import { useRouter, Stack } from 'expo-router';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';

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

export default function SecretKeySettingsScreen() {
    const insets = useSafeAreaInsets();
    const router = useRouter();
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const scrollY = useSharedValue(0);

    const [secretKey, setSecretKey] = useState<string | null>(null);
    const [showKeyText, setShowKeyText] = useState(false);

    useEffect(() => {
        const loadKey = async () => {
            const session = AuthManager.getInstance().getSession();
            if (session?.secretKey) {
                setSecretKey(session.secretKey);
            }
        };
        loadKey();
    }, []);

    const scrollHandler = useAnimatedScrollHandler({
        onScroll: (event) => {
            scrollY.value = event.contentOffset.y;
        },
    });

    const headerChromeStyle = useAnimatedStyle(() => {
        const opacity = interpolate(scrollY.value, [0, 20], [0, 1], Extrapolate.CLAMP);
        return { opacity };
    });

    const sectionBg = isLight ? '#ffffff' : colors.card;
    const secondaryBg = isLight ? withAlpha('#000', 0.04) : withAlpha(colors.text, 0.06);

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{ headerShown: false }} />

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
                        Secret Key
                    </Text>
                    <View style={{ width: 44 }} />
                </View>
            </View>

            <Animated.ScrollView
                onScroll={scrollHandler}
                scrollEventThrottle={16}
                contentContainerStyle={{ paddingTop: insets.top + 80, paddingBottom: insets.bottom + 40, paddingHorizontal: 20 }}
                showsVerticalScrollIndicator={false}
            >
                {/* QR Section */}
                <View style={[styles.qrContainer, { backgroundColor: '#fff', alignSelf: 'center', marginBottom: 32 }]}>
                    {secretKey ? (
                        <QRCode value={secretKey} size={220} />
                    ) : (
                        <View style={{ width: 220, height: 220, backgroundColor: '#f0f0f0', alignItems: 'center', justifyContent: 'center' }}>
                            <Text style={{ color: '#aaa' }}>Loading...</Text>
                        </View>
                    )}
                </View>

                {/* Key Card */}
                <SafeLiquidGlass style={[styles.keyCard, { backgroundColor: sectionBg }]} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <View style={{ marginBottom: 16 }}>
                        <Text style={[styles.cardLabel, { color: colors.textSecondary }]}>YOUR SECRET KEY</Text>
                        <View style={styles.keyTextWrapper}>
                            <View style={{ position: 'relative' }}>
                                <Text style={[styles.keyText, { color: colors.text, opacity: showKeyText ? 1 : 0 }]}>
                                    {secretKey || 'No key found'}
                                </Text>
                                {!showKeyText && (
                                    <View style={[StyleSheet.absoluteFill, { zIndex: 10 }]}>
                                        <BlurView intensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { borderRadius: 8 }]} />
                                        <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }]}>
                                            <Text style={{ color: colors.text, opacity: 0.3, letterSpacing: 4, fontWeight: '700' }}>•••• •••• •••• ••••</Text>
                                        </View>
                                    </View>
                                )}
                            </View>
                        </View>
                    </View>

                    <View style={styles.actionRow}>
                        <TouchableOpacity
                            onPress={() => setShowKeyText(!showKeyText)}
                            style={[styles.actionButton, { backgroundColor: secondaryBg }]}
                        >
                            {showKeyText ? <EyeOff size={18} color={colors.text} /> : <Eye size={18} color={colors.text} />}
                            <Text style={[styles.actionText, { color: colors.text }]}>{showKeyText ? 'Hide' : 'Show'}</Text>
                        </TouchableOpacity>
                        <TouchableOpacity
                            onPress={() => {
                                if (secretKey) {
                                    Clipboard.setStringAsync(secretKey);
                                    Alert.alert('Copied', 'Secret key copied to clipboard');
                                }
                            }}
                            style={[styles.actionButton, { backgroundColor: withAlpha(colors.primary, 0.12) }]}
                        >
                            <Copy size={18} color={colors.primary} />
                            <Text style={[styles.actionText, { color: colors.primary }]}>Copy</Text>
                        </TouchableOpacity>
                    </View>
                </SafeLiquidGlass>

                {/* Warning Box */}
                <View style={[styles.warningBox, { backgroundColor: withAlpha('#ef4444', 0.08) }]}>
                    <ShieldAlert size={20} color="#ef4444" style={{ marginRight: 12 }} />
                    <Text style={styles.warningText}>
                        Do not share this key. It grants full access to your account and cannot be recovered if lost.
                    </Text>
                </View>

                <View style={{ height: 40 }} />
            </Animated.ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0 },
    headerMaskContainer: { position: 'absolute', top: 0, left: 0, right: 0 },
    headerContentContainer: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16 },
    headerTitle: { fontSize: 17, fontWeight: '700', letterSpacing: -0.4 },
    glassBtnCircle: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },

    qrContainer: { padding: 8, borderRadius: 32, overflow: 'hidden', elevation: 12, shadowColor: '#000', shadowOffset: { width: 0, height: 6 }, shadowOpacity: 0.1, shadowRadius: 12 },
    keyCard: { borderRadius: 26, padding: 22, marginBottom: 24, overflow: 'hidden' },
    cardLabel: { fontSize: 11, fontWeight: '800', letterSpacing: 1.2, textTransform: 'uppercase', marginBottom: 12, opacity: 0.8 },
    keyTextWrapper: { minHeight: 50, justifyContent: 'center' },
    keyText: { fontSize: 16, fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace', fontWeight: '600', lineHeight: 24 },

    actionRow: { flexDirection: 'row', gap: 12, marginTop: 4 },
    actionButton: { flexDirection: 'row', height: 48, borderRadius: 16, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16, flex: 1 },
    actionText: { fontWeight: '700', fontSize: 15, marginLeft: 10 },

    warningBox: { flexDirection: 'row', padding: 20, borderRadius: 22, alignItems: 'center', width: '100%' },
    warningText: { color: '#ef4444', fontSize: 14, fontWeight: '600', flex: 1, lineHeight: 20 },
});
