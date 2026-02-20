import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Platform, Image, Alert } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Camera, Check, ChevronRight, LogOut, Trash } from 'lucide-react-native';
import { useRouter, useLocalSearchParams } from 'expo-router';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import UserProfile from '../src/components/chat/UserProfile';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { Message } from '../src/lib/types';
import { TextInput, ActivityIndicator } from 'react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import * as ImagePicker from 'expo-image-picker';
import { apiClient } from '../src/lib/api-client';

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

export default function ProfileScreen() {
    const insets = useSafeAreaInsets();
    const router = useRouter();
    const { user, updateProfileInfo, updateProfileImage, logout } = useAuthStore();
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';

    const [isSaving, setIsSaving] = useState(false);
    const [isUploadingPhoto, setIsUploadingPhoto] = useState(false);

    // Form State (save all at once)
    const [name, setName] = useState(user?.name || '');
    const [username, setUsername] = useState(user?.username || '');
    const [phoneNumber, setPhoneNumber] = useState(user?.phoneNumber || '');
    const [bio, setBio] = useState(user?.bio || '');
    const [dateOfBirth, setDateOfBirth] = useState((user as any)?.dateOfBirth || '');

    useEffect(() => {
        setName(user?.name || '');
        setUsername(user?.username || '');
        setPhoneNumber(user?.phoneNumber || '');
        setBio(user?.bio || '');
        setDateOfBirth((user as any)?.dateOfBirth || '');
    }, [user?.name, user?.username, user?.phoneNumber, user?.bio, (user as any)?.dateOfBirth]);

    const pickProfilePhoto = async () => {
        const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
        if (!perm.granted) {
            Alert.alert('Permission needed', 'Please allow photo library access to change your photo.');
            return;
        }

        const result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.Images,
            allowsEditing: true,
            quality: 1,
            base64: true,
            exif: false,
        });

        if (result.canceled) return;
        const base64 = result.assets?.[0]?.base64;
        if (!base64) return;

        setIsUploadingPhoto(true);
        try {
            const base64Img = `data:image/jpeg;base64,${base64}`;
            await updateProfileImage(base64Img);
        } catch (e) {
            Alert.alert('Error', 'Failed to update profile photo.');
        } finally {
            setIsUploadingPhoto(false);
        }
    };

    const isDirty =
        name !== (user?.name || '') ||
        username !== (user?.username || '') ||
        phoneNumber !== (user?.phoneNumber || '') ||
        bio !== (user?.bio || '') ||
        dateOfBirth !== ((user as any)?.dateOfBirth || '');

    const handleSave = async () => {
        if (!user) return;
        if (!isDirty) return;

        setIsSaving(true);
        try {
            const updates: any = {};
            if (name !== (user.name || '')) updates.name = name.trim();
            if (username !== (user.username || '')) updates.username = username.trim();
            if (phoneNumber !== (user.phoneNumber || '')) updates.phoneNumber = phoneNumber.trim();
            if (bio !== (user.bio || '')) updates.bio = bio.trim();
            if (dateOfBirth !== ((user as any)?.dateOfBirth || '')) updates.dateOfBirth = dateOfBirth.trim();
            await updateProfileInfo(updates);
            router.back();
        } catch (e: any) {
            Alert.alert('Error', e?.message || 'Failed to save changes');
        } finally {
            setIsSaving(false);
        }
    };

    const handleLogout = () => {
        Alert.alert(
            "Log Out",
            "Are you sure you want to log out?",
            [
                { text: "Cancel", style: "cancel" },
                {
                    text: "Log Out",
                    style: "destructive",
                    onPress: async () => {
                        try {
                            // Disconnect socket but keep data
                            try {
                                const { useChatStore } = require('../src/lib/ChatStore');
                                useChatStore.getState().disconnect();
                            } catch { }

                            // Clear session
                            await logout();
                            router.replace('/(auth)/welcome');
                        } catch (e) {
                            Alert.alert("Error", "Logout failed");
                        }
                    }
                }
            ]
        );
    };

    const handleDeleteAccount = () => {
        Alert.alert(
            "Delete Account",
            "Are you absolutely sure? This cannot be undone. All your chats, messages, and data will be permanently erased.",
            [
                { text: "Cancel", style: "cancel" },
                {
                    text: "Delete Account",
                    style: "destructive",
                    onPress: async () => {
                        setIsSaving(true);
                        try {
                            if (!user?.userId) return;
                            await apiClient.deleteAccount(user.userId);

                            // Disconnect and cleanup
                            try {
                                const { useChatStore } = require('../src/lib/ChatStore');
                                useChatStore.getState().disconnect();
                                useChatStore.setState({
                                    chats: [],
                                    activeChatId: null,
                                    typingUsers: new Set(),
                                    recordingUsers: new Set(),
                                    onlineUsers: new Set(),
                                    offlineQueue: [],
                                    uploadProgress: {}
                                });
                            } catch { }

                            // Clear session
                            await logout();

                            // Force clear SecureStore for session if logout doesn't fully cover it
                            try {
                                const SecureStore = require('expo-secure-store');
                                await SecureStore.deleteItemAsync('user_session_v2');
                            } catch { }

                            router.replace('/(auth)/welcome');
                        } catch (e: any) {
                            Alert.alert("Error", "Failed to delete account: " + e.message);
                            setIsSaving(false);
                        }
                    }
                }
            ]
        );
    };

    const Card = ({ title, children }: { title: string; children: React.ReactNode }) => (
        <View style={styles.section}>
            <Text style={[styles.sectionLabel, { color: colors.textSecondary }]}>{title}</Text>
            <View style={[styles.card, { backgroundColor: isLight ? '#ffffff' : colors.card }]}>
                {children}
            </View>
        </View>
    );

    const InputRow = ({
        label,
        value,
        onChangeText,
        placeholder,
        keyboardType,
        autoCapitalize,
        autoCorrect,
        multiline,
        isLast,
    }: {
        label: string;
        value: string;
        onChangeText: (t: string) => void;
        placeholder?: string;
        keyboardType?: any;
        autoCapitalize?: any;
        autoCorrect?: boolean;
        multiline?: boolean;
        isLast?: boolean;
    }) => (
        <View>
            <View style={[styles.row, multiline && { alignItems: 'flex-start' }]}>
                <Text style={[styles.rowLabel, { color: colors.text }]}>{label}</Text>
                <TextInput
                    value={value}
                    onChangeText={onChangeText}
                    placeholder={placeholder}
                    placeholderTextColor={withAlpha(colors.text, 0.35)}
                    keyboardType={keyboardType}
                    autoCapitalize={autoCapitalize}
                    autoCorrect={autoCorrect}
                    multiline={multiline}
                    style={[
                        styles.rowInput,
                        { color: colors.text, textAlignVertical: multiline ? 'top' : 'center', minHeight: multiline ? 64 : undefined }
                    ]}
                />
            </View>
            {!isLast && <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />}
        </View>
    );

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* MASKED HEADER */}
            <View style={[styles.headerContainer, { height: insets.top + 40, zIndex: 60, pointerEvents: 'none' }]}>
                <MaskedView
                    style={StyleSheet.absoluteFill}
                    maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.6, 1]} style={StyleSheet.absoluteFill} />}
                >
                    <BlurView intensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.8) }]} />
                </MaskedView>
            </View>

            {/* HEADER CONTENT */}
            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top, zIndex: 130 }]} pointerEvents="box-none">
                <View style={styles.headerBtnWrapper}>
                    <SafeLiquidGlass style={styles.headerGlassBtn} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => router.back()} style={styles.headerTouchArea}>
                            <ArrowLeft color={colors.text} size={22} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                </View>
                <View style={styles.headerCenterWrapper}>
                    <Text style={[styles.headerTitle, { color: colors.text }]}>Edit Profile</Text>
                </View>
                <View style={styles.headerBtnWrapper}>
                    <SafeLiquidGlass style={styles.headerGlassBtn} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity
                            onPress={handleSave}
                            disabled={!isDirty || isSaving}
                            style={[styles.headerTouchArea, { opacity: !isDirty || isSaving ? 0.4 : 1 }]}
                        >
                            {isSaving ? <ActivityIndicator size="small" /> : <Check color={colors.text} size={22} />}
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                </View>
            </View>

            <ScrollView contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
                {/* Avatar Section */}
                <View style={styles.avatarSection}>
                    <View style={styles.avatarWrapper}>
                        <View style={[styles.avatar, { backgroundColor: withAlpha(colors.text, 0.06) }]}>
                            {!!user?.profileImage ? (
                                <Image source={{ uri: user.profileImage }} style={styles.avatarImg} />
                            ) : (
                                <Text style={[styles.avatarText, { color: colors.text }]}>
                                    {(user?.name?.[0] || user?.username?.[0] || 'U').toUpperCase()}
                                </Text>
                            )}
                        </View>
                        <TouchableOpacity
                            onPress={pickProfilePhoto}
                            activeOpacity={0.85}
                            style={styles.cameraBadgeWrap}
                            disabled={isUploadingPhoto}
                        >
                            <SafeLiquidGlass style={styles.cameraBadge} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                {isUploadingPhoto ? (
                                    <ActivityIndicator size="small" />
                                ) : (
                                    <Camera size={16} color={colors.text} />
                                )}
                            </SafeLiquidGlass>
                        </TouchableOpacity>
                    </View>
                    <Text style={[styles.titleName, { color: colors.text }]} numberOfLines={1}>
                        {user?.name || user?.username || 'Your Profile'}
                    </Text>
                    {!!user?.username && (
                        <Text style={{ color: colors.textSecondary, fontSize: 13, fontWeight: '600' }} numberOfLines={1}>
                            @{user.username}
                        </Text>
                    )}
                </View>

                <Card title="PERSONAL INFO">
                    <InputRow label="Name" value={name} onChangeText={setName} placeholder="Your name" autoCapitalize="words" />
                    <InputRow label="Username" value={username} onChangeText={setUsername} placeholder="username" autoCapitalize="none" autoCorrect={false} />
                    <InputRow label="Phone" value={phoneNumber} onChangeText={setPhoneNumber} placeholder="Add phone" keyboardType="phone-pad" autoCapitalize="none" autoCorrect={false} />
                    <InputRow label="Birth" value={dateOfBirth} onChangeText={setDateOfBirth} placeholder="YYYY-MM-DD" autoCapitalize="none" autoCorrect={false} />
                    <InputRow label="Bio" value={bio} onChangeText={setBio} placeholder="Add a bio" autoCapitalize="sentences" multiline isLast />
                </Card>

                <Card title="SECURITY">
                    <View>
                        <TouchableOpacity onPress={() => router.push('/settings/secret-key')} activeOpacity={0.8} style={styles.row}>
                            <Text style={[styles.rowLabel, { color: colors.text }]}>Secret Key</Text>
                            <View style={styles.rowRight}>
                                <Text style={[styles.rowValue, { color: colors.textSecondary }]} numberOfLines={1}>View</Text>
                                <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                            </View>
                        </TouchableOpacity>
                    </View>
                </Card>

                <Card title="ACTIONS">
                    <TouchableOpacity
                        onPress={handleLogout}
                        activeOpacity={0.7}
                        style={styles.row}
                    >
                        <LogOut size={20} color={colors.text} style={{ marginRight: 12 }} />
                        <Text style={[styles.rowLabel, { color: colors.text, flex: 1 }]}>Log Out</Text>
                        <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                    </TouchableOpacity>
                    <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />
                    <TouchableOpacity
                        onPress={handleDeleteAccount}
                        activeOpacity={0.7}
                        style={styles.row}
                    >
                        <Trash size={20} color="#ef4444" style={{ marginRight: 12 }} />
                        <Text style={[styles.rowLabel, { color: "#ef4444", flex: 1 }]}>Delete Account</Text>
                        {isSaving && <ActivityIndicator size="small" color="#ef4444" />}
                    </TouchableOpacity>
                </Card>

                <View style={{ height: 40 }} />
            </ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },

    // Header Styles
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 50 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 4 },
    headerBtnWrapper: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center', zIndex: 140 },
    headerGlassBtn: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    headerTouchArea: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center' },
    headerCenterWrapper: { flex: 1, alignItems: 'center', justifyContent: 'center', marginHorizontal: 10, height: 44 },
    headerTitle: { fontSize: 17, fontWeight: '700', textAlign: 'center' },

    content: {
        paddingTop: 140,
        paddingBottom: 40,
        paddingHorizontal: 16,
    },

    avatarSection: { alignItems: 'center', marginBottom: 26 },
    avatarWrapper: { position: 'relative', marginBottom: 10 },
    avatar: { width: 112, height: 112, borderRadius: 56, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    avatarImg: { width: '100%', height: '100%' },
    avatarText: { fontSize: 40, fontWeight: '800' },
    titleName: { fontSize: 24, fontWeight: '800', marginBottom: 4 },
    cameraBadgeWrap: { position: 'absolute', bottom: -2, right: -2 },
    cameraBadge: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center', overflow: 'hidden' },

    section: { marginBottom: 18 },
    sectionLabel: { fontSize: 13, fontWeight: '700', marginBottom: 8, marginLeft: 16, opacity: 0.6, letterSpacing: 0.5, textTransform: 'uppercase' },
    card: { borderRadius: 26, overflow: 'hidden' },
    row: { flexDirection: 'row', alignItems: 'center', paddingVertical: 16, paddingHorizontal: 20, minHeight: 58 },
    divider: { height: StyleSheet.hairlineWidth, marginLeft: 18 },
    rowLabel: { fontSize: 16, fontWeight: '500', width: 98 },
    rowRight: { flexDirection: 'row', alignItems: 'center', gap: 8, marginLeft: 10 },
    rowValue: { flex: 1, fontSize: 15, fontWeight: '500', textAlign: 'right' },
    rowInput: { flex: 1, fontSize: 16, fontWeight: '500', paddingVertical: 0 },
});
