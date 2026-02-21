import React, { useEffect, useState } from 'react';
import { View, Text, StyleSheet, Dimensions, TouchableOpacity, TextInput, ActivityIndicator, Keyboard, Modal, FlatList, Alert, TouchableWithoutFeedback } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    Easing,
    FadeIn,
    SharedValue
} from 'react-native-reanimated';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useChatStore } from '../../lib/ChatStore';
import { useAuthStore } from '../../lib/stores/auth-store';
import { apiClient } from '../../lib/api-client';
import { X, Search, Users, Check } from 'lucide-react-native';
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

interface NewGroupModalProps {
    visible: boolean;
    onClose: () => void;
    parentScale?: SharedValue<number>;
}

interface FoundUser {
    id?: string;
    userId?: string;
    username?: string;
    profileImage?: string;
    phoneNumber?: string;
}

const resolveFoundUserId = (user: Partial<FoundUser> | null | undefined): string => {
    const rawId = user?.userId ?? user?.id;
    return typeof rawId === 'string' ? rawId.trim() : String(rawId || '').trim();
};

const normalizeFoundUser = (value: any): FoundUser | null => {
    if (!value || typeof value !== 'object') return null;

    const resolvedId = resolveFoundUserId(value);
    if (!resolvedId) return null;

    const username = (typeof value.username === 'string' ? value.username.trim() : '') || resolvedId;
    return {
        ...value,
        id: resolvedId,
        userId: resolvedId,
        username,
    };
};

const normalizeFoundUsers = (value: any): FoundUser[] => {
    const source = Array.isArray(value) ? value : [value];
    const uniqueById = new Map<string, FoundUser>();

    source.forEach((entry) => {
        const normalized = normalizeFoundUser(entry);
        if (!normalized) return;
        const id = resolveFoundUserId(normalized);
        if (!id || uniqueById.has(id)) return;
        uniqueById.set(id, normalized);
    });

    return Array.from(uniqueById.values());
};

