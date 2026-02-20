import React, { useMemo, useEffect } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Modal, Pressable, Dimensions } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Animated, {
    useSharedValue,
    withTiming,
    withSpring,
    Easing,
    useAnimatedStyle,
    runOnJS,
    interpolate,
    Extrapolation,
} from 'react-native-reanimated';
import {
    Copy,
    Sticker,
    Languages,
    MousePointerSquareDashed,
    MoreHorizontal,
} from 'lucide-react-native';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { BlurView } from 'expo-blur';
import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';
import { Message } from '../../lib/types';
import { MessageBubbleBody } from './bubbles';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../lib/stores/theme-store';
import { LinearGradient } from 'expo-linear-gradient';
import ReactionPicker from './ReactionPicker';
import ReactionEffect from './ReactionEffect';

interface MessageContextMenuProps {
    visible: boolean;
    onClose: () => void;
    position: { x: number; y: number; width: number; height: number } | null;
    isMe: boolean;
    messageText?: string;
    onReply?: () => void;
    onDelete?: () => void;
    onEdit?: () => void;
    onSelect?: () => void;
    onForward?: () => void;
    colors: any;
    displayContent?: string;
    item?: Message;
    isSequenceStart?: boolean;
    isSequenceEnd?: boolean;
    isMiddle?: boolean;
    onReaction?: (emoji: string) => void;
    // Generic extensions
    customContent?: React.ReactNode;
    menuOptions?: Array<{
        label?: string;
        icon?: any;
        onPress?: () => void;
        destructive?: boolean;
        separator?: boolean;
    }>;
    hideReactions?: boolean;
}

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

