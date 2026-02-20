import React, { useEffect, useState } from 'react';
import { View, Text, StyleSheet, Dimensions, TouchableOpacity, TextInput, ActivityIndicator, Keyboard, Modal, Alert, TouchableWithoutFeedback } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    Easing,
    SharedValue
} from 'react-native-reanimated';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useChatStore } from '../../lib/ChatStore';
import { X, Megaphone, Check } from 'lucide-react-native';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import AnimatedGlassButton from '../native/AnimatedGlassButton';

const { height: SCREEN_HEIGHT } = Dimensions.get('window');
const MODAL_HEIGHT = SCREEN_HEIGHT * 0.94;
const CLOSED_Y = SCREEN_HEIGHT;

const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) };

const AnimatedView = Animated.View;

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color;
};

interface NewChannelModalProps {
    visible: boolean;
    onClose: () => void;
    parentScale?: SharedValue<number>;
}

export default function NewChannelModal({ visible, onClose, parentScale }: NewChannelModalProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const { createChannel } = useChatStore();

    const [channelName, setChannelName] = useState('');
    const [description, setDescription] = useState('');
    const [isCreating, setIsCreating] = useState(false);

    const isLight = effectiveTheme === 'light';
    const bgColor = isLight ? '#f5f5f5' : colors.background;

    const [showModal, setShowModal] = useState(false);

    const translateY = useSharedValue(CLOSED_Y);
    const backdrop = useSharedValue(0);
    const startY = useSharedValue(0);
    const closeButtonProgress = useSharedValue(0);

    useEffect(() => {
        if (visible) {
            setShowModal(true);
            requestAnimationFrame(() => {
                translateY.value = withTiming(0, { duration: 350, easing: Easing.out(Easing.exp) });
                backdrop.value = withTiming(1, { duration: 300 });
                if (parentScale) {
                    parentScale.value = withTiming(0.94, SMOOTH_TIMING);
                }
            });
        } else {
            translateY.value = withTiming(CLOSED_Y, { duration: 250 }, (finished) => {
                if (finished) {
                    runOnJS(setShowModal)(false);
                    runOnJS(resetState)();
                }
            });
            backdrop.value = withTiming(0, { duration: 250 });
            if (parentScale) {
                parentScale.value = withTiming(1, SMOOTH_TIMING);
            }
        }
    }, [visible]);

    const resetState = () => {
        setChannelName('');
        setDescription('');
    };

    const handleCloseInternal = () => {
        Keyboard.dismiss();
        backdrop.value = withTiming(0, { duration: 250 });
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
            runOnJS(onClose)();
        });
        if (parentScale) {
            parentScale.value = withTiming(1, SMOOTH_TIMING);
        }
    };

    const handleCreate = async () => {
        if (!channelName.trim()) {
            Alert.alert('Error', 'Please enter a channel name');
            return;
        }

        setIsCreating(true);
        const chatId = await createChannel(channelName.trim(), description.trim() || undefined);
        setIsCreating(false);

        if (chatId) {
            handleCloseInternal();
        } else {
            Alert.alert('Error', 'Failed to create channel');
        }
    };

    const gesture = Gesture.Pan()
        .onBegin(() => {
            startY.value = translateY.value;
        })
        .onUpdate((e) => {
            const nextY = startY.value + e.translationY;
            translateY.value = Math.max(0, nextY);
        })
        .onEnd((e) => {
            if (translateY.value > SCREEN_HEIGHT * 0.2 || e.velocityY > 1000) {
                runOnJS(handleCloseInternal)();
            } else {
                translateY.value = withTiming(0, { duration: 250 });
            }
        });

    const sheetStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
    }));

    const backdropStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
    }));

    if (!showModal) return null;

    return (
        <Modal transparent visible={visible} animationType="none" onRequestClose={handleCloseInternal} statusBarTranslucent>
            <GestureHandlerRootView style={{ flex: 1, zIndex: 9999 }}>
                <AnimatedView style={[styles.backdrop, backdropStyle]}>
                    <TouchableWithoutFeedback onPress={handleCloseInternal}>
                        <View style={StyleSheet.absoluteFill} />
                    </TouchableWithoutFeedback>
                </AnimatedView>

                <GestureDetector gesture={gesture}>
                    <AnimatedView style={[styles.panelWrapper, sheetStyle]}>
                        <SafeLiquidGlass
                            style={[styles.glassPanel, { backgroundColor: bgColor }]}
                            blurIntensity={40}
                            tint={isLight ? 'light' : 'dark'}
                            interactive={false}
                        >
                            <View style={styles.handleContainer}>
                                <View style={[styles.handle, { backgroundColor: withAlpha(colors.text, 0.15) }]} />
                            </View>

                            <View style={styles.header}>
                                <Text style={[styles.title, { color: colors.text }]}>New Channel</Text>
                                <View style={styles.headerRight}>
                                    <TouchableOpacity
                                        onPress={handleCreate}
                                        disabled={isCreating || !channelName.trim()}
                                        style={[styles.createBtn, { opacity: channelName.trim() ? 1 : 0.4 }]}
                                    >
                                        {isCreating ? (
                                            <ActivityIndicator size="small" color={colors.primary} />
                                        ) : (
                                            <Check size={24} color={colors.primary} />
                                        )}
                                    </TouchableOpacity>
                                    <AnimatedGlassButton
                                        onPress={handleCloseInternal}
                                        progress={closeButtonProgress}
                                        showPanelIcon={false}
                                        effectiveTheme={effectiveTheme}
                                        size={36}
                                        homeIcon={<X size={20} color={colors.text} strokeWidth={2} />}
                                        panelIcon={<View />}
                                        homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                                    />
                                </View>
                            </View>

                            <View style={styles.contentContainer}>
                                {/* Channel Icon */}
                                <View style={[styles.iconContainer, { backgroundColor: withAlpha('#f59e0b', 0.15) }]}>
                                    <Megaphone size={48} color="#f59e0b" />
                                </View>
                                <Text style={[styles.subtitle, { color: colors.textSecondary }]}>
                                    Channels are for broadcasting messages to subscribers. Only you can post.
                                </Text>

                                {/* Channel Name Input */}
                                <Text style={[styles.label, { color: colors.textSecondary }]}>Channel Name</Text>
                                <SafeLiquidGlass
                                    style={[styles.inputWrapper, { borderColor: withAlpha(colors.text, 0.1) }]}
                                    blurIntensity={20}
                                >
                                    <View style={styles.innerInput}>
                                        <TextInput
                                            style={[styles.input, { color: colors.text }]}
                                            placeholder="e.g. Daily Updates"
                                            placeholderTextColor={colors.textSecondary}
                                            value={channelName}
                                            onChangeText={setChannelName}
                                            maxLength={50}
                                        />
                                    </View>
                                </SafeLiquidGlass>

                                {/* Description Input */}
                                <Text style={[styles.label, { color: colors.textSecondary, marginTop: 20 }]}>Description (optional)</Text>
                                <SafeLiquidGlass
                                    style={[styles.inputWrapper, styles.multilineWrapper, { borderColor: withAlpha(colors.text, 0.1) }]}
                                    blurIntensity={20}
                                >
                                    <TextInput
                                        style={[styles.input, styles.multilineInput, { color: colors.text }]}
                                        placeholder="What's this channel about?"
                                        placeholderTextColor={colors.textSecondary}
                                        value={description}
                                        onChangeText={setDescription}
                                        multiline
                                        maxLength={200}
                                        numberOfLines={3}
                                    />
                                </SafeLiquidGlass>
                            </View>
                        </SafeLiquidGlass>
                    </AnimatedView>
                </GestureDetector>
            </GestureHandlerRootView>
        </Modal>
    );
}

