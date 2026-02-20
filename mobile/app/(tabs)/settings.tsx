import React, { useState, useEffect, useCallback } from 'react';
import { View, Text, StyleSheet, Switch, TouchableOpacity, Image, Platform, useWindowDimensions, Alert, ActivityIndicator, TextInput, Modal, Share, ScrollView } from 'react-native';
import { useRouter } from 'expo-router';
import { useTranslation } from 'react-i18next';
import { useAuthStore } from '../../src/lib/stores/auth-store';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useSubscriptionStore, getTierInfo } from '../../src/lib/stores/subscription-store';
import { useNotificationStore } from '../../src/lib/stores/notification-store';
import * as Notifications from 'expo-notifications';
import { Linking } from 'react-native';
import { useReferralStore } from '../../src/lib/stores/referral-store';
import { ChevronRight, Bell, Shield, Server, Moon, User, ArrowLeft, Key, Camera, Image as ImageIcon, Bookmark, Crown, Award, Users, Briefcase, HardDrive, Edit2, QrCode } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as ImagePicker from 'expo-image-picker';
import Animated, { useAnimatedScrollHandler, useSharedValue, useAnimatedStyle, interpolate, Extrapolate, withTiming, withSpring, useAnimatedReaction, runOnJS, useDerivedValue } from 'react-native-reanimated';

import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import { useHaptics } from '../../src/lib/hooks/useHaptics';
import AnimatedGlassButton from '../../src/components/native/AnimatedGlassButton';
import ConnectionModal from '../../src/components/settings/ConnectionModal';
import SubscriptionModal from '../../src/components/settings/SubscriptionModal';
import ReferralModal from '../../src/components/settings/ReferralModal';
import BusinessSettingsModal from '../../src/components/settings/BusinessSettingsModal';
import { InlineBadge } from '../../src/components/shared/BadgeIcon';
import { apiClient } from '../../src/lib/api-client';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import { Canvas, Circle, Group, ColorMatrix, Paint, Image as SkiaImage, useImage, vec, dist, Rect, BlurMask, Mask, Blur } from '@shopify/react-native-skia';
import * as Clipboard from 'expo-clipboard';
import QRCode from 'react-native-qrcode-svg';
import * as FileSystem from 'expo-file-system/legacy';
import { useWallpaperStore, resolveThemeVariant, PRESET_THEMES } from '../../src/lib/stores/wallpaper-store';
import TelegramDoodleWallpaper from '../../src/components/chat/wallpapers/TelegramDoodleWallpaper';
import MusicWallpaper from '../../src/components/chat/wallpapers/MusicWallpaper';
import FoodWallpaper from '../../src/components/chat/wallpapers/FoodWallpaper';
import TravelWallpaper from '../../src/components/chat/wallpapers/TravelWallpaper';
import WeatherWallpaper from '../../src/components/chat/wallpapers/WeatherWallpaper';
import TechWallpaper from '../../src/components/chat/wallpapers/TechWallpaper';
import PatternWallpaper from '../../src/components/chat/wallpapers/PatternWallpaper';


// MaskedViewAny workaround for TypeScript
const MaskedViewAny = MaskedView as any;
const AnimatedBlurView = Animated.createAnimatedComponent(BlurView);

const VIBE_QR_LOGO = require('../../assets/logos/logo1.png');

