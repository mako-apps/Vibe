
/**
 * ═══════════════════════════════════════════════════════════════════════════
 * VIBE THEME SYSTEM — "Philosophy of Color"
 * ═══════════════════════════════════════════════════════════════════════════
 * 
 * COLOR PHILOSOPHY:
 * 
 * 🌑 DARK THEME: "Obsidian Sanctuary"
 *    Inspired by Japanese Wabi-Sabi — finding beauty in imperfection, 
 *    natural materials, and the passage of time. Colors drawn from
 *    volcanic glass, bioluminescent depths, and midnight gardens.
 * 
 * 🌅 LIGHT THEME: "Ethereal Morning"
 *    Inspired by misty mountain dawns, rice paper, and the first light
 *    filtering through cherry blossoms. A palette of gentle awakening.
 * 
 * Each color is crafted using HSL for harmonic relationships,
 * featuring rare gemstone tones and natural phenomena.
 * 
 * ═══════════════════════════════════════════════════════════════════════════
 */

// ═══════════════════════════════════════════════════════════════════════════
// DARK THEME: "Obsidian Sanctuary"
// ═══════════════════════════════════════════════════════════════════════════

export const colors = {
    bg: {
        // "Void Obsidian" — Deeper charcoal palette for higher contrast with cards
        primary: '#121212',      // Slightly deeper than previous #191919

        // "Ink Stone" — Slightly lighter, like wet sumi ink on stone
        secondary: '#151515',    // hsl(240, 18%, 8%) — Deep indigo-black

        // "Charred Cedar" — Inspired by Shou Sugi Ban (焼杉板),
        // the Japanese technique of charring wood
        card: '#242424',         // hsl(244, 13%, 14%) — Lighter charcoal for better contrast

        // "Night Moss" — Like moss in moonlight, alive yet subdued
        input: '#222222',        // Slightly lighter for better visibility against #121212

        // "Smoke Glass" — Elevated surfaces with a whisper of warmth
        elevated: '#252530',     // hsl(244, 13%, 17%) — Smoked glass
    },

    text: {
        // "Moon Silk" — The soft glow of moonlight on silk fabric
        primary: '#E8E6F0',      // hsl(250, 25%, 92%) — Warm lunar white

        // "Silver Mist" — Like morning fog catching first light
        secondary: '#9896A8',    // hsl(245, 10%, 62%) — Lavender gray

        // "Distant Mountain" — Faded like mountains on the horizon
        tertiary: '#5D5B6B',     // hsl(248, 9%, 39%) — Twilight gray

        // "Ink Black" — For contrast on light backgrounds
        inverse: '#0A0A0D',      // hsl(240, 15%, 4%) — True ink
    },

    button: {
        // "Alexandrite Glow" — Like the rare color-changing gemstone
        background: '#6B9E9F',   // hsl(181, 22%, 52%) — Muted alexandrite
        text: '#FAFBFC',
    },

    accent: {
        // "Bioluminescent Tide" — The glow of ocean plankton at night
        DEFAULT: '#7CB8B8',      // hsl(180, 28%, 60%) — Living ocean
        muted: 'rgba(124, 184, 184, 0.6)',

        // "Deep Sea Aurora" — Electric bioluminescence
        cyan: '#4DD9E5',         // hsl(185, 73%, 60%) — Aurora cyan

        // "Jade Spring" — Fresh jade stone, symbol of harmony
        teal: '#5BC4B4',         // hsl(168, 45%, 56%) — Living jade

        // "Forest Firefly" — The magical glow of summer fireflies
        emerald: '#5EC99F',      // hsl(155, 48%, 58%) — Firefly green
    },

    palette: {
        // ═══ WARM SPECTRUM: "Ember Garden" ═══
        // Like watching coals glow in a traditional hearth

        // "Crimson Silk" — Japanese obi silk in deep red
        rose: '#D4637A',         // hsl(350, 54%, 61%) — Refined crimson

        // "Peony Dusk" — Evening-lit peony petals
        pink: '#C87A9E',         // hsl(330, 40%, 63%) — Dusty peony

        // "Persimmon" — The warm fruit of autumn
        orange: '#D8875A',       // hsl(22, 58%, 60%) — Ripe persimmon

        // "Temple Gold" — Ancient gold leaf on shrine doors
        amber: '#CFA352',        // hsl(42, 55%, 57%) — Aged gold

        // ═══ COOL SPECTRUM: "Twilight Garden" ═══
        // The moment between day and night, full of mystery

        // "Wisteria Night" — Purple wisteria under starlight
        violet: '#9B7BD4',       // hsl(260, 50%, 65%) — Evening wisteria

        // "Deep Iris" — The royal flower in shadow
        indigo: '#7B7DD4',       // hsl(239, 50%, 65%) — Twilight iris

        // "Midnight Pool" — Still water reflecting the night sky
        blue: '#6B91D4',         // hsl(218, 50%, 62%) — Reflection blue

        // "Morning Pond" — First light on calm water
        sky: '#5AAED4',          // hsl(197, 55%, 59%) — Dawn water

        // ═══ NEUTRAL LUXE: "Stone Garden" ═══
        // Inspired by Japanese dry gardens (枯山水)

        // "Weathered Slate" — Stone aged by centuries of rain
        slate: '#7D8899',        // hsl(215, 12%, 55%) — Ancient slate

        // "Meditation Stone" — Zen garden raking stones
        zinc: '#848490',         // hsl(240, 6%, 54%) — Temple stone

        // "River Pebble" — Smooth stones from mountain streams
        stone: '#8A847A',        // hsl(37, 8%, 51%) — River worn

        // ═══ MUTED LUXE: "Garden Elements" ═══

        // "Temple Moss" — Ancient moss on stone lanterns
        sage: '#7FA888',         // hsl(135, 20%, 58%) — Living moss

        // "Twilight Iris" — Iris petals in fading light
        mauve: '#A99CBF',        // hsl(270, 22%, 68%) — Soft iris

        // "Cherry Bark" — The weathered bark of sakura trees
        dustyRose: '#BFA39D',    // hsl(12, 22%, 68%) — Aged cherry

        // "Rice Paper" — Traditional washi paper in candlelight
        champagne: '#E8DDD0',    // hsl(35, 35%, 86%) — Warm washi
    },

    lime: {
        // "Spring Shoot" — New bamboo growth
        2: '#D4E8A3',            // hsl(78, 55%, 77%) — Young bamboo
        6: '#6B9946',            // hsl(88, 37%, 44%) — Mature bamboo
    },

    bubble: {
        // "Deep Lagoon" — Ocean grottos where light barely reaches
        me: '#3D6E70',           // hsl(182, 29%, 34%) — Cavern teal
        meText: '#F4F6F7',

        // "Obsidian Surface" — Polished volcanic glass
        them: '#24242C',         // hsl(240, 10%, 16%) — Lighter Obsidian
        themText: '#FFFFFF',
    },

    status: {
        // "Jade Harmony" — Symbol of good fortune
        online: '#5EC99F',       // hsl(155, 48%, 58%) — Jade glow

        // "Sunset Lantern" — Paper lanterns at dusk
        away: '#D4B05E',         // hsl(45, 57%, 60%) — Lantern glow

        // "Autumn Maple" — Brilliant fall leaves
        busy: '#D47A6B',         // hsl(8, 50%, 62%) — Maple red

        // "Stone Shadow" — Dormant garden stones
        offline: '#6B7580',      // hsl(213, 8%, 46%) — Shadow gray

        // "Warning Vermillion" — Traditional warning color
        error: '#D45A5A',        // hsl(0, 55%, 59%) — Alert red

        // "Growth Jade" — Success and prosperity
        success: '#5ABF8F',      // hsl(152, 42%, 55%) — Prosperity green

        // "Caution Gold" — Temple bells
        warning: '#C9A33D',      // hsl(45, 55%, 51%) — Bell gold

        // "Sky Message" — Clear communication
        info: '#5A9ED4',         // hsl(207, 55%, 59%) — Clear sky
    },

    overlay: {
        // "Shōji Screen" — Light through paper screens
        light: 'rgba(248, 246, 252, 0.04)',  // Moon-touched
        medium: 'rgba(248, 246, 252, 0.08)', // Lantern glow

        // "Ink Shadow" — Calligraphy shadows
        dark: 'rgba(10, 10, 15, 0.65)',      // Deep shadow

        // "Night Veil" — Evening mist
        blur: 'rgba(13, 13, 18, 0.88)',      // Fog cover
    },

    border: {
        // "Whisper Line" — Barely visible, like morning dew
        subtle: 'rgba(248, 246, 252, 0.05)',

        // "Thread Silver" — Like silver thread in fabric
        default: 'rgba(248, 246, 252, 0.09)',

        // "Moon Edge" — Visible but gentle
        strong: 'rgba(248, 246, 252, 0.16)',
    },

    // "Void Canvas" — The deepest background
    surface: '#0A0A0D',
};

