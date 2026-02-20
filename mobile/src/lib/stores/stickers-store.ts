import AsyncStorage from '@react-native-async-storage/async-storage';
import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';

export interface SavedSticker {
    id: string;
    url: string;
    preview?: string;
    width?: number;
    height?: number;
    addedAt: number;
}

interface StickersState {
    stickers: SavedSticker[];
    addSticker: (sticker: Omit<SavedSticker, 'addedAt'>) => void;
    removeSticker: (id: string) => void;
    clearStickers: () => void;
}

export const useStickersStore = create<StickersState>()(
    persist(
        (set, get) => ({
            stickers: [],
            addSticker: (sticker) => {
                const normalizedId = sticker.id || sticker.url;
                const existing = get().stickers;
                if (existing.some(s => s.id === normalizedId || s.url === sticker.url)) return;
                set({
                    stickers: [
                        { ...sticker, id: normalizedId, addedAt: Date.now() },
                        ...existing
                    ].slice(0, 60)
                });
            },
            removeSticker: (id) => {
                set({ stickers: get().stickers.filter(s => s.id !== id) });
            },
            clearStickers: () => set({ stickers: [] }),
        }),
        {
            name: 'vibe-stickers-store',
            storage: createJSONStorage(() => AsyncStorage),
            version: 1,
        }
    )
);

