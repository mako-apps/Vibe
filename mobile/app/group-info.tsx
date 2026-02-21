import React from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Users } from 'lucide-react-native';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useChatStore } from '../src/lib/ChatStore';

export default function GroupInfoScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const params = useLocalSearchParams<{ groupId: string }>();
    const colors = useThemeStore(s => s.colors);
    const chats = useChatStore(s => s.chats);

    const group = chats.find(c => c.chatId === params.groupId);
    const memberCount = Number(group?.memberCount || 0);

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{ headerShown: false }} />

            <View style={[styles.header, { paddingTop: insets.top + 8 }]}>
                <TouchableOpacity onPress={() => router.back()} style={styles.backBtn}>
                    <ArrowLeft size={24} color={colors.text} />
                </TouchableOpacity>
                <Text style={[styles.title, { color: colors.text }]}>Group Info</Text>
            </View>

            <View style={styles.content}>
                <View style={[styles.avatar, { backgroundColor: colors.primary + '20' }]}>
                    <Text style={{ color: colors.primary, fontSize: 30, fontWeight: '700' }}>
                        {(group?.name || '?')[0].toUpperCase()}
                    </Text>
                </View>

                <Text style={[styles.name, { color: colors.text }]}>
                    {group?.name || 'Group'}
                </Text>

                {!!group?.description && (
                    <Text style={[styles.description, { color: colors.textSecondary }]}>
                        {group.description}
                    </Text>
                )}

                <View style={[styles.card, { backgroundColor: colors.card }]}>
                    <View style={styles.row}>
                        <Users size={18} color={colors.primary} />
                        <Text style={[styles.rowText, { color: colors.text }]}>
                            {memberCount > 0 ? `${memberCount} members` : 'Members unavailable'}
                        </Text>
                    </View>
                </View>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    header: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingBottom: 12 },
    backBtn: { padding: 8, marginRight: 8 },
    title: { fontSize: 20, fontWeight: '700', flex: 1 },
    content: { padding: 16, alignItems: 'center' },
    avatar: {
        width: 84,
        height: 84,
        borderRadius: 42,
        justifyContent: 'center',
        alignItems: 'center',
        marginBottom: 14,
    },
    name: { fontSize: 22, fontWeight: '700' },
    description: { marginTop: 8, textAlign: 'center', fontSize: 14, lineHeight: 20 },
    card: { width: '100%', borderRadius: 14, padding: 14, marginTop: 20 },
    row: { flexDirection: 'row', alignItems: 'center' },
    rowText: { marginLeft: 10, fontSize: 15, fontWeight: '600' },
});

