import React, { useState, useEffect, useMemo } from 'react';
import {
    View,
    Image,
    TouchableOpacity,
    StyleSheet,
    Platform,
    Dimensions,
    Text,
    Alert,
    Keyboard,
    TouchableWithoutFeedback,
    TextInput,
    Modal,
    ScrollView
} from 'react-native';
import {
    X,
    Download,
    Smile,
    Music,
    Settings,
    TriangleAlert,
    RefreshCcw,
    RotateCcw,
    Type,
    Trash2,
    Check,
    Palette,
    AlignLeft,
    AlignCenter,
    AlignRight,
    Pencil
} from 'lucide-react-native';
import * as MediaLibrary from 'expo-media-library';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';

import { KeyboardStickyView, useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import { StoryEffects, EFFECTS, Effect, EffectId } from './StoryEffects';
import { ShareModal } from './ShareModal';
import StoryInput from './StoryInput';
import { StoryInputBackground } from './StoryInputBackground';
import GlassFontMenu from './GlassFontMenu';
import * as Haptics from 'expo-haptics';
import Animated, {
    FadeIn,
    FadeOut,
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withSpring,
    runOnJS,
    withRepeat,
    withSequence,
    withDelay,
    interpolate,
    Easing,
    useAnimatedProps,
    SharedValue
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import Svg, { Path, Circle as SvgCircle } from 'react-native-svg';
import { theme } from '../../lib/theme';
import { useAuthStore } from '../../lib/stores/auth-store';
import { StrokeText } from '@charmy.tech/react-native-stroke-text';
import { Canvas, Image as SkiaImage, Blur, Rect, useImage } from '@shopify/react-native-skia';

const COLORS = [
    '#FFFFFF', '#000000', '#FF3B30', '#FF9500', '#FFCC00', '#4CD964', '#5AC8FA', '#007AFF', '#5856D6', '#FF2D55',
    '#AF52DE', '#FF2D55', '#5856D6', '#007AFF', '#34AADC', '#5AC8FA', '#4CD964', '#FFCC00', '#FF9500', '#FF3B30',
    '#8E8E93', '#AEAEB2', '#C7C7CC', '#D1D1D6', '#E5E5EA', '#F2F2F7', '#34C759', '#32ADE6', '#007AFF', '#5856D6',
    '#1ABC9C', '#2ECC71', '#3498DB', '#9B59B6', '#34495E', '#16A085', '#27AE60', '#2980B9', '#8E44AD', '#2C3E50',
    '#F1C40F', '#E67E22', '#E74C3C', '#ECF0F1', '#95A5A6', '#F39C12', '#D35400', '#C0392B', '#BDC3C7', '#7F8C8D'
];

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

// Always use dark theme for story preview, EXCEPT for specific controls
const colors = theme.dark;


interface StoryPreviewProps {
    media: { uri: string, type: 'image' | 'video', mirrored?: boolean };
    onDiscard: () => void;
    onPost: (details?: {
        prompt?: string,
        effect?: EffectId,
        audience?: string,
        allowScreenshots?: boolean,
        postToProfile?: boolean,
        duration?: number,
        visibleTo?: string[],
        hiddenFrom?: string[]
    }) => void;
    onSaveDraft: () => void;
    onSettings: () => void;
    onAIEdit: (prompt: string) => void;
    isEditing?: boolean;
    editError?: string | null;
    editRateLimitSeconds?: number | null;
    onClearError?: () => void;
    canRevert?: boolean;
    onRevert?: () => void;
}

interface TextOverlay {
    id: string;
    text: string;
    x: number;
    y: number;
    color: string;
    scale: number;
    fontSize: number;
    font?: string;
    alignment?: 'left' | 'center' | 'right';
    textStyle?: 'none' | 'outline' | 'neon' | 'background' | 'background-glass' | 'stroke';
}

const FONTS = [
    { name: 'Default', family: undefined },
    { name: 'Serif', family: 'serif' },
    { name: 'Mono', family: 'monospace' },
    { name: 'Grotesk', family: 'SpaceGrotesk-Regular' }
];

const TEXT_STYLES = ['none', 'background', 'background-glass', 'neon', 'outline'] as const;

const getTextStyle = (style: string | undefined, color: string) => {
    switch (style) {
        case 'outline':
        case 'stroke':
            // Solid color during editing ensures visibility
            return {
                textShadowColor: style === 'stroke' ? '#000' : 'rgba(0,0,0,0.5)',
                textShadowOffset: { width: 1, height: 1 },
                textShadowRadius: 1,
                color: color // Always visible
            };
        case 'neon':
            return {
                textShadowColor: color,
                textShadowOffset: { width: 0, height: 0 },
                textShadowRadius: 10,
                color: '#fff'
            };
        case 'background':
            return {
                backgroundColor: color,
                color: color === '#FFFFFF' ? '#000' : '#fff',
                paddingHorizontal: 8,
                paddingVertical: 4,
                borderRadius: 8,
                overflow: 'hidden' as const
            };
        case 'background-glass':
            return {
                backgroundColor: withAlpha(color, 0.55),
                color: '#fff',
                paddingHorizontal: 8,
                paddingVertical: 4,
                borderRadius: 8,
                overflow: 'hidden' as const
            };
        default:
            return {};
    }
};

const DraggableText = ({
    item,
    onUpdate,
    onDelete,
    isSelected,
    onSelect,
    onEdit
}: {
    item: TextOverlay,
    onUpdate: (id: string, updates: Partial<TextOverlay>) => void,
    onDelete: (id: string) => void,
    isSelected: boolean,
    onSelect: () => void,
    onEdit: () => void
}) => {
    const isDragging = useSharedValue(false);
    const offsetX = useSharedValue(item.x);
    const offsetY = useSharedValue(item.y);

    // Sync initial position if it changes (e.g. from external update)
    useEffect(() => {
        offsetX.value = item.x;
        offsetY.value = item.y;
    }, [item.x, item.y]);

    const pan = Gesture.Pan()
        .onStart(() => {
            isDragging.value = true;
            runOnJS(onSelect)();
        })
        .onUpdate((event) => {
            offsetX.value = event.absoluteX - 50; // Center offset approximation
            offsetY.value = event.absoluteY - 50;
        })
        .onEnd(() => {
            isDragging.value = false;
            runOnJS(onUpdate)(item.id, { x: offsetX.value, y: offsetY.value });
        });

    // Tap to select logic handled by TouchableOpacity for better compatibility with child buttons
    // Pan only for dragging

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateX: offsetX.value },
            { translateY: offsetY.value },
            { scale: withSpring(isDragging.value || isSelected ? 1.05 : 1) }
        ],
        position: 'absolute',
        top: 0,
        left: 0,
        zIndex: isSelected ? 100 : 10,
    }));

    // If selected, show a border/clean container
    const containerStyle = {
        borderWidth: isSelected ? 1 : 0,
        borderColor: isSelected ? 'rgba(255,255,255,0.5)' : 'transparent',
        padding: 8,
        borderRadius: 8,
    };

    return (
        <Animated.View style={animatedStyle}>
            <GestureDetector gesture={pan}>
                <View>
                    <TouchableOpacity
                        onPress={onSelect}
                        style={containerStyle}
                        activeOpacity={0.9}
                    >
                        {item.textStyle === 'outline' || item.textStyle === 'stroke' ? (
                            <StrokeText
                                text={item.text}
                                fontSize={item.fontSize || 30}
                                color={item.color}
                                strokeColor={item.textStyle === 'stroke' ? '#000000' : '#FFFFFF'}
                                strokeWidth={2}
                                fontFamily={item.font}
                            />
                        ) : (
                            <Text style={[
                                styles.overlayText,
                                {
                                    fontSize: item.fontSize || 30,
                                    color: item.textStyle === 'neon' ? '#fff' : item.color,
                                    fontFamily: item.font,
                                    textAlign: item.alignment || 'left',
                                    alignSelf: 'flex-start', // Ensure background wraps text
                                    ...getTextStyle(item.textStyle, item.color)
                                }
                            ]}>
                                {item.text}
                            </Text>
                        )}
                    </TouchableOpacity>
                </View>
            </GestureDetector>

            {/* Context Menu for Selected Item (Edit/Delete) - Sibling to GestureDetector so touches pass through defined buttons */}
            {isSelected && (
                <View style={styles.contextMenu}>
                    <TouchableOpacity onPress={onEdit} style={styles.contextBtn}>
                        <Pencil size={14} color="#000" />
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => onDelete(item.id)} style={[styles.contextBtn, { backgroundColor: '#FF453A' }]}>
                        <Trash2 size={14} color="#fff" />
                    </TouchableOpacity>
                </View>
            )}
        </Animated.View>
    );
};

