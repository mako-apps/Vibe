import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Alert, View, ActivityIndicator, StyleSheet } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import UserProfile from '../src/components/chat/UserProfile';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { getUserChannel, useChatStore } from '../src/lib/ChatStore';
import { apiClient } from '../src/lib/api-client';
import { useCallStore } from '../src/lib/stores/CallStore';
import type { Message } from '../src/lib/types';
import type { UserTier } from '../src/lib/stores/subscription-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import type {
    UserProfileMediaItem,
    UserProfileFileItem,
    UserProfileLinkItem,
    UserProfilePinnedItem,
} from '../src/components/chat/UserProfile';

const isValidTier = (value: unknown): value is UserTier => (
    value === 'free' ||
    value === 'bronze' ||
    value === 'silver' ||
    value === 'gold' ||
    value === 'admin' ||
    value === 'verified'
);

const toBool = (value: unknown): boolean | undefined => {
    if (typeof value === 'boolean') return value;
    if (typeof value !== 'string') return undefined;
    const v = value.trim().toLowerCase();
    if (v === '1' || v === 'true' || v === 'yes') return true;
    if (v === '0' || v === 'false' || v === 'no') return false;
    return undefined;
};

const waitForUserChannel = async (timeoutMs = 12000): Promise<any | null> => {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
        const channel = getUserChannel();
        const state = (channel as any)?.state;
        const ready =
            channel &&
            typeof channel.push === 'function' &&
            (state === 'joined' || state === 'joining' || !state);
        if (ready) return channel;
        await new Promise((resolve) => setTimeout(resolve, 120));
    }
    return null;
};

const URL_RE = /(https?:\/\/[^\s]+)/gi;

const toTimestamp = (value: unknown): number => {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
        const n = Number(value);
        if (Number.isFinite(n)) return n;
        const d = new Date(value).getTime();
        if (Number.isFinite(d)) return d;
    }
    return Date.now();
};

const toText = (m: Message): string => {
    return (m.plaintext || m.caption || '').toString();
};

