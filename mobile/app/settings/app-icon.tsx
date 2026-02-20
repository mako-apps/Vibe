import React, { useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Image, ScrollView, Dimensions, Platform, Alert } from 'react-native';
import { useRouter, Stack } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Check, ShieldCheck } from 'lucide-react-native';
import { BlurView } from 'expo-blur';
import { LinearGradient } from 'expo-linear-gradient';
import Animated, { FadeIn, FadeInDown, useAnimatedStyle, useSharedValue, withSpring, interpolate, Extrapolate } from 'react-native-reanimated';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const ICON_SIZE = (SCREEN_WIDTH - 48 - 32) / 3; // 3 columns

// Define available icons
const APP_ICONS = [
    { id: 'logo1', name: 'Obsidian', source: require('../../assets/logos/logo1.png'), description: 'Teal on Black' },
    { id: 'logo2', name: 'Ethereal', source: require('../../assets/logos/logo2.png'), description: 'Teal on White' },
    { id: 'logo3', name: 'Midnight', source: require('../../assets/logos/logo3.png'), description: 'White on Black' },
    { id: 'logo4', name: 'Aurora', source: require('../../assets/logos/logo4.png'), description: 'White on Teal' },
    { id: 'logo5', name: 'Phantom', source: require('../../assets/logos/logo5.png'), description: 'Black on Teal' },
];

export default function AppIconScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const [activeIcon, setActiveIcon] = useState('logo1'); // Default to logo1

    const handleIconSelect = (iconId: string) => {
        setActiveIcon(iconId);
        // creating a "fake" change for now as actual icon changing requires native module config
        // In a real scenario seamlessly: SharedDefaults or native method
        if (Platform.OS === 'web') return;

        // Haptic feedback could be added here
    };

    const Header = () => (
        <View style={[styles.headerContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
            <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                    <ArrowLeft size={24} color={colors.text} />
                </TouchableOpacity>
            </SafeLiquidGlass>
            <Text style={[styles.headerTitle, { color: colors.text }]}>App Icon</Text>
            <View style={{ width: 44 }} />
        </View>
    );

    const PreviewSection = () => {
        const currentIcon = APP_ICONS.find(i => i.id === activeIcon) || APP_ICONS[0];

        return (
            <Animated.View entering={FadeInDown.delay(100).springify()} style={styles.previewContainer}>
                <View style={[styles.mainPreviewIcon, { shadowColor: colors.primary }]}>
                    <Image source={currentIcon.source} style={styles.largeIconImage} />
                </View>
                <Text style={[styles.previewLabel, { color: colors.text }]}>
                    {currentIcon.name}
                </Text>
                <Text style={[styles.previewDescription, { color: colors.textSecondary }]}>
                    {currentIcon.description}
                </Text>
            </Animated.View>
        );
    };

    return (
        <View style={{ flex: 1, backgroundColor: '#000' }}>
            <Stack.Screen options={{ headerShown: false }} />
            <View style={[{ flex: 1, backgroundColor: colors.background }]}>

                <Header />

                <ScrollView
                    contentContainerStyle={{ paddingTop: insets.top + 60 + 20, paddingBottom: 40, paddingHorizontal: 24 }}
                    showsVerticalScrollIndicator={false}
                >
                    <PreviewSection />

                    <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>AVAILABLE ICONS</Text>

                    <View style={styles.grid}>
                        {APP_ICONS.map((icon, index) => {
                            const isActive = activeIcon === icon.id;
                            return (
                                <Animated.View
                                    key={icon.id}
                                    entering={FadeInDown.delay(200 + index * 50).springify()}
                                >
                                    <TouchableOpacity
                                        style={[styles.iconOption, isActive && styles.activeOption]}
                                        onPress={() => handleIconSelect(icon.id)}
                                        activeOpacity={0.8}
                                    >
                                        <View style={[
                                            styles.iconFrame,
                                            isActive && { borderColor: colors.primary, borderWidth: 2 }
                                        ]}>
                                            <Image source={icon.source} style={styles.gridIconImage} />
                                            {isActive && (
                                                <View style={[styles.checkBadge, { backgroundColor: colors.primary }]}>
                                                    <Check size={12} color="#fff" strokeWidth={3} />
                                                </View>
                                            )}
                                        </View>
                                        <Text style={[
                                            styles.iconName,
                                            { color: isActive ? colors.primary : colors.text }
                                        ]}>
                                            {icon.name}
                                        </Text>
                                    </TouchableOpacity>
                                </Animated.View>
                            );
                        })}
                    </View>


                </ScrollView>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    headerContainer: {
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
        fontWeight: '600'
    },
    glassBtnCircle: {
        width: 40,
        height: 40,
        borderRadius: 20,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    iconBtnCircle: {
        width: 40,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center'
    },

    // Preview
    previewContainer: {
        alignItems: 'center',
        marginBottom: 48,
    },
    mainPreviewIcon: {
        width: 120,
        height: 120,
        borderRadius: 28,
        overflow: 'hidden',
        backgroundColor: '#000',
        shadowOffset: { width: 0, height: 12 },
        shadowOpacity: 0.4,
        shadowRadius: 16,
        elevation: 15,
        marginBottom: 20,
    },
    largeIconImage: {
        width: '100%',
        height: '100%',
    },
    previewLabel: {
        fontSize: 22,
        fontWeight: '700',
        marginBottom: 4,
    },
    previewDescription: {
        fontSize: 14,
        fontWeight: '500',
        opacity: 0.8,
    },

    // Grid
    sectionTitle: {
        fontSize: 13,
        fontWeight: '600',
        marginBottom: 16,
        opacity: 0.6,
        letterSpacing: 0.5,
        textTransform: 'uppercase'
    },
    grid: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 16,
        justifyContent: 'flex-start',
    },
    iconOption: {
        width: ICON_SIZE,
        alignItems: 'center',
        marginBottom: 16,
    },
    activeOption: {
        // scale?
    },
    iconFrame: {
        width: ICON_SIZE,
        height: ICON_SIZE,
        borderRadius: 18,
        overflow: 'hidden',
        marginBottom: 8,
        backgroundColor: '#1a1a1a',
        padding: 0,
    },
    gridIconImage: {
        width: '100%',
        height: '100%',
    },
    checkBadge: {
        position: 'absolute',
        bottom: 4,
        right: 4,
        width: 20,
        height: 20,
        borderRadius: 10,
        alignItems: 'center',
        justifyContent: 'center',
    },
    iconName: {
        fontSize: 13,
        fontWeight: '500',
        textAlign: 'center',
    },

    // Info
    infoBox: {
        marginTop: 20,
        borderRadius: 16,
        padding: 16,
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
    },
    infoText: {
        fontSize: 13,
        flex: 1,
        lineHeight: 18,
    }
});
