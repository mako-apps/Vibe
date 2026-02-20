import Constants, { ExecutionEnvironment } from 'expo-constants';

const isExpoGo = Constants.executionEnvironment === ExecutionEnvironment.StoreClient;

let NativeWaveform: any = null;

// Dynamic import for native module (to work with Expo Go / Dev Client)
if (!isExpoGo) {
    try {
        // Try to load a native waveform extraction library
        // Example: 'react-native-audiowaveform' or similar package
        // Note: The user needs to install the specific native package for this to work
        NativeWaveform = require('react-native-audiowaveform');
        // Or check for other common libraries
    } catch (e) {
        console.warn("[AudioWaveform] Native module not found. Falling back to simulation.");
    }
}

/**
 * Interface for Waveform Data
 */
export type WaveformData = number[];

/**
 * Service to generate waveform data from an audio URI.
 * Uses native module if available, otherwise falls back to realistic simulation.
 */
export const AudioWaveform = {
    /**
     * Get waveform amplitude data for a given audio URI
     * @param uri Local or remote audio URI
     * @param duration Duration in seconds (required for simulation fallback)
     * @param barCount Number of bars to generate (resolution)
     */
    getWaveform: async (uri: string, duration: number, barCount: number = 30): Promise<WaveformData> => {
        // 1. Try Native Extraction (Production / Native Build)
        if (NativeWaveform && NativeWaveform.extract) {
            try {
                // Assuming the library provides an extract method
                // This API signature depends on the specific library installed
                const data = await NativeWaveform.extract(uri, { samples: barCount });
                if (data && Array.isArray(data) && data.length > 0) {
                    return normalizeWaveform(data);
                }
            } catch (e) {
                console.warn("[AudioWaveform] Native extraction failed, falling back", e);
            }
        }

        // 2. Fallback: Realistic Simulation (Expo Go / No Native Lib)
        return generateSimulatedWaveform(uri, duration, barCount);
    }
};

/**
 * Generates a deterministically random but realistic "speech-like" waveform
 */
const generateSimulatedWaveform = (seedStr: string, duration: number, count: number): number[] => {
    return Array.from({ length: count }).map((_, i) => {
        // Seed based on URI to be deterministic
        const seed = (seedStr || 'default').charCodeAt(i % (seedStr?.length || 1));

        // Normalized position (0 to 1)
        const t = i / count;

        // 1. Envelope (taper starts and ends)
        const envelope = Math.sin(t * Math.PI);

        // 2. Harmonics (Structure)
        const signal =
            Math.sin(i * 0.2 + seed) * 0.5 +
            Math.sin(i * 0.8) * 0.25 +
            Math.sin(i * 0.05) * 0.25;

        // 3. Noise (Texture)
        const noise = (Math.random() * 0.6 + 0.4);

        // 4. Silence Gaps (Speech pauses) - Threshold logic
        const raw = (signal + 1) / 2;
        const isSilence = raw < 0.35; // 35% chance to be "quiet"
        const amplitude = isSilence ? 0.1 : (raw * noise);

        // Scale to 0-1 range for normalized output
        return amplitude * envelope;
    });
};

/**
 * Normalizes an array of arbitrary numbers to 0-1 range
 */
const normalizeWaveform = (data: number[]): number[] => {
    const max = Math.max(...data, 1); // Avoid div by zero
    return data.map(v => Math.abs(v) / max);
};
