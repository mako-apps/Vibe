// Map of emoji characters to Lottie JSON assets
// To add animated emojis:
// 1. Download Lottie JSON files (e.g. from lottiefiles.com)
// 2. Place them in assets/emojis/
// 3. Import and map them below

export const ANIMATED_EMOJIS: Record<string, any> = {
    // '❤️': require('../../assets/emojis/heart.json'),
    // '🔥': require('../../assets/emojis/fire.json'),
    // '😂': require('../../assets/emojis/joy.json'),
};

export const hasAnimatedVersion = (text: string) => {
    // Check if the text is exactly one of our mapped emojis
    return !!ANIMATED_EMOJIS[text.trim()];
};
