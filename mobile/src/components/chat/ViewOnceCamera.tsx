import React, { useState, useRef, useEffect } from 'react';
import { View, StyleSheet, TouchableOpacity, Image, Dimensions, StatusBar, Text, Modal } from 'react-native';
import { CameraView, CameraType, FlashMode, useCameraPermissions } from 'expo-camera';
import { X, Zap, ZapOff, Send, Eye, EyeOff, Check, ArrowUp } from 'lucide-react-native';
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated';
import * as Haptics from 'expo-haptics';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const { width, height } = Dimensions.get('window');

// Dark theme colors for camera
const colors = {
    bg: '#000',
    primary: '#6B66FF',
    text: '#fff'
};

interface ViewOnceCameraProps {
    visible: boolean;
    onClose: () => void;
    onSend: (data: { uri: string; width: number; height: number; viewOnce: boolean }) => void;
}

export function ViewOnceCamera({ visible, onClose, onSend }: ViewOnceCameraProps) {
    const [permission, requestPermission] = useCameraPermissions();
    const cameraRef = useRef<CameraView>(null);
    const [facing, setFacing] = useState<CameraType>('back');
    const [flash, setFlash] = useState<FlashMode>('off');
    const [capturedImage, setCapturedImage] = useState<{ uri: string; width: number; height: number } | null>(null);

    // Toggle state: If true, it is "View Once" (1x). If false, it is "Allow Reply" (standard image).
    const [isViewOnce, setIsViewOnce] = useState(true);

    useEffect(() => {
        if (visible && !permission?.granted) {
            requestPermission();
        }
    }, [visible, permission]);

    const handleTakePicture = async () => {
        if (cameraRef.current) {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
            try {
                const photo = await cameraRef.current.takePictureAsync({ quality: 0.8, skipProcessing: true });
                if (photo) {
                    setCapturedImage(photo);
                }
            } catch (e) {
                console.error(e);
            }
        }
    };

    const handleRetake = () => {
        setCapturedImage(null);
        setIsViewOnce(true); // Reset to default
    };

    const handleSend = () => {
        if (capturedImage) {
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            onSend({
                uri: capturedImage.uri,
                width: capturedImage.width,
                height: capturedImage.height,
                viewOnce: isViewOnce
            });
            handleRetake(); // Reset state
        }
    };

    if (!visible) return null;

    if (!permission?.granted) {
        return (
            <View style={styles.container}>
                <StatusBar barStyle="light-content" />
                <View style={[styles.card, { alignItems: 'center', justifyContent: 'center' }]}>
                    <Text style={{ color: 'white', marginBottom: 20 }}>Camera permission needed</Text>
                    <TouchableOpacity onPress={requestPermission} style={{ padding: 10, backgroundColor: colors.primary, borderRadius: 8 }}>
                        <Text style={{ color: 'white' }}>Grant Permission</Text>
                    </TouchableOpacity>
                    <TouchableOpacity onPress={onClose} style={{ marginTop: 20 }}>
                        <Text style={{ color: '#999' }}>Cancel</Text>
                    </TouchableOpacity>
                </View>
            </View>
        );
    }

    return (
        <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
            <View style={styles.container}>
                <StatusBar barStyle="light-content" />

                {/* Main Card Container */}
                <View style={styles.card}>
                    {capturedImage ? (
                        <Image source={{ uri: capturedImage.uri }} style={styles.preview} resizeMode="cover" />
                    ) : (
                        <CameraView
                            ref={cameraRef}
                            style={styles.preview}
                            facing={facing}
                            flash={flash}
                        />
                    )}

                    {/* Top Controls */}
                    <View style={styles.topBar}>
                        {!capturedImage ? (
                            <SafeLiquidGlass style={styles.glassCircle} blurIntensity={20} tint="dark">
                                <TouchableOpacity onPress={onClose} style={styles.iconBtn}>
                                    <X size={24} color="#fff" />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        ) : (
                            <SafeLiquidGlass style={styles.glassCircle} blurIntensity={20} tint="dark">
                                <TouchableOpacity onPress={handleRetake} style={styles.iconBtn}>
                                    <X size={24} color="#fff" />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        )}

                        {!capturedImage && (
                            <SafeLiquidGlass style={styles.glassCircle} blurIntensity={20} tint="dark">
                                <TouchableOpacity
                                    onPress={() => setFlash(f => f === 'off' ? 'on' : 'off')}
                                    style={styles.iconBtn}
                                >
                                    {flash === 'on' ? <Zap size={20} color="#FFD700" fill="#FFD700" /> : <ZapOff size={20} color="#fff" />}
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        )}
                    </View>

                    {/* Bottom Controls */}
                    <View style={styles.bottomBar}>
                        {!capturedImage ? (
                            <View style={styles.shutterContainer}>
                                <TouchableOpacity onPress={handleTakePicture} style={styles.shutterOuter}>
                                    <View style={styles.shutterInner} />
                                </TouchableOpacity>
                            </View>
                        ) : (
                            <View style={styles.reviewControls}>
                                {/* View Once Toggle */}
                                <TouchableOpacity
                                    onPress={() => {
                                        Haptics.selectionAsync();
                                        setIsViewOnce(!isViewOnce);
                                    }}
                                    style={styles.toggleBtn}
                                >
                                    <SafeLiquidGlass style={{ borderRadius: 20, overflow: 'hidden' }} blurIntensity={30} tint="dark">
                                        <View style={[styles.toggleContent, isViewOnce ? { backgroundColor: 'rgba(255,255,255,0.2)' } : {}]}>
                                            {isViewOnce ? (
                                                <>
                                                    <View style={[styles.badge, { backgroundColor: colors.primary }]}>
                                                        <Text style={styles.badgeText}>1</Text>
                                                    </View>
                                                    <Text style={styles.toggleText}>View Once</Text>
                                                </>
                                            ) : (
                                                <>
                                                    <Check size={18} color="#fff" style={{ marginRight: 6 }} />
                                                    <Text style={styles.toggleText}>Allow Reply</Text>
                                                </>
                                            )}
                                        </View>
                                    </SafeLiquidGlass>
                                </TouchableOpacity>

                                {/* Send Button */}
                                <TouchableOpacity onPress={handleSend} style={styles.sendBtn}>
                                    <View style={styles.sendBtnCircle}>
                                        <ArrowUp size={24} color="#fff" strokeWidth={3} />
                                    </View>
                                </TouchableOpacity>
                            </View>
                        )}
                    </View>
                </View>
            </View>
        </Modal>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#000',
    },
    card: {
        flex: 1,
        marginHorizontal: 10,
        marginTop: 50,
        marginBottom: 30,
        borderRadius: 32,
        overflow: 'hidden',
        backgroundColor: '#1a1a1a',
        position: 'relative',
    },
    preview: {
        flex: 1,
        width: '100%',
        height: '100%',
    },
    topBar: {
        position: 'absolute',
        top: 20,
        left: 20,
        right: 20,
        flexDirection: 'row',
        justifyContent: 'space-between',
        zIndex: 10,
    },
    glassCircle: {
        width: 44,
        height: 44,
        borderRadius: 22,
        overflow: 'hidden',
    },
    iconBtn: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(0,0,0,0.2)',
    },
    bottomBar: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        paddingBottom: 30,
        paddingHorizontal: 30,
        alignItems: 'center',
        zIndex: 10,
    },
    shutterContainer: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    shutterOuter: {
        width: 80,
        height: 80,
        borderRadius: 40,
        borderWidth: 5,
        borderColor: '#fff',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'transparent',
    },
    shutterInner: {
        width: 64,
        height: 64,
        borderRadius: 32,
        backgroundColor: '#fff',
    },
    reviewControls: {
        flexDirection: 'row',
        width: '100%',
        alignItems: 'center',
        justifyContent: 'space-between',
    },
    toggleBtn: {
        borderRadius: 20,
    },
    toggleContent: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16,
        paddingVertical: 10,
        backgroundColor: 'rgba(0,0,0,0.3)',
        minWidth: 120,
        justifyContent: 'center',
    },
    toggleText: {
        color: '#fff',
        fontWeight: '600',
        fontSize: 14,
    },
    badge: {
        width: 20,
        height: 20,
        borderRadius: 10,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 8,
        borderWidth: 1.5,
        borderColor: '#fff',
        borderStyle: 'dashed',
    },
    badgeText: {
        color: '#fff',
        fontSize: 11,
        fontWeight: 'bold',
    },
    sendBtn: {

    },
    sendBtnCircle: {
        width: 50,
        height: 50,
        borderRadius: 25,
        backgroundColor: colors.primary,
        alignItems: 'center',
        justifyContent: 'center',
    },
});
