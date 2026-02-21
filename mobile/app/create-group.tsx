import React, { useState, useEffect } from 'react';
import {
    View, Text, TextInput, TouchableOpacity, FlatList,
    StyleSheet, ActivityIndicator, Alert,
} from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Check, Search, Users } from 'lucide-react-native';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { apiClient } from '../src/lib/api-client';

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

export default function CreateGroupScreen() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const colors = useThemeStore(s => s.colors);
    const createGroup = useChatStore(s => s.createGroup);
    const user = useAuthStore(s => s.user);

    const [groupName, setGroupName] = useState('');
    const [searchQuery, setSearchQuery] = useState('');
    const [selectedMembers, setSelectedMembers] = useState<{ id: string; name: string }[]>([]);
    const [searchResults, setSearchResults] = useState<FoundUser[]>([]);
    const [isCreating, setIsCreating] = useState(false);
    const [isSearching, setIsSearching] = useState(false);

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
            router.replace({ pathname: '/chat', params: { chatId, friendName: groupName } });
        } else {
            Alert.alert('Error', 'Failed to create group');
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
                <Text style={[styles.title, { color: colors.text }]}>New Group</Text>
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
            </View>

            {/* Group Name */}
            <View style={styles.section}>
                <View style={[styles.inputRow, { backgroundColor: colors.card }]}>
                    <Users size={20} color={colors.textSecondary} />
                    <TextInput
                        style={[styles.input, { color: colors.text }]}
                        placeholder="Group name"
                        placeholderTextColor={colors.textSecondary}
                        value={groupName}
                        onChangeText={setGroupName}
                        maxLength={50}
                    />
                </View>
            </View>

            {/* Selected Members */}
            {selectedMembers.length > 0 && (
                <View style={styles.selectedRow}>
                    {selectedMembers.map(m => (
                        <TouchableOpacity
                            key={m.id}
                            onPress={() => toggleMember(m)}
                            style={[styles.chip, { backgroundColor: colors.primary + '20' }]}
                        >
                            <Text style={[styles.chipText, { color: colors.primary }]}>{m.name}</Text>
                            <Text style={{ color: colors.primary, marginLeft: 4 }}>x</Text>
                        </TouchableOpacity>
                    ))}
                </View>
            )}

            {/* Search Members */}
            <View style={styles.section}>
                <View style={[styles.inputRow, { backgroundColor: colors.card }]}>
                    <Search size={20} color={colors.textSecondary} />
                    <TextInput
                        style={[styles.input, { color: colors.text }]}
                        placeholder="Search by username..."
                        placeholderTextColor={colors.textSecondary}
                        value={searchQuery}
                        onChangeText={setSearchQuery}
                    />
                </View>
            </View>

            {/* Search Results */}
            {isSearching && <ActivityIndicator style={{ marginTop: 16 }} color={colors.primary} />}
            <FlatList
                data={searchResults}
                keyExtractor={(item, index) => {
                    const id = resolveFoundUserId(item);
                    return id ? `search-user-${id}` : `search-user-fallback-${index}`;
                }}
                renderItem={({ item }) => {
                    const memberId = resolveFoundUserId(item);
                    const isSelected = selectedMembers.some(m => m.id === memberId);
                    return (
                        <TouchableOpacity
                            onPress={() => toggleMember({ id: memberId, name: item.username || memberId })}
                            style={[styles.userRow, { backgroundColor: isSelected ? colors.primary + '10' : 'transparent' }]}
                        >
                            <View style={[styles.avatar, { backgroundColor: colors.primary + '30' }]}>
                                <Text style={{ color: colors.primary, fontWeight: '600' }}>
                                    {(item.username || '?')[0].toUpperCase()}
                                </Text>
                            </View>
                            <Text style={[styles.userName, { color: colors.text }]}>{item.username}</Text>
                            {isSelected && <Check size={20} color={colors.primary} />}
                        </TouchableOpacity>
                    );
                }}
                contentContainerStyle={{ paddingHorizontal: 16 }}
            />
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    header: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingBottom: 12 },
    backBtn: { padding: 8, marginRight: 8 },
    title: { fontSize: 20, fontWeight: '700', flex: 1 },
    createBtn: { padding: 8 },
    section: { paddingHorizontal: 16, marginBottom: 12 },
    inputRow: { flexDirection: 'row', alignItems: 'center', borderRadius: 12, paddingHorizontal: 14, height: 48 },
    input: { flex: 1, fontSize: 16, marginLeft: 10 },
    selectedRow: { flexDirection: 'row', flexWrap: 'wrap', paddingHorizontal: 16, gap: 8, marginBottom: 12 },
    chip: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, paddingVertical: 6, borderRadius: 20 },
    chipText: { fontSize: 14, fontWeight: '500' },
    userRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 12, paddingHorizontal: 4, borderRadius: 10 },
    avatar: { width: 40, height: 40, borderRadius: 20, justifyContent: 'center', alignItems: 'center', marginRight: 12 },
    userName: { fontSize: 16, fontWeight: '500', flex: 1 },
});
