import React, { useState, useEffect } from 'react'
import { View, Text, StyleSheet, TouchableOpacity, Alert, Platform } from 'react-native'
import { useRouter } from 'expo-router'
import { ChevronLeft, Key, Copy, Eye, EyeOff, ShieldAlert } from 'lucide-react-native'
import * as Clipboard from 'expo-clipboard'
import QRCode from 'react-native-qrcode-svg'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import AuthManager from '../../src/lib/AuthManager'
import { BlurView } from 'expo-blur'

// Helper for colors
const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

export default function SecretKeyScreen() {
    const { colors, effectiveTheme } = useThemeStore()
    const router = useRouter()
    const [secretKey, setSecretKey] = useState<string | null>(null)
    const [showKey, setShowKey] = useState(false)

    useEffect(() => {
        const loadKey = async () => {
            const session = AuthManager.getInstance().getSession();
            // Ensure we prioritize the full secret key from session
            if (session?.secretKey) {
                setSecretKey(session.secretKey);
            } else {
                // If checking auth store or other sources if session is empty
                // This handles edge cases where AuthManager might not be fully synced
            }
        }
        loadKey()
    }, [])

    const handleCopy = async () => {
        if (secretKey) {
            await Clipboard.setStringAsync(secretKey)
            Alert.alert('Copied', 'Secret Key copied to clipboard')
        }
    }

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <View style={styles.header}>
                <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
                    <ChevronLeft size={28} color={colors.text} />
                </TouchableOpacity>
                <Text style={[styles.title, { color: colors.text }]}>Secret Key</Text>
            </View>

            <View style={styles.content}>
                <Text style={[styles.description, { color: colors.textSecondary }]}>
                    This QR code and key is your ONLY way to recover your account or login on new devices.
                </Text>

                {secretKey ? (
                    <View style={styles.keyWrapper}>
                        {/* QR Code Card */}
                        <View style={[styles.qrContainer, { backgroundColor: '#fff' }]}>
                            <View style={styles.qrInner}>
                                <QRCode
                                    value={secretKey}
                                    size={220}
                                    color="black"
                                    backgroundColor="white"
                                    quietZone={10}
                                />
                            </View>
                            {!showKey && (
                                <BlurView intensity={60} tint="light" style={StyleSheet.absoluteFill}>
                                    <View style={styles.blurCenter}>
                                        <EyeOff size={32} color="#000" style={{ opacity: 0.5 }} />
                                        <Text style={{ color: '#000', marginTop: 8, fontWeight: '600', opacity: 0.7 }}>Tap Eye to Reveal</Text>
                                    </View>
                                </BlurView>
                            )}
                        </View>

                        {/* Text Key Card */}
                        <SafeLiquidGlass style={[styles.keyCard, { backgroundColor: colors.card }]} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                            <View style={styles.keyRow}>
                                <Text style={[styles.keyLabel, { color: colors.textSecondary }]}>YOUR SECRET KEY</Text>
                                <View style={styles.keyValueContainer}>
                                    <Text
                                        style={[
                                            styles.keyText,
                                            { color: colors.text, opacity: showKey ? 1 : 0 } // Hide text but keep layout
                                        ]}
                                    >
                                        {secretKey}
                                    </Text>

                                    {!showKey && (
                                        <View style={StyleSheet.absoluteFill}>
                                            <BlurView intensity={40} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { borderRadius: 8 }]} />
                                            <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }]}>
                                                <Text style={{ color: colors.text, opacity: 0.5, letterSpacing: 2 }}>•••• •••• •••• ••••</Text>
                                            </View>
                                        </View>
                                    )}
                                </View>
                            </View>

                            <View style={styles.actionsRow}>
                                <TouchableOpacity onPress={() => setShowKey(!showKey)} style={[styles.actionButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}>
                                    {showKey ? <EyeOff size={20} color={colors.text} /> : <Eye size={20} color={colors.text} />}
                                    <Text style={[styles.actionText, { color: colors.text }]}>{showKey ? 'Hide' : 'Reveal'}</Text>
                                </TouchableOpacity>
                                <TouchableOpacity onPress={handleCopy} style={[styles.actionButton, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                    <Copy size={20} color={colors.primary} />
                                    <Text style={[styles.actionText, { color: colors.primary }]}>Copy</Text>
                                </TouchableOpacity>
                            </View>
                        </SafeLiquidGlass>

                        <View style={[styles.warningBox, { backgroundColor: 'rgba(239, 68, 68, 0.1)' }]}>
                            <ShieldAlert size={20} color="#ef4444" style={{ marginRight: 10 }} />
                            <Text style={styles.warningText}>
                                Do not share this key. It grants full access to your account.
                            </Text>
                        </View>
                    </View>
                ) : (
                    <View style={styles.errorContainer}>
                        <Text style={[styles.errorText, { color: colors.textSecondary }]}>
                            Secret Key not available using current session.
                        </Text>
                    </View>
                )}
            </View>
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        padding: 20,
        paddingTop: 60,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        marginBottom: 20,
    },
    backButton: {
        marginRight: 16,
        padding: 4,
    },
    title: {
        fontSize: 28,
        fontWeight: 'bold',
    },
    content: {
        flex: 1,
        alignItems: 'center',
    },
    description: {
        fontSize: 15,
        textAlign: 'center',
        marginBottom: 30,
        lineHeight: 22,
        paddingHorizontal: 10,
        opacity: 0.7
    },
    keyWrapper: {
        width: '100%',
        alignItems: 'center',
        gap: 24
    },
    qrContainer: {
        padding: 4,
        borderRadius: 24,
        overflow: 'hidden',
        elevation: 8,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.1,
        shadowRadius: 12,
        position: 'relative'
    },
    qrInner: {
        padding: 20,
        backgroundColor: 'white',
        borderRadius: 20
    },
    blurCenter: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center'
    },
    keyCard: {
        width: '100%',
        borderRadius: 20,
        padding: 20,
        gap: 16
    },
    keyRow: {
        gap: 8
    },
    keyLabel: {
        fontSize: 11,
        fontWeight: '700',
        letterSpacing: 1,
        textTransform: 'uppercase',
        opacity: 0.5
    },
    keyValueContainer: {
        position: 'relative',
        minHeight: 24,
        justifyContent: 'center'
    },
    keyText: {
        fontSize: 16,
        fontWeight: '600',
        fontVariant: ['tabular-nums'],
        letterSpacing: 0.5,
        textAlign: 'center',
        lineHeight: 24
    },
    actionsRow: {
        flexDirection: 'row',
        gap: 12
    },
    actionButton: {
        flex: 1,
        flexDirection: 'row',
        height: 44,
        borderRadius: 12,
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8
    },
    actionText: {
        fontSize: 15,
        fontWeight: '600'
    },
    warningBox: {
        flexDirection: 'row',
        padding: 16,
        borderRadius: 16,
        alignItems: 'center',
        width: '100%'
    },
    warningText: {
        color: '#ef4444',
        fontSize: 14,
        fontWeight: '500',
        flex: 1,
        lineHeight: 20
    },
    errorContainer: {
        padding: 40,
        alignItems: 'center'
    },
    errorText: {
        textAlign: 'center',
        fontSize: 16,
        opacity: 0.7
    }
})
