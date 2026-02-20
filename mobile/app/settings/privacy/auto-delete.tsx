import React, { useMemo } from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import { ArrowLeft, Check } from 'lucide-react-native';
import SafeLiquidGlass from '../../../src/components/native/SafeLiquidGlass';
import { useThemeStore } from '../../../src/lib/stores/theme-store';
import { useAuthStore } from '../../../src/lib/stores/auth-store';

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

const OPTIONS: Array<{ minutes: number; label: string; help?: string }> = [
    { minutes: 0, label: 'Off' },
    { minutes: 60, label: 'After 1 hour' },
    { minutes: 1440, label: 'After 1 day' },
    { minutes: 10080, label: 'After 1 week' },
];

export default function AutoDeleteScreen() {
    const { colors, effectiveTheme } = useThemeStore();
    const { user, updateProfileInfo } = useAuthStore();
    const router = useRouter();
    const insets = useSafeAreaInsets();

    const current = useMemo(() => user?.autoDeleteTimer ?? 0, [user?.autoDeleteTimer]);

    const setMinutes = async (minutes: number) => {
        await updateProfileInfo({ autoDeleteTimer: minutes });
        router.back();
    };

    return (
        <View style={{ flex: 1, backgroundColor: '#000' }}>
            <Stack.Screen options={{ headerShown: false }} />

            <View style={{ flex: 1, backgroundColor: colors.background }}>
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

                <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top + 6 }]}>
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                            <ArrowLeft size={24} color={colors.text} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                    <Text style={[styles.headerTitle, { color: colors.text }]} numberOfLines={1}>Auto-Delete Messages</Text>
                    <View style={{ width: 40 }} />
                </View>

                <View style={{ paddingTop: insets.top + 80, paddingHorizontal: 16 }}>
                    <View style={[styles.group, { backgroundColor: effectiveTheme === 'light' ? '#fff' : colors.card }]}>
                        {OPTIONS.map((opt, idx) => {
                            const isLast = idx === OPTIONS.length - 1;
                            const selected = current === opt.minutes;
                            return (
                                <View key={opt.minutes}>
                                    <TouchableOpacity onPress={() => setMinutes(opt.minutes)} activeOpacity={0.8} style={styles.row}>
                                        <Text style={[styles.rowLabel, { color: colors.text }]}>{opt.label}</Text>
                                        {selected && <Check size={18} color={colors.primary} strokeWidth={3} />}
                                    </TouchableOpacity>
                                    {!isLast && <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />}
                                </View>
                            );
                        })}
                    </View>
                    <Text style={[styles.footer, { color: withAlpha(colors.textSecondary || colors.text, 0.75) }]}>
                        Automatically delete messages for everyone after the selected time in new chats you start.
                    </Text>
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

    group: { borderRadius: 26, overflow: 'hidden' },
    row: { minHeight: 58, paddingHorizontal: 18, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
    rowLabel: { fontSize: 16, fontWeight: '600' },
    divider: { height: StyleSheet.hairlineWidth, marginLeft: 18 },
    footer: { fontSize: 13, marginTop: 10, marginLeft: 16, marginRight: 16, lineHeight: 18 },
});