const styles = StyleSheet.create({
    backdrop: {
        ...StyleSheet.absoluteFillObject,
        backgroundColor: 'rgba(0,0,0,0.3)',
    },
    panelWrapper: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        justifyContent: 'flex-end',
    },
    glassPanel: {
        width: '100%',
        height: MODAL_HEIGHT,
        borderTopLeftRadius: 24,
        borderTopRightRadius: 24,
        overflow: 'hidden',
    },
    handleContainer: {
        width: '100%',
        alignItems: 'center',
        paddingTop: 16,
        paddingBottom: 8,
    },
    handle: {
        width: 40,
        height: 5,
        borderRadius: 3,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        marginTop: 10,
        marginBottom: 30,
        paddingHorizontal: 24
    },
    headerRight: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12
    },
    title: {
        fontSize: 20,
        fontWeight: '700',
        letterSpacing: 0.5,
    },
    createBtn: {
        padding: 8,
    },
    contentContainer: {
        paddingHorizontal: 24,
    },
    iconContainer: {
        width: 80,
        height: 80,
        borderRadius: 40,
        justifyContent: 'center',
        alignItems: 'center',
        alignSelf: 'center',
        marginBottom: 16
    },
    subtitle: {
        fontSize: 14,
        textAlign: 'center',
        lineHeight: 20,
        marginBottom: 24
    },
    label: {
        fontSize: 13,
        fontWeight: '600',
        marginBottom: 8,
        textTransform: 'uppercase',
        letterSpacing: 0.5
    },
    inputWrapper: {
        height: 56,
        borderRadius: 20,
        borderWidth: 1,
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.05)'
    },
    multilineWrapper: {
        height: 100,
    },
    innerInput: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16
    },
    input: {
        flex: 1,
        fontSize: 16,
        fontWeight: '500',
        height: '100%'
    },
    multilineInput: {
        paddingTop: 14,
        textAlignVertical: 'top'
    }
});
