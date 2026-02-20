import React from 'react';
import { View, StyleSheet, Text, TouchableOpacity, Image, useWindowDimensions } from 'react-native';
import { useRouter } from 'expo-router';
import { LinearGradient } from 'expo-linear-gradient';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import MaskedView from '@react-native-masked-view/masked-view';



export default function TestWallpaperScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { width: screenWidth, height: screenHeight } = useWindowDimensions();
    const { colors } = useThemeStore();

    // Calculate image dimensions based on 9/20 ratio to avoid "too zoomed" look
    const imageDimensions = React.useMemo(() => {
        // We want to fit the image to the screen while maintaining 9:20 ratio
        // We will contain it "cover" style but centered, and scale it down slightly to avoid massive zoom
        const targetRatio = 9 / 20;
        const screenRatio = screenWidth / screenHeight;

        let width, height;

        if (screenRatio > targetRatio) {
            // Screen is wider than image (9/19 vs 9/20) - Fit width
            width = screenWidth;
            height = screenWidth / targetRatio;
        } else {
            // Screen is taller than image - Fit height
            width = screenHeight * targetRatio;
            height = screenHeight;
        }

        return { width, height };
    }, [screenWidth, screenHeight]);

    // Gradient colors for the paths
    const GRADIENT_COLORS = ['#3B82F6', '#8B5CF6', '#D946EF', '#F43F5E'];
    const GRADIENT_LOCATIONS = [0, 0.33, 0.66, 1];

    return (
        <View style={{ flex: 1, backgroundColor: '#000' }}>
            <View style={StyleSheet.absoluteFill}>
                {/* 1. Base Layer: Solid Black Background */}
                <View style={[StyleSheet.absoluteFill, { backgroundColor: '#000' }]} />

                {/* 2. Masked Gradient Layer */}
                {/* The MaskedView uses the maskElement (Image) to determine opacity. */}
                {/* The child (Gradient) is drawn ONLY where the mask is opaque. */}
                {/* Since the PNG has transparent background and opaque lines, the gradient will show on the lines. */}
                <MaskedView
                    style={StyleSheet.absoluteFill}
                    maskElement={
                        <View style={{
                            flex: 1,
                            backgroundColor: 'transparent',
                            alignItems: 'center',
                            justifyContent: 'center'
                        }}>
                            <Image

                                style={{
                                    width: imageDimensions.width,
                                    height: imageDimensions.height,
                                }}
                                resizeMode="cover"
                                fadeDuration={0}
                            />
                        </View>
                    }
                >
                    {/* The Gradient that "fills" the lines */}
                    <LinearGradient
                        colors={GRADIENT_COLORS as any}
                        locations={GRADIENT_LOCATIONS as any}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 1 }}
                        style={[StyleSheet.absoluteFill, { opacity: 0.15 }]} // Reduced opacity of the gradient itself
                    />
                </MaskedView>

                {/* 3. Optional Overlay for Depth (Vignette) */}
                <LinearGradient
                    colors={['rgba(0,0,0,0.6)', 'transparent', 'rgba(0,0,0,0.6)']}
                    style={StyleSheet.absoluteFill}
                    locations={[0, 0.5, 1]}
                    pointerEvents="none"
                />
            </View>

            <View style={{ flex: 1 }}>
                {/* Simple Header */}
                <View style={[styles.header, { paddingTop: insets.top }]}>
                    <TouchableOpacity onPress={() => router.back()} style={styles.backButton}>
                        <ArrowLeft color="#fff" size={28} />
                    </TouchableOpacity>
                    <Text style={[styles.title, { color: '#fff' }]}>Wallpaper Test</Text>
                </View>

                <View style={[styles.content, { justifyContent: 'flex-end', paddingBottom: 60 }]}>
                    <Text style={[styles.text, { color: '#fff', fontSize: 18, fontWeight: '600' }]}>
                        Masked Gradient Effect
                    </Text>
                    <Text style={[styles.text, { color: 'rgba(255,255,255,0.6)', marginTop: 8 }]}>
                        Gradient applied strictly to image paths
                    </Text>
                </View>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16,
        paddingBottom: 12,
        zIndex: 10,
    },
    backButton: {
        padding: 8,
        marginRight: 8,
    },
    title: {
        fontSize: 20,
        fontWeight: 'bold',
    },
    content: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        padding: 24,
    },
    text: {
        fontSize: 16,
        textAlign: 'center',
        opacity: 0.8,
    },
});
