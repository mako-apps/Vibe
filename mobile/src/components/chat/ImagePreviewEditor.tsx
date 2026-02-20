import React, { useState, useCallback, useRef, useMemo } from 'react';
import {
    View,
    Text,
    StyleSheet,
    Dimensions,
    TouchableOpacity,
    TextInput,
    Modal,
    Image,
    KeyboardAvoidingView,
    Platform,
    StatusBar,
} from 'react-native';
import { Canvas, Path, Skia, SkPath, SkImage, useCanvasRef, makeImageFromView } from '@shopify/react-native-skia';
import { GestureDetector, Gesture } from 'react-native-gesture-handler';
import { X, Undo2, Pen, ArrowUp, ChevronLeft, ChevronRight } from 'lucide-react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import * as FileSystem from 'expo-file-system/legacy';
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const DRAW_COLORS = ['#FFFFFF', '#FF3B30', '#FF9500', '#34C759', '#007AFF', '#AF52DE', '#000000'];
const STROKE_WIDTHS = [3, 6, 12];

interface ImagePreviewEditorProps {
    visible: boolean;
    images: { uri: string; width?: number; height?: number }[];
    onClose: () => void;
    onSend: (results: { uri: string; width?: number; height?: number; caption?: string; hdMode?: boolean }[]) => void;
    initialHdMode?: boolean;
}

interface DrawnPath {
    path: SkPath;
    color: string;
    strokeWidth: number;
}