export default function NewGroupModal({ visible, onClose, parentScale }: NewGroupModalProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const { createGroup } = useChatStore();
    const { user } = useAuthStore();

    const [groupName, setGroupName] = useState('');
    const [searchQuery, setSearchQuery] = useState('');
    const [selectedMembers, setSelectedMembers] = useState<{ id: string; name: string }[]>([]);
    const [searchResults, setSearchResults] = useState<FoundUser[]>([]);
    const [isCreating, setIsCreating] = useState(false);
    const [isSearching, setIsSearching] = useState(false);

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
        setGroupName('');
        setSearchQuery('');
        setSelectedMembers([]);
        setSearchResults([]);
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

    // Search for users
    useEffect(() => {
        if (searchQuery.length < 2) {
            setSearchResults([]);
            return;
        }

        const timer = setTimeout(async () => {
            setIsSearching(true);
            try {
                const result = await apiClient.findUserByName(searchQuery);
                const currentUserId = (user?.userId || '').trim().toUpperCase();
                const normalizedResults = normalizeFoundUsers(result).filter(
                    (entry) => resolveFoundUserId(entry).toUpperCase() !== currentUserId
                );
                setSearchResults(normalizedResults);
            } catch (e) {
                setSearchResults([]);
            }
            setIsSearching(false);
        }, 300);

        return () => clearTimeout(timer);
    }, [searchQuery]);

    const toggleMember = (member: { id: string; name: string }) => {
        setSelectedMembers(prev => {
            const normalizedId = member.id.trim();
            if (!normalizedId) return prev;

            const nextMember = { ...member, id: normalizedId, name: member.name || normalizedId };
            const exists = prev.find(m => m.id === normalizedId);
            if (exists) return prev.filter(m => m.id !== normalizedId);
            return [...prev, nextMember];
        });
    };

    const handleCreate = async () => {
        if (!groupName.trim()) {
            Alert.alert('Error', 'Please enter a group name');
            return;
        }
        if (selectedMembers.length === 0) {
            Alert.alert('Error', 'Please add at least one member');
            return;
        }

        setIsCreating(true);
        const memberIds = Array.from(new Set(selectedMembers.map(m => m.id.trim()).filter(Boolean)));
        if (memberIds.length === 0) {
            setIsCreating(false);
            Alert.alert('Error', 'Please add at least one valid member');
            return;
        }

        const chatId = await createGroup(groupName.trim(), memberIds);
        setIsCreating(false);

        if (chatId) {
            handleCloseInternal();
        } else {
            Alert.alert('Error', 'Failed to create group');
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
                                <Text style={[styles.title, { color: colors.text }]}>New Group</Text>
                                <View style={styles.headerRight}>
                                    <TouchableOpacity
                                        onPress={handleCreate}
                                        disabled={isCreating || !groupName.trim() || selectedMembers.length === 0}
                                        style={[styles.createBtn, { opacity: groupName.trim() && selectedMembers.length > 0 ? 1 : 0.4 }]}
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
                                {/* Group Name Input */}
                                <SafeLiquidGlass
                                    style={[styles.inputWrapper, { borderColor: withAlpha(colors.text, 0.1) }]}
                                    blurIntensity={20}
                                >
                                    <View style={styles.innerInput}>
                                        <Users size={20} color={colors.primary} style={{ marginRight: 12, opacity: 0.6 }} />
                                        <TextInput
                                            style={[styles.input, { color: colors.text }]}
                                            placeholder="Group name"
                                            placeholderTextColor={colors.textSecondary}
                                            value={groupName}
                                            onChangeText={setGroupName}
                                            maxLength={50}
                                        />
                                    </View>
                                </SafeLiquidGlass>

                                {/* Selected Members */}
                                {selectedMembers.length > 0 && (
                                    <View style={styles.selectedRow}>
                                        {selectedMembers.map(m => (
                                            <TouchableOpacity
                                                key={m.id}
                                                onPress={() => toggleMember(m)}
                                                style={[styles.chip, { backgroundColor: withAlpha(colors.primary, 0.15) }]}
                                            >
                                                <Text style={[styles.chipText, { color: colors.primary }]}>{m.name}</Text>
                                                <X size={14} color={colors.primary} style={{ marginLeft: 4 }} />
                                            </TouchableOpacity>
                                        ))}
                                    </View>
                                )}

                                {/* Search Members */}
                                <SafeLiquidGlass
                                    style={[styles.inputWrapper, { borderColor: withAlpha(colors.text, 0.1), marginTop: 16 }]}
                                    blurIntensity={20}
                                >
                                    <View style={styles.innerInput}>
                                        <Search size={20} color={colors.primary} style={{ marginRight: 12, opacity: 0.6 }} />
                                        <TextInput
                                            style={[styles.input, { color: colors.text }]}
                                            placeholder="Search by username..."
                                            placeholderTextColor={colors.textSecondary}
                                            value={searchQuery}
                                            onChangeText={setSearchQuery}
                                        />
                                        {isSearching && <ActivityIndicator size="small" color={colors.primary} />}
                                    </View>
                                </SafeLiquidGlass>

                                {/* Search Results */}
                                <FlatList
                                    data={searchResults}
                                    keyExtractor={(item, index) => {
                                        const id = resolveFoundUserId(item);
                                        return id ? `search-user-${id}` : `search-user-fallback-${index}`;
                                    }}
                                    style={{ marginTop: 16, maxHeight: 300 }}
                                    renderItem={({ item }) => {
                                        const memberId = resolveFoundUserId(item);
                                        const isSelected = selectedMembers.some(m => m.id === memberId);
                                        return (
                                            <TouchableOpacity
                                                onPress={() => toggleMember({ id: memberId, name: item.username || memberId })}
                                                style={[styles.userRow, { backgroundColor: isSelected ? withAlpha(colors.primary, 0.1) : 'transparent' }]}
                                            >
                                                <View style={[styles.avatar, { backgroundColor: withAlpha(colors.primary, 0.2) }]}>
                                                    <Text style={{ color: colors.primary, fontWeight: '600' }}>
                                                        {(item.username || '?')[0].toUpperCase()}
                                                    </Text>
                                                </View>
                                                <Text style={[styles.userName, { color: colors.text }]}>{item.username}</Text>
                                                {isSelected && <Check size={20} color={colors.primary} />}
                                            </TouchableOpacity>
                                        );
                                    }}
                                />
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
        flex: 1,
    },
    inputWrapper: {
        height: 56,
        borderRadius: 20,
        borderWidth: 1,
        overflow: 'hidden',
        backgroundColor: 'rgba(150,150,150,0.05)'
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
    selectedRow: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 8,
        marginTop: 16
    },
    chip: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingVertical: 6,
        borderRadius: 20
    },
    chipText: {
        fontSize: 14,
        fontWeight: '500'
    },
    userRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        paddingHorizontal: 8,
        borderRadius: 12
    },
    avatar: {
        width: 40,
        height: 40,
        borderRadius: 20,
        justifyContent: 'center',
        alignItems: 'center',
        marginRight: 12
    },
    userName: {
        fontSize: 16,
        fontWeight: '500',
        flex: 1
    }
});
