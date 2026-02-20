import React, { useCallback, useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Alert, Platform } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { CameraView, useCameraPermissions } from 'expo-camera';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import { ArrowLeft } from 'lucide-react-native';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import { useThemeStore } from '../src/lib/stores/theme-store';

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    if (color.startsWith('rgba')) return color.replace(/[\d\.]+\)$/g, `${alpha})`);
    return color;
};

const normalizeScannedId = (raw?: string): string | null => {
    if (!raw) return null;
    const trimmed = raw.trim();
    // Accept "vibe:<uuid>" or "vibe:user:<uuid>" formats too.
    const parts = trimmed.split(':');
    const candidate = parts.length >= 2 ? parts[parts.length - 1] : trimmed;
    if (UUID_REGEX.test(candidate)) return candidate;
    return null;
};

export default function QrScanScreen() {
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const router = useRouter();
    const [permission, requestPermission] = useCameraPermissions();
    const [hasScanned, setHasScanned] = useState(false);

    const onBarcodeScanned = useCallback((event: any) => {
        if (hasScanned) return;
        setHasScanned(true);
        const id = normalizeScannedId(event?.data);
        if (!id) {
            Alert.alert('Invalid QR', 'This QR does not contain a valid Vibe ID.', [
                { text: 'Scan Again', onPress: () => setHasScanned(false) },
                { text: 'Close', style: 'cancel', onPress: () => router.back() },
            ]);
            return;
        }

        // Open draft chat by friendId. chat.tsx will resolve to existing chat if needed.
        router.replace({ pathname: '/chat', params: { friendId: id } });
    }, [hasScanned, router]);

    return (
        <View style={{ flex: 1, backgroundColor: '#000' }}>
            <Stack.Screen options={{ headerShown: false }} />

            <View style={{ flex: 1, backgroundColor: colors.background }}>
                {/* MASKED HEADER */}
                <View style={[styles.headerMaskContainer, { height: insets.top + 60 }]}>
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
                            intensity={20}
                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                            style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.8) }]}
                        />
                    </MaskedView>
                </View>

                {/* HEADER CONTENT */}
                <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top + 6 }]}>
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                            <ArrowLeft size={24} color={colors.text} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                    <Text style={[styles.headerTitle, { color: colors.text }]} numberOfLines={1}>Scan QR</Text>
                    <View style={{ width: 40 }} />
                </View>

                <View style={{ flex: 1, paddingTop: insets.top + 70, paddingHorizontal: 16, paddingBottom: insets.bottom + 16 }}>
                    {!permission?.granted ? (
                        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
                            <Text style={{ color: colors.text, fontSize: 18, fontWeight: '800', textAlign: 'center' }}>Camera access needed</Text>
                            <Text style={{ color: colors.textSecondary, marginTop: 8, textAlign: 'center', fontWeight: '600' }}>
                                Allow camera access to scan a Vibe QR code.
                            </Text>
                            <TouchableOpacity
                                onPress={() => requestPermission()}
                                activeOpacity={0.85}
                                style={[styles.primaryBtn, { backgroundColor: colors.primary, marginTop: 18 }]}
                            >
                                <Text style={{ color: '#fff', fontWeight: '800' }}>Allow Camera</Text>
                            </TouchableOpacity>
                        </View>
                    ) : (
                        <View style={styles.cameraWrap}>
                            <CameraView
                                style={StyleSheet.absoluteFill}
                                facing="back"
                                onBarcodeScanned={onBarcodeScanned}
                                barcodeScannerSettings={{
                                    barcodeTypes: ['qr'],
                                }}
                            />
                            <View style={styles.overlay}>
                                <View style={styles.frame} />
                                <Text style={[styles.hint, { color: withAlpha('#fff', 0.9) }]}>Center the QR in the frame</Text>
                                {hasScanned && (
                                    <TouchableOpacity
                                        onPress={() => setHasScanned(false)}
                                        activeOpacity={0.85}
                                        style={[styles.primaryBtn, { backgroundColor: withAlpha('#000', 0.55), marginTop: 14 }]}
                                    >
                                        <Text style={{ color: '#fff', fontWeight: '800' }}>Scan Again</Text>
                                    </TouchableOpacity>
                                )}
                            </View>
                        </View>
                    )}
                </View>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    headerMaskContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 60, pointerEvents: 'none' },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 130, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingHorizontal: 16 },
    headerTitle: { fontSize: 17, fontWeight: '700', letterSpacing: -0.4, textAlign: 'center', flex: 1, marginHorizontal: 10 },
    glassBtnCircle: { width: 40, height: 40, borderRadius: 20, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },

    cameraWrap: { flex: 1, borderRadius: 26, overflow: 'hidden', backgroundColor: '#000' },
    overlay: { ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 20 },
    frame: {
        width: 260,
        height: 260,
        borderRadius: 26,
        borderWidth: 2,
        borderColor: 'rgba(255,255,255,0.65)',
        backgroundColor: 'rgba(0,0,0,0.12)',
    },
    hint: { marginTop: 16, fontSize: 13, fontWeight: '700' },
    primaryBtn: { height: 44, paddingHorizontal: 18, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
});