const withAlpha = (color: string, opacity: number) => {
    if (!color) return `rgba(0, 0, 0, ${opacity})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${opacity})`;
    }
    return color;
};

// --- Shimmer Components ---

const ShimmerChar = ({ char, index }: { char: string, index: number }) => {
    const opacity = useSharedValue(0.2);

    useEffect(() => {
        const delay = index * 100;
        const timeout = setTimeout(() => {
            opacity.value = withRepeat(
                withSequence(
                    withTiming(1, { duration: 1000, easing: Easing.inOut(Easing.ease) }),
                    withTiming(0.2, { duration: 1000, easing: Easing.inOut(Easing.ease) })
                ),
                -1,
                true
            );
        }, delay);
        return () => clearTimeout(timeout);
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        opacity: opacity.value,
        transform: [
            { translateY: interpolate(opacity.value, [0.2, 1], [3, 0]) },
            { scale: interpolate(opacity.value, [0.2, 1], [0.95, 1]) }
        ]
    }));

    return (
        <Animated.View style={[{ marginRight: char === ' ' ? 8 : 1 }, animatedStyle]}>
            <Text style={styles.shimmerText}>{char}</Text>
        </Animated.View>
    );
};

const ShimmerText = ({ messages }: { messages: string[] }) => {
    const [index, setIndex] = useState(0);

    useEffect(() => {
        const interval = setInterval(() => {
            setIndex((prev) => (prev + 1) % messages.length);
        }, 3000);
        return () => clearInterval(interval);
    }, [messages]);

    const activeText = messages[index];

    return (
        <View style={{ height: 40, justifyContent: 'center', alignItems: 'center' }}>
            <Animated.View
                key={`msg - ${index} `}
                entering={FadeIn.duration(800)}
                exiting={FadeOut.duration(500)}
                style={{ flexDirection: 'row', alignItems: 'center' }}
            >
                {activeText.split('').map((char, i) => (
                    <ShimmerChar key={`${index} -${i} -${char} `} char={char} index={i} />
                ))}
            </Animated.View>
        </View>
    );
};

const RateLimitBlurCard = ({ imageUri }: { imageUri: string }) => {
    const img = useImage(imageUri);

    if (!img) {
        return (
            <View style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(13, 18, 27, 0.94)' }]} />
        );
    }

    return (
        <Canvas style={StyleSheet.absoluteFill}>
            <SkiaImage image={img} fit="cover" x={0} y={0} width={SCREEN_WIDTH - 32} height={238}>
                <Blur blur={20} />
            </SkiaImage>
            <Rect x={0} y={0} width={SCREEN_WIDTH - 32} height={238} color="rgba(8, 11, 18, 0.72)" />
        </Canvas>
    );
};

// --- Animated Percentage using TextInput trick ---
// --- Animated Percentage using TextInput trick ---
const AnimatedTextInput = Animated.createAnimatedComponent(TextInput);

const AnimatedPercentage = ({ progress }: { progress: SharedValue<number> }) => {
    const animatedProps = useAnimatedProps(() => {
        return {
            text: `${Math.round(progress.value)}% `,
            // Also set defaultValue/value to force update on some RN versions
            defaultValue: `${Math.round(progress.value)}% `
        } as any;
    });

    return (
        <AnimatedTextInput
            underlineColorAndroid="transparent"
            editable={false}
            value={`${Math.round(progress.value)}% `} // Initial value
            animatedProps={animatedProps}
            style={styles.percentageSmall}
        />
    );
};


