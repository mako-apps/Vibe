import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Contacts from 'expo-contacts';
import { apiClient } from './api-client';
import { useAuthStore } from './stores/auth-store';
import { useContactStore } from './stores/contact-store';
import { normalizePhoneNumber } from './utils/security';

const CONTACT_SYNC_LAST_RUN_KEY = 'vibe-contact-sync:last-run';
const CONTACT_SYNC_MIN_INTERVAL_MS = 6 * 60 * 60 * 1000;
const CONTACT_SYNC_BATCH_LIMIT = 500;

type SyncStatus =
    | 'ok'
    | 'no_auth'
    | 'no_permission'
    | 'no_phone_contacts'
    | 'skipped_recently';

export interface ContactSyncResult {
    status: SyncStatus;
    matched: number;
    scanned: number;
}

const getContactDisplayName = (contact: Contacts.Contact): string | null => {
    const directName = typeof contact.name === 'string' ? contact.name.trim() : '';
    if (directName) return directName;

    const first = typeof contact.firstName === 'string' ? contact.firstName.trim() : '';
    const last = typeof contact.lastName === 'string' ? contact.lastName.trim() : '';
    const composed = `${first} ${last}`.trim();
    return composed || null;
};

const collectDevicePhoneBook = async (): Promise<Map<string, string>> => {
    const phoneToName = new Map<string, string>();
    const response = await Contacts.getContactsAsync({
        fields: [
            Contacts.Fields.PhoneNumbers,
            Contacts.Fields.FirstName,
            Contacts.Fields.LastName,
        ],
    });

    for (const contact of response.data || []) {
        const displayName = getContactDisplayName(contact);
        const phoneNumbers = contact.phoneNumbers || [];

        for (const phoneEntry of phoneNumbers) {
            const normalized = normalizePhoneNumber(phoneEntry.number || '');
            if (!normalized) continue;
            if (!phoneToName.has(normalized) && displayName) {
                phoneToName.set(normalized, displayName);
            } else if (!phoneToName.has(normalized)) {
                phoneToName.set(normalized, normalized);
            }
        }
    }

    return phoneToName;
};

export const syncContactsWithServer = async (opts?: {
    force?: boolean;
    requestPermission?: boolean;
}): Promise<ContactSyncResult> => {
    const force = opts?.force === true;
    const requestPermission = opts?.requestPermission !== false;
    const authUser = useAuthStore.getState().user;

    if (!authUser?.userId) {
        return { status: 'no_auth', matched: 0, scanned: 0 };
    }

    if (!force) {
        const lastSyncRaw = await AsyncStorage.getItem(CONTACT_SYNC_LAST_RUN_KEY);
        const lastSync = Number(lastSyncRaw || 0);
        if (Number.isFinite(lastSync) && lastSync > 0 && Date.now() - lastSync < CONTACT_SYNC_MIN_INTERVAL_MS) {
            return { status: 'skipped_recently', matched: 0, scanned: 0 };
        }
    }

    let permission = await Contacts.getPermissionsAsync();
    if (!permission.granted && requestPermission) {
        permission = await Contacts.requestPermissionsAsync();
    }

    if (!permission.granted) {
        return { status: 'no_permission', matched: 0, scanned: 0 };
    }

    const phoneToName = await collectDevicePhoneBook();
    const phoneNumbers = Array.from(phoneToName.keys()).slice(0, CONTACT_SYNC_BATCH_LIMIT);

    if (phoneNumbers.length === 0) {
        await AsyncStorage.setItem(CONTACT_SYNC_LAST_RUN_KEY, String(Date.now()));
        return { status: 'no_phone_contacts', matched: 0, scanned: 0 };
    }

    const response = await apiClient.matchContacts(phoneNumbers);
    const matches = Array.isArray(response?.matches) ? response.matches : [];
    const { upsertContact } = useContactStore.getState();
    const selfId = authUser.userId.toUpperCase();

    let matchedCount = 0;

    for (const match of matches) {
        const userId = String(match?.userId || '').toUpperCase();
        if (!userId || userId === selfId) continue;

        const normalizedMatchPhone = normalizePhoneNumber(match?.phoneNumber || '');
        const localName = normalizedMatchPhone ? phoneToName.get(normalizedMatchPhone) : null;
        const username = localName || match?.name || match?.username || userId;

        upsertContact({
            id: userId,
            username,
            phoneNumber: match?.phoneNumber || undefined,
            profileImage: match?.profileImage || undefined,
        });
        matchedCount += 1;
    }

    await AsyncStorage.setItem(CONTACT_SYNC_LAST_RUN_KEY, String(Date.now()));

    return {
        status: 'ok',
        matched: matchedCount,
        scanned: phoneNumbers.length,
    };
};

export const syncContactsInBackground = async (): Promise<void> => {
    try {
        await syncContactsWithServer({ requestPermission: false });
    } catch (e) {
        console.warn('[Contacts] Background sync failed', e);
    }
};
