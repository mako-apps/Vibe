import React, { useState, useCallback } from 'react';
import { View, Text, TouchableOpacity, StyleSheet, Dimensions } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as Haptics from 'expo-haptics';
import MessageContextMenu from '../../src/components/chat/MessageContextMenu';
import { MessageBubbleBody } from '../../src/components/chat/bubbles';
import { useWallpaperStore, resolveThemeVariant } from '../../src/lib/stores/wallpaper-store';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { LinearGradient } from 'expo-linear-gradient';
import { Message } from '../../src/lib/types';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

type Position = { x: number; y: number; width: number; height: number };

export default function Playground() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const [menuVisible, setMenuVisible] = useState(false);
    const [bubblePos, setBubblePos] = useState<Position | null>(null);
    const [msgType, setMsgType] = useState<'text' | 'emoji'>('text');
    const [reactions, setReactions] = useState<string[]>([]);

    // Mock Message Item
    const mockItem: Message = {
        id: 'playground-msg-1',
        fromId: 'me',
        plaintext: msgType === 'emoji' ? '🔥' : 'Check out the new snappy context menu! Works with all message types.',
        encryptedContent: 'encrypted',
        timestamp: Date.now(),
        type: 'text',
        status: 'read',
        extra: { reactions }
    };

    const handleReaction = useCallback((emoji: string) => {
        setReactions([emoji]); // For playground, just show one
    }, []);

    const handleLongPress = useCallback((ref: React.RefObject<View>) => {
        if (!ref.current) return;
        ref.current.measureInWindow((x: number, y: number, w: number, h: number) => {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
            setBubblePos({ x, y, width: w, height: h });
            setMenuVisible(true);
        });
    }, []);

    return (
        <View style={[styles.container, { paddingTop: insets.top }]}>
            <Stack.Screen options={{ headerShown: false }} />

            <View style={styles.header}>
                <TouchableOpacity onPress={() => router.back()} style={{ padding: 16 }}>
                    <Text style={{ color: 'white', fontSize: 18 }}>← Back</Text>
                </TouchableOpacity>
                <TouchableOpacity
                    onPress={() => setMsgType(t => t === 'text' ? 'emoji' : 'text')}
                    style={styles.toggleBtn}
                >
                    <Text style={{ color: 'white' }}>Switch to {msgType === 'text' ? 'Emoji' : 'Text'}</Text>
                </TouchableOpacity>
            </View>

            <View style={{ flex: 1, padding: 20 }}>
                <Text style={{ color: '#aaa', fontSize: 14, textAlign: 'center', marginBottom: 40 }}>
                    Testing production "MessageBubble" + "MessageContextMenu".
                </Text>

                <View style={{ flex: 1, justifyContent: 'flex-end', paddingBottom: 150 }}>
                    {(() => {
                        const resolvedTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
                        const bubbleTheme = {
                            meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
                                ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
                                : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
                        };

                        return (
                            <View style={{ alignItems: 'flex-end' }}>
                                <LinearGradient
                                    colors={bubbleTheme.meGradient}
                                    style={{
                                        padding: 8,
                                        paddingHorizontal: 12,
                                        borderRadius: 18,
                                        maxWidth: '85%',
                                        borderBottomRightRadius: 4
                                    }}
                                >
                                    <MessageBubbleBody
                                        item={{
                                            ...mockItem,
                                            isMe: true,
                                            text: mockItem.plaintext || '',
                                            timestamp: new Date(mockItem.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                        } as any}
                                    />
                                </LinearGradient>
                            </View>
                        );
                    })()}
                </View>
            </View>

            <MessageContextMenu
                visible={menuVisible}
                position={bubblePos}
                onClose={() => setMenuVisible(false)}
                isMe={true}
                messageText={mockItem.plaintext}
                item={mockItem}
                colors={colors}
                displayContent={mockItem.plaintext}
                onReaction={handleReaction}
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: '#000' },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingRight: 16
    },
    toggleBtn: {
        backgroundColor: 'rgba(255,255,255,0.1)',
        paddingHorizontal: 16,
        paddingVertical: 8,
        borderRadius: 20
    }
});
