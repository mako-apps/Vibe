import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, Switch, TouchableOpacity, ScrollView, Alert } from 'react-native';
import { useAuthStore } from '../../lib/stores/auth-store';
import { useThemeStore } from '../../lib/stores/theme-store';
import {
    ChevronLeft, ChevronRight, Ban, Fingerprint, Lock, Clock, Eye, Shield,
    Phone, Image as ImageIcon, FileText, Gift, Music, Share2, Key
} from 'lucide-react-native';
import * as LocalAuthentication from 'expo-local-authentication';
import * as SecureStore from 'expo-secure-store';
import { apiClient } from '../../lib/api-client';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useRouter } from 'expo-router';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        let hex = color.replace('#', '')
        if (hex.length === 3) {
            hex = hex.split('').map(char => char + char).join('')
        }
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color;
};

export default function PrivacySettings() {
    const { colors, effectiveTheme } = useThemeStore()
    const { user, updateProfileInfo } = useAuthStore()
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const isLight = effectiveTheme === 'light';

    // State
    const [biometricsEnabled, setBiometricsEnabled] = useState(false);
    const [blockedCount, setBlockedCount] = useState(0);

    // Initial Values
    // Note: user object in store needs to be updated when these change

    useEffect(() => {
        checkBiometrics();
        fetchBlockedCount();
    }, []);

    const checkBiometrics = async () => {
        const stored = await SecureStore.getItemAsync('biometrics_enabled');
        setBiometricsEnabled(stored === 'true');
    };

    const fetchBlockedCount = async () => {
        if (!user?.userId) return;
        try {
            const users = await apiClient.listBlockedUsers(user.userId);
            if (Array.isArray(users)) {
                setBlockedCount(users.length);
            }
        } catch (e) {
            console.error('Failed to fetch blocked users', e);
        }
    };

    const handleBiometricToggle = async (val: boolean) => {
        if (val) {
            const hasHardware = await LocalAuthentication.hasHardwareAsync();
            if (!hasHardware) {
                Alert.alert('Not Supported', 'This device does not support biometrics.');
                return;
            }

            const result = await LocalAuthentication.authenticateAsync({
                promptMessage: 'Authenticate to enable Face ID / Touch ID',
            });
            if (result.success) {
                await SecureStore.setItemAsync('biometrics_enabled', 'true');
                setBiometricsEnabled(true);
            } else {
                Alert.alert('Authentication failed');
                setBiometricsEnabled(false); // Ensure toggle is off
                return;
            }
        } else {
            await SecureStore.deleteItemAsync('biometrics_enabled');
            setBiometricsEnabled(false);
        }
    };

    const handlePrivacyChange = async (key: string, value: any) => {
        try {
            await updateProfileInfo({ [key]: value });
        } catch (e) {
            console.error(`Failed to update ${key}`, e);
            Alert.alert('Error', 'Failed to update setting');
        }
    };

    const formatPrivacy = (val?: string) => {
        if (!val || val === 'everybody') return 'Everybody';
        if (val === 'contacts') return 'My Contacts';
        if (val === 'nobody') return 'Nobody';
        return 'Everybody';
    };

    const SettingItem = ({ icon: Icon, label, value, type = 'link', onPress, color = colors.text, divider = true, destructive, secondaryValue }: any) => (
        <View>
            <TouchableOpacity
                style={[styles.settingRow]}
                onPress={() => type === 'switch' ? onPress && onPress(!value) : onPress?.()}
                activeOpacity={type === 'switch' ? 1 : 0.7}
            >
                {Icon && (
                    <View style={[styles.settingIconContainer, { backgroundColor: color }]}>
                        <Icon size={20} color="#fff" />
                    </View>
                )}
                <View style={styles.settingLabelWrap}>
                    <Text style={[styles.settingLabel, { color: destructive ? '#ef4444' : colors.text }]} numberOfLines={1}>
                        {label}
                    </Text>
                </View>

                <View style={styles.settingRight}>
                    {type === 'link' && (
                        <>
                            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                {value && <Text style={[styles.settingValue, { color: colors.textSecondary }]}>{value}</Text>}
                                {secondaryValue && <Text style={[styles.settingValue, { color: withAlpha(colors.textSecondary, 0.5), marginLeft: 4 }]}>{secondaryValue}</Text>}
                            </View>
                            <ChevronRight size={16} color={withAlpha(colors.textSecondary, 0.35)} style={{ marginLeft: 6 }} />
                        </>
                    )}
                    {type === 'switch' && (
                        <Switch
                            value={value as boolean}
                            onValueChange={onPress}
                            trackColor={{ false: '#767577', true: colors.primary }}
                        />
                    )}
                    {type === 'count' && (
                        <>
                            <Text style={[styles.settingValue, { color: colors.textSecondary }]}>{value}</Text>
                            <ChevronRight size={16} color={withAlpha(colors.textSecondary, 0.35)} style={{ marginLeft: 6 }} />
                        </>
                    )}
                </View>
            </TouchableOpacity>
            {divider && <View style={[styles.divider, { backgroundColor: isLight ? 'rgba(0,0,0,0.1)' : 'rgba(255,255,255,0.1)', marginLeft: Icon ? 16 + 32 + 12 : 16 }]} />}
        </View>
    )


    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            {/* COMPACT HEADER */}
            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top + 6 }]}>
                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity onPress={() => router.back()} style={styles.backBtnCircle}>
                        <ChevronLeft size={26} color={colors.text} />
                    </TouchableOpacity>
                </SafeLiquidGlass>
                <Text style={[styles.headerTitle, { color: colors.text }]}>Privacy and Security</Text>
                <View style={{ width: 44 }} />
            </View>

            <ScrollView
                contentContainerStyle={{ paddingTop: insets.top + 70, paddingBottom: 40, paddingHorizontal: 16 }}
                showsVerticalScrollIndicator={false}
            >
                {/* SECURITY SECTION */}
                <View style={styles.sectionWrapper}>
                    <View style={[styles.sectionContainer, { backgroundColor: isLight ? '#ffffff' : colors.card }]}>
                        <SettingItem
                            icon={Ban}
                            label="Blocked Users"
                            value={blockedCount > 0 ? `${blockedCount}` : undefined}
                            color="#ff3b30"
                            onPress={() => router.push('/settings/privacy/blocked')}
                        />
                        <SettingItem
                            icon={Fingerprint}
                            label="Passcode & Face ID"
                            value={biometricsEnabled ? 'On' : 'Off'}
                            color="#34c759"
                            onPress={() => handleBiometricToggle(!biometricsEnabled)}
                        />
                        <SettingItem
                            icon={Lock}
                            label="Two-Step Verification"
                            value="Off"
                            color="#ff9500"
                            onPress={() => { }}
                        />
                        <SettingItem
                            icon={Key}
                            label="Passkeys"
                            value="Off"
                            color="#5856d6"
                            onPress={() => { }}
                        />
                        <SettingItem
                            icon={Clock}
                            label="Auto-Delete Messages"
                            value={user?.autoDeleteTimer ? (user.autoDeleteTimer >= 60 ? (user.autoDeleteTimer >= 1440 ? (user.autoDeleteTimer >= 10080 ? '1w' : '1d') : '1h') : `${user.autoDeleteTimer}m`) : 'Off'}
                            color="#af52de"
                            divider={false}
                            onPress={() => router.push('/settings/privacy/auto-delete')}
                        />
                    </View>
                    <Text style={[styles.sectionFooter, { color: colors.textSecondary }]}>
                        Automatically delete messages for everyone after a period of time in all new chats you start.
                    </Text>
                </View>

                {/* PRIVACY SECTION */}
                <View style={styles.sectionWrapper}>
                    <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>PRIVACY</Text>
                    <View style={[styles.sectionContainer, { backgroundColor: isLight ? '#ffffff' : colors.card }]}>
                        <SettingItem
                            label="Phone Number"
                            value={formatPrivacy((user as any)?.privacyPhoneNumber)}
                            secondaryValue="(+6)"
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyPhoneNumber', title: 'Phone Number' } })}
                        />
                        <SettingItem
                            label="Last Seen & Online"
                            value={formatPrivacy((user as any)?.privacyLastSeen)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyLastSeen', title: 'Last Seen & Online' } })}
                        />
                        <SettingItem
                            label="Profile Photos"
                            value={formatPrivacy((user as any)?.privacyProfilePhotos)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyProfilePhotos', title: 'Profile Photos' } })}
                        />
                        <SettingItem
                            label="Bio"
                            value={formatPrivacy((user as any)?.privacyBio)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyBio', title: 'Bio' } })}
                        />
                        <SettingItem
                            label="Gifts"
                            value={formatPrivacy((user as any)?.privacyGifts)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyGifts', title: 'Gifts' } })}
                        />
                        <SettingItem
                            label="Birthday"
                            value={formatPrivacy((user as any)?.privacyBirthday)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyBirthday', title: 'Birthday' } })}
                        />
                        <SettingItem
                            label="Saved Music"
                            value={formatPrivacy((user as any)?.privacySavedMusic)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacySavedMusic', title: 'Saved Music' } })}
                        />
                        <SettingItem
                            label="Forwarded Messages"
                            value={formatPrivacy(user?.privacyForward)}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyForward', title: 'Forwarded Messages' } })}
                        />
                        <SettingItem
                            label="Calls"
                            value={formatPrivacy(user?.privacyCalls)}
                            divider={false}
                            onPress={() => router.push({ pathname: '/settings/privacy/choice', params: { key: 'privacyCalls', title: 'Calls' } })}
                        />
                    </View>
                </View>
            </ScrollView>
        </View>
    )
}

const styles = StyleSheet.create({
    headerContentContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 130,
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingHorizontal: 16,
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '700',
        letterSpacing: -0.4,
    },
    backBtnCircle: {
        width: 40,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center',
    },
    glassBtnCircle: {
        width: 40,
        height: 40,
        borderRadius: 20,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    sectionWrapper: {
        marginBottom: 20,
    },
    sectionHeader: {
        fontSize: 13,
        fontWeight: '500',
        marginBottom: 8,
        marginLeft: 16,
        opacity: 0.5,
        letterSpacing: 0.3,
        textTransform: 'uppercase'
    },
    sectionContainer: {
        borderRadius: 14,
        overflow: 'hidden',
    },
    settingRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 14,
        paddingHorizontal: 16,
        minHeight: 52,
    },
    divider: {
        height: 0.5,
    },
    settingIconContainer: {
        width: 32,
        height: 32,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 12
    },
    settingLabelWrap: {
        flex: 1,
        minWidth: 0
    },
    settingLabel: {
        fontSize: 16,
        fontWeight: '400'
    },
    settingRight: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8
    },
    settingValue: {
        fontSize: 16,
        textAlign: 'right'
    },
    sectionFooter: {
        fontSize: 13,
        color: 'rgba(127,127,127,0.6)',
        marginTop: 10,
        marginLeft: 16,
        marginRight: 16,
        lineHeight: 18,
    },
});
