import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Message } from '../types';
import { apiClient } from '../api-client';
import { useAuthStore } from './auth-store';
import { useChatStore } from '../ChatStore';
import { encryptMessage, decryptMessage, importPublicKey, encryptFileData } from '../crypto';
import { uploadMedia } from '../api-client';
import { useEncryptedMediaStore } from './encrypted-media-store';
import * as FileSystem from 'expo-file-system/legacy';
import AuthManager from '../AuthManager';
import { useToastStore } from './toast-store';

// Helper to parse decrypted content
const parseDecryptedContent = (decrypted: string): Partial<Message> => {
    try {
        if (decrypted.trim().startsWith('{')) {
            const parsed = JSON.parse(decrypted);
            if (parsed.text !== undefined || parsed.mediaUrl !== undefined) {
                return {
                    plaintext: parsed.text,
                    mediaUrl: parsed.mediaUrl,
                    mediaKey: parsed.mediaKey,
                    fileName: parsed.fileName,
                    fileSize: parsed.fileSize,
                    latitude: parsed.latitude,
                    longitude: parsed.longitude,
                    replyToId: parsed.replyToId,
                    extra: {
                        width: parsed.width,
                        height: parsed.height,
                    },
                };
            }
        }
    } catch (e) { }
    return { plaintext: decrypted };
};

interface SavedMessage extends Message {
    savedAt: number;
}

interface SavedMessagesState {
    savedMessages: SavedMessage[];
    saveMessage: (msg: Message) => Promise<void>;
    sendMessage: (text: string, type?: Message['type'], metadata?: any, existingMsgId?: string) => Promise<void>;
    retryMessage: (id: string) => Promise<void>;
    removeMessage: (id: string) => Promise<void>;
    isSaved: (id: string) => boolean;
    sync: () => Promise<void>;
}