const WallpaperComponents: Record<string, React.ComponentType<any>> = {
    doodles: TelegramDoodleWallpaper,
    music: MusicWallpaper,
    food: FoodWallpaper,
    travel: TravelWallpaper,
    weather: WeatherWallpaper,
    tech: TechWallpaper,
    geometric: (props: any) => <PatternWallpaper {...props} patternType="geometric" />,
    nature: (props: any) => <PatternWallpaper {...props} patternType="nature" />,
    space: (props: any) => <PatternWallpaper {...props} patternType="space" />,
    abstract: (props: any) => <PatternWallpaper {...props} patternType="abstract" />,
};

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`)
    }
    return color
};

type ViewState = 'main' | 'privacy' | 'secret-key' | 'appearance';

interface SettingItemProps {
    icon: any;
    label: string;
    value?: string | boolean;
    type?: 'link' | 'switch' | 'value' | 'button';
    onPress?: (val?: boolean) => void;
    color?: string;
    divider?: boolean;
    destructive?: boolean;
}

export default function SettingsScreen() {
    const { user, updateProfileImage } = useAuthStore();
    const { t } = useTranslation();
    const { colors, theme, effectiveTheme } = useThemeStore();
    const { activeTheme, selectedPatternId, setPatternTheme } = useWallpaperStore();
    const { userTier, setUserTier, setPlans, setSubscription } = useSubscriptionStore();
    const { stats, setStats } = useReferralStore();
    const { notificationsEnabled, setNotificationsEnabled, initNotifications } = useNotificationStore();
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { width: windowWidth, height: windowHeight } = useWindowDimensions();
    const HEADER_HEIGHT = insets.top + 60;
    const HERO_COLLAPSED_HEIGHT = 120; // spacer for pinned hero
    const HERO_TOP_ADJUST = 12; // reduce top padding under Dynamic Island
    const HERO_MIX_DISTANCE = 160; // how far the avatar travels upward to "merge" with the island
    const HERO_MIX_OVERSHOOT = 60; // extra travel so it fully disappears behind the island
    const HERO_ISLAND_ANCHOR = 56; // approximate Dynamic Island height inside the top inset
    const HERO_TOP_OFFSET = 80; // pushes the avatar slightly down if it feels too high
    const HERO_TOP = Math.max(0, insets.top - HERO_ISLAND_ANCHOR - HERO_TOP_ADJUST) + HERO_TOP_OFFSET;

    // Navigation State
    const [activeView, setActiveView] = useState<ViewState>('main');
    const [showConnectionModal, setShowConnectionModal] = useState(false);
    const [showSubscriptionModal, setShowSubscriptionModal] = useState(false);
    const [showReferralModal, setShowReferralModal] = useState(false);
    const [showBusinessModal, setShowBusinessModal] = useState(false);
    const [isUploading, setIsUploading] = useState(false);

    // Load subscription data on mount
    useEffect(() => {
        if (user?.userId) {
            loadSubscriptionData();
        }
    }, [user?.userId]);

    const loadSubscriptionData = async () => {
        if (!user?.userId) return;
        try {
            const [plansRes, subRes, statsRes] = await Promise.all([
                apiClient.getPlans(),
                apiClient.getSubscription(user.userId),
                apiClient.getReferralStats(user.userId),
            ]);
            if (plansRes.plans) setPlans(plansRes.plans);
            if (subRes.subscription) setSubscription(subRes.subscription);
            if (subRes.tier) setUserTier(subRes.tier);
            if (statsRes) setStats(statsRes);
        } catch (e) {
            console.error('Failed to load subscription data', e);
        }
    };



    // Animation Values
    const scrollY = useSharedValue(0);
    const parentScale = useSharedValue(1);
    const headerProgress = useSharedValue(0);
    const expandState = useSharedValue(0);
    const editMenuProgress = useSharedValue(0);
    const [isEditMenuOpen, setIsEditMenuOpen] = useState(false);
    const qrProgress = useSharedValue(0);
    const [isQrOpen, setIsQrOpen] = useState(false);
    const qrRef = React.useRef<any>(null);

    const scrollHandler = useAnimatedScrollHandler((event) => {
        scrollY.value = event.contentOffset.y;
    });

    useEffect(() => {
        headerProgress.value = withTiming(activeView !== 'main' ? 1 : 0, { duration: 300 });
    }, [activeView]);

    const openEditMenu = () => {
        if (activeView !== 'main') return;
        setIsEditMenuOpen(true);
        parentScale.value = withSpring(0.94, springConfig);
        editMenuProgress.value = withTiming(1, { duration: 220 });
    };

    const closeEditMenu = () => {
        editMenuProgress.value = withTiming(0, { duration: 200 }, (finished) => {
            if (finished) {
                runOnJS(setIsEditMenuOpen)(false);
            }
        });
        parentScale.value = withSpring(1, springConfig);
    };

    const openQr = () => {
        if (activeView !== 'main') return;
        setIsQrOpen(true);
        qrProgress.value = withTiming(1, { duration: 220 });
    };

    const closeQr = () => {
        qrProgress.value = withTiming(0, { duration: 200 }, (finished) => {
            if (finished) runOnJS(setIsQrOpen)(false);
        });
    };

    const shareQr = async () => {
        if (!user?.userId) return;
        const inst = qrRef.current;
        if (!inst?.toDataURL) return;

        inst.toDataURL(async (data: string) => {
            try {
                const uri = `${FileSystem.cacheDirectory}vibe_qr_${user.userId}.png`;
                await FileSystem.writeAsStringAsync(uri, data, { encoding: FileSystem.EncodingType.Base64 });
                await Share.share({
                    url: uri,
                    message: `Vibe ID: ${user.userId}`,
                });
            } catch (e) {
                Alert.alert('Error', 'Failed to share QR code.');
            }
        });
    };

    const handleBack = () => {
        if (activeView !== 'main') {
            setActiveView('main');
        }
    };

    const pickImage = async () => {
        const result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.Images,
            allowsEditing: true,
            quality: 1, // Ensure max quality
            base64: true,
            exif: false,
        });

        if (!result.canceled && result.assets[0].base64) {
            setIsUploading(true);
            try {
                if (updateProfileImage) {
                    const base64Img = `data:image/jpeg;base64,${result.assets[0].base64}`;
                    await updateProfileImage(base64Img);
                }
            } catch (e) {
                Alert.alert("Error", "Failed to upload image");
            } finally {
                setIsUploading(false);
            }
        }
    };



    // --- Components ---

    const SettingsSection = ({ title, children }: { title?: string, children: React.ReactNode }) => (
        <View style={styles.sectionWrapper}>
            {title && <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>{title}</Text>}
            <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                {children}
            </View>
        </View>
    );

    const SettingItem = ({ icon: Icon, label, value, type = 'link', onPress, color, divider = true, destructive }: SettingItemProps) => (
        <View>
            <TouchableOpacity
                style={[styles.settingRow]}
                onPress={() => type === 'switch' ? onPress && onPress(!value) : onPress?.()}
                disabled={type === 'switch' && Platform.OS === 'android'}
                activeOpacity={type === 'switch' ? 1 : 0.7}
            >
                <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(color || colors.text, 0.1) }]}>
                    <Icon size={18} color={color || colors.text} />
                </View>
                <View style={styles.settingLabelWrap}>
                    <Text style={[styles.settingLabel, { color: destructive ? '#ef4444' : colors.text }]} numberOfLines={1}>
                        {label}
                    </Text>
                </View>

                <View style={styles.settingRight}>
                    {(type === 'link') && (
                        <>
                            {value && <Text style={[styles.settingValue, { color: colors.textSecondary }]}>{value}</Text>}
                            <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                        </>
                    )}
                    {type === 'switch' && (
                        <Switch
                            value={value as boolean}
                            onValueChange={onPress}
                            trackColor={{ false: '#767577', true: colors.primary }}
                            thumbColor={Platform.OS === 'ios' ? '#fff' : (value ? colors.primary : '#f4f3f4')}
                        />
                    )}
                    {type === 'value' && (
                        <Text style={[styles.settingValue, { color: colors.textSecondary }]}>{value}</Text>
                    )}
                </View>
            </TouchableOpacity>
            {divider && <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />}
        </View>
    );

    const haptics = useHaptics();
    const skiaImage = useImage(user?.profileImage);
    const springConfig = { damping: 25, stiffness: 350, mass: 0.6 };
    const LIQUID_MATRIX = [
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 20, -10,
    ];

    useAnimatedReaction(
        () => scrollY.value,
        (curr) => {
            if (!user?.profileImage) return;
            // Increased threshold to prevent premature expansion, keeping the liquid effect active longer
            if (curr < -110 && expandState.value === 0) {
                expandState.value = withSpring(1, springConfig);
                runOnJS(haptics.light)();
            } else if (curr > -10 && expandState.value === 1) {
                expandState.value = withSpring(0, springConfig);
            }
        }
    );

    const wrapperStyle = useAnimatedStyle(() => {
        const targetWidth = interpolate(expandState.value, [0, 1], [100, windowWidth]);
        const targetHeight = interpolate(expandState.value, [0, 1], [100, windowHeight * 0.5]);
        // Extended scale range to match the new deep pull threshold
        const pullScale = interpolate(scrollY.value, [-220, 0], [2, 1], Extrapolate.CLAMP);
        const scrollUp = Math.min(Math.max(scrollY.value, 0), HERO_MIX_DISTANCE);
        const mixProgress = scrollUp / HERO_MIX_DISTANCE;
        const collapsedBlend = interpolate(expandState.value, [0, 0.15], [1, 0], Extrapolate.CLAMP);

        const mixScale = interpolate(scrollY.value, [0, HERO_MIX_DISTANCE], [1, 0.6], Extrapolate.CLAMP);
        const scaleBlend = 1 - collapsedBlend + collapsedBlend * mixScale;

        const mixOpacity = interpolate(
            scrollY.value,
            [0, HERO_MIX_DISTANCE * 0.7, HERO_MIX_DISTANCE],
            [1, 1, 0],
            Extrapolate.CLAMP
        );
        const opacity = 1 - collapsedBlend + collapsedBlend * mixOpacity;

        const collapsedTranslateY = -scrollUp - mixProgress * HERO_MIX_OVERSHOOT;
        return {
            width: targetWidth,
            height: targetHeight,
            marginBottom: 0,
            marginTop: 0,
            opacity,
            transform: [
                // When collapsed, move up with scroll (clamped) so it visually "mixes" into the Dynamic Island.
                // When expanded, keep the existing dampened follow behavior.
                { translateY: interpolate(expandState.value, [0, 1], [collapsedTranslateY, scrollY.value * 0.8]) },
                { scale: pullScale * scaleBlend }
            ],
            zIndex: 1050
        };
    });

    const innerImageStyle = useAnimatedStyle(() => ({
        borderRadius: interpolate(expandState.value, [0, 1], [50, 0]),
        overflow: 'hidden',
        flex: 1,
        backgroundColor: colors.card,
    }));

    const avatarBlurStyle = useAnimatedStyle(() => ({
        opacity: interpolate(scrollY.value, [100, 150], [0, 1], Extrapolate.CLAMP) * interpolate(expandState.value, [0, 0.1], [1, 0], Extrapolate.CLAMP)
    }));

    const bannerBottomBlurStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expandState.value, [0.5, 0.9], [0, 1]),
        height: interpolate(expandState.value, [0.5, 1], [0, 100]),
    }));

    const dragDistance = useSharedValue(150);

    useAnimatedReaction(
        () => scrollY.value,
        (y) => {
            // Updated: Always magnet to TOP (0) whether pulling down or scrolling up
            // [-220 -> 0] : [40 -> 150] (Pull Down -> Magnet stretches UP)
            // [0 -> 100]  : [150 -> 40] (Scroll Up -> Magnet stretches UP towards header)
            // Adjusted limit to 60 to prevent overlap with Island
            dragDistance.value = interpolate(y, [-150, 0, 100], [60, 150, 60], Extrapolate.CLAMP);
        }
    );

    const blurRadius = useDerivedValue(() => {
        return interpolate(scrollY.value, [-220, 0, 100], [10, 0, 10], Extrapolate.CLAMP);
    });

    const darkeningMatrix = useDerivedValue(() => {
        // Opacity of "black" overlay -> Scale down RGB channels
        // 0 -> No dark (1.0 scale), 0.6 -> Dark (0.4 scale)
        const opacity = interpolate(scrollY.value, [-220, 0, 100], [0.85, 0, 0.85], Extrapolate.CLAMP);
        const scale = 1 - opacity;
        return [
            scale, 0, 0, 0, 0,
            0, scale, 0, 0, 0,
            0, 0, scale, 0, 0,
            0, 0, 0, 1, 0
        ];
    });

    const bannerLayerStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expandState.value, [0, 0.1], [0, 1])
    }));

    const liquidLayerStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expandState.value, [0, 0.05], [1, 0])
    }));

    const penButtonStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expandState.value, [0, 0.2], [1, 0]),
        transform: [{ scale: interpolate(expandState.value, [0, 0.2], [1, 0]) }]
    }));

    // --- Dynamic Styles ---

    const headerTitle = activeView === 'main' ? (user?.name || user?.username || t('settings.title')) :
        activeView === 'privacy' ? t('settings.privacy') :
            activeView === 'appearance' ? 'Appearance' : t('settings.secretKey');


    // Header Title Animation (Fade In on Scroll)
    const headerTitleStyle = useAnimatedStyle(() => {
        if (activeView !== 'main') return { opacity: 1 };
        const threshold = 160;
        return {
            opacity: interpolate(scrollY.value, [threshold - 20, threshold + 10], [0, 1], Extrapolate.CLAMP),
            transform: [{ translateY: interpolate(scrollY.value, [threshold - 20, threshold + 10], [10, 0], Extrapolate.CLAMP) }]
        };
    });

    // Parent Scaling Animation
    const animatedParentStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: parentScale.value },
            { translateY: interpolate(editMenuProgress.value, [0, 1], [0, -30], Extrapolate.CLAMP) }
        ],
        borderRadius: interpolate(parentScale.value, [1, 0.92], [0, 24], Extrapolate.CLAMP),
        overflow: 'hidden',
        flex: 1,
        backgroundColor: colors.background
    }));

    const editBackdropStyle = useAnimatedStyle(() => ({
        opacity: interpolate(editMenuProgress.value, [0, 1], [0, 1], Extrapolate.CLAMP),
    }));

    const editSheetStyle = useAnimatedStyle(() => ({
        opacity: interpolate(editMenuProgress.value, [0, 1], [0, 1], Extrapolate.CLAMP),
        transform: [
            { translateY: interpolate(editMenuProgress.value, [0, 1], [40, 0], Extrapolate.CLAMP) },
            { scale: interpolate(editMenuProgress.value, [0, 1], [0.98, 1], Extrapolate.CLAMP) }
        ]
    }));

    const qrBackdropStyle = useAnimatedStyle(() => ({
        opacity: interpolate(qrProgress.value, [0, 1], [0, 1], Extrapolate.CLAMP),
    }));

    const qrSheetStyle = useAnimatedStyle(() => ({
        opacity: interpolate(qrProgress.value, [0, 1], [0, 1], Extrapolate.CLAMP),
        transform: [
            { translateY: interpolate(qrProgress.value, [0, 1], [40, 0], Extrapolate.CLAMP) },
            { scale: interpolate(qrProgress.value, [0, 1], [0.98, 1], Extrapolate.CLAMP) }
        ]
    }));

    const isDark = effectiveTheme === 'dark';
    const qrTheme = resolveThemeVariant(activeTheme, isDark);
    const WallpaperComp = WallpaperComponents[qrTheme.patternType || 'doodles'] || TelegramDoodleWallpaper;
    const selectedPattern = selectedPatternId || activeTheme.id;
    const qrAccent = qrTheme.patternColor || (qrTheme.backgroundGradient?.[0] as string) || colors.primary;
    const qrGradient = (qrTheme.backgroundGradient?.length ? (qrTheme.backgroundGradient as string[]) : [colors.primary, colors.primary]) as [string, string];
    const QR_SIZE = Math.min(260, Math.max(210, Math.floor(windowWidth * 0.62)));

    // Avatar Shrink Animation
    const avatarStyle = useAnimatedStyle(() => {
        const size = interpolate(scrollY.value, [0, 100], [100, 32], Extrapolate.CLAMP);
        // Fade out as scroll increases to transition to title in header

        return {
            width: size,
            height: size,
            borderRadius: size / 2,
            top: interpolate(scrollY.value, [0, 100], [insets.top + 10, insets.top + 6], Extrapolate.CLAMP),
            left: (windowWidth - size) / 2,
            position: 'absolute',
            zIndex: 50,
            opacity: interpolate(scrollY.value, [0, 80], [1, 0], Extrapolate.CLAMP)
        };
    });

    const cameraIconStyle = useAnimatedStyle(() => ({
        opacity: interpolate(scrollY.value, [0, 50], [1, 0], Extrapolate.CLAMP),
        transform: [{ scale: interpolate(scrollY.value, [0, 50], [1, 0.5], Extrapolate.CLAMP) }]
    }));

    const headerMaskStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expandState.value, [0, 0.2], [1, 0])
    }));

    const backButtonStyle = useAnimatedStyle(() => ({
        opacity: headerProgress.value,
        transform: [{ scale: headerProgress.value }]
    }));

    const floatingNameWrapperStyle = useAnimatedStyle(() => {
        const BASE_TOP = insets.top + 140
        const EXPAND_TOP = windowHeight * 0.5 - 80; // Place on banner bottom
        const PIN_OFFSET = 185; // BASE_TOP - (insets.top + 10)

        // Vertical Movement
        const currentTop = interpolate(expandState.value, [0, 1], [BASE_TOP, EXPAND_TOP]);

        // Vertical scroll offset
        const translateY = -Math.min(scrollY.value, PIN_OFFSET);

        // Scale Effect
        const scale = interpolate(scrollY.value, [160, 200], [1, 0.82], Extrapolate.CLAMP);

        return {
            top: currentTop,
            paddingLeft: interpolate(expandState.value, [0, 1], [0, 20]),
            alignItems: expandState.value > 0.5 ? 'flex-start' : 'center',
            transform: [
                { translateY },
                { scale }
            ],
            zIndex: 1200, // Above everything
            // Fade out on scroll into header
            opacity: interpolate(scrollY.value, [220, 250], [1, 0], Extrapolate.CLAMP)
        };
    });

    const floatingNameTextStyle = useAnimatedStyle(() => {
        const textColor = interpolate(expandState.value, [0.8, 1], [0, 1]) === 1 ? '#fff' : colors.text;
        return {
            color: textColor,
            fontSize: interpolate(scrollY.value, [-100, 0, 100], [34, 28, 18], Extrapolate.CLAMP),
        };
    });

    const floatingSubtextStyle = useAnimatedStyle(() => {
        const textColor = interpolate(expandState.value, [0.8, 1], [0, 1]) === 1 ? 'rgba(255,255,255,0.8)' : colors.textSecondary;
        return {
            color: textColor,
            opacity: interpolate(expandState.value, [0.8, 1], [0.8, 1]), // Slightly brighter on banner
        };
    });

    return (
        <View style={{ flex: 1, backgroundColor: '#000' }} >
            <Animated.View style={animatedParentStyle}>

                {/* MASKED HEADER */}
                <Animated.View style={[
                    styles.headerContainer,
                    { height: insets.top + 60, zIndex: 140, pointerEvents: 'none' }, // Below Content Name (150) but above Banner (100)
                    headerMaskStyle
                ]}>
                    <MaskedViewAny
                        style={StyleSheet.absoluteFill}
                        maskElement={
                            <LinearGradient
                                colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']}
                                locations={[0.6, 1]}
                                style={StyleSheet.absoluteFill}
                            />
                        }
                    >
                        <BlurView intensity={25} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.7) }]} />
                    </MaskedViewAny>
                </Animated.View>

                {/* HEADER CONTENT */}
                <View style={[styles.headerContentContainer, { height: HEADER_HEIGHT, paddingTop: insets.top, zIndex: 1100 }]} pointerEvents="box-none">
                    {/* Left: Back Button or QR */}
                    <View style={styles.headerBtnWrapper}>
                        {activeView !== 'main' ? (
                            <Animated.View style={[
                                backButtonStyle
                            ]}>
                                <AnimatedGlassButton
                                    onPress={handleBack}
                                    progress={headerProgress}
                                    showPanelIcon={true}
                                    homeIcon={<View />}
                                    panelIcon={<ArrowLeft color={colors.text} size={22} />}
                                    effectiveTheme={effectiveTheme}
                                    size={44}
                                    homeBackgroundColor={'transparent'}
                                />
                            </Animated.View>
                        ) : (
                            <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <TouchableOpacity onPress={openQr} style={styles.iconBtnCircle}>
                                    <QrCode size={20} color={colors.text} />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        )}
                    </View>

                    {/* Center: Title (Only on secondary views) */}
                    <View style={styles.headerCenterWrapper}>
                        {activeView !== 'main' && (
                            <Animated.View style={[{ alignItems: 'center' }, headerTitleStyle]}>
                                <Text style={[styles.headerTitle, { color: colors.text }]}>{headerTitle}</Text>
                            </Animated.View>
                        )}
                    </View>

                    {/* Right: Edit Button or Spacer */}
                    <View style={styles.headerBtnWrapper}>
                        {activeView === 'main' ? (
                            <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <TouchableOpacity onPress={openEditMenu} style={styles.iconBtnCircle}>
                                    <Text style={{ color: colors.text, fontSize: 13, fontWeight: '600' }}>{t('settings.edit')}</Text>
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        ) : (
                            <View style={{ width: 44 }} />
                        )}
                    </View>
                </View>

                {/* HERO AVATAR (Pinned; does not scroll) */}
                {activeView === 'main' && (
                    <View
                        pointerEvents="box-none"
                        style={[
                            StyleSheet.absoluteFill,
                            { zIndex: 1060, top: HERO_TOP }
                        ]}
                    >
                        <View pointerEvents="box-none" style={{ alignItems: 'center' }}>
                            <Animated.View pointerEvents="box-none" style={[wrapperStyle, { alignItems: 'center', justifyContent: 'center' }]}>
                                {/* LAYER 1: Standard Banner Image (Visible when expanding) */}
                                <Animated.View style={[StyleSheet.absoluteFill, innerImageStyle, bannerLayerStyle]} pointerEvents="none">
                                    {user?.profileImage ? (
                                        <View style={{ width: '100%', height: '100%' }}>
                                            <Image
                                                source={{ uri: user.profileImage }}
                                                style={{ width: '100%', height: '100%' }}
                                                resizeMode="cover"
                                            />
                                            {/* Glass Strip for Banner */}
                                            <AnimatedBlurView
                                                intensity={0}
                                                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                                style={[{ position: 'absolute', bottom: 0, left: 0, right: 0 }, bannerBottomBlurStyle]}
                                            />
                                        </View>
                                    ) : (
                                        <View style={{ width: '100%', height: '100%', backgroundColor: colors.primary, alignItems: 'center', justifyContent: 'center' }}>
                                            <Text style={{ fontSize: 18, color: '#fff' }}>{(user?.name?.[0] || user?.username?.[0] || 'U').toUpperCase()}</Text>
                                        </View>
                                    )}
                                </Animated.View>

                                {/* LAYER 2: Skia Liquid Avatar (Visible when collapsed) */}
                                {user?.profileImage && skiaImage ? (
                                    <Animated.View style={[{ position: 'absolute', top: -100, left: 0, right: 0, bottom: 0 }, liquidLayerStyle]} pointerEvents="none">
                                        <Canvas style={{ flex: 1 }}>
                                            <Mask
                                                mode="luminance"
                                                mask={
                                                    <Group>
                                                        <Group layer={
                                                            <Paint>
                                                                <ColorMatrix matrix={LIQUID_MATRIX} />
                                                            </Paint>
                                                        }>
                                                            <Group>
                                                                <BlurMask blur={15} style="normal" />
                                                                {/* Reduced radius to 46 to prevent squaring off at edges (100px width) */}
                                                                <Circle cx={50} cy={150} r={46} color="white" />
                                                                <Circle cx={50} cy={dragDistance} r={32} color="white" />
                                                            </Group>
                                                        </Group>
                                                    </Group>
                                                }
                                            >
                                                <SkiaImage
                                                    image={skiaImage}
                                                    x={0}
                                                    y={30}
                                                    width={100}
                                                    height={240}
                                                    fit="cover"
                                                >
                                                    <Blur blur={blurRadius} />
                                                    <ColorMatrix matrix={darkeningMatrix} />
                                                </SkiaImage>
                                            </Mask>
                                        </Canvas>
                                    </Animated.View>
                                ) : null}

                                {/* Edit/Pen Button */}
                                <Animated.View style={[
                                    {
                                        position: 'absolute',
                                        bottom: 0,
                                        right: 0,
                                        zIndex: 30
                                    },
                                    penButtonStyle
                                ]}>
                                    <TouchableOpacity onPress={pickImage}>
                                        <SafeLiquidGlass
                                            style={{ padding: 8, borderRadius: 20 }}
                                            blurIntensity={15}
                                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                        >
                                            <Edit2 size={16} color={colors.text} />
                                        </SafeLiquidGlass>
                                    </TouchableOpacity>
                                </Animated.View>
                            </Animated.View>
                        </View>
                    </View>
                )}

                <Animated.ScrollView
                    onScroll={activeView === 'main' ? scrollHandler : undefined}
                    scrollEventThrottle={16}
                    style={{ zIndex: 1050 }}
                    contentContainerStyle={{
                        paddingTop: insets.top + 0,
                        paddingBottom: 100,
                        flexGrow: 1
                    }}
                    showsVerticalScrollIndicator={false}
                >
                    <View style={{ paddingHorizontal: 16, flex: 1 }}>
                        {activeView === 'main' && (
                            <View style={{ flex: 1 }}>
                                {/* Spacer for pinned hero avatar */}
                                <View style={{ height: HERO_COLLAPSED_HEIGHT }} />

                                {/* Profile Info Space - Hidden Spacer for Floating Name */}
                                <View style={{ alignItems: 'center', marginBottom: 30, opacity: 0 }}>
                                    <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                        <Text style={{ fontSize: 18, color: colors.text }}>
                                            {user?.name || user?.username || 'Guest'}
                                        </Text>
                                        <InlineBadge tier={userTier} size={18} />
                                    </View>

                                    <Text style={{ fontSize: 13, color: colors.textSecondary, opacity: 0.7, marginTop: 2 }}>
                                        {user?.phoneNumber ? `${user.phoneNumber} • ` : ''}@{user?.username || 'unknown'}
                                    </Text>
                                </View>

                                <SettingsSection title={t('settings.account')}>
                                    <SettingItem
                                        icon={User}
                                        label={t('settings.editProfile')}
                                        value={user?.name ? 'Manage' : 'Set up'}
                                        onPress={() => router.push('/profile')}
                                        color={colors.text}
                                    />
                                    <SettingItem
                                        icon={Bookmark}
                                        label={t('settings.savedMessages')}
                                        onPress={() => router.push('/saved-messages')}
                                        color="#f59e0b"
                                    />
                                    <SettingItem
                                        icon={QrCode}
                                        label={t('settings.yourQr')}
                                        value="Show"
                                        onPress={openQr}
                                        color="#10b981"
                                    />
                                    <SettingItem
                                        icon={Server}
                                        label={t('settings.connectionManager')}
                                        value="Automatic"
                                        onPress={() => setShowConnectionModal(true)}
                                        color="#3b82f6"
                                        divider={false}
                                    />
                                </SettingsSection>

                                <SettingsSection title={t('settings.privacySecurity')}>
                                    <SettingItem
                                        icon={Shield}
                                        label={t('settings.privacy')}
                                        value="Manage"
                                        onPress={() => router.push('/settings/privacy')}
                                        color="#10b981"
                                    />
                                    <SettingItem
                                        icon={Key}
                                        label={t('settings.secretKey')}
                                        onPress={() => router.push('/settings/secret-key')}
                                        color="#8b5cf6"
                                        divider={false}
                                    />
                                </SettingsSection>

                                <SettingsSection title={t('settings.notifications')}>
                                    <SettingItem
                                        icon={Bell}
                                        label="Push Notifications"
                                        type="switch"
                                        value={notificationsEnabled}
                                        onPress={async (val) => {
                                            const enabling = val !== false;
                                            if (enabling) {
                                                // Check OS-level permission first
                                                const { status } = await Notifications.getPermissionsAsync();
                                                if (status === 'denied') {
                                                    Alert.alert(
                                                        'Notifications Disabled',
                                                        'Push notifications are blocked at the system level. Please enable them in your device Settings.',
                                                        [
                                                            { text: 'Cancel', style: 'cancel' },
                                                            { text: 'Open Settings', onPress: () => Linking.openSettings() },
                                                        ]
                                                    );
                                                    return;
                                                }
                                            }
                                            await setNotificationsEnabled(enabling);
                                        }}
                                        color="#ef4444"
                                        divider={false}
                                    />
                                </SettingsSection>

                                <SettingsSection title="APPEARANCE">
                                    <SettingItem
                                        icon={Moon}
                                        label="Appearance"
                                        value={theme === 'dark' ? 'Dark' : 'Light'}
                                        onPress={() => router.push('/settings/appearance')}
                                        color={colors.text}
                                        divider={false}
                                    />
                                </SettingsSection>

                                <SettingsSection title="MEDIA & STORAGE">
                                    <SettingItem
                                        icon={HardDrive}
                                        label="Media Cache"
                                        value="Manage"
                                        onPress={() => router.push('/media-cache')}
                                        color="#ec4899"
                                        divider={false}
                                    />
                                </SettingsSection>

                                <SettingsSection title="SUBSCRIPTION">
                                    <SettingItem
                                        icon={Crown}
                                        label="Your Plan"
                                        value={getTierInfo(userTier).label}
                                        onPress={() => setShowSubscriptionModal(true)}
                                        color="#FFD700"
                                    />
                                    <SettingItem
                                        icon={Users}
                                        label="Invite Friends"
                                        value={`${stats?.verifiedCount || 0}/4000`}
                                        onPress={() => setShowReferralModal(true)}
                                        color="#CD7F32"
                                        divider={userTier === 'silver' || userTier === 'gold'}
                                    />
                                    {(userTier === 'silver' || userTier === 'gold') && (
                                        <SettingItem
                                            icon={Briefcase}
                                            label="Business Settings"
                                            onPress={() => setShowBusinessModal(true)}
                                            color="#3b82f6"
                                            divider={false}
                                        />
                                    )}
                                </SettingsSection>


                                <View style={styles.footer}>
                                    <Text style={[styles.footerText, { color: colors.textSecondary }]}>Vibe Mobile v1.0.3</Text>
                                </View>
                            </View>
                        )}

                        {/* Privacy and Secret Key are now routed pages under /settings/* */}




                    </View>
                </Animated.ScrollView>

                {/* FLOATING PINNED NAME (Over Mask) */}
                {activeView === 'main' && (
                    <Animated.View
                        pointerEvents="none"
                        style={[
                            {
                                position: 'absolute',
                                left: 0,
                                right: 0,
                                zIndex: 1000,
                                height: 60, // approximate height of content
                            },
                            floatingNameWrapperStyle
                        ]}>
                        <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                            <Animated.Text style={[
                                { fontWeight: '400' },
                                floatingNameTextStyle
                            ]}>
                                {user?.name || user?.username || 'Guest'}
                            </Animated.Text>
                            <InlineBadge tier={userTier} size={18} />
                        </View>

                        <Animated.Text style={[
                            { fontSize: 13, marginTop: 2 },
                            floatingSubtextStyle
                        ]}>
                            {user?.phoneNumber ? `${user.phoneNumber} • ` : ''}@{user?.username || 'unknown'}
                        </Animated.Text>
                    </Animated.View>
                )}

            </Animated.View>

            {/* Edit Menu Overlay (Home-style focus) */}
            <Animated.View
                pointerEvents={isEditMenuOpen ? 'auto' : 'none'}
                style={[StyleSheet.absoluteFill, { zIndex: 5000 }, editBackdropStyle]}
            >
                <TouchableOpacity
                    activeOpacity={1}
                    onPress={closeEditMenu}
                    style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.35)' }]}
                />

                <Animated.View
                    style={[
                        {
                            position: 'absolute',
                            left: 16,
                            right: 16,
                            top: insets.top + 70,
                        },
                        editSheetStyle
                    ]}
                >
                    <View style={[styles.sectionContainer, { backgroundColor: colors.card, borderRadius: 26, overflow: 'hidden' }]}>
                        <TouchableOpacity
                            onPress={() => { closeEditMenu(); router.push('/profile'); }}
                            activeOpacity={0.8}
                            style={styles.settingRow}
                        >
                            <View style={styles.settingLabelWrap}>
                                <Text style={[styles.settingLabel, { color: colors.text }]} numberOfLines={1}>Edit Profile</Text>
                            </View>
                            <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                        </TouchableOpacity>
                        <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />
                        <TouchableOpacity
                            onPress={async () => {
                                closeEditMenu();
                                if (user?.userId) await Clipboard.setStringAsync(user.userId);
                            }}
                            activeOpacity={0.8}
                            style={styles.settingRow}
                        >
                            <View style={styles.settingLabelWrap}>
                                <Text style={[styles.settingLabel, { color: colors.text }]} numberOfLines={1}>Copy User ID</Text>
                            </View>
                        </TouchableOpacity>
                        <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />
                        <TouchableOpacity
                            onPress={() => { closeEditMenu(); router.push('/settings/privacy'); }}
                            activeOpacity={0.8}
                            style={styles.settingRow}
                        >
                            <View style={styles.settingLabelWrap}>
                                <Text style={[styles.settingLabel, { color: colors.text }]} numberOfLines={1}>Privacy</Text>
                            </View>
                            <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                        </TouchableOpacity>
                    </View>
                </Animated.View>
            </Animated.View>

            <Modal
                visible={isQrOpen}
                transparent
                animationType="none"
                statusBarTranslucent
                onRequestClose={closeQr}
            >
                <View style={{ flex: 1, backgroundColor: '#000' }}>
                    <View style={[StyleSheet.absoluteFill, { backgroundColor: colors.background }]}>
                        <WallpaperComp theme={qrTheme} width={windowWidth} height={windowHeight} />
                    </View>

                    <Animated.View style={[StyleSheet.absoluteFill, qrSheetStyle]}>
                        {/* Top-left close */}
                        <View style={{ position: 'absolute', top: insets.top + 10, left: 16, zIndex: 20 }}>
                            <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={18} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <TouchableOpacity onPress={closeQr} style={styles.iconBtnCircle} activeOpacity={0.85}>
                                    <ArrowLeft size={22} color={colors.text} />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        </View>

                        {/* QR Card */}
                        <View style={{ flex: 1, paddingTop: insets.top + 60, paddingHorizontal: 16, paddingBottom: insets.bottom + 200 }}>
                            <View style={{ flex: 1, justifyContent: 'center' }}>
                                <View style={{ alignSelf: 'center', width: '100%', maxWidth: 420 }}>
                                    <View style={{ alignItems: 'center' }}>
                                        <View
                                            style={{
                                                position: 'absolute',
                                                top: -34,
                                                width: 68,
                                                height: 68,
                                                borderRadius: 34,
                                                backgroundColor: '#fff',
                                                alignItems: 'center',
                                                justifyContent: 'center',
                                                zIndex: 10,
                                                shadowColor: '#000',
                                                shadowOpacity: 0.18,
                                                shadowRadius: 16,
                                                shadowOffset: { width: 0, height: 10 },
                                                elevation: 10,
                                            }}
                                        >
                                            <View style={{ width: 60, height: 60, borderRadius: 30, overflow: 'hidden', backgroundColor: withAlpha(colors.text, 0.08), alignItems: 'center', justifyContent: 'center' }}>
                                                {!!user?.profileImage ? (
                                                    <Image source={{ uri: user.profileImage }} style={{ width: '100%', height: '100%' }} />
                                                ) : (
                                                    <Text style={{ fontSize: 22, fontWeight: '900', color: colors.text }}>
                                                        {(user?.name?.[0] || user?.username?.[0] || 'V').toUpperCase()}
                                                    </Text>
                                                )}
                                            </View>
                                        </View>

                                        <View style={{ width: '100%', maxWidth: Math.min(380, windowWidth - 48) }}>
                                            {/* Gradient border (shows theme gradient) */}
                                            <LinearGradient
                                                colors={qrGradient}
                                                start={{ x: 0, y: 0 }}
                                                end={{ x: 1, y: 1 }}
                                                style={{ borderRadius: 36, padding: 2 }}
                                            >
                                                {/* White square card for scannability */}
                                                <View
                                                    style={{
                                                        backgroundColor: '#fff',
                                                        borderRadius: 34,
                                                        overflow: 'hidden',
                                                        width: '100%',
                                                        aspectRatio: 1,
                                                        alignItems: 'center',
                                                        justifyContent: 'center',
                                                        paddingTop: 22, // space for avatar overlap
                                                    }}
                                                >
                                                    <QRCode
                                                        value={`vibe:${user?.userId || ''}`}
                                                        size={QR_SIZE}
                                                        color={qrAccent}
                                                        backgroundColor="#fff"
                                                        logo={VIBE_QR_LOGO}
                                                        logoSize={56}
                                                        logoBorderRadius={14}
                                                        logoBackgroundColor="#fff"
                                                        getRef={(c) => { qrRef.current = c; }}
                                                    />
                                                </View>
                                            </LinearGradient>
                                        </View>

                                        {/* Gradient preview bar */}
                                        <View style={{ marginTop: 14, width: 96, height: 10, borderRadius: 5, overflow: 'hidden' }}>
                                            <LinearGradient colors={qrGradient} start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }} style={StyleSheet.absoluteFill} />
                                        </View>
                                    </View>
                                </View>
                            </View>
                        </View>

                        {/* Bottom Sheet */}
                        <View style={{ position: 'absolute', left: 0, right: 0, bottom: 0 }}>
                            <SafeLiquidGlass
                                style={{ borderTopLeftRadius: 28, borderTopRightRadius: 28, overflow: 'hidden', paddingTop: 14, paddingBottom: insets.bottom + 18 }}
                                blurIntensity={18}
                                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                            >
                                <View style={{ paddingHorizontal: 16 }}>
                                    <Text style={{ color: colors.text, fontSize: 17, fontWeight: '900', textAlign: 'center' }}>QR Code</Text>
                                </View>

                                <View style={{ height: 12 }} />

                                <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 16, gap: 12 }}>
                                    {PRESET_THEMES.slice(0, 8).map((t) => {
                                        const isActive = (selectedPattern === t.id);
                                        const thumbTheme = resolveThemeVariant(t, isDark);
                                        const ThumbComp = WallpaperComponents[thumbTheme.patternType || 'doodles'] || TelegramDoodleWallpaper;
                                        return (
                                            <TouchableOpacity
                                                key={t.id}
                                                activeOpacity={0.85}
                                                onPress={() => setPatternTheme(t.id)}
                                                style={{ width: 74, height: 98, borderRadius: 18, overflow: 'hidden', borderWidth: 2, borderColor: isActive ? colors.primary : 'transparent' }}
                                            >
                                                <ThumbComp theme={thumbTheme} width={74} height={98} />
                                            </TouchableOpacity>
                                        );
                                    })}
                                </ScrollView>

                                <View style={{ height: 14 }} />

                                <View style={{ paddingHorizontal: 16 }}>
                                    <TouchableOpacity
                                        onPress={shareQr}
                                        activeOpacity={0.9}
                                        style={{ height: 52, borderRadius: 20, backgroundColor: colors.primary, alignItems: 'center', justifyContent: 'center' }}
                                    >
                                        <Text style={{ color: '#fff', fontWeight: '900', fontSize: 16 }}>Share QR Code</Text>
                                    </TouchableOpacity>

                                    <TouchableOpacity
                                        onPress={() => { closeQr(); router.push('/qr-scan'); }}
                                        activeOpacity={0.85}
                                        style={{ height: 52, borderRadius: 20, marginTop: 10, alignItems: 'center', justifyContent: 'center' }}
                                    >
                                        <Text style={{ color: colors.primary, fontWeight: '900', fontSize: 16 }}>Scan QR Code</Text>
                                    </TouchableOpacity>
                                </View>
                            </SafeLiquidGlass>
                        </View>
                    </Animated.View>
                </View>
            </Modal>

            {/* Connection Modal Overlay (Outside scaled view) */}
            < ConnectionModal
                visible={showConnectionModal}
                onClose={() => setShowConnectionModal(false)
                }
                parentScale={parentScale}
            />

            {/* Subscription Modal */}
            < SubscriptionModal
                visible={showSubscriptionModal}
                onClose={() => setShowSubscriptionModal(false)}
                parentScale={parentScale}
                userId={user?.userId || ''}
            />

            {/* Referral Modal */}
            <ReferralModal
                visible={showReferralModal}
                onClose={() => setShowReferralModal(false)}
                parentScale={parentScale}
                userId={user?.userId || ''}
            />

            {/* Business Settings Modal */}
            <BusinessSettingsModal
                visible={showBusinessModal}
                onClose={() => setShowBusinessModal(false)}
                parentScale={parentScale}
                userId={user?.userId || ''}
            />

        </View >
    );
}

const styles = StyleSheet.create({
    mainContent: { flex: 1 },

    // Header Styles matched with Chat
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 1000 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 4 },
    headerBtnWrapper: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    glassBtnCircle: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    headerCenterWrapper: { flex: 1, alignItems: 'center', justifyContent: 'center', marginHorizontal: 10, height: 44 },
    headerTitle: { fontSize: 17, fontWeight: '700', textAlign: 'center' },

    sectionWrapper: { marginBottom: 24 },
    sectionHeader: { fontSize: 13, fontWeight: '600', marginBottom: 8, marginLeft: 16, opacity: 0.6, letterSpacing: 0.5, textTransform: 'uppercase' },
    sectionContainer: { borderRadius: 26, overflow: 'hidden' },
    settingRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, paddingHorizontal: 18, minHeight: 58 },
    divider: { height: 1, marginLeft: 18 + 32 + 14 },
    settingIconContainer: { width: 30, height: 30, borderRadius: 8, alignItems: 'center', justifyContent: 'center', marginRight: 14 },
    settingLabelWrap: { flex: 1, minWidth: 0 },
    settingLabel: { fontSize: 16, fontWeight: '600' },
    settingRight: { flexDirection: 'row', alignItems: 'center', gap: 8 },
    settingValue: { fontSize: 15, opacity: 0.7 },
    footer: { alignItems: 'center', marginTop: 10, marginBottom: 30 },
    footerText: { fontSize: 12, opacity: 0.5 },
    cameraBadge: {
        position: 'absolute',
        bottom: 0,
        right: 0,
        width: 28,
        height: 28,
        borderRadius: 14,
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.2,
        shadowRadius: 4,
        elevation: 4
    }
});
