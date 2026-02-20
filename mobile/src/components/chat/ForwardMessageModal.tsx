import React, { useState, useMemo } from 'react';
import { View, Text, StyleSheet, Modal, FlatList, TouchableOpacity, Image, TextInput, Pressable, Dimensions } from 'react-native';
import { BlurView } from 'expo-blur';
import { X, Search, Send, Check } from 'lucide-react-native';
import Animated, { FadeIn, FadeInDown, ZoomIn } from 'react-native-reanimated';
import { useChatStore } from '../../lib/ChatStore';
import { useThemeStore } from '../../lib/stores/theme-store';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

interface ForwardMessageModalProps {
    visible: boolean;
    onClose: () => void;
    onSend: (chatIds: string[]) => void;
}

const ForwardMessageModal = ({ visible, onClose, onSend }: ForwardMessageModalProps) => {
    const { chats } = useChatStore(); // Assuming chats are loaded
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const [searchQuery, setSearchQuery] = useState('');
    const [selectedChatIds, setSelectedChatIds] = useState<Set<string>>(new Set());

    const filteredChats = useMemo(() => {
        if (!searchQuery) return chats;
        const lower = searchQuery.toLowerCase();
        return chats.filter(c =>
            (c.friendName?.toLowerCase().includes(lower)) ||
            (c.friendId?.toLowerCase().includes(lower))
        );
    }, [chats, searchQuery]);

    const toggleSelection = (chatId: string) => {
        setSelectedChatIds(prev => {
            const next = new Set(prev);
            if (next.has(chatId)) next.delete(chatId);
            else next.add(chatId);
            return next;
        });
    };

    const handleSend = () => {
        onSend(Array.from(selectedChatIds));
        setSelectedChatIds(new Set());
        onClose();
    };

    const getSelectedImages = () => {
        return Array.from(selectedChatIds).map(id => {
            const chat = chats.find(c => c.chatId === id);
            return chat?.friendImage || null;
        });
    };

    const renderItem = ({ item }: { item: any }) => {
        const isSelected = selectedChatIds.has(item.chatId);
        const name = item.friendName || item.friendId || 'Unknown';

        return (
            <TouchableOpacity
                activeOpacity={0.7}
                onPress={() => toggleSelection(item.chatId)}
                style={[
                    styles.chatRow,
                    { borderBottomColor: `rgba(127,127,127,0.1)` }
                ]}
            >
                <View style={[styles.avatarContainer, { borderColor: isSelected ? colors.primary : 'transparent', borderWidth: 2 }]}>
                    {item.friendImage ? (
                        <Image source={{ uri: item.friendImage }} style={styles.avatar} />
                    ) : (
                        <View style={[styles.avatarPlaceholder, { backgroundColor: 'rgba(127,127,127,0.2)' }]}>
                            <Text style={[styles.avatarText, { color: colors.text }]}>{name.substring(0, 1).toUpperCase()}</Text>
                        </View>
                    )}
                    {isSelected && (
                        <View style={[styles.checkBadge, { backgroundColor: colors.primary }]}>
                            <Check size={10} color="#fff" strokeWidth={3} />
                        </View>
                    )}
                </View>

                <View style={styles.chatInfo}>
                    <Text style={[styles.chatName, { color: colors.text }]} numberOfLines={1}>{name}</Text>
                    <Text style={[styles.chatSub, { color: colors.textSecondary }]}>
                        {isSelected ? 'Selected' : (item.lastMessage?.text || 'Mobile')}
                    </Text>
                </View>

                <View style={[styles.radioCircle, { borderColor: isSelected ? colors.primary : 'rgba(127,127,127,0.3)', backgroundColor: isSelected ? colors.primary : 'transparent' }]}>
                    {isSelected && <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: '#fff' }} />}
                </View>
            </TouchableOpacity>
        );
    };

    if (!visible) return null;

    return (
        <Modal visible={visible} animationType="slide" transparent presentationStyle="pageSheet" onRequestClose={onClose}>
            <View style={[styles.container, { backgroundColor: effectiveTheme === 'dark' ? '#1c1c1c' : '#ffffff' }]}>

                {/* Header */}
                <View style={[styles.header, { paddingTop: 16 }]}>
                    <Text style={[styles.title, { color: colors.text }]}>Forward to...</Text>
                    <TouchableOpacity onPress={onClose} style={styles.closeBtn}>
                        <View style={{ backgroundColor: 'rgba(127,127,127,0.2)', padding: 6, borderRadius: 20 }}>
                            <X size={20} color={colors.text} />
                        </View>
                    </TouchableOpacity>
                </View>

                {/* Search */}
                <View style={styles.searchContainer}>
                    <View style={[styles.searchBar, { backgroundColor: 'rgba(127,127,127,0.1)' }]}>
                        <Search size={18} color={colors.textSecondary} />
                        <TextInput
                            placeholder="Search"
                            placeholderTextColor={colors.textSecondary}
                            style={[styles.searchInput, { color: colors.text }]}
                            value={searchQuery}
                            onChangeText={setSearchQuery}
                        />
                    </View>
                </View>

                {/* List */}
                <FlatList
                    data={filteredChats}
                    renderItem={renderItem}
                    keyExtractor={item => item.chatId}
                    contentContainerStyle={{ paddingBottom: 100 }}
                    style={{ flex: 1 }}
                />

                {/* Footer / Send Button */}
                {selectedChatIds.size > 0 && (
                    <Animated.View entering={FadeInDown.duration(200)} style={[styles.footer, { paddingBottom: insets.bottom + 10, backgroundColor: colors.background }]}>
                        <BlurView intensity={20} style={StyleSheet.absoluteFill} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} />
                        <View style={styles.footerContent}>
                            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                {getSelectedImages().slice(0, 3).map((img, idx) => (
                                    <Animated.View key={idx} entering={ZoomIn.delay(idx * 50)} style={[styles.selectedAvatarSmall, { marginLeft: idx > 0 ? -10 : 0, zIndex: 3 - idx }]}>
                                        {img ? (
                                            <Image source={{ uri: img }} style={styles.selectedAvatarImg} />
                                        ) : (
                                            <View style={[styles.selectedAvatarImg, { backgroundColor: 'gray' }]} />
                                        )}
                                    </Animated.View>
                                ))}
                                <Text style={{ color: colors.text, marginLeft: 10, fontWeight: '600' }}>
                                    {selectedChatIds.size} selected
                                </Text>
                            </View>

                            <TouchableOpacity onPress={handleSend} style={[styles.sendButton, { backgroundColor: colors.primary }]}>
                                <Send size={20} color="#fff" style={{ marginRight: 4 }} />
                                <Text style={{ color: '#fff', fontWeight: 'bold' }}>Send</Text>
                            </TouchableOpacity>
                        </View>
                    </Animated.View>
                )}
            </View>
        </Modal>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 16,
        paddingHorizontal: 20,
        borderBottomWidth: 0.5,
        borderBottomColor: 'rgba(127,127,127,0.1)'
    },
    title: {
        fontSize: 18,
        fontWeight: 'bold',
    },
    closeBtn: {
        position: 'absolute',
        right: 16,
        top: 14 // Align with title
    },
    searchContainer: {
        padding: 12,
        paddingBottom: 8
    },
    searchBar: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        height: 40,
        borderRadius: 12,
    },
    searchInput: {
        flex: 1,
        marginLeft: 8,
        fontSize: 16
    },
    chatRow: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 12,
        paddingHorizontal: 16,
        borderBottomWidth: 0.5,
    },
    avatarContainer: {
        width: 50,
        height: 50,
        borderRadius: 25,
        marginRight: 12,
        position: 'relative',
        padding: 2
    },
    avatar: {
        width: '100%',
        height: '100%',
        borderRadius: 25,
    },
    avatarPlaceholder: {
        width: '100%',
        height: '100%',
        borderRadius: 25,
        alignItems: 'center',
        justifyContent: 'center'
    },
    avatarText: {
        fontSize: 18,
        fontWeight: '600'
    },
    checkBadge: {
        position: 'absolute',
        bottom: 0,
        right: 0,
        width: 16,
        height: 16,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 1.5,
        borderColor: '#fff'
    },
    chatInfo: {
        flex: 1,
    },
    chatName: {
        fontSize: 16,
        fontWeight: '600',
        marginBottom: 2
    },
    chatSub: {
        fontSize: 13,
    },
    radioCircle: {
        width: 22,
        height: 22,
        borderRadius: 11,
        borderWidth: 2,
        alignItems: 'center',
        justifyContent: 'center'
    },
    footer: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        overflow: 'hidden'
    },
    footerContent: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        paddingVertical: 12
    },
    selectedAvatarSmall: {
        width: 30,
        height: 30,
        borderRadius: 15,
        borderWidth: 2,
        borderColor: '#fff',
        overflow: 'hidden'
    },
    selectedAvatarImg: {
        width: '100%',
        height: '100%'
    },
    sendButton: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 10,
        paddingHorizontal: 20,
        borderRadius: 25
    }
});

export default ForwardMessageModal;