export default function UserProfileRoute() {
    const router = useRouter();
    const params = useLocalSearchParams();
    const { colors } = useThemeStore();
    const { user } = useAuthStore();
    const chats = useChatStore((s) => s.chats);
    const loadMessages = useChatStore((s) => s.loadMessages);
    const isConnected = useChatStore((s) => s.isConnected);
    const initSocket = useChatStore((s) => s.initSocket);
    const toggleMuteChat = useChatStore((s) => s.toggleMuteChat);
    const deleteChat = useChatStore((s) => s.deleteChat);
    const startCall = useCallStore((s) => s.startCall);
    const callStatus = useCallStore((s) => s.callStatus);
    const checkWebRTCAvailability = useCallStore((s) => s.checkWebRTCAvailability);

    const userId = typeof params.userId === 'string' ? params.userId : '';
    const chatIdParam = typeof params.chatId === 'string' ? params.chatId : '';
    const usernameParam = typeof params.username === 'string' ? params.username : '';
    const profileImageParam = typeof params.profileImage === 'string' ? params.profileImage : '';
    const isOnlineParam = toBool(params.isOnline);

    const chat = useMemo(() => {
        if (chatIdParam) {
            const byChatId = chats.find((entry) => entry.chatId === chatIdParam);
            if (byChatId) return byChatId;
        }
        if (!userId) return undefined;
        const targetId = userId.toUpperCase();
        return chats.find((entry) => (entry.friendId || '').toUpperCase() === targetId);
    }, [chatIdParam, chats, userId]);

    const [remoteProfile, setRemoteProfile] = useState<{
        username?: string;
        profileImage?: string | null;
        bio?: string;
        tier?: UserTier;
        online?: boolean;
    }>({});
    const [contentLoading, setContentLoading] = useState(false);
    const [mediaItems, setMediaItems] = useState<UserProfileMediaItem[]>([]);
    const [videoItems, setVideoItems] = useState<UserProfileMediaItem[]>([]);
    const [imageItems, setImageItems] = useState<UserProfileMediaItem[]>([]);
    const [fileItems, setFileItems] = useState<UserProfileFileItem[]>([]);
    const [linkItems, setLinkItems] = useState<UserProfileLinkItem[]>([]);
    const [pinnedItems, setPinnedItems] = useState<UserProfilePinnedItem[]>([]);

    useEffect(() => {
        let cancelled = false;
        if (!userId) return;
        (async () => {
            try {
                const payload = await apiClient.getUser(userId);
                if (!payload || cancelled) return;
                const resolvedTier = isValidTier(payload?.tier) ? payload.tier : undefined;
                setRemoteProfile({
                    username: payload?.username || payload?.name,
                    profileImage: payload?.profileImage || payload?.profile_image || null,
                    bio: payload?.bio,
                    tier: resolvedTier,
                    online: typeof payload?.online === 'boolean' ? payload.online : undefined,
                });
            } catch {
                // Keep route resilient with fallback params/chat data.
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [userId]);

    const displayUsername = remoteProfile.username || usernameParam || chat?.friendName || 'User';
    const displayImage = remoteProfile.profileImage ?? (profileImageParam || chat?.friendImage || null);
    const displayBio = remoteProfile.bio;
    const displayTier = remoteProfile.tier;
    const displayOnline = remoteProfile.online ?? isOnlineParam ?? false;
    const resolvedChatId = chat?.chatId || chatIdParam;
    const isMuted = !!chat?.muted;

    useEffect(() => {
        let cancelled = false;

        const run = async () => {
            if (!resolvedChatId) {
                setMediaItems([]);
                setVideoItems([]);
                setImageItems([]);
                setFileItems([]);
                setLinkItems([]);
                setPinnedItems([]);
                return;
            }

            setContentLoading(true);
            try {
                await loadMessages(resolvedChatId);
            } catch {
                // Continue with whatever local messages are currently available.
            }

            try {
                const latestChat = useChatStore.getState().chats.find((c) => c.chatId === resolvedChatId);
                const messages = [...(latestChat?.messages || [])].sort((a, b) => toTimestamp(b.timestamp) - toTimestamp(a.timestamp));

                const allMedia = messages
                    .filter((m) => !!m.mediaUrl || ['image', 'video', 'gif', 'sticker'].includes(m.type))
                    .map((m) => ({
                        id: m.id,
                        type: m.type,
                        mediaUrl: m.mediaUrl || '',
                        caption: toText(m),
                        timestamp: toTimestamp(m.timestamp),
                    }));

                const videos = allMedia.filter((m) => m.type === 'video');
                const images = allMedia.filter((m) => m.type === 'image' || m.type === 'gif' || m.type === 'sticker');

                const files = messages
                    .filter((m) => m.type === 'file' || m.type === 'music' || m.type === 'voice')
                    .map((m) => ({
                        id: m.id,
                        type: m.type,
                        fileName: m.fileName || `${m.type.toUpperCase()}-${m.id.slice(0, 6)}`,
                        fileSize: m.fileSize,
                        mediaUrl: m.mediaUrl,
                        timestamp: toTimestamp(m.timestamp),
                    }));

                const links: UserProfileLinkItem[] = [];
                messages.forEach((m) => {
                    const text = toText(m);
                    const found = text.match(URL_RE) || [];
                    found.forEach((url, index) => {
                        links.push({
                            id: `${m.id}_${index}`,
                            url,
                            previewText: text.length > 220 ? `${text.slice(0, 220)}...` : text,
                            timestamp: toTimestamp(m.timestamp),
                        });
                    });
                });

                let pinned: UserProfilePinnedItem[] = [];
                try {
                    const pinnedResp = await apiClient.getPinnedMessages(resolvedChatId);
                    const rawList = Array.isArray(pinnedResp)
                        ? pinnedResp
                        : Array.isArray((pinnedResp as any)?.data)
                            ? (pinnedResp as any).data
                            : Array.isArray((pinnedResp as any)?.messages)
                                ? (pinnedResp as any).messages
                                : [];

                    pinned = rawList.map((item: any) => ({
                        id: item?.id || item?.messageId || item?.message_id || `${Math.random()}`,
                        type: item?.type || 'text',
                        text: item?.plaintext || item?.content || item?.text || item?.fileName || item?.file_name || '',
                        timestamp: toTimestamp(item?.timestamp || item?.createdAt || item?.created_at),
                    }));
                } catch {
                    pinned = [];
                }

                if (cancelled) return;
                setMediaItems(allMedia);
                setVideoItems(videos);
                setImageItems(images);
                setFileItems(files);
                setLinkItems(links);
                setPinnedItems(pinned);
            } finally {
                if (!cancelled) setContentLoading(false);
            }
        };

        void run();
        return () => {
            cancelled = true;
        };
    }, [resolvedChatId, loadMessages]);

    const handleToggleMute = useCallback(() => {
        if (!resolvedChatId) return;
        toggleMuteChat(resolvedChatId);
    }, [resolvedChatId, toggleMuteChat]);

    const handleClearChat = useCallback(() => {
        if (!resolvedChatId) return;
        Alert.alert(
            'Delete chat',
            'This removes the chat from your list.',
            [
                { text: 'Cancel', style: 'cancel' },
                {
                    text: 'Delete',
                    style: 'destructive',
                    onPress: () => {
                        deleteChat(resolvedChatId);
                        router.back();
                    },
                },
            ],
        );
    }, [resolvedChatId, deleteChat, router]);

    const handleBlock = useCallback(async () => {
        if (!user?.userId || !userId) return;
        try {
            await apiClient.blockUser(user.userId, userId);
            Alert.alert('Blocked', `${displayUsername} has been blocked.`);
            router.back();
        } catch {
            Alert.alert('Error', 'Failed to block this user.');
        }
    }, [user?.userId, userId, displayUsername, router]);

    const handleStartCall = useCallback(async (type: 'voice' | 'video') => {
        if (!userId) return;
        if ((user?.userId || '').toUpperCase() === userId.toUpperCase()) {
            Alert.alert('Call unavailable', 'You cannot call yourself.');
            return;
        }
        if (callStatus !== 'idle') {
            Alert.alert('Call in progress', 'Finish the current call first.');
            return;
        }

        const available = await checkWebRTCAvailability();
        if (!available) {
            Alert.alert('Call unavailable', 'WebRTC is not available on this build/device.');
            return;
        }

        if (!isConnected) {
            initSocket();
        }

        const channel = await waitForUserChannel();
        if (!channel) {
            Alert.alert('Call unavailable', 'Could not connect to call signaling. Please try again.');
            return;
        }

        const ok = await startCall(
            {
                userId,
                userName: displayUsername,
                userImage: displayImage || undefined,
            },
            type,
            channel,
        );

        if (!ok) {
            Alert.alert('Call failed', `Could not start ${type} call. Please try again.`);
        }
    }, [
        userId,
        user?.userId,
        callStatus,
        checkWebRTCAvailability,
        isConnected,
        initSocket,
        startCall,
        displayUsername,
        displayImage,
    ]);

    if (!userId) {
        return (
            <View style={[styles.fallback, { backgroundColor: colors.background }]}>
                <ActivityIndicator size="small" color={colors.text} />
            </View>
        );
    }

    return (
        <UserProfile
            visible
            onClose={() => router.back()}
            username={displayUsername}
            userId={userId}
            chatId={resolvedChatId || undefined}
            profileImage={displayImage}
            tier={displayTier}
            bio={displayBio}
            isOnline={displayOnline}
            isMuted={isMuted}
            onToggleMute={handleToggleMute}
            onAudioCall={() => { void handleStartCall('voice'); }}
            onVideoCall={() => { void handleStartCall('video'); }}
            onClearChat={handleClearChat}
            onDeleteContact={resolvedChatId ? handleClearChat : undefined}
            onBlock={handleBlock}
            isContentLoading={contentLoading}
            mediaItems={mediaItems}
            videoItems={videoItems}
            imageItems={imageItems}
            fileItems={fileItems}
            linkItems={linkItems}
            pinnedItems={pinnedItems}
        />
    );
}

const styles = StyleSheet.create({
    fallback: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
});