export const useSavedMessagesStore = create<SavedMessagesState>()(
    persist(
        (set, get) => ({
            savedMessages: [],
            saveMessage: async (msg) => {
                if (get().savedMessages.some(m => m.id === msg.id)) return;

                const savedMsg: SavedMessage = {
                    ...msg,
                    savedAt: Date.now()
                };

                set({ savedMessages: [savedMsg, ...get().savedMessages] });

                // Sync to Backend
                const { user } = useAuthStore.getState();
                if (user?.userId) {
                    await apiClient.saveMessage({
                        user_id: user.userId,
                        original_message_id: msg.id,
                        chat_id: msg.chatId || 'saved_messages',
                        from_id: msg.fromId,
                        encrypted_content: msg.encryptedContent || '',
                        content: '', // SECURITY: Don't store plaintext on server
                        type: msg.type,
                        media_url: null, // SECURITY: Don't store metadata on server
                        timestamp: msg.timestamp,
                        extra: typeof msg.extra === 'string' ? msg.extra : JSON.stringify(msg.extra)
                    });
                }
            },
            sendMessage: async (text, type = 'text', metadata = {}, existingMsgId) => {
                const { user } = useAuthStore.getState();
                if (!user?.userId) return;

                const msgId = existingMsgId || Math.random().toString(36).substring(7);
                const now = Date.now();
                let mediaKey: string | undefined;
                let finalMediaUrl = metadata.mediaUrl;

                if (existingMsgId) {
                    // Update existing message to sending status
                    set(s => ({
                        savedMessages: s.savedMessages.map(m => m.id === msgId ? { ...m, status: 'sending', timestamp: now } : m)
                    }));
                } else {
                    // Add Optimistic Message
                    const newMsg: Message = {
                        id: msgId,
                        fromId: user.userId,
                        chatId: 'saved_messages',
                        encryptedContent: '', // Placeholder
                        type: type,
                        timestamp: now,
                        plaintext: text,
                        mediaUrl: metadata.mediaUrl, // Local URI for display
                        mediaKey: undefined,
                        fileName: metadata.fileName,
                        fileSize: metadata.fileSize,
                        latitude: metadata.latitude,
                        longitude: metadata.longitude,
                        replyToId: metadata.replyToId,
                        extra: { width: metadata.width, height: metadata.height },
                        status: 'sending' // Start as sending to show spinner
                    };

                    const savedMsg: SavedMessage = {
                        ...newMsg,
                        savedAt: now
                    };

                    set({ savedMessages: [savedMsg, ...get().savedMessages] });
                }

                try {
                    // Handle Media Upload if needed
                    if (metadata.mediaUrl && !metadata.mediaUrl.startsWith('http') && ['image', 'voice', 'video', 'file', 'sticker'].includes(type || '')) {
                        const fileUri = metadata.mediaUrl;

                        // Encrypt File
                        const fileContent = await FileSystem.readAsStringAsync(fileUri, { encoding: FileSystem.EncodingType.Base64 });
                        const { encryptedBase64, keyBase64 } = await encryptFileData(fileContent);
                        mediaKey = keyBase64;

                        const encryptedUri = `${FileSystem.cacheDirectory}${msgId}.enc`;
                        await FileSystem.writeAsStringAsync(encryptedUri, encryptedBase64, { encoding: FileSystem.EncodingType.Base64 });

                        // Upload
                        const uploadedUrl = await uploadMedia(
                            encryptedUri,
                            user.userId,
                            type as any,
                            (progress) => {
                                // Update ChatStore progress so MessageBubble picks it up
                                useChatStore.getState().setUploadProgress(msgId, progress);
                            }
                        );

                        if (uploadedUrl) {
                            finalMediaUrl = uploadedUrl;
                            // Map encrypted URL to original local file for instant preview
                            useEncryptedMediaStore.getState().manuallyCacheFile(uploadedUrl, fileUri);
                        } else {
                            throw new Error("Media upload failed");
                        }

                        // Cleanup temp encrypted file
                        await FileSystem.deleteAsync(encryptedUri, { idempotent: true }).catch(() => { });
                    }

                    // Encrypt Payload with Final URL and Key
                    const auth = AuthManager.getInstance().getSession();
                    let encryptedContent = '';
                    if (auth?.keyPair?.publicKey) {
                        const payload = JSON.stringify({
                            text: text,
                            mediaUrl: finalMediaUrl,
                            mediaKey: mediaKey,
                            fileName: metadata.fileName,
                            fileSize: metadata.fileSize,
                            latitude: metadata.latitude,
                            longitude: metadata.longitude,
                            width: metadata.width,
                            height: metadata.height,
                            replyToId: metadata.replyToId
                        });
                        const myPubKey = await importPublicKey(auth.keyPair.publicKey);
                        // Encrypt for self
                        encryptedContent = await encryptMessage(myPubKey, payload, auth.keyPair.publicKey);
                    }

                    // Update Message to 'sent'
                    set(s => ({
                        savedMessages: s.savedMessages.map(m => m.id === msgId ? {
                            ...m,
                            status: 'sent',
                            mediaUrl: finalMediaUrl,
                            mediaKey: mediaKey,
                            encryptedContent,
                            extra: { width: metadata.width, height: metadata.height }
                        } : m)
                    }));

                    // Sync to Backend
                    await apiClient.saveMessage({
                        user_id: user.userId,
                        original_message_id: msgId,
                        chat_id: 'saved_messages',
                        from_id: user.userId,
                        encrypted_content: encryptedContent,
                        content: '', // SECURITY
                        type: type,
                        media_url: null, // SECURITY
                        timestamp: now,
                        extra: JSON.stringify({
                            fileName: metadata.fileName,
                            fileSize: metadata.fileSize,
                            latitude: metadata.latitude,
                            longitude: metadata.longitude,
                            width: metadata.width,
                            height: metadata.height,
                            replyToId: metadata.replyToId
                        })
                    });
                } catch (e) {
                    console.error("SavedMessage send failed", e);
                    set(s => ({
                        savedMessages: s.savedMessages.map(m => m.id === msgId ? { ...m, status: 'error' } : m)
                    }));
                    useToastStore.getState().showToast('Message failed to send', 'error');
                } finally {
                    useChatStore.getState().clearUploadProgress(msgId);
                }
            },
            removeMessage: async (id) => {
                set({ savedMessages: get().savedMessages.filter(m => m.id !== id) });

                const { user } = useAuthStore.getState();
                if (user?.userId) {
                    await apiClient.deleteSavedMessage(user.userId, id);
                }
            },
            retryMessage: async (id) => {
                const msg = get().savedMessages.find(m => m.id === id);
                if (msg && msg.status === 'error') {
                    const metadata = {
                        mediaUrl: msg.mediaUrl,
                        fileName: msg.fileName,
                        latitude: msg.latitude,
                        longitude: msg.longitude
                    };
                    // Call sendMessage with existing ID
                    await get().sendMessage(msg.plaintext || '', msg.type, metadata, id);
                }
            },
            isSaved: (id) => get().savedMessages.some(m => m.id === id),
            sync: async () => {
                const { user } = useAuthStore.getState();
                if (!user?.userId) return;

                try {
                    const res = await apiClient.getSavedMessages(user.userId);
                    if (res?.data) {
                        const auth = AuthManager.getInstance().getSession();

                        const mapped: SavedMessage[] = await Promise.all(res.data.map(async (m: any) => {
                            let parsedExtra = {};
                            try {
                                if (m.extra && typeof m.extra === 'string') {
                                    parsedExtra = JSON.parse(m.extra);
                                }
                            } catch (e) {
                                console.warn('Failed to parse message extra', e);
                            }

                            // Decrypt if needed
                            let plaintext = m.content;
                            let mediaUrl = m.media_url;
                            let mediaKey = undefined;
                            let fileName = (parsedExtra as any).fileName;
                            let latitude = (parsedExtra as any).latitude;
                            let longitude = (parsedExtra as any).longitude;

                            if (!plaintext && m.encrypted_content && auth?.keyPair?.privateKey) {
                                try {
                                    const decrypted = await decryptMessage(auth.keyPair.privateKey, m.encrypted_content, true); // Treating as "from me" or just decrypting with private key
                                    if (decrypted) {
                                        const parsed = parseDecryptedContent(decrypted);
                                        plaintext = parsed.plaintext;
                                        if (parsed.mediaUrl) mediaUrl = parsed.mediaUrl;
                                        if (parsed.mediaKey) mediaKey = parsed.mediaKey;
                                        if (parsed.fileName) fileName = parsed.fileName;
                                        if (parsed.latitude) latitude = parsed.latitude;
                                        if (parsed.longitude) longitude = parsed.longitude;
                                    }
                                } catch (e) {
                                    plaintext = "[Decryption Error]";
                                }
                            }

                            return {
                                id: m.original_message_id,
                                fromId: m.from_id,
                                chatId: m.chat_id,
                                encryptedContent: m.encrypted_content,
                                plaintext: plaintext,
                                type: m.type as any,
                                mediaUrl: mediaUrl,
                                mediaKey: mediaKey,
                                latitude: latitude,
                                longitude: longitude,
                                fileName: fileName,
                                timestamp: m.timestamp,
                                extra: parsedExtra,
                                savedAt: new Date(m.inserted_at).getTime(),
                                ...parsedExtra
                            };
                        }));

                        // Merge Strategy: Prefer Backend? Or Union?
                        // For simplified logic: Replace usage with Backend + existing Local unique?
                        // We'll trust backend as source of truth for "Saved List"
                        set({ savedMessages: mapped });
                    }
                } catch (e) {
                    console.log('Sync saved messages failed', e);
                }
            }
        }),
        {
            name: 'saved-messages-storage',
            storage: createJSONStorage(() => AsyncStorage)
        }
    )
);