// Convenience colors shortcut (points to dark theme by default)
export const themeColors = {
    ...colors,
    background: colors.bg.primary,
    text: colors.text.primary,
    textSecondary: colors.text.secondary,
    primary: colors.accent.DEFAULT,
};

export const borderRadius = {
    sm: 4,
    md: 8,
    lg: 12,
    xl: 16,
    none: 0,
    full: 9999,
}

export const spacing = {
    xs: 4,
    sm: 8,
    md: 12,
    lg: 16,
    xl: 20,
    xxl: 24,
}

// ═══════════════════════════════════════════════════════════════════════════
// LIGHT THEME: "Ethereal Morning"
// ═══════════════════════════════════════════════════════════════════════════

export const theme = {
    // colors shortcut for components using theme.colors
    colors: themeColors,
    dark: {
        ...colors
    },
    light: {
        bg: {
            // "Dawn Mist" — Soft morning light
            primary: '#F5F4F1',      // Deeper Soft Beige

            // "Cloud Whisper" — Soft morning cloud
            secondary: '#F5F4F1',    // Deeper Soft Beige

            // "Snow Petal" — Fresh snow on cherry blossoms
            card: '#FFFFFF',         // Pure white

            // "Porcelain" — Fine Japanese ceramics
            input: '#F2F2F2',        // Slightly deeper for contrast against white

            // "Morning Silk" — Fresh, luminous surface
            elevated: '#FFFFFF',     // Pure White
        },

        text: {
            // "Ink Essence" — Like traditional sumi ink
            primary: '#1A1A1F',      // hsl(240, 10%, 11%) — Deep ink

            // "Tea Shadow" — Aged tea-stained paper
            secondary: '#5A5A66',    // hsl(240, 6%, 38%) — Gentle shadow

            // "Mist Distance" — Far-off mountains in haze
            tertiary: '#9A9AA3',     // hsl(240, 5%, 62%) — Distant mist

            // "Moon Reflection" — For dark backgrounds
            inverse: '#FAF9F7',      // Warm pearl
        },

        button: {
            // "Ocean Pearl" — Rare tahitian pearl
            background: '#4A8D8E',   // hsl(181, 32%, 42%) — Deep pearl
            text: '#FEFEFE',
        },

        accent: {
            // "Celadon Glaze" — Classic Korean celadon pottery
            DEFAULT: '#4A8D8E',      // hsl(181, 32%, 42%) — Living celadon
            muted: 'rgba(74, 141, 142, 0.6)',

            // "Spring Water" — Crystal clear mountain springs
            cyan: '#2BA5B5',         // hsl(188, 62%, 44%) — Pure spring

            // "Sea Glass" — Tumbled glass from the ocean
            teal: '#3A9E90',         // hsl(171, 45%, 42%) — Worn jade

            // "Garden Fern" — New fern fronds unfurling
            emerald: '#3A9E75',      // hsl(155, 45%, 42%) — Fresh fern
        },

        palette: {
            // ═══ WARM SPECTRUM: "Garden Bloom" ═══

            // "Camellia" — Deep red garden camellias
            rose: '#C4475E',         // hsl(350, 48%, 52%) — Camellia red

            // "Orchid Blush" — Soft orchid petals
            pink: '#B85A82',         // hsl(330, 36%, 54%) — Orchid pink

            // "Kumquat" — Bright citrus from the garden
            orange: '#C8714A',       // hsl(22, 50%, 54%) — Ripe kumquat

            // "Chrysanthemum" — Imperial yellow flower
            amber: '#B8933D',        // hsl(45, 50%, 48%) — Royal yellow

            // ═══ COOL SPECTRUM: "Water Garden" ═══

            // "Morning Glory" — Purple morning glory vines
            violet: '#7B5AC4',       // hsl(260, 45%, 56%) — Climbing violet

            // "Bellflower" — Delicate blue campanula
            indigo: '#5A5DC4',       // hsl(238, 45%, 56%) — Bell blue

            // "Reflection Pool" — Clear pool beneath sky
            blue: '#4A7DC4',         // hsl(216, 45%, 53%) — Still water

            // "Dragonfly Wing" — Iridescent dragonfly
            sky: '#3A94C4',          // hsl(198, 55%, 50%) — Wing shimmer

            // ═══ NEUTRAL LUXE: "Clay Studio" ═══

            // "Kiln Slate" — Fired pottery glaze
            slate: '#5A6675',        // hsl(213, 14%, 41%) — Glaze gray

            // "Unglazed Clay" — Natural fired clay
            zinc: '#5A5A66',         // hsl(240, 7%, 38%) — Raw clay

            // "River Sand" — Fine sand from mountain rivers
            stone: '#66605A',        // hsl(30, 8%, 38%) — Wet sand

            // ═══ MUTED LUXE: "Tea Garden" ═══

            // "Matcha" — Powdered green tea
            sage: '#5A8A66',         // hsl(135, 22%, 45%) — Ground tea

            // "Plum Blossom" — Early spring plum flowers
            mauve: '#8A75A3',        // hsl(270, 20%, 55%) — Plum petal

            // "Dried Rose" — Pressed rose petals
            dustyRose: '#A3857D',    // hsl(15, 20%, 56%) — Rose memory

            // "Parchment" — Aged writing paper
            champagne: '#D8CBBA',    // hsl(35, 30%, 79%) — Antique paper
        },

        lime: {
            // "New Leaf" — Spring's first leaves
            2: '#C8E095',            // hsl(78, 50%, 73%) — Young leaf
            6: '#5A8A38',            // hsl(88, 42%, 38%) — Forest depth
        },

        bubble: {
            // "Morning Tide" — Ocean at dawn
            me: '#007A7C',           // Sharper Tide
            meText: '#FFFFFF',

            them: '#E0F2F1',         // High contrast tinted paper
            themText: '#000000',
        },

        status: {
            // "Bamboo Heart" — Fresh cut bamboo
            online: '#3A9E75',       // hsl(155, 45%, 42%) — Living bamboo

            // "Marigold" — Bright garden flowers
            away: '#C49938',         // hsl(45, 55%, 49%) — Flower gold

            // "Autumn Berry" — Ripened nandina berries
            busy: '#C4605A',         // hsl(5, 45%, 56%) — Berry red

            // "Sleeping Stone" — Garden stones at rest
            offline: '#8A8A96',      // hsl(240, 6%, 56%) — Rest gray

            // "Warning Poppy" — Alert red flowers
            error: '#C44A4A',        // hsl(0, 48%, 53%) — Poppy red

            // "Prosperity Bamboo" — Thriving garden
            success: '#428A6A',      // hsl(150, 36%, 40%) — Growth green

            // "Caution Saffron" — Rare spice color
            warning: '#B89338',      // hsl(45, 55%, 47%) — Saffron gold

            // "Message Sky" — Clear information
            info: '#3A80C4',         // hsl(210, 55%, 50%) — Open sky
        },

        overlay: {
            // "Shōji Glow" — Light through rice paper
            light: 'rgba(26, 26, 31, 0.025)',   // Filtered light
            medium: 'rgba(26, 26, 31, 0.05)',   // Gentle shadow

            // "Ink Wash" — Diluted sumi ink
            dark: 'rgba(26, 26, 31, 0.35)',     // Wash shadow

            // "Morning Fog" — Dawn mist
            blur: 'rgba(250, 249, 247, 0.90)',  // Dense mist
        },

        border: {
            // "Thread Whisper" — Silk thread catching light
            subtle: 'rgba(26, 26, 31, 0.035)',

            // "Pencil Line" — Soft graphite
            default: 'rgba(26, 26, 31, 0.07)',

            // "Brush Stroke" — Calligraphy edge
            strong: 'rgba(26, 26, 31, 0.12)',
        },

        // "Pure Canvas" — Fresh paper
        surface: '#FEFEFE',
    }
};

export const useTheme = () => theme.dark; 
