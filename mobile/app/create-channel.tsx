import React, { useState } from 'react';
import {
    View, Text, TextInput, TouchableOpacity,
    StyleSheet, ActivityIndicator, Alert,
} from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Check, Megaphone } from 'lucide-react-native';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useChatStore } from '../src/lib/ChatStore';

export default function CreateChannelScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const colors = useThemeStore(s => s.colors);
    const createChannel = useChatStore(s => s.createChannel);

    const [channelName, setChannelName] = useState('');
    const [description, setDescription] = useState('');
    const [isCreating, setIsCreating] = useState(false);

    const handleCreate = async () => {
        if (!channelName.trim()) {
            Alert.alert('Error', 'Please enter a channel name');
            return;
        }

        setIsCreating(true);
        const chatId = await createChannel(channelName.trim(), description.trim() || undefined);
        setIsCreating(false);

        if (chatId) {
            router.replace({ pathname: '/chat', params: { chatId, friendName: channelName } });
        } else {
            Alert.alert('Error', 'Failed to create channel');
        }
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{ headerShown: false }} />

            {/* Header */}
            <View style={[styles.header, { paddingTop: insets.top + 8 }]}>
                <TouchableOpacity onPress={() => router.back()} style={styles.backBtn}>
                    <ArrowLeft size={24} color={colors.text} />
                </TouchableOpacity>
                <Text style={[styles.title, { color: colors.text }]}>New Channel</Text>
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
            </View>

            {/* Channel Info */}
            <View style={styles.section}>
                <View style={[styles.iconContainer, { backgroundColor: colors.primary + '15' }]}>
                    <Megaphone size={48} color={colors.primary} />
                </View>
                <Text style={[styles.subtitle, { color: colors.textSecondary }]}>
                    Channels are for broadcasting messages to subscribers. Only you can post.
                </Text>
            </View>

            {/* Channel Name */}
            <View style={styles.section}>
                <Text style={[styles.label, { color: colors.textSecondary }]}>Channel Name</Text>
                <TextInput
                    style={[styles.textInput, { color: colors.text, backgroundColor: colors.card }]}
                    placeholder="e.g. Daily Updates"
                    placeholderTextColor={colors.textSecondary}
                    value={channelName}
                    onChangeText={setChannelName}
                    maxLength={50}
                />
            </View>

            {/* Description */}
            <View style={styles.section}>
                <Text style={[styles.label, { color: colors.textSecondary }]}>Description (optional)</Text>
                <TextInput
                    style={[styles.textInput, styles.multiline, { color: colors.text, backgroundColor: colors.card }]}
                    placeholder="What's this channel about?"
                    placeholderTextColor={colors.textSecondary}
                    value={description}
                    onChangeText={setDescription}
                    multiline
                    maxLength={200}
                    numberOfLines={3}
                />
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    header: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingBottom: 12 },
    backBtn: { padding: 8, marginRight: 8 },
    title: { fontSize: 20, fontWeight: '700', flex: 1 },
    createBtn: { padding: 8 },
    section: { paddingHorizontal: 16, marginBottom: 20 },
    iconContainer: { width: 80, height: 80, borderRadius: 40, justifyContent: 'center', alignItems: 'center', alignSelf: 'center', marginBottom: 12 },
    subtitle: { fontSize: 14, textAlign: 'center', lineHeight: 20 },
    label: { fontSize: 13, fontWeight: '600', marginBottom: 8, textTransform: 'uppercase', letterSpacing: 0.5 },
    textInput: { borderRadius: 12, paddingHorizontal: 14, height: 48, fontSize: 16 },
    multiline: { height: 90, paddingTop: 14, textAlignVertical: 'top' },
});
