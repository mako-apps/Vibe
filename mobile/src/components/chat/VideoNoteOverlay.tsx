import React, { useEffect, useRef, useState } from 'react';
import { View, StyleSheet, Dimensions } from 'react-native';
import Animated, { useAnimatedStyle, withTiming, useSharedValue, Easing } from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import { CameraView } from 'expo-camera';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');
const CIRCLE_SIZE = 300; // Large circular preview

interface VideoNoteOverlayProps {
    visible: boolean;
    onVideoRecorded: (file: { uri: string; duration?: number }) => void;
}

export const VideoNoteOverlay = ({ visible, onVideoRecorded }: VideoNoteOverlayProps) => {
    const translateY = useSharedValue(SCREEN_HEIGHT);
    const opacity = useSharedValue(0);
    const cameraRef = useRef<CameraView>(null);
    const isRecordingRef = useRef(false);
    const onVideoRecordedRef = useRef(onVideoRecorded);
    onVideoRecordedRef.current = onVideoRecorded;

    // Track whether the component should stay rendered (don't unmount during recording/stopping)
    const [keepMounted, setKeepMounted] = useState(false);

    useEffect(() => {
        let mounted = true;

        if (visible) {
            setKeepMounted(true);
            translateY.value = withTiming(0, { duration: 350, easing: Easing.bezier(0.25, 0.1, 0.25, 1) });
            opacity.value = withTiming(1, { duration: 300 });

            // Start recording after a slight delay
            const start = async () => {
                await new Promise(r => setTimeout(r, 400));
                if (!mounted || !visible) return;

                if (cameraRef.current && !isRecordingRef.current) {
                    isRecordingRef.current = true;
                    const recordStartTime = Date.now();
                    try {
                        const video = await cameraRef.current.recordAsync({
                            maxDuration: 60,
                        });

                        if (video) {
                            const durationSec = (Date.now() - recordStartTime) / 1000;
                            console.log('[VideoNote] Recording complete:', video.uri, 'duration:', Math.round(durationSec), 's');
                            onVideoRecordedRef.current({ uri: video.uri, duration: durationSec });
                        }
                    } catch (e) {
                        console.log('[VideoNote] Recording stopped or failed:', e);
                    } finally {
                        isRecordingRef.current = false;
                        // Allow unmount after recording fully resolved
                        if (!visible) {
                            setTimeout(() => setKeepMounted(false), 350);
                        }
                    }
                }
            };
            start();

        } else {
            // Animate out
            translateY.value = withTiming(SCREEN_HEIGHT, { duration: 300, easing: Easing.in(Easing.ease) });
            opacity.value = withTiming(0, { duration: 250 });

            // Stop recording — recordAsync promise above will resolve with the video
            if (isRecordingRef.current) {
                try {
                    cameraRef.current?.stopRecording();
                } catch (e) { /* ignore */ }
            } else {
                // Not recording, safe to unmount after animation
                setTimeout(() => setKeepMounted(false), 350);
            }
        }

        return () => {
            mounted = false;
        };
    }, [visible]);

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
        opacity: opacity.value
    }));

    // Don't unmount until recording has fully resolved — prevents camera ref being destroyed mid-record
    if (!visible && !keepMounted) return null;

    return (
        <Animated.View style={[styles.container, animatedStyle]} pointerEvents="none">
            <BlurView intensity={20} style={StyleSheet.absoluteFill} tint="dark" />
            <View style={styles.circleContainer}>
                <View style={styles.circleMask}>
                    <CameraView
                        ref={cameraRef}
                        style={styles.camera}
                        facing="front"
                        mode="video"
                        videoQuality="480p"
                    />
                </View>
            </View>
        </Animated.View>
    );
};

const styles = StyleSheet.create({
    container: {
        position: 'absolute',
        bottom: 0,
        left: -16, // Offset the padding from ChatInput
        width: SCREEN_WIDTH,
        height: SCREEN_HEIGHT,
        zIndex: 500, // Below the chat input (which is usually high zIndex) but above content? 
        // Actually, if ChatInput is at bottom, this should probably strictly cover the chat area.
        // We'll rely on the parent to position it or use absolute fill on screen.
        // If rendered INSIDE ChatInput, it might be constrained.
        // Better to render this portal-like or assume ChatInput's parent has space.
        // However, user said "backdrop blur", so full screen is best.
        alignItems: 'center',
        justifyContent: 'center',
    },
    circleContainer: {
        width: CIRCLE_SIZE,
        height: CIRCLE_SIZE,
        borderRadius: CIRCLE_SIZE / 2,
        overflow: 'hidden',
        borderWidth: 4,
        borderColor: 'white',
        shadowColor: "#000",
        shadowOffset: { width: 0, height: 10 },
        shadowOpacity: 0.3,
        shadowRadius: 20,
        elevation: 10,
    },
    circleMask: {
        width: '100%',
        height: '100%',
        borderRadius: CIRCLE_SIZE / 2,
        overflow: 'hidden',
        backgroundColor: '#000'
    },
    camera: {
        flex: 1
    }
});
