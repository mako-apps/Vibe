import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { theme as appTheme } from '../theme';

// Wallpapers types
export type WallpaperType = 'none' | 'pattern' | 'image' | 'masked-image';

/**
 * ═══════════════════════════════════════════════════════════════════════════
 * THEME VARIANT — Colors for Light or Dark mode
 * ═══════════════════════════════════════════════════════════════════════════
 */
export interface ThemeVariant {
    backgroundGradient: string[];
    bubbleMe: string;
    bubbleMeGradient?: string[];
    bubbleThem: string;
    bubbleThemGradient?: string[];
    patternColor?: string;
    patternGradientColors?: string[]; // Array of colors for soft gradient flow across patterns
    patternGradientLocations?: number[]; // Added for masked-image control
    maskedImage?: string; // Key for the image asset
    patternOpacity: number;
    textColorMe: string;
    textColorThem: string;
}

/**
 * ═══════════════════════════════════════════════════════════════════════════
 * CHAT THEME — Complete theme with light/dark variants
 * ═══════════════════════════════════════════════════════════════════════════
 */
export interface ChatTheme {
    id: string;
    name: string;
    type: WallpaperType;
    patternType?: string;
    maskedImage?: string; // Top level fallback

    // Light mode variant
    light: ThemeVariant;
    // Dark mode variant  
    dark: ThemeVariant;

    // Flattened properties (resolved based on current system theme)
    backgroundGradient: string[];
    bubbleMe: string;
    bubbleMeGradient?: string[];
    bubbleThem: string;
    bubbleThemGradient?: string[];
    patternOpacity: number;
    patternColor?: string;
    patternGradientColors?: string[]; // Gradient colors for pattern flow
    patternGradientLocations?: number[];
    textColorMe: string;
    textColorThem: string;

    isAdaptive?: boolean;
}

/**
 * ═══════════════════════════════════════════════════════════════════════════
 * CHAT THEME PRESETS — "Spaces of Contemplation"
 * ═══════════════════════════════════════════════════════════════════════════
 * 
 * Each theme is a complete aesthetic experience with BOTH light and dark
 * variants. The theme adapts seamlessly to your system preferences while
 * maintaining its unique character and philosophy.
 * 
 * ═══════════════════════════════════════════════════════════════════════════
 */

