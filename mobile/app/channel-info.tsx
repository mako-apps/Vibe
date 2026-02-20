import React, { useState, useEffect } from 'react';
import {
    View, Text, TouchableOpacity, FlatList,
    StyleSheet, ActivityIndicator, Alert,
} from 'react-native';
import { Stack, useRouter, useLocalSearchParams } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Users, MessageSquare, TrendingUp, LogOut, Clock } from 'lucide-react-native';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useChatStore } from '../src/lib/ChatStore';
import { apiClient } from '../src/lib/api-client';
import { ScheduledPost } from '../src/lib/types';

export default function ChannelInfoScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const params = useLocalSearchParams<{ channelId: string }>();
    const colors = useThemeStore(s => s.colors);
    const chats = useChatStore(s => s.chats);
    const leaveChannel = useChatStore(s => s.leaveChannel);

    const channel = chats.find(c => c.chatId === params.channelId);
    const isOwner = channel?.role === 'owner';

    const [analytics, setAnalytics] = useState<any>(null);
    const [scheduledPosts, setScheduledPosts] = useState<ScheduledPost[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        loadData();
    }, [params.channelId]);

    const loadData = async () => {
        setLoading(true);
        try {
            const [analyticsRes, postsRes] = await Promise.all([
                apiClient.getChannelAnalytics(params.channelId),
                isOwner ? apiClient.getScheduledPosts(params.channelId) : Promise.resolve([]),
            ]);
            setAnalytics(analyticsRes);
            setScheduledPosts(postsRes);
        } catch (e) {
            console.error('Load channel info failed', e);
        }
        setLoading(false);
    };

    const handleLeave = () => {
        Alert.alert('Leave Channel', 'Are you sure you want to leave this channel?', [
            { text: 'Cancel', style: 'cancel' },
            {
                text: 'Leave', style: 'destructive', onPress: async () => {
                    const success = await leaveChannel(params.channelId);
                    if (success) router.back();
                }
            }
        ]);
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{ headerShown: false }} />

            {/* Header */}
            <View style={[styles.header, { paddingTop: insets.top + 8 }]}>
                <TouchableOpacity onPress={() => router.back()} style={styles.backBtn}>
                    <ArrowLeft size={24} color={colors.text} />
                </TouchableOpacity>
                <Text style={[styles.title, { color: colors.text }]}>Channel Info</Text>
            </View>

            {loading ? (
                <ActivityIndicator style={{ marginTop: 40 }} color={colors.primary} />
            ) : (
                <FlatList
                    data={[]}
                    renderItem={() => null}
                    ListHeaderComponent={() => (
                        <View style={styles.content}>
                            {/* Channel Header */}
                            <View style={styles.channelHeader}>
                                <View style={[styles.bigAvatar, { backgroundColor: colors.primary + '20' }]}>
                                    <Text style={{ fontSize: 32, color: colors.primary, fontWeight: '700' }}>
                                        {(channel?.name || '?')[0].toUpperCase()}
                                    </Text>
                                </View>
                                <Text style={[styles.channelName, { color: colors.text }]}>
                                    {channel?.name || 'Channel'}
                                </Text>
                                {channel?.description && (
                                    <Text style={[styles.description, { color: colors.textSecondary }]}>
                                        {channel.description}
                                    </Text>
                                )}
                            </View>

                            {/* Analytics Cards */}
                            {analytics && (
                                <View style={styles.statsRow}>
                                    <View style={[styles.statCard, { backgroundColor: colors.card }]}>
                                        <Users size={20} color={colors.primary} />
                                        <Text style={[styles.statNumber, { color: colors.text }]}>
                                            {analytics.subscriber_count}
                                        </Text>
                                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>
                                            Subscribers
                                        </Text>
                                    </View>
                                    <View style={[styles.statCard, { backgroundColor: colors.card }]}>
                                        <MessageSquare size={20} color={colors.primary} />
                                        <Text style={[styles.statNumber, { color: colors.text }]}>
                                            {analytics.message_count}
                                        </Text>
                                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>
                                            Messages
                                        </Text>
                                    </View>
                                    <View style={[styles.statCard, { backgroundColor: colors.card }]}>
                                        <TrendingUp size={20} color={colors.primary} />
                                        <Text style={[styles.statNumber, { color: colors.text }]}>
                                            +{analytics.recent_joins_7d}
                                        </Text>
                                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>
                                            This Week
                                        </Text>
                                    </View>
                                </View>
                            )}

                            {/* Scheduled Posts (owner only) */}
                            {isOwner && scheduledPosts.length > 0 && (
                                <View style={styles.scheduledSection}>
                                    <Text style={[styles.sectionTitle, { color: colors.text }]}>
                                        Scheduled Posts
                                    </Text>
                                    {scheduledPosts.map(post => (
                                        <View key={post.id} style={[styles.scheduledCard, { backgroundColor: colors.card }]}>
                                            <Clock size={16} color={colors.textSecondary} />
                                            <View style={{ flex: 1, marginLeft: 10 }}>
                                                <Text style={[{ color: colors.text, fontSize: 14 }]} numberOfLines={2}>
                                                    {post.content}
                                                </Text>
                                                <Text style={[{ color: colors.textSecondary, fontSize: 12, marginTop: 4 }]}>
                                                    {new Date(post.scheduledAt).toLocaleString()}
                                                </Text>
                                            </View>
                                        </View>
                                    ))}
                                </View>
                            )}

                            {/* Leave Button (non-owners) */}
                            {!isOwner && (
                                <TouchableOpacity
                                    onPress={handleLeave}
                                    style={[styles.leaveBtn, { backgroundColor: '#ff3b3020' }]}
                                >
                                    <LogOut size={20} color="#ff3b30" />
                                    <Text style={styles.leaveBtnText}>Leave Channel</Text>
                                </TouchableOpacity>
                            )}
                        </View>
                    )}
                />
            )}
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    header: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingBottom: 12 },
    backBtn: { padding: 8, marginRight: 8 },
    title: { fontSize: 20, fontWeight: '700', flex: 1 },
    content: { padding: 16 },
    channelHeader: { alignItems: 'center', marginBottom: 24 },
    bigAvatar: { width: 80, height: 80, borderRadius: 40, justifyContent: 'center', alignItems: 'center', marginBottom: 12 },
    channelName: { fontSize: 22, fontWeight: '700' },
    description: { fontSize: 14, marginTop: 6, textAlign: 'center', lineHeight: 20 },
    statsRow: { flexDirection: 'row', gap: 10, marginBottom: 24 },
    statCard: { flex: 1, borderRadius: 14, padding: 14, alignItems: 'center', gap: 6 },
    statNumber: { fontSize: 22, fontWeight: '700' },
    statLabel: { fontSize: 12 },
    scheduledSection: { marginBottom: 24 },
    sectionTitle: { fontSize: 16, fontWeight: '700', marginBottom: 12 },
    scheduledCard: { flexDirection: 'row', alignItems: 'center', padding: 14, borderRadius: 12, marginBottom: 8 },
    leaveBtn: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8, padding: 14, borderRadius: 12, marginTop: 16 },
    leaveBtnText: { color: '#ff3b30', fontSize: 16, fontWeight: '600' },
});
