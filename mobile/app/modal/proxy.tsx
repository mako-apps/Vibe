
import React, { useState } from 'react';
import { View, Text, StyleSheet, Platform, TouchableOpacity, ScrollView, Switch, TextInput } from 'react-native';
import { useRouter } from 'expo-router';
import { X, Server, Globe, Shield, Radio, ChevronRight } from 'lucide-react-native';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import { useThemeStore } from '../../src/lib/stores/theme-store';

export default function ProxyModal() {
    const router = useRouter();
    const { colors } = useThemeStore();
    const [proxyEnabled, setProxyEnabled] = useState(false);
    const [customIp, setCustomIp] = useState('');

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* Header */}
            <View style={styles.header}>
                <Text style={[styles.title, { color: colors.text }]}>Connection</Text>
                <TouchableOpacity onPress={() => router.back()} style={styles.closeBtn}>
                    <X size={24} color={colors.text} />
                </TouchableOpacity>
            </View>

            <ScrollView contentContainerStyle={styles.content}>
                {/* Status Card */}
                <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                    <View style={styles.row}>
                        <View style={styles.iconContainer}>
                            <Globe size={24} color={colors.primary} />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.cardTitle, { color: colors.text }]}>Public Relay</Text>
                            <Text style={[styles.cardSub, { color: colors.text, opacity: 0.6 }]}>Connected via Railway (US-East)</Text>
                        </View>
                        <View style={[styles.statusBadge, { backgroundColor: '#22c55e' }]}>
                            <Text style={styles.statusText}>Stable</Text>
                        </View>
                    </View>
                </SafeLiquidGlass>

                <View style={[styles.divider, { backgroundColor: colors.border }]} />

                <Text style={[styles.sectionTitle, { color: colors.text, opacity: 0.6 }]}>PROXY SETTINGS</Text>

                {/* Proxy Toggle */}
                <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                    <View style={styles.row}>
                        <View style={styles.iconContainer}>
                            <Server size={24} color={colors.text} />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.cardTitle, { color: colors.text }]}>Use Custom Proxy</Text>
                            <Text style={[styles.cardSub, { color: colors.text, opacity: 0.6 }]}>Route traffic through your own server</Text>
                        </View>
                        <Switch
                            value={proxyEnabled}
                            onValueChange={setProxyEnabled}
                            trackColor={{ false: '#767577', true: colors.primary }}
                        />
                    </View>

                    {proxyEnabled && (
                        <View style={{ marginTop: 16 }}>
                            <Text style={[styles.inputLabel, { color: colors.text }]}>Server Address</Text>
                            <TextInput
                                style={[styles.input, { color: colors.text, borderColor: colors.border }]}
                                placeholder="socks5://user:pass@127.0.0.1:1080"
                                placeholderTextColor={colors.text + '50'}
                                value={customIp}
                                onChangeText={setCustomIp}
                            />
                        </View>
                    )}
                </SafeLiquidGlass>

                <View style={[styles.divider, { backgroundColor: colors.border }]} />

                <Text style={[styles.sectionTitle, { color: colors.text, opacity: 0.6 }]}>RELAY NETWORK</Text>

                {/* Relay Network */}
                <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                    <TouchableOpacity
                        style={styles.row}
                        activeOpacity={0.7}
                        onPress={() => router.push('/modal/relay-network')}
                    >
                        <View style={[styles.iconContainer, { backgroundColor: 'rgba(34, 197, 94, 0.1)' }]}>
                            <Radio size={24} color="#22c55e" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.cardTitle, { color: colors.text }]}>Peer Relay Network</Text>
                            <Text style={[styles.cardSub, { color: colors.text, opacity: 0.6 }]}>Connect through other users or become a relay</Text>
                        </View>
                        <ChevronRight size={20} color={colors.text} style={{ opacity: 0.4 }} />
                    </TouchableOpacity>
                </SafeLiquidGlass>

                {/* Info */}
                <View style={styles.infoBox}>
                    <Shield size={16} color={colors.text} style={{ opacity: 0.6, marginRight: 8 }} />
                    <Text style={{ color: colors.text, opacity: 0.6, fontSize: 13, flex: 1 }}>
                        All connections are end-to-end encrypted. Using a proxy or relay does not break encryption.
                    </Text>
                </View>

            </ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        paddingTop: Platform.OS === 'ios' ? 20 : 0
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        paddingVertical: 16,
    },
    title: {
        fontSize: 20,
        fontWeight: 'bold',
    },
    closeBtn: {
        padding: 4,
    },
    content: {
        padding: 20,
        gap: 20,
    },
    card: {
        padding: 16,
        borderRadius: 16,
        overflow: 'hidden'
    },
    row: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12
    },
    iconContainer: {
        width: 40,
        height: 40,
        borderRadius: 20,
        backgroundColor: 'rgba(127,127,127,0.1)',
        alignItems: 'center',
        justifyContent: 'center'
    },
    cardTitle: {
        fontSize: 16,
        fontWeight: '600',
        marginBottom: 2
    },
    cardSub: {
        fontSize: 13,
    },
    statusBadge: {
        paddingHorizontal: 8,
        paddingVertical: 4,
        borderRadius: 8,
    },
    statusText: {
        color: '#fff',
        fontSize: 11,
        fontWeight: 'bold'
    },
    sectionTitle: {
        fontSize: 13,
        fontWeight: '700',
        letterSpacing: 1,
        marginLeft: 4,
        marginBottom: -10
    },
    divider: {
        height: 1,
        width: '100%',
        opacity: 0.1
    },
    inputLabel: {
        fontSize: 13,
        marginBottom: 8,
        opacity: 0.8
    },
    input: {
        height: 44,
        borderWidth: 1,
        borderRadius: 12,
        paddingHorizontal: 12,
        fontSize: 15
    },
    infoBox: {
        flexDirection: 'row',
        padding: 12,
        backgroundColor: 'rgba(127,127,127,0.05)',
        borderRadius: 12,
        alignItems: 'flex-start'
    }
});
