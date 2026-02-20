import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions, Pressable } from 'react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useWallpaperStore, PRESET_THEMES, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { ChevronRight, ArrowLeft, Check } from 'lucide-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Animated, { useSharedValue, useAnimatedStyle, withSpring, interpolate, Extrapolate } from 'react-native-reanimated';
import { MessageBubbleBody } from '../chat/bubbles';
import { Message } from '../../lib/types';
import WallpaperBackground from '../chat/WallpaperBackground';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const PREVIEW_WIDTH = SCREEN_WIDTH - 32;
const PREVIEW_HEIGHT = 200;

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

interface SettingItemProps {
    label: string;
    value?: string | boolean;
    type?: 'link' | 'switch' | 'value' | 'button';
    onPress?: (val?: boolean) => void;
    color?: string;
    divider?: boolean;
}

export default function ThemeSettings() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme, theme } = useThemeStore();
    const { activeTheme, activeThemeId, updateCustomTheme } = useWallpaperStore();

    const isDark = effectiveTheme === 'dark';
    const themeToRender = resolveThemeVariant(activeTheme, isDark);

    const dummyMessages: { msg: Message; isMe: boolean }[] = [
        { msg: { id: '1', fromId: 'them', type: 'text', plaintext: "Testing the theme...", encryptedContent: '', timestamp: Date.now() }, isMe: false },
        { msg: { id: '2', fromId: 'me', type: 'text', plaintext: "Looks great!", encryptedContent: '', timestamp: Date.now() }, isMe: true }
    ];

    const handleApplyPalette = (presetId: string) => {
        const preset = PRESET_THEMES.find(t => t.id === presetId);
        if (!preset) return;

        // Apply ONLY the color/gradient properties from the preset
        // but preserve the current wallpaper pattern (maskedImage and patternType)
        updateCustomTheme({
            ...activeTheme,
            id: 'custom',
            // Update mode-specific colors
            light: {
                ...preset.light,
            },
            dark: {
                ...preset.dark,
            },
            // Update top-level fallbacks
            backgroundGradient: preset.backgroundGradient,
            bubbleMe: preset.bubbleMe,
            bubbleThem: preset.bubbleThem,
            patternGradientColors: preset.patternGradientColors,
            patternGradientLocations: preset.patternGradientLocations,
            textColorMe: preset.textColorMe,
            textColorThem: preset.textColorThem,
        });
    };

    const SettingsSection = ({ title, children }: { title?: string; children: React.ReactNode }) => (
        <View style={styles.sectionWrapper}>
            {title && <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>{title}</Text>}
            <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                {children}
            </View>
        </View>
    );

    const SettingItem = ({ label, value, type = 'link', onPress, color, divider = true }: SettingItemProps) => (
        <View>
            <TouchableOpacity
                style={styles.settingRow}
                onPress={() => onPress?.()}
                activeOpacity={0.7}
            >
                <Text style={[styles.settingLabel, { color: colors.text }]}>{label}</Text>

                <View style={styles.settingRight}>
                    {type === 'link' && (
                        <>
                            {value && typeof value === 'string' && (
                                <Text style={[styles.settingValue, { color: colors.textSecondary }]}>{value}</Text>
                            )}
                            <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                        </>
                    )}
                </View>
            </TouchableOpacity>
            {divider && <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />}
        </View>
    );

    return (
        <View style={{ flex: 1, backgroundColor: '#000' }}>
            <View style={[{ flex: 1, backgroundColor: colors.background }]}>

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
                <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                            <ArrowLeft size={24} color={colors.text} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                    <Text style={[styles.headerTitle, { color: colors.text }]}>Appearance</Text>
                    <View style={{ width: 44 }} />
                </View>

                <ScrollView contentContainerStyle={[styles.scrollContent, { paddingTop: insets.top + 80 }]} showsVerticalScrollIndicator={false}>

                    {/* BANNER PREVIEW */}
                    <View style={styles.previewSection}>
                        <View style={styles.previewCard}>
                            <View style={styles.previewWallpaper}>
                                <WallpaperBackground theme={themeToRender} width={PREVIEW_WIDTH} height={PREVIEW_HEIGHT} />
                            </View>
                            <View style={styles.previewBubbles}>
                                {dummyMessages.map((item) => {
                                    const resolvedBubbleTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
                                    const gradient = item.isMe
                                        ? (resolvedBubbleTheme.bubbleMeGradient && resolvedBubbleTheme.bubbleMeGradient.length >= 2 ? resolvedBubbleTheme.bubbleMeGradient : [resolvedBubbleTheme.bubbleMe, resolvedBubbleTheme.bubbleMe])
                                        : (resolvedBubbleTheme.bubbleThemGradient && resolvedBubbleTheme.bubbleThemGradient.length >= 2 ? resolvedBubbleTheme.bubbleThemGradient : [resolvedBubbleTheme.bubbleThem, resolvedBubbleTheme.bubbleThem]);

                                    return (
                                        <View key={item.msg.id} style={{
                                            marginBottom: 8,
                                            alignItems: item.isMe ? 'flex-end' : 'flex-start',
                                            transform: [{ scale: 1.05 }]
                                        }}>
                                            <LinearGradient
                                                colors={gradient as any}
                                                start={{ x: 0, y: 0 }}
                                                end={{ x: 1, y: 1 }}
                                                style={[
                                                    {
                                                        padding: 8,
                                                        paddingHorizontal: 12,
                                                        borderRadius: 18,
                                                        maxWidth: '85%',
                                                    },
                                                    item.isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 }
                                                ]}
                                            >
                                                <MessageBubbleBody
                                                    item={{
                                                        ...item.msg,
                                                        isMe: item.isMe,
                                                        text: item.msg.plaintext || '',
                                                        timestamp: new Date(item.msg.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                                    } as any}
                                                />
                                            </LinearGradient>
                                        </View>
                                    );
                                })}
                            </View>
                        </View>

                        {/* FAST THEME SELECTOR - APPLY COLOR PLATES ONLY */}
                        <View style={styles.inlineThemeSelector}>
                            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.themesScroll}>
                                {PRESET_THEMES.map((t) => {
                                    const presetResolved = resolveThemeVariant(t, isDark);

                                    // Construct a preview theme that uses the PRESET'S COLORS 
                                    // but the CURRENT ACTIVE WALLPAPER PATTERN
                                    const previewTheme = {
                                        ...presetResolved,
                                        type: themeToRender.type,
                                        maskedImage: themeToRender.maskedImage,
                                        patternType: themeToRender.patternType,
                                    };

                                    const isActive = activeThemeId === t.id;

                                    return (
                                        <TouchableOpacity
                                            key={t.id}
                                            onPress={() => handleApplyPalette(t.id)}
                                            activeOpacity={0.7}
                                            style={{
                                                alignItems: 'center',
                                                marginRight: 12,
                                                opacity: isActive ? 1 : 0.7
                                            }}
                                        >
                                            <View style={{
                                                width: 70,
                                                height: 100,
                                                borderRadius: 16,
                                                overflow: 'hidden',
                                                borderWidth: isActive ? 2 : 1,
                                                borderColor: isActive ? colors.primary : colors.border
                                            }}>
                                                <WallpaperBackground theme={previewTheme} width={70} height={100} />

                                                {/* Mini Bubbles Preview */}
                                                <View style={{ position: 'absolute', bottom: 10, left: 6, right: 6, gap: 5 }}>
                                                    <View style={{
                                                        height: 6,
                                                        width: '50%',
                                                        backgroundColor: presetResolved.bubbleThem,
                                                        borderRadius: 3,
                                                        alignSelf: 'flex-start'
                                                    }} />
                                                    <View style={{
                                                        height: 6,
                                                        width: '70%',
                                                        backgroundColor: presetResolved.bubbleMe,
                                                        borderRadius: 3,
                                                        alignSelf: 'flex-end'
                                                    }} />
                                                </View>

                                                {isActive && (
                                                    <View style={{
                                                        position: 'absolute',
                                                        top: 6,
                                                        right: 6,
                                                        width: 18,
                                                        height: 18,
                                                        borderRadius: 9,
                                                        backgroundColor: colors.primary,
                                                        alignItems: 'center',
                                                        justifyContent: 'center'
                                                    }}>
                                                        <Check size={12} color="#fff" strokeWidth={3} />
                                                    </View>
                                                )}
                                            </View>
                                            <Text style={{
                                                marginTop: 6,
                                                fontSize: 12,
                                                fontWeight: isActive ? '600' : '400',
                                                color: isActive ? colors.text : colors.textSecondary
                                            }}>
                                                {t.name}
                                            </Text>
                                        </TouchableOpacity>
                                    );
                                })}
                            </ScrollView>
                        </View>
                    </View>

                    {/* SETTINGS ROWS */}
                    <SettingsSection title="Appearance">
                        <SettingItem
                            label="Appearance"
                            value={theme === 'dark' ? 'Dark' : theme === 'light' ? 'Light' : 'System'}
                            onPress={() => router.push('/settings/theme-mode')}
                        />
                        <SettingItem
                            label="App Icon"
                            value="Obsidian"
                            onPress={() => router.push('/settings/app-icon')}
                        />
                        <SettingItem
                            label="Chat Wallpaper"
                            onPress={() => router.push('/settings/chat-wallpaper')}
                        />
                        <SettingItem
                            label="Your Color"
                            onPress={() => router.push('/settings/your-color')}
                        />

                    </SettingsSection>

                    <View style={{ height: 40 }} />
                </ScrollView>
            </View>

            {/* Modal Removed */}
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },

    // HEADER STYLES
    headerMaskContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 60,
        pointerEvents: 'none'
    },
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

    scrollContent: { paddingHorizontal: 16, paddingBottom: 40 },
    sectionWrapper: { marginBottom: 24 },
    sectionHeader: { fontSize: 13, fontWeight: '600', marginBottom: 8, marginLeft: 16, opacity: 0.6, letterSpacing: 0.5, textTransform: 'uppercase' },
    sectionContainer: { borderRadius: 24, overflow: 'hidden' },
    settingRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 12, paddingHorizontal: 16, minHeight: 52 },
    divider: { height: 1, marginLeft: 16 },
    settingLabel: { fontSize: 16, flex: 1, fontWeight: '500' },
    settingRight: { flexDirection: 'row', alignItems: 'center', gap: 8 },
    settingValue: { fontSize: 15, opacity: 0.7 },

    // Preview Banner
    previewSection: { marginBottom: 24 },
    previewCard: { height: PREVIEW_HEIGHT, borderRadius: 24, overflow: 'hidden', marginBottom: 16, position: 'relative' },
    previewWallpaper: { ...StyleSheet.absoluteFillObject },
    previewBubbles: { flex: 1, paddingHorizontal: 12, paddingVertical: 8, justifyContent: 'center' },

    // Theme Selector
    inlineThemeSelector: { marginTop: 4 },
    themesScroll: { paddingVertical: 4, gap: 12, paddingHorizontal: 4 },
    thumbCard: { alignItems: 'center', gap: 6 },
    thumbCardInner: { width: 64, height: 80, borderRadius: 12, overflow: 'hidden', borderWidth: 1, borderColor: '#333' },
    thumbCheck: { position: 'absolute', top: 4, right: 4, width: 16, height: 16, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
    thumbLabel: { fontSize: 11, fontWeight: '600' },
    miniBubbleContainer: { position: 'absolute', bottom: 8, left: 8, right: 8, gap: 4 },
    miniBubbleMe: { width: '70%', height: 4, borderRadius: 2, alignSelf: 'flex-end' },
    miniBubbleThem: { width: '50%', height: 4, borderRadius: 2, alignSelf: 'flex-start' },
});