export const ImagePreviewEditor = ({ visible, images, onClose, onSend, initialHdMode = false }: ImagePreviewEditorProps) => {
    const { colors } = useThemeStore();
    const [currentIndex, setCurrentIndex] = useState(0);
    const [caption, setCaption] = useState('');
    const [hdMode, setHdMode] = useState(initialHdMode);
    const [drawMode, setDrawMode] = useState(false);
    const [selectedColor, setSelectedColor] = useState(DRAW_COLORS[0]);
    const [selectedStrokeWidth, setSelectedStrokeWidth] = useState(STROKE_WIDTHS[1]);

    // Per-image drawn paths
    const [pathsByImage, setPathsByImage] = useState<Record<number, DrawnPath[]>>({});
    const currentPathRef = useRef<SkPath | null>(null);
    const [currentPath, setCurrentPath] = useState<SkPath | null>(null);

    const imageRef = useRef<View>(null);

    const currentImage = images[currentIndex];
    const currentPaths = pathsByImage[currentIndex] || [];

    // Calculate image display dimensions
    const imageLayout = useMemo(() => {
        if (!currentImage) return { width: SCREEN_WIDTH, height: SCREEN_WIDTH * 0.75, top: 0 };
        const imgW = currentImage.width || SCREEN_WIDTH;
        const imgH = currentImage.height || SCREEN_WIDTH * 0.75;
        const ratio = imgH / imgW;
        const displayW = SCREEN_WIDTH;
        const displayH = Math.min(SCREEN_HEIGHT * 0.6, displayW * ratio);
        const top = (SCREEN_HEIGHT * 0.55 - displayH) / 2;
        return { width: displayW, height: displayH, top: Math.max(60, top) };
    }, [currentImage]);

    // Drawing gesture
    const drawGesture = Gesture.Pan()
        .enabled(drawMode)
        .onBegin((e) => {
            const path = Skia.Path.Make();
            path.moveTo(e.x, e.y);
            currentPathRef.current = path;
            setCurrentPath(path);
        })
        .onUpdate((e) => {
            if (currentPathRef.current) {
                currentPathRef.current.lineTo(e.x, e.y);
                // Force re-render by creating new ref
                setCurrentPath(Skia.Path.MakeFromSVGString(currentPathRef.current.toSVGString()) || currentPathRef.current);
            }
        })
        .onEnd(() => {
            if (currentPathRef.current) {
                setPathsByImage(prev => ({
                    ...prev,
                    [currentIndex]: [
                        ...(prev[currentIndex] || []),
                        { path: currentPathRef.current!, color: selectedColor, strokeWidth: selectedStrokeWidth }
                    ]
                }));
                currentPathRef.current = null;
                setCurrentPath(null);
            }
        });

    const handleUndo = useCallback(() => {
        setPathsByImage(prev => {
            const current = prev[currentIndex] || [];
            if (current.length === 0) return prev;
            return { ...prev, [currentIndex]: current.slice(0, -1) };
        });
    }, [currentIndex]);

    const handleSend = useCallback(async () => {
        const results = [];
        for (let i = 0; i < images.length; i++) {
            const img = images[i];
            const paths = pathsByImage[i];
            let finalUri = img.uri;

            // If there are drawings, capture the composited view using Skia's makeImageFromView
            if (paths && paths.length > 0 && imageRef.current && i === currentIndex) {
                try {
                    const snapshot = await makeImageFromView(imageRef);
                    if (snapshot) {
                        const encoded = snapshot.encodeToBase64();
                        const tmpPath = `${FileSystem.cacheDirectory}edited_${Date.now()}.jpg`;
                        await FileSystem.writeAsStringAsync(tmpPath, encoded, {
                            encoding: FileSystem.EncodingType.Base64,
                        });
                        finalUri = tmpPath;
                    }
                } catch (e) {
                    console.warn('[ImagePreviewEditor] Snapshot failed, sending original:', e);
                }
            }

            results.push({
                uri: finalUri,
                width: img.width,
                height: img.height,
                caption: i === 0 ? caption.trim() || undefined : undefined,
                hdMode,
            });
        }
        onSend(results);
    }, [images, pathsByImage, currentIndex, caption, hdMode, onSend]);

    const handlePrev = useCallback(() => {
        setCurrentIndex(i => Math.max(0, i - 1));
    }, []);

    const handleNext = useCallback(() => {
        setCurrentIndex(i => Math.min(images.length - 1, i + 1));
    }, [images.length]);

    if (!visible || images.length === 0) return null;

    return (
        <Modal visible={visible} animationType="slide" presentationStyle="fullScreen" statusBarTranslucent>
            <StatusBar barStyle="light-content" />
            <KeyboardAvoidingView
                style={styles.container}
                behavior={Platform.OS === 'ios' ? 'padding' : undefined}
            >
                {/* Top Bar */}
                <View style={styles.topBar}>
                    <TouchableOpacity onPress={onClose} style={styles.topBtn} hitSlop={12}>
                        <X size={24} color="#fff" />
                    </TouchableOpacity>

                    <View style={styles.topCenter}>
                        {images.length > 1 && (
                            <Text style={styles.pageIndicator}>{currentIndex + 1} / {images.length}</Text>
                        )}
                    </View>

                    {drawMode && (
                        <TouchableOpacity onPress={handleUndo} style={styles.topBtn} hitSlop={12}>
                            <Undo2 size={22} color="#fff" />
                        </TouchableOpacity>
                    )}
                </View>

                {/* Image + Drawing Canvas */}
                <View
                    ref={imageRef}
                    collapsable={false}
                    style={[styles.imageContainer, { top: imageLayout.top, height: imageLayout.height }]}
                >
                    <Image
                        source={{ uri: currentImage.uri }}
                        style={{ width: imageLayout.width, height: imageLayout.height }}
                        resizeMode="contain"
                    />

                    {/* Drawing Canvas Overlay */}
                    {drawMode && (
                        <GestureDetector gesture={drawGesture}>
                            <View style={StyleSheet.absoluteFill}>
                                <Canvas style={StyleSheet.absoluteFill}>
                                    {/* Committed paths */}
                                    {currentPaths.map((dp, idx) => (
                                        <Path
                                            key={idx}
                                            path={dp.path}
                                            color={dp.color}
                                            style="stroke"
                                            strokeWidth={dp.strokeWidth}
                                            strokeCap="round"
                                            strokeJoin="round"
                                        />
                                    ))}
                                    {/* Active path being drawn */}
                                    {currentPath && (
                                        <Path
                                            path={currentPath}
                                            color={selectedColor}
                                            style="stroke"
                                            strokeWidth={selectedStrokeWidth}
                                            strokeCap="round"
                                            strokeJoin="round"
                                        />
                                    )}
                                </Canvas>
                            </View>
                        </GestureDetector>
                    )}

                    {/* Image navigation arrows */}
                    {images.length > 1 && (
                        <>
                            {currentIndex > 0 && (
                                <TouchableOpacity style={[styles.navArrow, styles.navLeft]} onPress={handlePrev}>
                                    <ChevronLeft size={28} color="#fff" />
                                </TouchableOpacity>
                            )}
                            {currentIndex < images.length - 1 && (
                                <TouchableOpacity style={[styles.navArrow, styles.navRight]} onPress={handleNext}>
                                    <ChevronRight size={28} color="#fff" />
                                </TouchableOpacity>
                            )}
                        </>
                    )}
                </View>

                {/* Draw Mode Toolbar */}
                {drawMode && (
                    <Animated.View entering={FadeIn.duration(200)} exiting={FadeOut.duration(150)} style={styles.drawToolbar}>
                        {/* Color Picker */}
                        <View style={styles.colorRow}>
                            {DRAW_COLORS.map((c) => (
                                <TouchableOpacity
                                    key={c}
                                    onPress={() => setSelectedColor(c)}
                                    style={[
                                        styles.colorDot,
                                        { backgroundColor: c, borderColor: c === '#FFFFFF' ? '#666' : c },
                                        selectedColor === c && styles.colorDotSelected,
                                    ]}
                                />
                            ))}
                        </View>
                        {/* Stroke Width */}
                        <View style={styles.strokeRow}>
                            {STROKE_WIDTHS.map((sw) => (
                                <TouchableOpacity
                                    key={sw}
                                    onPress={() => setSelectedStrokeWidth(sw)}
                                    style={[styles.strokeBtn, selectedStrokeWidth === sw && styles.strokeBtnSelected]}
                                >
                                    <View style={[styles.strokePreview, { width: sw * 2.5, height: sw * 2.5, backgroundColor: selectedColor }]} />
                                </TouchableOpacity>
                            ))}
                        </View>
                    </Animated.View>
                )}

                {/* Bottom Area */}
                <View style={styles.bottomArea}>
                    {/* Caption Input */}
                    <View style={styles.captionRow}>
                        <TextInput
                            style={styles.captionInput}
                            placeholder="Add a caption..."
                            placeholderTextColor="rgba(255,255,255,0.4)"
                            value={caption}
                            onChangeText={setCaption}
                            multiline
                            maxLength={500}
                        />
                    </View>

                    {/* Bottom Toolbar */}
                    <View style={styles.toolbar}>
                        {/* Draw Toggle */}
                        <TouchableOpacity
                            style={[styles.toolBtn, drawMode && styles.toolBtnActive]}
                            onPress={() => setDrawMode(d => !d)}
                        >
                            <Pen size={20} color={drawMode ? '#007AFF' : '#fff'} />
                            <Text style={[styles.toolLabel, drawMode && { color: '#007AFF' }]}>Draw</Text>
                        </TouchableOpacity>

                        {/* SD/HD Toggle */}
                        <TouchableOpacity
                            style={styles.hdToggle}
                            onPress={() => setHdMode(h => !h)}
                        >
                            <View style={[styles.hdPill, hdMode && styles.hdPillActive]}>
                                <Text style={[styles.hdText, !hdMode && styles.hdTextActive]}>SD</Text>
                                <Text style={[styles.hdText, hdMode && styles.hdTextActive]}>HD</Text>
                            </View>
                        </TouchableOpacity>

                        {/* Send Button */}
                        <TouchableOpacity style={styles.sendBtn} onPress={handleSend}>
                            <ArrowUp size={22} color="#fff" strokeWidth={2.5} />
                        </TouchableOpacity>
                    </View>
                </View>
            </KeyboardAvoidingView>
        </Modal>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: '#000',
    },
    topBar: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingTop: Platform.OS === 'ios' ? 56 : 40,
        paddingHorizontal: 16,
        paddingBottom: 12,
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 100,
    },
    topBtn: {
        width: 40,
        height: 40,
        borderRadius: 20,
        backgroundColor: 'rgba(255,255,255,0.12)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    topCenter: {
        flex: 1,
        alignItems: 'center',
    },
    pageIndicator: {
        color: '#fff',
        fontSize: 15,
        fontWeight: '600',
    },
    imageContainer: {
        position: 'absolute',
        left: 0,
        width: SCREEN_WIDTH,
        overflow: 'hidden',
    },
    navArrow: {
        position: 'absolute',
        top: '50%',
        marginTop: -20,
        width: 40,
        height: 40,
        borderRadius: 20,
        backgroundColor: 'rgba(0,0,0,0.4)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    navLeft: { left: 12 },
    navRight: { right: 12 },
    drawToolbar: {
        position: 'absolute',
        bottom: 180,
        left: 0,
        right: 0,
        paddingHorizontal: 20,
    },
    colorRow: {
        flexDirection: 'row',
        justifyContent: 'center',
        gap: 12,
        marginBottom: 12,
    },
    colorDot: {
        width: 28,
        height: 28,
        borderRadius: 14,
        borderWidth: 2,
    },
    colorDotSelected: {
        borderColor: '#fff',
        borderWidth: 3,
        transform: [{ scale: 1.15 }],
    },
    strokeRow: {
        flexDirection: 'row',
        justifyContent: 'center',
        gap: 16,
    },
    strokeBtn: {
        width: 40,
        height: 40,
        borderRadius: 20,
        backgroundColor: 'rgba(255,255,255,0.1)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    strokeBtnSelected: {
        backgroundColor: 'rgba(255,255,255,0.25)',
        borderWidth: 1.5,
        borderColor: 'rgba(255,255,255,0.5)',
    },
    strokePreview: {
        borderRadius: 99,
    },
    bottomArea: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        paddingBottom: Platform.OS === 'ios' ? 36 : 20,
        paddingHorizontal: 16,
    },
    captionRow: {
        backgroundColor: 'rgba(255,255,255,0.08)',
        borderRadius: 20,
        paddingHorizontal: 16,
        paddingVertical: 10,
        marginBottom: 12,
    },
    captionInput: {
        color: '#fff',
        fontSize: 15,
        maxHeight: 80,
        lineHeight: 20,
    },
    toolbar: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
    },
    toolBtn: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        paddingHorizontal: 14,
        paddingVertical: 10,
        borderRadius: 20,
        backgroundColor: 'rgba(255,255,255,0.1)',
    },
    toolBtnActive: {
        backgroundColor: 'rgba(0,122,255,0.15)',
    },
    toolLabel: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '500',
    },
    hdToggle: {
        alignItems: 'center',
    },
    hdPill: {
        flexDirection: 'row',
        backgroundColor: 'rgba(255,255,255,0.1)',
        borderRadius: 16,
        overflow: 'hidden',
    },
    hdPillActive: {
        backgroundColor: 'rgba(0,122,255,0.15)',
    },
    hdText: {
        paddingHorizontal: 14,
        paddingVertical: 8,
        color: 'rgba(255,255,255,0.5)',
        fontSize: 14,
        fontWeight: '600',
    },
    hdTextActive: {
        color: '#fff',
    },
    sendBtn: {
        width: 44,
        height: 44,
        borderRadius: 22,
        backgroundColor: '#007AFF',
        alignItems: 'center',
        justifyContent: 'center',
    },
});

export default ImagePreviewEditor;