export const StoryPreview = ({
    media,
    onDiscard,
    onPost,
    onSaveDraft,
    onSettings,
    onAIEdit,
    isEditing,
    editError,
    editRateLimitSeconds,
    onClearError,
    canRevert,
    onRevert
}: StoryPreviewProps) => {
    const { user } = useAuthStore();
    const [showEffects, setShowEffects] = useState(false);
    const [selectedEffect, setSelectedEffect] = useState<Effect>(EFFECTS[0]);
    const [showShareModal, setShowShareModal] = useState(false);
    const [lastPrompt, setLastPrompt] = useState('');
    const [loadingPhaseIndex, setLoadingPhaseIndex] = useState(0);
    const [loadingElapsedSec, setLoadingElapsedSec] = useState(0);
    const [rateLimitCountdown, setRateLimitCountdown] = useState(0);
    const [isImageLoading, setIsImageLoading] = useState(false);
    const [textOverlays, setTextOverlays] = useState<TextOverlay[]>([]);
    const [activeTextId, setActiveTextId] = useState<string | null>(null);
    const [editingText, setEditingText] = useState('');
    const [isTextEditing, setIsTextEditing] = useState(false);

    // Editor State
    const [editorColor, setEditorColor] = useState('#FFFFFF');
    const [editorFontSize, setEditorFontSize] = useState(30);
    const [editorFont, setEditorFont] = useState<string | undefined>(undefined);
    const [editorAlign, setEditorAlign] = useState<'left' | 'center' | 'right'>('center');
    const [editorStyle, setEditorStyle] = useState<'none' | 'outline' | 'neon' | 'background' | 'background-glass' | 'stroke'>('none');
    const [showColorPicker, setShowColorPicker] = useState(false);

    // Keyboard Animation & Fake View
    const { progress: keyboardProgress, height: keyboardHeight } = useReanimatedKeyboardAnimation();

    // "Fake View" animation to push content up when keyboard opens (only during text edit or similar)
    const fakeViewStyle = useAnimatedStyle(() => {
        return {}; // Handled in animatedParentStyle to avoid transform conflict
    });

    // Manual Keyboard Animated Style for Bottom Elements
    const stickyBottomStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: keyboardHeight.value }]
    }));

    // Progress Animation
    const progressValue = useSharedValue(0);
    const limitSheetProgress = useSharedValue(0);
    const fontSizeShared = useSharedValue(30);

    const animatedFontSizeStyle = useAnimatedStyle(() => ({
        // Use transform scale for smoother updates without layout trashing
        transform: [{ scale: fontSizeShared.value / 40 }]
    }));

    const animatedSliderHandleStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: interpolate(fontSizeShared.value, [10, 100], [108, -108], 'clamp') }]
    }));

    const sliderVisibility = useSharedValue(1);

    const sliderAnimatedStyle = useAnimatedStyle(() => ({
        opacity: withTiming(interpolate(sliderVisibility.value, [0, 1], [0.65, 1]), { duration: 300 }),
        transform: [
            { translateX: withTiming(interpolate(sliderVisibility.value, [0, 1], [-18, 0]), { duration: 400 }) }
        ]
    }));

    // Fix: Move inline hooks to top level
    const animatedProgressStyle = useAnimatedStyle(() => ({
        width: `${progressValue.value}%`
    }));

    const textInputContainerStyle = useAnimatedStyle(() => ({
        paddingBottom: Math.abs(keyboardHeight.value) + 60 // Adjust for bottom bar
    }));

    const colorPickerHeight = useSharedValue(0);
    useEffect(() => {
        colorPickerHeight.value = withTiming(showColorPicker ? 56 : 0, { duration: 200 });
    }, [showColorPicker]);

    const colorPickerAnimatedStyle = useAnimatedStyle(() => ({
        height: colorPickerHeight.value,
        opacity: interpolate(colorPickerHeight.value, [0, 56], [0, 1]),
        overflow: 'hidden',
        marginTop: interpolate(colorPickerHeight.value, [0, 56], [0, 8]),
    }));

    // Sync SharedValue when editor opens
    const shouldShiftContent = useSharedValue(0);
    useEffect(() => {
        shouldShiftContent.value = isTextEditing ? 1 : 0;
    }, [isTextEditing]);

    useEffect(() => {
        if (isTextEditing) {
            fontSizeShared.value = editorFontSize;
            sliderVisibility.value = 1;
            // Hide after 3s
            sliderVisibility.value = withDelay(3000, withTiming(0, { duration: 600 }));
        }
    }, [isTextEditing]);

    useEffect(() => {
        if (isEditing) {
            // Reset and start animation to 92% over 15s (typical latency)
            progressValue.value = 0;
            progressValue.value = withTiming(92, { duration: 15000, easing: Easing.out(Easing.cubic) });
            setIsImageLoading(true); // Ensure loading state starts

            fontSizeShared.value = editorFontSize;
        } else {
            // Finish quickly
            progressValue.value = withTiming(100, { duration: 800 });
        }
    }, [isEditing]);

    useEffect(() => {
        // When media changes, if we have edit history, assume loading
        if (canRevert) {
            setIsImageLoading(true);
        }
    }, [media.uri]);

    // Derived loading state: API is editing OR Image is still loading
    const showLoadingOverlay = isEditing || (isImageLoading && canRevert);
    const loadingMessages = useMemo(() => ([
        'Preparing frame...',
        'Building edit plan...',
        'Rendering details...',
        'Applying finish...',
    ]), []);
    useEffect(() => {
        if (!showLoadingOverlay) {
            setLoadingElapsedSec(0);
            setLoadingPhaseIndex(0);
            return;
        }

        const tick = setInterval(() => {
            setLoadingElapsedSec(prev => prev + 1);
        }, 1000);

        const rotate = setInterval(() => {
            setLoadingPhaseIndex(prev => (prev + 1) % loadingMessages.length);
        }, 2400);

        return () => {
            clearInterval(tick);
            clearInterval(rotate);
        };
    }, [showLoadingOverlay, loadingMessages]);
    const isRateLimited = !!editError && !isEditing && (
        (typeof editRateLimitSeconds === 'number' && editRateLimitSeconds > 0) ||
        /too many requests|rate limit|slow down/i.test(editError)
    );

    // Animation Values
    const processingScale = useSharedValue(1);

    const processingScaleStyle = useAnimatedStyle(() => ({
        transform: [{ scale: processingScale.value }]
    }));

    useEffect(() => {
        if (showLoadingOverlay) {
            processingScale.value = withRepeat(
                withTiming(1.05, { duration: 8000, easing: Easing.inOut(Easing.ease) }),
                -1,
                true
            );
        } else {
            processingScale.value = withTiming(1, { duration: 500 });
        }
    }, [showLoadingOverlay]);

    const [shouldRevert, setShouldRevert] = useState(false);
    useEffect(() => {
        // ... (existing logic)
    }, [showLoadingOverlay]);

    // Simplified scaling logic
    const parentScale = useSharedValue(1);

    useEffect(() => {
        parentScale.value = withTiming(showShareModal ? 0.94 : 1);
    }, [showShareModal]);

    useEffect(() => {
        if (!isRateLimited) {
            setRateLimitCountdown(0);
            return;
        }
        setRateLimitCountdown(editRateLimitSeconds && editRateLimitSeconds > 0 ? editRateLimitSeconds : 60);
    }, [isRateLimited, editRateLimitSeconds]);

    useEffect(() => {
        if (!isRateLimited || rateLimitCountdown <= 0) return;
        const timer = setInterval(() => {
            setRateLimitCountdown(prev => (prev > 0 ? prev - 1 : 0));
        }, 1000);
        return () => clearInterval(timer);
    }, [isRateLimited, rateLimitCountdown]);

    useEffect(() => {
        limitSheetProgress.value = withTiming(isRateLimited ? 1 : 0, {
            duration: 340,
            easing: Easing.out(Easing.cubic),
        });
    }, [isRateLimited]);

    const rateLimitBackdropStyle = useAnimatedStyle(() => ({
        opacity: interpolate(limitSheetProgress.value, [0, 1], [0, 1]),
    }));

    const rateLimitSheetStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: interpolate(limitSheetProgress.value, [0, 1], [300, 0]) }],
        opacity: interpolate(limitSheetProgress.value, [0, 1], [0, 1]),
    }));

    const animatedParentStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: parentScale.value },
            { translateY: keyboardHeight.value * 0.12 * shouldShiftContent.value }
        ],
        borderRadius: 32,
        overflow: 'hidden',
        flex: 1,
        backgroundColor: colors.bg.primary
    }));

    const handleSelectEffect = (effect: Effect) => {
        setSelectedEffect(effect);
        Haptics.selectionAsync();
    };


    const handleDiscard = () => {

        Alert.alert(
            "Discard Edits?",
            "Are you sure you want to discard your story? This cannot be undone.",
            [
                { text: "Cancel", style: "cancel" },
                { text: "Discard", style: "destructive", onPress: onDiscard }
            ]
        );
    };

    const handleNext = () => {

        setShowShareModal(true);
    };

    const handleShareOption = (options: any) => {
        setShowShareModal(false);
        onPost({
            effect: selectedEffect.id,
            audience: options.audience,
            allowScreenshots: options.allowScreenshots,
            postToProfile: options.postToProfile,
            duration: options.duration,
            visibleTo: options.includedUsers,
            hiddenFrom: options.excludedUsers
        });
    };

    const handleAIEditSubmit = (prompt: string) => {
        setLastPrompt(prompt);
        // Explicitly dismiss keyboard to ensure the input collapses
        Keyboard.dismiss();
        onAIEdit(prompt);
    };

    const handleDownload = async () => {
        try {
            const { status } = await MediaLibrary.requestPermissionsAsync();
            if (status !== 'granted') {
                Alert.alert("Permission needed", "Please allow access to save photos.");
                return;
            }
            await MediaLibrary.saveToLibraryAsync(media.uri);
            Alert.alert("Saved", "Story saved to your gallery!");
        } catch (err) {
            Alert.alert("Error", "Failed to save media.");
        }
    };

    const handleAddText = () => {
        // Immediate edit mode
        const newId = Math.random().toString(36).substr(2, 9);
        const newText: TextOverlay = {
            id: newId,
            text: "",
            x: SCREEN_WIDTH / 2 - 50,
            y: SCREEN_HEIGHT / 4, // Start at bottom area
            color: '#FFFFFF',
            scale: 1,
            fontSize: 30,
            alignment: 'center',
            textStyle: 'none'
        };
        setTextOverlays(prev => [...prev, newText]);
        setActiveTextId(newId);

        // Setup editor
        setEditingText("");
        setEditorColor('#FFFFFF');
        setEditorFontSize(30);
        setEditorFont(undefined);
        setEditorAlign('center');
        setEditorStyle('none');
        setIsTextEditing(true);
    };

    const handleUpdateText = (id: string, updates: Partial<TextOverlay>) => {
        setTextOverlays(prev => prev.map(t => t.id === id ? { ...t, ...updates } : t));
    };

    const handleDeleteText = (id: string) => {
        setTextOverlays(prev => prev.filter(t => t.id !== id));
        if (activeTextId === id) {
            setActiveTextId(null);
            setIsTextEditing(false);
        }
    };

    const startEditing = (item: TextOverlay) => {
        setEditingText(item.text);
        setEditorColor(item.color);
        setEditorFontSize(item.fontSize || 30);
        setEditorFont(item.font);
        setEditorAlign(item.alignment || 'center');
        setEditorStyle(item.textStyle || 'none');
        setIsTextEditing(true);
    };

    const handleTextEditSubmit = () => {
        if (activeTextId) {
            if (!editingText.trim()) {
                handleDeleteText(activeTextId);
            } else {
                handleUpdateText(activeTextId, {
                    text: editingText,
                    color: editorColor,
                    fontSize: editorFontSize,
                    font: editorFont,
                    alignment: editorAlign,
                    textStyle: editorStyle
                });
            }
        }
        setIsTextEditing(false);
        setActiveTextId(null);
        Keyboard.dismiss();
    };

    const toggleAlign = () => {
        const aligns: ('left' | 'center' | 'right')[] = ['left', 'center', 'right'];
        const next = aligns[(aligns.indexOf(editorAlign) + 1) % 3];
        setEditorAlign(next);
    };

    const toggleFont = () => {
        // Simple cycler
        const currentIdx = FONTS.findIndex(f => f.family === editorFont);
        const next = FONTS[(currentIdx + 1) % FONTS.length];
        setEditorFont(next.family);
    };

    const toggleStyle = () => {
        // Force type cast to avoid strict literal checks during development
        const currentIdx = (TEXT_STYLES as readonly string[]).indexOf(editorStyle);
        const next = TEXT_STYLES[(currentIdx + 1) % TEXT_STYLES.length];
        setEditorStyle(next);
    };


    return (
        <View style={[styles.container, { backgroundColor: colors.bg.primary }]}>
            <Animated.View style={[animatedParentStyle, fakeViewStyle]}>
                <View style={styles.contentWrapper}>
                    {/* Media Card - Tap to dismiss keyboard */}
                    <TouchableWithoutFeedback onPress={() => {
                        Keyboard.dismiss();
                        setActiveTextId(null);
                    }}>
                        <View style={[styles.cardWrapper, { borderColor: colors.border.default }]}>
                            <View style={styles.imageContainer}>
                                <Animated.View
                                    key={media.uri}
                                    entering={FadeIn.duration(300)}
                                    style={[StyleSheet.absoluteFill, processingScaleStyle]}
                                >
                                    {media.type === 'image' ? (
                                        <Image
                                            source={{ uri: media.uri }}
                                            style={[styles.fullMedia, media.mirrored && { transform: [{ scaleX: 1 }] }]}
                                            resizeMode="cover"
                                            onLoadEnd={() => setIsImageLoading(false)}
                                        />
                                    ) : (
                                        <View
                                            style={[styles.fullMedia, { backgroundColor: colors.bg.card, justifyContent: 'center', alignItems: 'center' }]}
                                            onLayout={() => setIsImageLoading(false)}
                                        >
                                            <Text style={{ color: colors.text.primary }}>Video Preview</Text>
                                        </View>
                                    )}


                                    {/* Text Overlays */}
                                    {textOverlays.map(item => (
                                        <DraggableText
                                            key={item.id}
                                            item={item}
                                            onUpdate={handleUpdateText}
                                            onDelete={handleDeleteText}
                                            isSelected={activeTextId === item.id && !isTextEditing}
                                            onSelect={() => !isTextEditing && setActiveTextId(item.id)}
                                            onEdit={() => startEditing(item)}
                                        />
                                    ))}
                                </Animated.View>

                                {/* Processing Overlay */}
                                {showLoadingOverlay && (
                                    <Animated.View
                                        entering={FadeIn.duration(500)}
                                        exiting={FadeOut.duration(500)}
                                        style={[StyleSheet.absoluteFill, styles.processingOverlay]}
                                    >
                                        <View style={StyleSheet.absoluteFill} pointerEvents="none">
                                            <StoryInputBackground
                                                width={SCREEN_WIDTH}
                                                height={SCREEN_HEIGHT}
                                                glowColor="rgba(94, 177, 178, 0.4)"
                                                cyanColor="rgba(6, 182, 212, 0.4)"
                                            />
                                        </View>
                                        <SafeLiquidGlass
                                            style={{ flex: 1, width: '100%', height: '100%' }}
                                            blurIntensity={40}
                                            colorScheme="dark"
                                            tint="dark"
                                            tintColor="rgba(10, 10, 10, 0.45)"
                                        >
                                            <View style={styles.processingContent}>
                                                <ShimmerText messages={loadingMessages} />
                                                <Text style={styles.processingSubtext}>
                                                    {loadingMessages[loadingPhaseIndex]} {loadingElapsedSec}s
                                                </Text>

                                                {/* Thin Progress Bar with Shimmer */}
                                                <View style={styles.progressBarContainer}>
                                                    <Animated.View style={[styles.progressBarFill, animatedProgressStyle]} />
                                                </View>
                                            </View>
                                        </SafeLiquidGlass>
                                    </Animated.View>
                                )}

                                {/* Error Overlay */}
                                {editError && !isEditing && !isRateLimited && (
                                    <Animated.View
                                        entering={FadeIn.duration(300)}
                                        style={[StyleSheet.absoluteFill, styles.processingOverlay]}
                                    >
                                        <SafeLiquidGlass
                                            style={StyleSheet.absoluteFill}
                                            blurIntensity={60}
                                            colorScheme="dark"
                                            tint="dark"
                                            tintColor="rgba(50, 0, 0, 0.4)"
                                        >
                                            <View style={styles.processingContent}>
                                                <TriangleAlert size={48} color={colors.status.error} style={{ marginBottom: 16 }} />
                                                <Text style={[styles.shimmerText, { color: colors.status.error, textAlign: 'center', fontSize: 20 }]}>
                                                    {editError}
                                                </Text>

                                                <View style={styles.errorActions}>
                                                    <TouchableOpacity onPress={onClearError} style={styles.cancelBtn}>
                                                        <Text style={styles.cancelBtnText}>Cancel</Text>
                                                    </TouchableOpacity>

                                                    <TouchableOpacity onPress={() => onAIEdit(lastPrompt)} style={styles.retryBtn}>
                                                        <RefreshCcw size={18} color={colors.bg.primary} style={{ marginRight: 8 }} />
                                                        <Text style={styles.retryBtnText}>Try Again</Text>
                                                    </TouchableOpacity>
                                                </View>
                                            </View>
                                        </SafeLiquidGlass>
                                    </Animated.View>
                                )}

                                {isRateLimited && (
                                    <Modal visible transparent animationType="none" statusBarTranslucent>
                                        <View style={styles.rateLimitRoot}>
                                            <Animated.View style={[styles.rateLimitBackdrop, rateLimitBackdropStyle]}>
                                                <BlurView style={StyleSheet.absoluteFill} intensity={44} tint="dark" />
                                                <View style={styles.rateLimitBackdropTint} />
                                            </Animated.View>

                                            <Animated.View style={[styles.rateLimitSheet, rateLimitSheetStyle]}>
                                                <View style={styles.rateLimitSheetBg}>
                                                    <RateLimitBlurCard imageUri={media.uri} />
                                                </View>
                                                <View style={styles.rateLimitSheetContent}>
                                                    <TriangleAlert size={30} color="#f59e0b" />
                                                    <Text style={styles.rateLimitTitle}>Image edit limit reached</Text>
                                                    <Text style={styles.rateLimitBody}>
                                                        Try again in {Math.max(rateLimitCountdown, 0)}s.
                                                    </Text>
                                                    <TouchableOpacity
                                                        style={styles.rateLimitDismissBtn}
                                                        onPress={onClearError}
                                                        activeOpacity={0.9}
                                                    >
                                                        <Text style={styles.rateLimitDismissText}>OK</Text>
                                                    </TouchableOpacity>
                                                </View>
                                            </Animated.View>
                                        </View>
                                    </Modal>
                                )}
                            </View>

                            {/* Top Controls Overlay - Hide when editing text */}
                            {!isTextEditing && (
                                <Animated.View entering={FadeIn} exiting={FadeOut} style={styles.topBar}>
                                    <TouchableOpacity onPress={handleDiscard} style={styles.closeBtn}>
                                        <View style={[styles.closeIconCircle, { backgroundColor: 'rgba(20, 20, 25, 0.75)' }]}>
                                            <X size={24} color="#E8E6F0" />
                                        </View>
                                    </TouchableOpacity>

                                    <View style={[styles.topRightActions, { backgroundColor: 'rgba(20, 20, 25, 0.75)' }]}>
                                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                                            {/* Revert Button - Only show if we can revert and not loading */}
                                            {canRevert && !showLoadingOverlay && (
                                                <TouchableOpacity onPress={onRevert} style={styles.topIcon}>
                                                    <RotateCcw size={22} color="#E8E6F0" />
                                                </TouchableOpacity>
                                            )}

                                            <TouchableOpacity onPress={handleDownload} style={styles.topIcon}><Download size={22} color="#E8E6F0" /></TouchableOpacity>
                                            <TouchableOpacity onPress={handleAddText} style={styles.topIcon}><Type size={22} color="#E8E6F0" /></TouchableOpacity>
                                            <TouchableOpacity style={styles.topIcon}><Smile size={22} color="#E8E6F0" /></TouchableOpacity>
                                            <TouchableOpacity style={styles.topIcon}><Music size={22} color="#E8E6F0" /></TouchableOpacity>
                                            <TouchableOpacity onPress={onSettings} style={styles.settingTextBtn}>
                                                <Settings size={22} color="#E8E6F0" />
                                            </TouchableOpacity>
                                        </View>
                                    </View>
                                </Animated.View>
                            )}
                        </View>
                    </TouchableWithoutFeedback>

                    {/* Effects Row */}
                    {showEffects && (
                        <Animated.View entering={FadeIn} style={styles.effectsWrapper}>
                            <StoryEffects
                                selectedEffectId={selectedEffect.id}
                                onSelectEffect={handleSelectEffect}
                            />
                        </Animated.View>
                    )}
                </View>
            </Animated.View>

            {/* Full Screen Text Editor Overlay - NO BLUR */}
            {isTextEditing && (
                <Animated.View
                    entering={FadeIn}
                    exiting={FadeOut}
                    style={[styles.textInputOverlay, { top: 0, backgroundColor: 'rgba(0,0,0,0.3)' }]}
                    pointerEvents="box-none"
                >

                    {/* Header: Cancel / Done */}
                    <View style={styles.editorHeader}>
                        <TouchableOpacity onPress={() => handleDeleteText(activeTextId!)} style={styles.headerBtn}>
                            <Text style={styles.headerBtnText}>Cancel</Text>
                        </TouchableOpacity>
                        <TouchableOpacity onPress={handleTextEditSubmit} style={styles.headerBtn}>
                            <Text style={[styles.headerBtnText,]}>Done</Text>
                        </TouchableOpacity>
                    </View>

                    {/* Text Input Container - Centered but keyboard aware */}
                    <Animated.View style={[{ flex: 1, justifyContent: 'center', width: '100%' }, textInputContainerStyle]}>
                        <AnimatedTextInput
                            style={[
                                styles.hiddenInput,
                                {
                                    fontSize: 40, // Base size for scaling
                                    color: (editorStyle === 'neon') ? '#fff' : editorColor, // Allow color for stroke/outline
                                    fontFamily: editorFont,
                                    textAlign: editorAlign,
                                    alignSelf: 'center', // Fix: Center to allow background to wrap text
                                    minWidth: 100,
                                    ...getTextStyle(editorStyle, editorColor)
                                },
                                animatedFontSizeStyle
                            ]}
                            value={editingText}
                            onChangeText={setEditingText}
                            multiline
                            autoFocus

                            placeholderTextColor="rgba(255,255,255,0.4)"
                        />
                    </Animated.View>

                    {/* Modern Vertical Slider on Left */}
                    <View style={styles.sliderContainer}>
                        <GestureDetector gesture={Gesture.Pan()
                            .onBegin((e) => {
                                'worklet';
                                sliderVisibility.value = 1;
                                fontSizeShared.value = interpolate(e.y, [0, 240], [100, 10], 'clamp');
                            })
                            .onUpdate((e: any) => {
                                'worklet';
                                sliderVisibility.value = 1;
                                // 1:1 finger tracking on the 240px track
                                fontSizeShared.value = interpolate(e.y, [0, 240], [100, 10], 'clamp');
                            })
                            .onEnd(() => {
                                'worklet';
                                runOnJS(setEditorFontSize)(fontSizeShared.value);
                                // Hide after 3s inactivity
                                sliderVisibility.value = withDelay(3000, withTiming(0, { duration: 600 }));
                            })
                        }>
                            {/* Hit Area (Fixed) */}
                            <Animated.View style={{ width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center' }}>
                                {/* Visuals (Animated) */}
                                <Animated.View style={[sliderAnimatedStyle, { width: 40, height: 240, alignItems: 'center', justifyContent: 'center' }]}>
                                    <Svg width={40} height={240} viewBox="0 0 40 240" style={styles.sliderTrackSvg}>
                                        <Path
                                            d="M3,0 L37,0 L21,240 L19,240 Z"
                                            fill="rgba(255,255,255,0.25)"
                                        />
                                    </Svg>
                                    <Animated.View style={[styles.sliderHandle, animatedSliderHandleStyle, { position: 'absolute' }]} />
                                </Animated.View>
                            </Animated.View>
                        </GestureDetector>
                    </View>

                    {/* Bottom Controls - Sticky above keyboard */}
                    <Animated.View style={[stickyBottomStyle, { width: '100%', paddingHorizontal: 20, paddingBottom: 20 }]}>

                        <View style={styles.editorBottomBar}>
                            {/* Left Side: Controls - Ordered: Colors - Font Style - Text Align */}
                            <View style={{ flexDirection: 'row', gap: 10, alignItems: 'center' }}>

                                {/* 1. Colors */}
                                <TouchableOpacity
                                    onPress={() => setShowColorPicker(!showColorPicker)}
                                    style={styles.colorPillBtn}
                                    activeOpacity={0.7}
                                >
                                    <LinearGradient
                                        colors={['#FF0000', '#FF7F00', '#FFFF00', '#00FF00', '#0000FF', '#4B0082', '#8B00FF']}
                                        start={{ x: 0, y: 0 }}
                                        end={{ x: 1, y: 1 }}
                                        style={styles.gradientRing}
                                    >
                                        <View style={[styles.colorInnerCircle, { backgroundColor: editorColor }]} />
                                    </LinearGradient>
                                </TouchableOpacity>

                                {/* 2. Font Style (Effects Toggle) */}
                                <TouchableOpacity onPress={toggleStyle} style={styles.editorIconBtn}>
                                    <View style={[
                                        styles.styleIconInner,
                                        (editorStyle === 'background' || editorStyle === 'background-glass') && {
                                            backgroundColor: editorStyle === 'background' ? editorColor : withAlpha(editorColor, 0.55),
                                            borderColor: editorStyle === 'background' ? '#fff' : 'rgba(255,255,255,0.5)'
                                        },
                                        editorStyle === 'neon' && { borderColor: editorColor, backgroundColor: 'rgba(0,0,0,0.3)' },
                                        (editorStyle === 'outline' || editorStyle === 'stroke') && { borderColor: editorColor, backgroundColor: 'transparent' }
                                    ]}>
                                        <Text style={[
                                            styles.styleIconText,
                                            {
                                                color: (editorStyle === 'background' || editorStyle === 'background-glass') ? (editorColor === '#FFFFFF' ? '#000' : '#fff') : '#fff',
                                                textShadowColor: editorStyle === 'neon' ? editorColor : 'transparent',
                                                textShadowRadius: editorStyle === 'neon' ? 5 : 0
                                            }
                                        ]}>A</Text>
                                    </View>
                                </TouchableOpacity>

                                {/* 3. Alignment */}
                                <TouchableOpacity onPress={toggleAlign} style={styles.editorIconBtn}>
                                    {editorAlign === 'left' && <AlignLeft size={20} color="#fff" />}
                                    {editorAlign === 'center' && <AlignCenter size={20} color="#fff" />}
                                    {editorAlign === 'right' && <AlignRight size={20} color="#fff" />}
                                </TouchableOpacity>

                            </View>

                            {/* Right Side: Font Menu */}
                            <GlassFontMenu
                                fonts={FONTS}
                                selectedFont={editorFont}
                                onSelect={setEditorFont}
                            />
                        </View>

                        {/* Color Picker Scroll (Moved Below Bar with Height Animation) */}
                        <Animated.View style={colorPickerAnimatedStyle}>
                            <ScrollView
                                horizontal
                                showsHorizontalScrollIndicator={false}
                                keyboardShouldPersistTaps="always"
                                contentContainerStyle={{ gap: 10, paddingHorizontal: 4, alignItems: 'center' }}
                            >
                                {COLORS.map((color, index) => (
                                    <TouchableOpacity
                                        key={`${color}-${index}`}
                                        onPress={() => setEditorColor(color)}
                                        style={{
                                            width: 34,
                                            height: 34,
                                            borderRadius: 17,
                                            backgroundColor: color,
                                            borderWidth: 0.5,
                                            borderColor: editorColor === color ? '#fff' : 'rgba(255,255,255,0.2)'
                                        }}
                                    />
                                ))}
                            </ScrollView>
                        </Animated.View>

                    </Animated.View>
                </Animated.View>
            )}

            {/* Story Input - Hide when editing or selecting a text overlay */}
            {/* Story Input - Hide when editing or selecting a text overlay */}
            <KeyboardStickyView
                offset={{ closed: -25, opened: -5 }}
                style={{
                    position: 'absolute',
                    bottom: 0,
                    left: 0,
                    right: 0,
                    zIndex: 100,
                }}
                pointerEvents={(isTextEditing || activeTextId) ? 'none' : 'auto'}
            >
                <View style={{ transform: [{ translateY: (isTextEditing || activeTextId) ? SCREEN_HEIGHT : 0 }] }}>
                    <StoryInput
                        onSend={handleAIEditSubmit}
                        onNext={handleNext}
                        isEditing={isEditing}
                        placeholder="Ask AI to edit..."
                        keyboardProgress={keyboardProgress}
                    />
                </View>
            </KeyboardStickyView>

            <ShareModal
                visible={showShareModal}
                onClose={() => setShowShareModal(false)}
                onPost={handleShareOption}
                onSaveDraft={onSaveDraft}
                parentScale={parentScale}
            />

            {/* Full Screen Text Editor Overlay - NO BLUR */}


        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    contentWrapper: {
        flex: 1,
    },
    cardWrapper: {
        height: SCREEN_HEIGHT * 0.85,
        marginTop: Platform.OS === 'ios' ? 50 : 40,
        marginBottom: 10,
        marginHorizontal: 0,
        borderRadius: 32,
        overflow: 'hidden',
        borderWidth: 1,
    },
    imageContainer: {
        flex: 1,
    },
    fullMedia: {
        width: '100%',
        height: '100%',
    },
    topBar: {
        position: 'absolute',
        top: 20,
        left: 0,
        right: 0,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 10,
        width: '100%',
        zIndex: 10,
    },
    closeBtn: {
        padding: 0,
    },
    closeIconCircle: {
        width: 44,
        height: 44,
        borderRadius: 22,
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative'

    },
    topRightActions: {
        paddingVertical: 4,
        paddingHorizontal: 12,
        borderRadius: 24,

    },
    topIcon: {
        padding: 8,
    },
    settingTextBtn: {
        paddingHorizontal: 8,
    },
    effectsWrapper: {
        marginBottom: 16,
        paddingHorizontal: 20,
    },
    processingOverlay: {
        zIndex: 5,
        width: '100%',
        height: '100%',
        alignItems: 'stretch',
    },
    processingContent: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
        // Make full width/height to support relative positioning inside
        width: '100%',
        height: '100%',
    },
    bottomRightPercentage: {
        position: 'absolute',
        bottom: 30,
        right: 30,
    },
    percentageSmall: {
        color: colors.accent.DEFAULT,
        fontSize: 16,
        fontWeight: 'bold',
        opacity: 0.8,
        letterSpacing: 1,
    },
    shimmerText: {
        color: colors.text.primary,
        fontSize: 24,
        fontWeight: '600',
        letterSpacing: 0.5,
        textShadowColor: 'rgba(255,255,255,0.35)',
        textShadowOffset: { width: 0, height: 0 },
        textShadowRadius: 10,
    },
    processingSubtext: {
        marginTop: 8,
        color: 'rgba(228, 241, 255, 0.84)',
        fontSize: 14,
        letterSpacing: 0.2,
    },
    errorActions: {
        flexDirection: 'row',
        marginTop: 30,
        gap: 12,
        alignItems: 'center'
    },
    retryBtn: {
        flexDirection: 'row',
        backgroundColor: colors.accent.DEFAULT,
        paddingVertical: 12,
        paddingHorizontal: 20,
        borderRadius: 24,
        alignItems: 'center',
    },
    retryBtnText: {
        color: colors.bg.primary,
        fontWeight: 'bold',
        fontSize: 16
    },
    cancelBtn: {
        paddingVertical: 12,
        paddingHorizontal: 20,
        borderRadius: 24,
        backgroundColor: 'rgba(255,255,255,0.1)',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.2)'
    },
    cancelBtnText: {
        color: colors.text.primary,
        fontSize: 16
    },
    overlayText: {
        fontSize: 24,
        fontWeight: 'bold',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 1 },
        shadowOpacity: 0.5,
        shadowRadius: 2,
        elevation: 2
    },
    contextMenu: {
        position: 'absolute',
        top: -40,
        left: '50%',
        marginLeft: -40,
        width: 80,
        flexDirection: 'row',
        backgroundColor: 'rgba(255,255,255,0.9)',
        borderRadius: 20,
        padding: 4,
        justifyContent: 'space-between',
        shadowColor: '#000',
        elevation: 5
    },
    contextBtn: {
        width: 34,
        height: 34,
        borderRadius: 17,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: '#fff'
    },
    progressBarContainer: {
        width: 200,
        height: 4,
        backgroundColor: 'rgba(255,255,255,0.2)',
        borderRadius: 2,
        marginTop: 16,
        overflow: 'hidden'
    },
    progressBarFill: {
        height: '100%',
        backgroundColor: colors.accent.DEFAULT,
        borderRadius: 2
    },
    rateLimitRoot: {
        flex: 1,
        justifyContent: 'flex-end',
    },
    rateLimitBackdrop: {
        ...StyleSheet.absoluteFillObject,
    },
    rateLimitBackdropTint: {
        ...StyleSheet.absoluteFillObject,
        backgroundColor: 'rgba(7, 10, 16, 0.42)',
    },
    rateLimitSheet: {
        marginHorizontal: 16,
        marginBottom: 20,
        borderRadius: 28,
        overflow: 'hidden',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.2)',
        minHeight: 238,
    },
    rateLimitSheetBg: {
        ...StyleSheet.absoluteFillObject,
    },
    rateLimitSheetContent: {
        minHeight: 238,
        paddingHorizontal: 22,
        paddingVertical: 24,
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
    },
    rateLimitTitle: {
        color: '#F4F7FF',
        fontSize: 22,
        fontWeight: '700',
        textAlign: 'center',
    },
    rateLimitBody: {
        color: 'rgba(233, 242, 255, 0.86)',
        fontSize: 15,
        textAlign: 'center',
        marginTop: 4,
    },
    rateLimitDismissBtn: {
        marginTop: 14,
        paddingHorizontal: 24,
        paddingVertical: 11,
        borderRadius: 20,
        backgroundColor: 'rgba(255,255,255,0.14)',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.2)',
    },
    rateLimitDismissText: {
        color: '#FFFFFF',
        fontWeight: '700',
        fontSize: 15,
    },
    textInputOverlay: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        zIndex: 200,
        justifyContent: 'space-between', // Space out Top and Bottom
        paddingBottom: Platform.OS === 'ios' ? 0 : 0
    },
    editorHeader: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        paddingTop: Platform.OS === 'ios' ? 70 : 40,
        width: '100%'
    },
    headerBtn: {
        padding: 8,
    },
    headerBtnText: {
        color: '#fff',
        fontSize: 16,
        fontWeight: 400
    },
    editorBottomBar: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingVertical: 8,
        backgroundColor: 'transparent',
        width: '100%',
    },
    editorTopBar: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        paddingHorizontal: 30,
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        zIndex: 210
    },
    editorControlsLeft: {
        flexDirection: 'row',
        gap: 0
    },
    editorIconBtn: {
        width: 40,
        height: 40,
        borderRadius: 20,
        alignItems: 'center',
        justifyContent: 'center',

    },
    doneBtn: {
        backgroundColor: '#fff',
        paddingVertical: 8,
        paddingHorizontal: 16,
        borderRadius: 20
    },
    doneBtnText: {
        color: '#000',
        fontWeight: 300,
        fontSize: 14
    },
    hiddenInput: {
        fontSize: 32,
        fontWeight: 'bold',
        minWidth: 100,
        maxWidth: '95%',
        padding: 10,
        textAlign: 'center'
    },
    // New Styles
    fontBtn: {
        paddingHorizontal: 12,
        paddingVertical: 6,
        backgroundColor: 'rgba(0,0,0,0.5)',
        borderRadius: 16,
        marginRight: 8,
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.2)'
    },
    fontBtnActive: {
        backgroundColor: '#fff',
        borderColor: '#fff'
    },
    fontBtnText: {
        color: '#fff',
        fontSize: 14
    },
    sliderContainer: {
        position: 'absolute',
        left: -10,
        top: '25%',
        height: 240,
        width: 60,
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 300,
    },
    sliderTrackSvg: {
        position: 'absolute',
        height: 240,
        width: 40,
        zIndex: -1,
        opacity: 0.8
    },
    sliderHandle: {
        width: 35,
        height: 35,
        borderRadius: '50%',
        backgroundColor: '#fff',

    },

    colorPreview: {
        width: 28,
        height: 28,
        borderRadius: 14,
        borderWidth: 2,
        borderColor: '#fff',
        alignItems: 'center',
        justifyContent: 'center'
    },
    modalOverlay: {
        flex: 1,
        justifyContent: 'flex-end',
        backgroundColor: 'transparent' // No dimming backdrop
    },
    colorPickerContainer: {
        backgroundColor: theme.dark.bg.card,
        borderTopLeftRadius: 24,
        borderTopRightRadius: 24,
        padding: 20,
        paddingBottom: 40,
        height: '50%', // 50% height
        shadowColor: '#000',
        shadowOffset: { width: 0, height: -2 },
        shadowOpacity: 0.3,
        shadowRadius: 10,
        elevation: 10
    },
    pickerHeader: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        marginBottom: 20
    },
    pickerTitle: {
        color: theme.dark.text.primary,
        fontSize: 18,
        fontWeight: 'bold'
    },
    // Premium Color Button
    colorPillBtn: {
        width: 32,
        height: 32,
        borderRadius: 16,
        justifyContent: 'center',
        alignItems: 'center',
    },
    gradientRing: {
        width: 30,
        height: 30,
        borderRadius: 15,
        padding: 1.5,
        justifyContent: 'center',
        alignItems: 'center',
    },
    colorInnerCircle: {
        width: 24,
        height: 24,
        borderRadius: 12,
        borderWidth: 1.5,
        borderColor: 'rgba(255,255,255,0.8)',
    },
    styleIconInner: {
        width: 30,
        height: 30,
        borderRadius: 6,
        borderWidth: 0.5,
        borderColor: '#fff',
        justifyContent: 'center',
        alignItems: 'center',
    },
    styleIconText: {
        fontSize: 16,
        fontWeight: '500',
    }
});
