import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { requestPermissionsAndGetToken } from '../NotificationManager';
import { useAuthStore } from './auth-store';

interface NotificationState {
    notificationsEnabled: boolean;
    pushToken: string | null;
    isInitializing: boolean;
    lastSyncedToken: string | null;
    lastSyncedUserId: string | null;
    lastSyncedAt: number | null;
    setNotificationsEnabled: (enabled: boolean) => Promise<void>;
    initNotifications: (options?: { forceSync?: boolean; reason?: string }) => Promise<void>;
}

const PUSH_TOKEN_RESYNC_INTERVAL_MS = 10 * 60 * 1000;

export const useNotificationStore = create<NotificationState>()(
    persist(
        (set, get) => ({
            notificationsEnabled: true, // Default to true
            pushToken: null,
            isInitializing: false,
            lastSyncedToken: null,
            lastSyncedUserId: null,
            lastSyncedAt: null,

            setNotificationsEnabled: async (enabled: boolean) => {
                console.log('[NotificationStore] setNotificationsEnabled', { enabled });
                set({ notificationsEnabled: enabled });
                if (enabled) {
                    await get().initNotifications();
                } else {
                    // If disabled, we might want to clear the token on the server
                    const { user, updateProfileInfo } = useAuthStore.getState();
                    if (user && updateProfileInfo) {
                        try {
                            await updateProfileInfo({ pushToken: '' });
                            set({
                                pushToken: null,
                                lastSyncedToken: null,
                                lastSyncedUserId: user.userId,
                                lastSyncedAt: Date.now(),
                            });
                        } catch (e) {
                            console.warn('[NotificationStore] Failed to clear push token on server', e);
                        }
                    }
                }
            },

            initNotifications: async (options = {}) => {
                const { forceSync = false, reason = 'unknown' } = options;
                const { notificationsEnabled, isInitializing } = get();
                if (!notificationsEnabled || isInitializing) {
                    console.log('[NotificationStore] initNotifications skipped', {
                        notificationsEnabled,
                        isInitializing,
                        reason,
                    });
                    return;
                }

                set({ isInitializing: true });
                try {
                    console.log('[NotificationStore] Requesting permissions and token...', {
                        reason,
                        forceSync,
                    });
                    const token = await requestPermissionsAndGetToken();
                    if (token) {
                        console.log('[NotificationStore] Got push token:', token);
                        set({ pushToken: token });

                        // Sync with backend via AuthStore
                        const { user, updateProfileInfo } = useAuthStore.getState();
                        if (!user || !updateProfileInfo) {
                            console.log('[NotificationStore] Cannot sync token yet (missing user or updateProfileInfo)');
                        } else {
                            const { lastSyncedToken, lastSyncedUserId, lastSyncedAt } = get();
                            const now = Date.now();
                            const syncExpired = !lastSyncedAt || (now - lastSyncedAt) > PUSH_TOKEN_RESYNC_INTERVAL_MS;
                            const reasons: string[] = [];

                            if (forceSync) reasons.push('forceSync');
                            if (user.pushToken !== token) reasons.push('authStoreMismatch');
                            if (lastSyncedToken !== token) reasons.push('lastSyncedTokenMismatch');
                            if (lastSyncedUserId !== user.userId) reasons.push('lastSyncedUserMismatch');
                            if (syncExpired) reasons.push('syncExpired');

                            if (reasons.length > 0) {
                                console.log('[NotificationStore] Syncing token with backend', {
                                    userId: user.userId,
                                    hadToken: !!user.pushToken,
                                    reason,
                                    reasons,
                                });
                                await updateProfileInfo({ pushToken: token });
                                set({
                                    lastSyncedToken: token,
                                    lastSyncedUserId: user.userId,
                                    lastSyncedAt: now,
                                });
                                console.log('[NotificationStore] Token sync completed');
                            } else {
                                console.log('[NotificationStore] Token recently synced, skipping profile update', {
                                    userId: user.userId,
                                    reason,
                                    lastSyncedAt,
                                });
                            }
                        }
                    } else {
                        console.log('[NotificationStore] No push token returned from NotificationManager');
                    }
                } catch (error) {
                    console.error('[NotificationStore] Failed to initialize notifications:', error);
                } finally {
                    set({ isInitializing: false });
                }
            },
        }),
        {
            name: 'notification-storage',
            storage: createJSONStorage(() => AsyncStorage),
        }
    )
);