export default function MessageContextMenu({
    visible,
    onClose,
    position,
    isMe,
    messageText,
    onReply,
    onDelete,
    onEdit,
    onSelect,
    onForward,
    colors,
    displayContent,
    item,
    isSequenceStart = true,
    isSequenceEnd = true,
    isMiddle = false,
    onReaction,
    customContent,
    menuOptions,
    hideReactions = false
}: MessageContextMenuProps) {
    const insets = useSafeAreaInsets();
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();

    const resolvedTheme = useMemo(() => {
        return resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
    }, [activeTheme, effectiveTheme]);

    const bubbleTheme = useMemo(() => ({
        meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
            ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
            : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
        themGradient: (resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length >= 2
            ? [resolvedTheme.bubbleThemGradient[0], resolvedTheme.bubbleThemGradient[1]]
            : [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem]) as [string, string],
    }), [resolvedTheme]);

    // Animation values
    const anim = useSharedValue(0); // 0 to 1
    const reactionScale = useSharedValue(0);
    const dismissEnabled = useSharedValue(0);
    const [selectedEmoji, setSelectedEmoji] = React.useState<string | null>(null);

    // Layout calculation
    const layout = useMemo(() => {
        if (!position) return null;

        const menuHeight = menuOptions
            ? menuOptions.reduce((acc, opt) => acc + (opt.separator ? 15 : 54), 20)
            : 280;
        const reactionHeight = hideReactions ? 0 : 110;
        const spacing = 12;
        const topPadding = insets?.top ? insets.top + 20 : 60;
        const bottomPadding = insets?.bottom ? insets.bottom + 20 : 60;

        const bubbleTop = position.y;
        const bubbleBottom = position.y + position.height;

        const preferBelowTop = bubbleBottom + spacing;
        const maxMenuTop = SCREEN_HEIGHT - bottomPadding - menuHeight;
        const minMenuTop = topPadding;
        const menuTop = Math.max(minMenuTop, Math.min(preferBelowTop, maxMenuTop));

        const preferReactionTop = bubbleTop - reactionHeight - spacing;
        const maxReactionTop = SCREEN_HEIGHT - bottomPadding - reactionHeight;
        const minReactionTop = topPadding;
        const reactionTop = Math.max(minReactionTop, Math.min(preferReactionTop, maxReactionTop));

        // Menu horizontal
        const menuWidth = 250;
        let menuLeft = isMe ? (position.x + position.width - menuWidth) : position.x;
        const sideMargin = 16;
        if (menuLeft < sideMargin) menuLeft = sideMargin;
        if (menuLeft + menuWidth > SCREEN_WIDTH - sideMargin) {
            menuLeft = SCREEN_WIDTH - menuWidth - sideMargin;
        }

        // Reaction horizontal
        const pickerWidth = 310;
        let reactionLeft = position.x + (position.width / 2) - (pickerWidth / 2);
        if (reactionLeft < 8) reactionLeft = 8;
        if (reactionLeft + pickerWidth > SCREEN_WIDTH - 8) {
            reactionLeft = SCREEN_WIDTH - pickerWidth - 8;
        }

        // Keep bubble visually attached above the menu with ~5px spacing.
        // If there is overlap, this becomes a negative offset and lifts bubble out.
        const bubbleTranslateTarget = Math.min(0, (menuTop - 5) - bubbleBottom);

        return { menuLeft, reactionLeft, reactionTop, menuTop, bubbleTranslateTarget };
    }, [position, isMe, insets, menuOptions, hideReactions]);

    useEffect(() => {
        if (visible && layout) {
            dismissEnabled.value = 0;
            anim.value = withSpring(1, {
                damping: 18,
                stiffness: 180,
                mass: 0.9,
            });
            reactionScale.value = 0;
            setSelectedEmoji(null);

            const timer = setTimeout(() => {
                dismissEnabled.value = 1;
            }, 150);
            return () => clearTimeout(timer);
        }
    }, [visible, layout, anim, reactionScale, dismissEnabled]);

    const handleClose = () => {
        dismissEnabled.value = 0;
        anim.value = withTiming(0, {
            duration: 170,
            easing: Easing.out(Easing.quad)
        }, (finished) => {
            if (finished) {
                runOnJS(onClose)();
            }
        });
    };

    const handleReactionSelect = (emoji: string) => {
        setSelectedEmoji(emoji);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        reactionScale.value = withSpring(1, { damping: 10, stiffness: 100 });

        if (onReaction) onReaction(emoji);

        // Wait and close
        setTimeout(() => {
            handleClose();
        }, 1200); // 1.2s to see animation
    };

    const bubbleAnimatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: (layout?.bubbleTranslateTarget || 0) * anim.value },
            { scale: 1 }
        ]
    }), [layout?.bubbleTranslateTarget]);

    const menuAnimatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: (1 - anim.value) * 18 },
            { scale: 0.94 + anim.value * 0.06 }
        ],
        top: layout?.menuTop || 0,
    }));

    const menuContentAnimatedStyle = useAnimatedStyle(() => ({
        opacity: interpolate(anim.value, [0, 0.42, 1], [0, 0.35, 1], Extrapolation.CLAMP),
        transform: [{ translateY: (1 - anim.value) * 6 }],
    }));

    const reactionAnimatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: (1 - anim.value) * -14 },
            { scale: 0.9 + anim.value * 0.1 }
        ],
        top: layout?.reactionTop || 0
    }));

    const backdropTintAnimatedStyle = useAnimatedStyle(() => ({
        opacity: interpolate(anim.value, [0, 1], [0, 1], Extrapolation.CLAMP),
    }));

    if (!visible || !position || !layout || (!item && !customContent)) return null;

    const handleCopy = async () => {
        if (messageText) {
            await Clipboard.setStringAsync(messageText);
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            handleClose();
        }
    };

    return (
        <Modal visible={visible} transparent animationType="none" onRequestClose={handleClose}>
            <View style={styles.overlay}>
                <View style={StyleSheet.absoluteFillObject} pointerEvents="none">
                    <BlurView intensity={28} tint="dark" style={StyleSheet.absoluteFillObject} />
                    <Animated.View style={[styles.backdropTint, backdropTintAnimatedStyle]} />
                </View>
                <Pressable
                    style={StyleSheet.absoluteFillObject}
                    onPress={() => {
                        if (dismissEnabled.value > 0.5) handleClose();
                    }}
                />

                {/* Reactions */}
                {!hideReactions && (
                    <Animated.View
                        style={[
                            { position: 'absolute', left: layout.reactionLeft, zIndex: 1003 },
                            reactionAnimatedStyle
                        ]}
                    >
                        <ReactionPicker isMe={isMe} onSelect={handleReactionSelect} />
                    </Animated.View>
                )}

                {/* Bubble Clone */}
                <Animated.View
                    style={[
                        {
                            position: 'absolute',
                            top: position.y,
                            left: position.x,
                            width: position.width,
                            height: position.height,
                            zIndex: 1010,
                            alignItems: isMe ? 'flex-end' : 'flex-start',
                            overflow: 'visible',
                            opacity: 1,
                        },
                        bubbleAnimatedStyle
                    ]}
                >
                    {customContent ? (
                        customContent
                    ) : (
                        <LinearGradient
                            colors={isMe ? bubbleTheme.meGradient : bubbleTheme.themGradient}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 1 }}
                            style={{
                                padding: (item?.type === 'image' || item?.type === 'sticker') && !item?.plaintext ? 0 : 8,
                                paddingHorizontal: (item?.type === 'image' || item?.type === 'sticker') && !item?.plaintext ? 0 : 12,
                                borderRadius: 18,
                            }}
                        >
                            <MessageBubbleBody
                                item={{
                                    ...item!,
                                    isMe,
                                    text: item?.plaintext || '',
                                    timestamp: item?.timestamp ? new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }) : ''
                                } as any}
                            />
                        </LinearGradient>
                    )}

                    {!hideReactions && selectedEmoji && (
                        <ReactionEffect
                            emoji={selectedEmoji}
                            isMe={isMe}
                        />
                    )}
                </Animated.View>

                {/* Menu */}
                <Animated.View
                    style={[
                        styles.menuContainer,
                        {
                            left: layout.menuLeft,
                        },
                        menuAnimatedStyle
                    ]}
                >
                    <SafeLiquidGlass style={styles.glassContainer} blurIntensity={40} tint="dark">
                        <Animated.View style={menuContentAnimatedStyle}>
                            {menuOptions ? (
                                menuOptions.map((opt, i) => (
                                    opt.separator ? (
                                        <View key={`sep-${i}`} style={styles.menuSeparator} />
                                    ) : (
                                        <TouchableOpacity
                                            key={i}
                                            style={styles.menuItem}
                                            onPress={() => {
                                                handleClose();
                                                if (opt.onPress) {
                                                    setTimeout(() => opt.onPress && opt.onPress(), 50);
                                                }
                                            }}
                                        >
                                            <View style={styles.menuItemLeading}>
                                                {opt.icon ? React.cloneElement(opt.icon as any, { size: 21, color: opt.destructive ? '#FF453A' : '#fff' }) : null}
                                                <Text style={[styles.menuText, opt.destructive && { color: '#FF453A' }]}>{opt.label}</Text>
                                            </View>
                                        </TouchableOpacity>
                                    )
                                ))
                            ) : (
                                <>
                                    <TouchableOpacity style={styles.menuItem} onPress={handleClose}>
                                        <View style={styles.menuItemLeading}>
                                            <Sticker size={20} color="#fff" />
                                            <Text style={styles.menuText}>Attach Sticker</Text>
                                        </View>
                                    </TouchableOpacity>

                                    <TouchableOpacity style={styles.menuItem} onPress={handleCopy}>
                                        <View style={styles.menuItemLeading}>
                                            <Copy size={20} color="#fff" />
                                            <Text style={styles.menuText}>Copy</Text>
                                        </View>
                                    </TouchableOpacity>

                                    <TouchableOpacity style={styles.menuItem} onPress={handleClose}>
                                        <View style={styles.menuItemLeading}>
                                            <Languages size={20} color="#fff" />
                                            <Text style={styles.menuText}>Translate</Text>
                                        </View>
                                    </TouchableOpacity>

                                    <TouchableOpacity style={styles.menuItem} onPress={() => { handleClose(); if (onSelect) onSelect(); }}>
                                        <View style={styles.menuItemLeading}>
                                            <MousePointerSquareDashed size={20} color="#fff" />
                                            <Text style={styles.menuText}>Select</Text>
                                        </View>
                                    </TouchableOpacity>

                                    <TouchableOpacity style={[styles.menuItem, { borderBottomWidth: 0 }]} onPress={handleClose}>
                                        <View style={styles.menuItemLeading}>
                                            <MoreHorizontal size={20} color="#fff" />
                                            <Text style={styles.menuText}>More...</Text>
                                        </View>
                                    </TouchableOpacity>
                                </>
                            )}
                        </Animated.View>
                    </SafeLiquidGlass>
                </Animated.View>
            </View>
        </Modal>
    );
}

const styles = StyleSheet.create({
    overlay: {
        flex: 1,
    },
    backdropTint: {
        ...StyleSheet.absoluteFillObject,
        backgroundColor: 'rgba(0,0,0,0.2)',
    },
    menuContainer: {
        position: 'absolute',
        width: 250,
        borderRadius: 22,
        overflow: 'hidden',
        zIndex: 1004,
    },
    glassContainer: {
        paddingVertical: 5,
        borderRadius: 22,
        backgroundColor: 'transparent',
    },
    menuItem: {
        justifyContent: 'center',
        paddingVertical: 14,
        paddingHorizontal: 18,
    },
    menuItemLeading: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 14,
    },
    menuSeparator: {
        height: StyleSheet.hairlineWidth,
        marginHorizontal: 16,
        marginVertical: 7,
        backgroundColor: 'rgba(255,255,255,0.2)',
    },
    menuText: {
        fontSize: 17,
        fontWeight: '400',
        color: '#fff'
    }
});
