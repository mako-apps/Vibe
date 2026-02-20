import React, { useState, useEffect } from 'react'
import { View, Text, StyleSheet, TouchableOpacity, Alert, Platform } from 'react-native'
import { Copy, Eye, EyeOff, ShieldAlert } from 'lucide-react-native'
import * as Clipboard from 'expo-clipboard'
import QRCode from 'react-native-qrcode-svg'
import { BlurView } from 'expo-blur'
import SafeLiquidGlass from '../../components/native/SafeLiquidGlass'
import { useThemeStore } from '../../lib/stores/theme-store'
import AuthManager from '../../lib/AuthManager'

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

export default function SecretKeySettings() {
    const { colors, effectiveTheme } = useThemeStore()
    const [secretKey, setSecretKey] = useState<string | null>(null)
    const [showKeyText, setShowKeyText] = useState(false)

    useEffect(() => {
        const loadKey = async () => {
            const session = AuthManager.getInstance().getSession();
            if (session?.secretKey) {
                setSecretKey(session.secretKey);
            }
        }
        loadKey()
    }, [])

    return (
        <View style={{ flex: 1, paddingHorizontal: 4 }}>
            <View style={[styles.qrContainer, { backgroundColor: '#fff', alignSelf: 'center', marginBottom: 24 }]}>
                {secretKey && <QRCode value={secretKey} size={200} />}
            </View>

            <SafeLiquidGlass style={[styles.keyCard, { backgroundColor: colors.card }]} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                <View style={{ marginBottom: 12 }}>
                    <Text style={{ fontSize: 11, fontWeight: '700', color: colors.textSecondary, letterSpacing: 1, marginBottom: 8 }}>YOUR SECRET KEY</Text>
                    <View style={{ minHeight: 40, justifyContent: 'center' }}>
                        <View style={{ position: 'relative' }}>
                            <Text style={{ fontSize: 16, fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace', color: colors.text, opacity: showKeyText ? 1 : 0 }}>
                                {secretKey}
                            </Text>
                            {!showKeyText && (
                                <View style={[StyleSheet.absoluteFill, { zIndex: 10 }]}>
                                    <BlurView intensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { borderRadius: 4 }]} />
                                    <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }]}>
                                        <Text style={{ color: colors.text, opacity: 0.4, letterSpacing: 2 }}>•••• •••• •••• ••••</Text>
                                    </View>
                                </View>
                            )}
                        </View>
                    </View>
                </View>
                <View style={{ flexDirection: 'row', gap: 12 }}>
                    <TouchableOpacity onPress={() => setShowKeyText(!showKeyText)} style={[styles.actionButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}>
                        {showKeyText ? <EyeOff size={18} color={colors.text} /> : <Eye size={18} color={colors.text} />}
                        <Text style={{ color: colors.text, fontWeight: '600', marginLeft: 8 }}>{showKeyText ? 'Hide' : 'Show'}</Text>
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => { if (secretKey) Clipboard.setStringAsync(secretKey) }} style={[styles.actionButton, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                        <Copy size={18} color={colors.primary} />
                        <Text style={{ color: colors.primary, fontWeight: '600', marginLeft: 8 }}>Copy</Text>
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
    )
}

const styles = StyleSheet.create({
    qrContainer: { padding: 4, borderRadius: 24, overflow: 'hidden', elevation: 8 },
    keyCard: { borderRadius: 16, padding: 20, marginBottom: 20 },
    actionButton: { flexDirection: 'row', height: 40, borderRadius: 8, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16, flex: 1 },
    warningBox: { flexDirection: 'row', padding: 16, borderRadius: 16, alignItems: 'center', width: '100%' },
    warningText: { color: '#ef4444', fontSize: 14, fontWeight: '500', flex: 1, lineHeight: 20 }
})
