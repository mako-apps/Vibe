import { create } from 'zustand'
import { Appearance } from 'react-native'
import { theme as appTheme } from '../theme'

// Flattened interface for easier usage in components
interface ThemeColors {
    // Backgrounds
    background: string
    backgroundSecondary: string
    card: string
    input: string
    elevated: string
    // Text
    text: string
    textSecondary: string
    textTertiary: string
    // Brand
    primary: string
    secondary: string
    accent: string
    cyan: string
    teal: string
    // Bubbles
    bubbleMe: string
    bubbleMeText: string
    bubbleThem: string
    bubbleThemText: string
    // Status
    success: string
    warning: string
    danger: string
    info: string
    // Borders
    border: string
    borderSubtle: string
    borderStrong: string
    // Overlay
    overlay: string
    surface: string
    // Palette
    palette: {
        rose: string
        pink: string
        orange: string
        amber: string
        violet: string
        indigo: string
        blue: string
        sky: string
        slate: string
        zinc: string
        stone: string
        sage: string
        mauve: string
        dustyRose: string
        champagne: string
    }
    lime?: {
        2: string
        6: string
    }
    button: string
    buttonText: string
}

interface ThemeState {
    theme: 'light' | 'dark' | 'system'
    effectiveTheme: 'light' | 'dark'
    colors: ThemeColors
    setTheme: (theme: 'light' | 'dark' | 'system') => void
    initTheme: () => void
}

const mapThemeToColors = (t: typeof appTheme.dark): ThemeColors => ({
    // Backgrounds
    background: t.bg.primary,
    backgroundSecondary: t.bg.secondary,
    card: t.bg.card,
    input: t.bg.input,
    elevated: t.bg.elevated,
    // Text
    text: t.text.primary,
    textSecondary: t.text.secondary,
    textTertiary: t.text.tertiary,
    // Brand
    primary: t.accent.DEFAULT,
    secondary: t.bubble.me,
    accent: t.accent.DEFAULT,
    cyan: t.accent.cyan,
    teal: t.accent.teal,
    // Bubbles
    bubbleMe: t.bubble.me,
    bubbleMeText: t.bubble.meText,
    bubbleThem: t.bubble.them,
    bubbleThemText: t.bubble.themText,
    // Status
    success: t.status.success,
    warning: t.status.warning,
    danger: t.status.error,
    info: t.status.info,
    // Borders
    border: t.border.strong || t.border.default, // Using strong for better visibility in some contexts
    borderSubtle: t.border.subtle,
    borderStrong: t.border.strong,
    // Overlay
    overlay: t.overlay.blur,
    surface: t.surface || t.bg.card,
    palette: t.palette,
    lime: t.lime,
    button: t.button?.background || '#ffffff',
    buttonText: t.button?.text || '#000000',
})

export const useThemeStore = create<ThemeState>((set, get) => ({
    theme: 'system',
    effectiveTheme: Appearance.getColorScheme() === 'dark' ? 'dark' : 'light',
    colors: mapThemeToColors(Appearance.getColorScheme() === 'dark' ? appTheme.dark : appTheme.light),

    setTheme: (theme) => {
        set({ theme })
        get().initTheme()
    },

    initTheme: () => {
        const { theme } = get()
        const systemScheme = Appearance.getColorScheme()

        const effectiveTheme = theme === 'system'
            ? (systemScheme === 'dark' ? 'dark' : 'light')
            : theme

        set({
            effectiveTheme,
            colors: mapThemeToColors(appTheme[effectiveTheme] || appTheme.dark)
        })
    }
}))

// Listen for system changes
Appearance.addChangeListener(() => {
    useThemeStore.getState().initTheme()
})