// --- PRESETS ---
// High-end, philosophically-inspired presets with light/dark support
export const PRESET_THEMES: ChatTheme[] = [
    /**
     * ═══════════════════════════════════════════════════════════════════════
     * GLACIER (氷河) — "Ancient Ice"
     * ═══════════════════════════════════════════════════════════════════════
     * Pristine blue of ancient glacial ice. Pure and crystalline.
     * NOW THE DEFAULT THEME.
     */
    {
        id: 'glacier',
        name: 'Glacier',
        type: 'masked-image',
        maskedImage: 'doodles',
        patternType: 'doodles',
        light: {
            backgroundGradient: ['#FFFFFF', '#FFFFFF'], // Pure White Background
            bubbleMe: '#00838F',
            bubbleMeGradient: ['#00ACC1', '#00838F'],
            bubbleThem: '#fff',
            bubbleThemGradient: ['#fff', '#fff'],
            patternColor: 'rgba(0, 96, 100, 0.08)',
            patternGradientColors: ['#B2EBF2', '#80DEEA', '#4DD0E1'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.12,
            textColorMe: '#FFFFFF',
            textColorThem: '#000000',
        },
        dark: {
            // "Frozen Depths" — Arctic night waters
            backgroundGradient: ['#000000', '#050507'],
            bubbleMe: '#2A8585',  // Deep Glacier
            bubbleMeGradient: ['#3A9595', '#1A7575'],
            bubbleThem: '#24242C',
            bubbleThemGradient: ['#2F3338', '#20242A'],
            patternColor: 'rgba(58, 158, 158, 0.10)',
            // Deep Ice: Teal -> Cyan -> Cold Blue
            patternGradientColors: ['#115E59', '#0891B2', '#0284C7'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.12,
            textColorMe: '#F0FCFC',
            textColorThem: '#FFFFFF',
        },
        backgroundGradient: ['#000000', '#050507'],
        bubbleMe: '#2A8585',
        bubbleThem: '#24242C',
        bubbleThemGradient: ['#2F3338', '#20242A'],
        patternOpacity: 0.12,
        patternGradientColors: ['#115E59', '#0891B2', '#0284C7'],
        textColorMe: '#F0FCFC',
        textColorThem: '#FFFFFF',
        isAdaptive: true
    },

    /**
     * ═══════════════════════════════════════════════════════════════════════
     * ZEN (枯山水) — "Karesansui"
     * ═══════════════════════════════════════════════════════════════════════
     * Updated to Purple/Violet tones to match the background pattern.
     */
    {
        id: 'zen',
        name: 'Zen',
        type: 'masked-image',
        patternType: 'doodles',
        maskedImage: 'doodles',
        light: {
            backgroundGradient: ['#FFFFFF', '#FFFFFF'], // Pure White Background
            bubbleMe: '#3F51B5',
            bubbleMeGradient: ['#5C6BC0', '#3949AB'],
            bubbleThem: '#F3F4FB',
            bubbleThemGradient: ['#fff', '#fff'],
            patternColor: 'rgba(63, 81, 181, 0.08)',
            patternGradientColors: ['#C5CAE9', '#9FA8DA', '#7986CB'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.12,
            textColorMe: '#FFFFFF',
            textColorThem: '#000000',
        },
        dark: {
            // "Midnight Zen"
            backgroundGradient: ['#000000', '#050507'],
            bubbleMe: '#7C3AED', // Violet/Purple to match pattern
            bubbleMeGradient: ['#8B5CF6', '#6D28D9'],
            bubbleThem: '#24242C',
            bubbleThemGradient: ['#312B3B', '#231E2C'],
            patternColor: 'rgba(124, 58, 237, 0.1)',
            // Sapphire -> Indigo -> Amethyst -> Magenta -> Rose
            patternGradientColors: ['#2563EB', '#4F46E5', '#7C3AED', '#C026D3', '#DB2777'],
            patternGradientLocations: [0, 0.25, 0.5, 0.75, 1],
            patternOpacity: 0.12,
            textColorMe: '#F4F6F7',
            textColorThem: '#FFFFFF',
        },
        // Default values
        backgroundGradient: ['#000000', '#050507'],
        bubbleMe: '#7C3AED',
        bubbleThem: '#24242C',
        bubbleThemGradient: ['#312B3B', '#231E2C'],
        patternOpacity: 0.12,
        patternGradientColors: ['#2563EB', '#4F46E5', '#7C3AED', '#C026D3', '#DB2777'],
        textColorMe: '#F4F6F7',
        textColorThem: '#FFFFFF',
        isAdaptive: true
    },

    /**
     * ═══════════════════════════════════════════════════════════════════════
     * OCEAN (朝の海) — "Morning Sea"
     * ═══════════════════════════════════════════════════════════════════════
     * Dawn light reflecting off calm waters. Azure depths and pearl foam.
     */
    {
        id: 'ocean',
        name: 'Ocean',
        type: 'masked-image',
        maskedImage: 'doodles',
        patternType: 'doodles',
        light: {
            backgroundGradient: ['#FFFFFF', '#FFFFFF'], // Pure White Background
            bubbleMe: '#0277BD',
            bubbleMeGradient: ['#039BE5', '#0277BD'],
            bubbleThem: '#fff',
            bubbleThemGradient: ['#fff', '#fff'],
            patternColor: 'rgba(1, 87, 155, 0.08)',
            patternGradientColors: ['#B3E5FC', '#81D4FA', '#4FC3F7'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.12,
            textColorMe: '#FFFFFF',
            textColorThem: '#000000',
        },
        dark: {
            // "Midnight Tide" — Deep ocean at night
            backgroundGradient: ['#000000', '#050507'],
            bubbleMe: '#3A7DA8',  // Deep Azure
            bubbleMeGradient: ['#4A8DB8', '#2A6D98'],
            bubbleThem: '#24242C',
            bubbleThemGradient: ['#2A313A', '#1B232C'],
            patternColor: 'rgba(90, 175, 212, 0.08)',
            // Deep Current: Dark Blue -> Teal -> Cyan Glow
            patternGradientColors: ['#1E3A8A', '#0F766E', '#06B6D4', '#22D3EE'],
            patternGradientLocations: [0, 0.4, 0.8, 1],
            patternOpacity: 0.15,
            textColorMe: '#F4F8FC',
            textColorThem: '#FFFFFF',
        },
        backgroundGradient: ['#000000', '#050507'],
        bubbleMe: '#3A7DA8',
        bubbleThem: '#24242C',
        bubbleThemGradient: ['#2A313A', '#1B232C'],
        patternOpacity: 0.15,
        patternGradientColors: ['#1E3A8A', '#0F766E', '#06B6D4', '#22D3EE'],
        textColorMe: '#F4F8FC',
        textColorThem: '#FFFFFF',
        isAdaptive: true
    },

    /**
     * ═══════════════════════════════════════════════════════════════════════
     * OBSIDIAN (黒曜石) — "Volcanic Glass"
     * ═══════════════════════════════════════════════════════════════════════
     * Carved from volcanic glass with sapphire bioluminescence.
     * Elegant void containing infinite depth.
     */
    {
        id: 'obsidian',
        name: 'Obsidian',
        type: 'masked-image',
        maskedImage: 'doodles',
        patternType: 'doodles',
        light: {
            backgroundGradient: ['#FFFFFF', '#FFFFFF'], // Pure White Background
            bubbleMe: '#1565C0',
            bubbleMeGradient: ['#1E88E5', '#1565C0'],
            bubbleThem: '#fff',
            bubbleThemGradient: ['#fff', '#fff'],
            patternColor: 'rgba(13, 71, 161, 0.08)',
            patternGradientColors: ['#BBDEFB', '#90CAF9', '#64B5F6'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.12,
            textColorMe: '#FFFFFF',
            textColorThem: '#000000',
        },
        dark: {
            // "Void Chamber" — Near-black with blue undertone
            backgroundGradient: ['#000000', '#050507'],
            bubbleMe: '#4A7DC4',  // Sapphire Glow
            bubbleMeGradient: ['#5A8FD4', '#3A6AB8'],
            bubbleThem: '#24242C',
            bubbleThemGradient: ['#2D313C', '#1F2430'],
            patternColor: '#E8E6F0',
            // Bioluminescence: Deep Indigo -> Electric Blue -> Violet
            patternGradientColors: ['#312E81', '#4338CA', '#4F46E5', '#818CF8'],
            patternGradientLocations: [0, 0.3, 0.7, 1],
            patternOpacity: 0.18,
            textColorMe: '#F4F6F8',
            textColorThem: '#FFFFFF',
        },
        backgroundGradient: ['#000000', '#050507'],
        bubbleMe: '#4A7DC4',
        bubbleThem: '#24242C',
        bubbleThemGradient: ['#2D313C', '#1F2430'],
        patternOpacity: 0.18,
        patternGradientColors: ['#312E81', '#4338CA', '#4F46E5', '#818CF8'],
        textColorMe: '#F4F6F8',
        textColorThem: '#FFFFFF',
        isAdaptive: true
    },

    /**
     * ═══════════════════════════════════════════════════════════════════════
     * MUSIC — "Rhythm & Flow"
     * ═══════════════════════════════════════════════════════════════════════
     * Vibrant and rhythmic, designed for the music lovers.
     * Uses the premium Masked Image technique.
     */
    {
        id: 'music',
        name: 'Music',
        type: 'masked-image',
        maskedImage: 'music',
        patternType: 'doodles',
        light: {
            backgroundGradient: ['#FFFFFF', '#FFFFFF'], // Pure White Background
            bubbleMe: '#7B1FA2',
            bubbleMeGradient: ['#9C27B0', '#7B1FA2'],
            bubbleThem: '#fff',
            bubbleThemGradient: ['#fff', '#fff'],
            patternColor: 'rgba(74, 20, 140, 0.08)',
            patternGradientColors: ['#E1BEE7', '#CE93D8', '#BA68C8'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.14,
            textColorMe: '#FFFFFF',
            textColorThem: '#000000',
        },
        dark: {
            backgroundGradient: ['#000000', '#050507'],
            bubbleMe: '#8B5CF6',
            bubbleMeGradient: ['#A78BFA', '#7C3AED'],
            bubbleThem: '#24242C',
            bubbleThemGradient: ['#332A3E', '#251F30'],
            patternColor: '#C4B8E0',
            patternGradientColors: ['#22D3EE', '#E879F9', '#8B5CF6'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.15,
            textColorMe: '#F8F6FC',
            textColorThem: '#FFFFFF',
        },
        backgroundGradient: ['#000000', '#050507'],
        bubbleMe: '#8B5CF6',
        bubbleThem: '#24242C',
        bubbleThemGradient: ['#332A3E', '#251F30'],
        patternOpacity: 0.15,
        patternGradientColors: ['#22D3EE', '#E879F9', '#8B5CF6'],
        textColorMe: '#F8F6FC',
        textColorThem: '#FFFFFF',
        isAdaptive: true
    },

    /**
     * ═══════════════════════════════════════════════════════════════════════
     * TERRACOTTA — "Mediterranean Dusk"
     * ═══════════════════════════════════════════════════════════════════════
     * Golden hour on the Amalfi coast. Warm stones and fired clay.
     */
    {
        id: 'terracotta',
        name: 'Terracotta',
        type: 'masked-image',
        maskedImage: 'doodles',
        patternType: 'doodles',
        light: {
            backgroundGradient: ['#FFFFFF', '#FFFFFF'], // Pure White Background
            bubbleMe: '#E65100',
            bubbleMeGradient: ['#F57C00', '#E65100'],
            bubbleThem: '#fff',
            bubbleThemGradient: ['#fff', '#fff'],
            patternColor: 'rgba(191, 54, 12, 0.08)',
            patternGradientColors: ['#FFE0B2', '#FFCC80', '#FFB74D'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.14,
            textColorMe: '#FFFFFF',
            textColorThem: '#000000',
        },
        dark: {
            // "Ember Night" — Warm coals in darkness
            backgroundGradient: ['#000000', '#050507'],
            bubbleMe: '#B87050',  // Fired Clay
            bubbleMeGradient: ['#C88060', '#A86040'],
            bubbleThem: '#24242C',
            bubbleThemGradient: ['#3B2F2A', '#2B221F'],
            patternColor: 'rgba(200, 128, 90, 0.10)',
            // Molten Flow: Red -> Orange -> Bronze
            patternGradientColors: ['#DC2626', '#EA580C', '#B45309'],
            patternGradientLocations: [0, 0.5, 1],
            patternOpacity: 0.12,
            textColorMe: '#FAF0E8',
            textColorThem: '#FFFFFF',
        },
        backgroundGradient: ['#000000', '#050507'],
        bubbleMe: '#B87050',
        bubbleThem: '#24242C',
        bubbleThemGradient: ['#3B2F2A', '#2B221F'],
        patternOpacity: 0.12,
        patternGradientColors: ['#DC2626', '#EA580C', '#B45309'],
        textColorMe: '#FAF0E8',
        textColorThem: '#FFFFFF',
        isAdaptive: true
    },

];

/**
 * Resolve a theme to the correct variant based on system dark/light mode
 */
export const resolveThemeVariant = (theme: ChatTheme, isDark: boolean): ChatTheme => {
    const variant = isDark ? theme.dark : theme.light;
    const lightNearSolidGradient = [
        '#F9F3EA', // Warm ivory
        '#EFE6D9', // Soft warm parchment tint
    ];
    const lightPatternGradient = [
        appTheme.light.palette.sage,
        appTheme.light.palette.slate,
        appTheme.light.palette.mauve,
    ];
    const lightPatternColor = appTheme.light.border.default;
    const lightPatternOpacity = 0.04;
    return {
        ...theme,
        backgroundGradient: isDark ? variant.backgroundGradient : lightNearSolidGradient,
        bubbleMe: variant.bubbleMe,
        bubbleMeGradient: variant.bubbleMeGradient,
        bubbleThem: variant.bubbleThem,
        bubbleThemGradient: (
            variant.bubbleThemGradient && variant.bubbleThemGradient.length >= 2
                ? variant.bubbleThemGradient
                : [variant.bubbleThem, variant.bubbleThem]
        ),
        patternColor: isDark ? variant.patternColor : lightPatternColor,
        patternGradientColors: isDark ? variant.patternGradientColors : lightPatternGradient,
        patternGradientLocations: variant.patternGradientLocations,
        patternOpacity: isDark ? variant.patternOpacity : lightPatternOpacity,
        textColorMe: variant.textColorMe,
        textColorThem: variant.textColorThem,
    };
};

const DEFAULT_THEME = PRESET_THEMES[0]; // 'glacier' theme now since we reordered

const createDefaultCustomTheme = (): ChatTheme => ({
    ...DEFAULT_THEME,
    id: 'custom',
    name: 'Custom',
});

const findPresetTheme = (themeId?: string | null): ChatTheme | undefined => {
    if (!themeId) return undefined;
    return PRESET_THEMES.find((theme) => theme.id === themeId);
};

const applyPatternOverride = (bubbleTheme: ChatTheme, patternTheme?: ChatTheme | null): ChatTheme => {
    if (!patternTheme) return bubbleTheme;
    return {
        ...bubbleTheme,
        patternType: patternTheme.patternType,
        maskedImage: patternTheme.maskedImage ?? bubbleTheme.maskedImage,
        light: {
            ...bubbleTheme.light,
            backgroundGradient: patternTheme.light.backgroundGradient,
            patternColor: patternTheme.light.patternColor,
            patternGradientColors: patternTheme.light.patternGradientColors,
            patternGradientLocations: patternTheme.light.patternGradientLocations,
            patternOpacity: patternTheme.light.patternOpacity,
            maskedImage: patternTheme.light.maskedImage ?? patternTheme.maskedImage ?? bubbleTheme.light.maskedImage,
        },
        dark: {
            ...bubbleTheme.dark,
            backgroundGradient: patternTheme.dark.backgroundGradient,
            patternColor: patternTheme.dark.patternColor,
            patternGradientColors: patternTheme.dark.patternGradientColors,
            patternGradientLocations: patternTheme.dark.patternGradientLocations,
            patternOpacity: patternTheme.dark.patternOpacity,
            maskedImage: patternTheme.dark.maskedImage ?? patternTheme.maskedImage ?? bubbleTheme.dark.maskedImage,
        },
        backgroundGradient: patternTheme.backgroundGradient,
        patternColor: patternTheme.patternColor,
        patternGradientColors: patternTheme.patternGradientColors,
        patternGradientLocations: patternTheme.patternGradientLocations,
        patternOpacity: patternTheme.patternOpacity,
    };
};

const resolveThemeState = ({
    activeThemeId,
    selectedPatternId,
    customTheme,
}: {
    activeThemeId: string | 'custom';
    selectedPatternId: string | null;
    customTheme: ChatTheme;
}): ChatTheme => {
    const baseTheme = activeThemeId === 'custom'
        ? customTheme
        : (findPresetTheme(activeThemeId) || DEFAULT_THEME);
    const patternTheme = findPresetTheme(selectedPatternId);
    return applyPatternOverride(baseTheme, patternTheme);
};

interface WallpaperState {
    activeThemeId: string | 'custom';
    activeTheme: ChatTheme;

    // Mix & Match: Allow selecting bubble colors from one theme, pattern from another
    selectedPatternId: string | null; // If null, uses pattern from activeTheme

    // Custom overrides (if activeThemeId is 'custom')
    customTheme: ChatTheme;

    // Actions
    setTheme: (themeId: string) => void;
    setBubbleTheme: (themeId: string) => void; // Set only bubble colors
    setPatternTheme: (themeId: string) => void; // Set only background pattern
    updateCustomTheme: (updates: Partial<ChatTheme>) => void;
    resetToDefault: () => void;

    // Computed helpers
    getResolvedTheme: (isDark: boolean) => ChatTheme;
}

export const useWallpaperStore = create<WallpaperState>()(
    persist(
        (set, get) => ({
            activeThemeId: 'glacier',
            activeTheme: DEFAULT_THEME,
            selectedPatternId: null, // Uses pattern from activeTheme by default
            customTheme: createDefaultCustomTheme(),

            setTheme: (themeId) => {
                if (findPresetTheme(themeId)) {
                    // Full theme selection resets pattern override
                    set({
                        activeThemeId: themeId,
                        activeTheme: resolveThemeState({
                            activeThemeId: themeId,
                            selectedPatternId: null,
                            customTheme: get().customTheme,
                        }),
                        selectedPatternId: null
                    });
                }
            },

            // Set only the bubble colors from a theme (keeps current pattern)
            setBubbleTheme: (themeId) => {
                if (findPresetTheme(themeId)) {
                    const current = get();
                    const mixedTheme = resolveThemeState({
                        activeThemeId: themeId,
                        selectedPatternId: current.selectedPatternId,
                        customTheme: current.customTheme,
                    });
                    set({
                        activeThemeId: themeId,
                        activeTheme: mixedTheme
                    });
                }
            },

            // Set only the background pattern from a theme (keeps current bubble colors)
            setPatternTheme: (themeId) => {
                if (findPresetTheme(themeId)) {
                    const current = get();
                    const mixedTheme = resolveThemeState({
                        activeThemeId: current.activeThemeId,
                        selectedPatternId: themeId,
                        customTheme: current.customTheme,
                    });

                    set({
                        activeTheme: mixedTheme,
                        selectedPatternId: themeId
                    });
                }
            },

            updateCustomTheme: (updates) => {
                const current = get().customTheme;
                const newCustom = { ...current, ...updates };
                const nextTheme = resolveThemeState({
                    activeThemeId: 'custom',
                    selectedPatternId: get().selectedPatternId,
                    customTheme: newCustom,
                });
                set({
                    activeThemeId: 'custom',
                    activeTheme: nextTheme,
                    customTheme: newCustom
                });
            },

            resetToDefault: () => {
                set({
                    activeThemeId: 'glacier',
                    activeTheme: DEFAULT_THEME,
                    selectedPatternId: null
                });
            },

            // Get the fully resolved theme (with light/dark variant applied)
            getResolvedTheme: (isDark: boolean) => {
                const { activeTheme } = get();
                return resolveThemeVariant(activeTheme, isDark);
            }
        }),
        {
            name: 'vibe-wallpaper-v9', // Version bump for unified background
            storage: createJSONStorage(() => AsyncStorage),
            merge: (persistedState, currentState) => {
                const persisted = (persistedState as Partial<WallpaperState>) || {};
                const activeThemeId = persisted.activeThemeId ?? currentState.activeThemeId;
                const selectedPatternId = persisted.selectedPatternId ?? currentState.selectedPatternId;
                const customTheme = persisted.customTheme
                    ?? (activeThemeId === 'custom' ? persisted.activeTheme : undefined)
                    ?? currentState.customTheme
                    ?? createDefaultCustomTheme();
                const activeTheme = resolveThemeState({
                    activeThemeId,
                    selectedPatternId,
                    customTheme,
                });

                return {
                    ...currentState,
                    ...persisted,
                    activeThemeId,
                    selectedPatternId,
                    customTheme,
                    activeTheme,
                };
            },
        }
    )
);
