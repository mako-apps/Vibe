import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { useAuthStore } from '../../lib/stores/auth-store';
import { useThemeStore } from '../../lib/stores/theme-store';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { AlertTriangle, LogIn } from 'lucide-react-native';
import { useRouter } from 'expo-router';

export default function SessionExpiredBanner() {
    const { isSessionExpired, logout } = useAuthStore();
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const router = useRouter();

    if (!isSessionExpired) return null;

    const handleReLogin = async () => {
        // Clear auth state and redirect
        await logout();
        router.replace('/(auth)/welcome');
    };

    const isDark = effectiveTheme === 'dark';

    return (
        <View style={styles.container}>
            <SafeLiquidGlass
                style={styles.banner}
                blurIntensity={30}
                tint={isDark ? 'dark' : 'light'}
            >
                <View style={styles.content}>
                    <View style={styles.textContainer}>
                        <View style={styles.headerRow}>
                            <AlertTriangle size={24} color="#ef4444" />
                            <Text style={[styles.title, { color: colors.text }]}>Session Expired</Text>
                        </View>
                        <Text style={[styles.message, { color: colors.textSecondary }]}>
                            Please log in again to continue using Vibe.
                        </Text>
                    </View>
                    <TouchableOpacity
                        onPress={handleReLogin}
                        style={[styles.button, { backgroundColor: colors.primary }]}
                        activeOpacity={0.8}
                    >
                        <LogIn size={18} color="#fff" style={{ marginRight: 8 }} />
                        <Text style={styles.buttonText}>Log In</Text>
                    </TouchableOpacity>
                </View>
            </SafeLiquidGlass>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0, // Cover the whole screen
        zIndex: 99999,
        backgroundColor: 'rgba(0,0,0,0.5)', // Dim background
        justifyContent: 'center',
        alignItems: 'center',
        paddingHorizontal: 20,
    },
    banner: {
        width: '100%',
        maxWidth: 340,
        borderRadius: 24,
        overflow: 'hidden',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.1)',
        shadowColor: "#000",
        shadowOffset: { width: 0, height: 10 },
        shadowOpacity: 0.3,
        shadowRadius: 20,
        elevation: 10,
    },
    content: {
        padding: 24,
        gap: 20,
        alignItems: 'center',
    },
    textContainer: {
        gap: 12,
        alignItems: 'center',
    },
    headerRow: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 10,
    },
    title: {
        fontSize: 20,
        fontWeight: '700',
        fontFamily: 'SpaceGrotesk-Bold',
    },
    message: {
        fontSize: 15,
        textAlign: 'center',
        lineHeight: 22,
        fontFamily: 'SpaceGrotesk-Regular',
    },
    button: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 14,
        paddingHorizontal: 24,
        borderRadius: 16,
        width: '100%',
    },
    buttonText: {
        color: '#fff',
        fontSize: 16,
        fontWeight: '600',
        fontFamily: 'SpaceGrotesk-Bold',
    },
});
