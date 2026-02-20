
import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';

export interface Contact {
    id: string; // userId
    username: string;
    phoneNumber?: string;
    profileImage?: string;
    createdAt: number;
}

interface ContactState {
    contacts: Contact[];
    addContact: (user: Omit<Contact, 'createdAt'>) => void;
    upsertContact: (user: Omit<Contact, 'createdAt'>) => void;
    removeContact: (id: string) => void;
    isContact: (id: string) => boolean;
}

export const useContactStore = create<ContactState>()(
    persist(
        (set, get) => ({
            contacts: [],
            addContact: (user) => {
                const { contacts } = get();
                const normalizedId = (user.id || '').toUpperCase();
                if (contacts.some(c => (c.id || '').toUpperCase() === normalizedId)) return;
                set({
                    contacts: [...contacts, { ...user, id: normalizedId, createdAt: Date.now() }]
                });
            },
            upsertContact: (user) => {
                const normalizedId = (user.id || '').toUpperCase();
                const { contacts } = get();
                const idx = contacts.findIndex(c => (c.id || '').toUpperCase() === normalizedId);
                if (idx === -1) {
                    set({
                        contacts: [...contacts, { ...user, id: normalizedId, createdAt: Date.now() }]
                    });
                    return;
                }

                const existing = contacts[idx];
                const updated = [...contacts];
                updated[idx] = {
                    ...existing,
                    username: user.username ?? existing.username,
                    phoneNumber: user.phoneNumber ?? existing.phoneNumber,
                    profileImage: user.profileImage ?? existing.profileImage,
                };
                set({ contacts: updated });
            },
            removeContact: (id) => {
                const normalizedId = (id || '').toUpperCase();
                set({
                    contacts: get().contacts.filter(c => (c.id || '').toUpperCase() !== normalizedId)
                });
            },
            isContact: (id) => {
                const normalizedId = (id || '').toUpperCase();
                return get().contacts.some(c => (c.id || '').toUpperCase() === normalizedId);
            }
        }),
        {
            name: 'vibe-contacts',
            storage: createJSONStorage(() => AsyncStorage),
        }
    )
);
