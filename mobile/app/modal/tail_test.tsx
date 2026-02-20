import React from 'react';
import { View, Text, StyleSheet, ScrollView, TouchableOpacity, SafeAreaView } from 'react-native';
import { useRouter } from 'expo-router';
import { LinearGradient } from 'expo-linear-gradient';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../../src/lib/stores/wallpaper-store';
import { CheckIcon, DoubleCheckIcon } from '../../src/components/Icons';
import { MessageBubbleBody } from '../../src/components/chat/bubbles';
import { Message } from '../../src/lib/types';

export default function TailTestModal() {
    const router = useRouter();
    const { colors, effectiveTheme } = useThemeStore();

    const gradientColors = effectiveTheme === 'dark'
        ? ['#489090', '#3C8181'] as const
        : ['#5CB8B8', '#4CA3A3'] as const;

    const metaColorMe = 'rgba(255,255,255,0.7)';
    const metaColorThem = 'rgba(0,0,0,0.5)';

    const mockMessage: Message = {
        id: 'test-1',
        fromId: 'me',
        plaintext: 'This is the real component',
        encryptedContent: 'enc',
        timestamp: Date.now(),
        status: 'read',
        type: 'text'
    };

    const renderMeta = (isMe: boolean) => (
        <View style={styles.msgMetaCompact}>
            <Text style={[styles.msgTime, { color: isMe ? metaColorMe : metaColorThem }]}>
                13:42
            </Text>
            {isMe && (
                <View style={{ marginLeft: 3 }}>
                    <DoubleCheckIcon size={12} color={metaColorMe} strokeWidth={2.5} />
                </View>
            )}
        </View>
    );

    return (
        <SafeAreaView style={[styles.safeArea, { backgroundColor: colors.background }]}>
            <View style={styles.header}>
                <Text style={[styles.headerTitle, { color: colors.text }]}>Comparison: Test vs Real</Text>
                <TouchableOpacity onPress={() => router.back()} style={styles.closeBtn}>
                    <Text style={{ color: colors.primary, fontSize: 16 }}>Done</Text>
                </TouchableOpacity>
            </View>

            <ScrollView contentContainerStyle={styles.body}>
                <View style={styles.chat}>

                    <Text style={[styles.sectionTitle, { color: colors.text }]}>1. Hardcoded CSS Logic (Successful)</Text>
                    {/* Mine Group - Hardcoded */}
                    <View style={[styles.messagesGroup, styles.mineGroup]}>
                        <View style={[styles.message, styles.mineMessage, styles.last]}>
                            <LinearGradient
                                colors={gradientColors}
                                start={{ x: 0, y: 0 }}
                                end={{ x: 1, y: 1 }}
                                style={styles.gradientFill}
                            >
                                <View>
                                    <Text style={styles.mineText}>
                                        I am the clean test
                                        <Text style={{ color: 'transparent', fontSize: 10 }}>{"\u00A0\u00A0\u00A0\u00A0\u00A0\u00A0\u00A0\u00A0"}</Text>
                                    </Text>
                                    {renderMeta(true)}
                                </View>
                            </LinearGradient>

                            {/* Mine Tail - CSS Logic */}
                            <View style={[styles.mineTailBefore, { backgroundColor: gradientColors[1] }]} />
                            <View style={[styles.mineTailAfter, { backgroundColor: colors.background }]} />
                        </View>
                    </View>

                    <View style={{ height: 40 }} />

                    <Text style={[styles.sectionTitle, { color: colors.text }]}>2. Real Component (Problematic?)</Text>
                    <View style={[styles.messagesGroup, styles.mineGroup]}>
                        {(() => {
                            const { activeTheme } = useWallpaperStore();
                            const resolvedTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
                            const bubbleGradient = (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2 ? resolvedTheme.bubbleMeGradient : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string];

                            return (
                                <View style={{ alignItems: 'flex-end' }}>
                                    <LinearGradient
                                        colors={bubbleGradient}
                                        start={{ x: 0, y: 0 }}
                                        end={{ x: 1, y: 1 }}
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
                                                ...mockMessage,
                                                isMe: true,
                                                text: mockMessage.plaintext || '',
                                                timestamp: new Date(mockMessage.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                            } as any}
                                        />
                                    </LinearGradient>
                                </View>
                            );
                        })()}
                    </View>

                </View>
            </ScrollView>
        </SafeAreaView>
    );
}

const styles = StyleSheet.create({
    safeArea: {
        flex: 1,
    },
    header: {
        height: 60,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
        borderBottomWidth: 1,
        borderBottomColor: 'rgba(127,127,127,0.1)',
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '600',
    },
    sectionTitle: {
        fontSize: 14,
        fontWeight: 'bold',
        marginBottom: 10,
        opacity: 0.6,
    },
    closeBtn: {
        padding: 8,
    },
    body: {
        flex: 1,
        alignItems: 'center',
        paddingTop: 30,
    },
    chat: {
        width: 320,
        padding: 10,
    },
    messagesGroup: {
        marginTop: 10,
        width: '100%',
    },
    mineGroup: {
        alignItems: 'flex-end',
    },
    message: {
        borderRadius: 20,
        maxWidth: '75%',
        position: 'relative',
        overflow: 'visible',
    },
    mineMessage: {
        marginLeft: '25%',
    },
    gradientFill: {
        borderRadius: 20,
        paddingVertical: 8,
        paddingHorizontal: 15,
    },
    mineText: {
        color: '#FFF',
        fontSize: 16,
    },
    msgMetaCompact: {
        position: 'absolute',
        bottom: -2,
        right: -4,
        flexDirection: 'row',
        alignItems: 'center',
    },
    msgTime: {
        fontSize: 11,
    },
    mineTailBefore: {
        position: 'absolute',
        zIndex: 0,
        bottom: 0,
        right: -8,
        height: 20,
        width: 20,
        borderBottomLeftRadius: 15,
    },
    mineTailAfter: {
        position: 'absolute',
        zIndex: 1,
        bottom: 0,
        right: -10,
        width: 10,
        height: 20,
        borderBottomLeftRadius: 10,
    },
    last: {}
});
