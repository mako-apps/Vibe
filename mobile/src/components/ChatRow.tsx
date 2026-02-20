
import React from 'react';
import { View, Text, StyleSheet, Image, TouchableOpacity } from 'react-native';
import Animated, { FadeInDown } from 'react-native-reanimated';
import { Pin, VolumeX, Check, CheckCheck } from 'lucide-react-native';
import { Chat } from '../lib/types';
import * as Haptics from 'expo-haptics';

interface ChatRowProps {
    chat: Chat;
    onPress: () => void;
    currentUserId: string;
    index: number;
}

export function ChatRow({ chat, onPress, currentUserId, index }: ChatRowProps) {
    const lastMsg = chat.lastMessage || chat.messages[chat.messages.length - 1];

    // Format Time (Simple helper)
    const formatTime = (ts: number) => {
        if (!ts) return '';
        const d = new Date(ts);
        const now = new Date();
        const diff = now.getTime() - ts;
        if (diff < 24 * 60 * 60 * 1000 && d.getDate() === now.getDate()) {
            return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        }
        return d.toLocaleDateString();
    };

    const handlePress = () => {
        // Light haptic on press (optional, maybe standard click is enough)
        onPress();
    };

    const handleLongPress = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        // context menu logic would go here
    };

    return (
        <Animated.View entering={FadeInDown.delay(index * 50).duration(400)}>
            <TouchableOpacity
                style={styles.container}
                onPress={handlePress}
                onLongPress={handleLongPress}
                delayLongPress={400}
                activeOpacity={0.7}
            >
                {/* Avatar */}
                <View style={styles.avatarContainer}>
                    {chat.friendImage ? (
                        <Image source={{ uri: chat.friendImage }} style={styles.avatar} />
                    ) : (
                        <View style={styles.avatarPlaceholder}>
                            <Text style={styles.avatarText}>{chat.friendName[0]?.toUpperCase()}</Text>
                        </View>
                    )}
                    {/* Online status could go here */}
                </View>

                {/* Content */}
                <View style={styles.content}>
                    <View style={styles.header}>
                        <Text style={styles.name} numberOfLines={1}>{chat.friendName}</Text>
                        <View style={styles.metaRow}>
                            {chat.pinned && <Pin size={12} color="#888" style={styles.icon} />}
                            {chat.muted && <VolumeX size={12} color="#888" style={styles.icon} />}
                            <Text style={styles.time}>{formatTime(lastMsg?.timestamp)}</Text>
                        </View>
                    </View>

                    <View style={styles.subHeader}>
                        <Text style={styles.preview} numberOfLines={1}>
                            {lastMsg ? (
                                lastMsg.type === 'text' ? (lastMsg.plaintext || lastMsg.encryptedContent || 'Message') :
                                    lastMsg.type === 'image' ? '📷 Photo' :
                                        lastMsg.type === 'voice' ? '🎤 Voice Message' : 'Message'
                            ) : 'No messages'}
                        </Text>

                        {/* Status / Badge */}
                        <View style={styles.statusContainer}>
                            {lastMsg?.fromId === currentUserId && (
                                <View style={styles.ticks}>
                                    {lastMsg.status === 'read' ? (
                                        <CheckCheck size={16} color="#4ade80" />
                                    ) : (
                                        <Check size={16} color="#888" />
                                    )}
                                </View>
                            )}
                            {chat.unreadCount ? (
                                <View style={styles.badge}>
                                    <Text style={styles.badgeText}>{chat.unreadCount}</Text>
                                </View>
                            ) : null}
                        </View>
                    </View>
                </View>
            </TouchableOpacity>
        </Animated.View>
    );
}

const styles = StyleSheet.create({
    container: {
        flexDirection: 'row',
        padding: 16,
        alignItems: 'center',
        backgroundColor: '#000', // Matches clean modern dark
    },
    avatarContainer: {
        position: 'relative',
        marginRight: 16,
    },
    avatar: {
        width: 56,
        height: 56,
        borderRadius: 28,
        backgroundColor: '#222',
    },
    avatarPlaceholder: {
        width: 56,
        height: 56,
        borderRadius: 28,
        backgroundColor: '#222',
        alignItems: 'center',
        justifyContent: 'center',
    },
    avatarText: {
        color: '#fff',
        fontSize: 20,
        fontWeight: '600',
    },
    content: {
        flex: 1,
        justifyContent: 'center',
    },
    header: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        marginBottom: 4,
    },
    name: {
        color: '#fff',
        fontSize: 17,
        fontWeight: '600',
        flex: 1,
        marginRight: 8,
    },
    metaRow: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    time: {
        color: '#666',
        fontSize: 13,
        marginLeft: 4,
    },
    icon: {
        marginRight: 4,
    },
    subHeader: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
    },
    preview: {
        color: '#888',
        fontSize: 15,
        flex: 1,
        marginRight: 16,
    },
    statusContainer: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    ticks: {
        marginRight: 4,
    },
    badge: {
        backgroundColor: '#3b82f6', // Accent color
        minWidth: 20,
        height: 20,
        borderRadius: 10,
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: 6,
    },
    badgeText: {
        color: '#fff',
        fontSize: 12,
        fontWeight: '700',
    },
});
