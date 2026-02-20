
import { create } from 'zustand';

type ToastType = 'success' | 'error' | 'info';

interface ToastItem {
    message: string;
    type: ToastType;
}

interface ToastState {
    visible: boolean;
    message: string;
    type: ToastType;
    queue: ToastItem[];
    showToast: (message: string, type?: ToastType) => void;
    hideToast: () => void;
}

export const useToastStore = create<ToastState>((set) => ({
    visible: false,
    message: '',
    type: 'info',
    queue: [],
    showToast: (message, type = 'info') => {
        set((state) => {
            if (state.visible) {
                return {
                    ...state,
                    queue: [...state.queue, { message, type }],
                };
            }
            return {
                ...state,
                visible: true,
                message,
                type,
            };
        });
    },
    hideToast: () => set((state) => {
        if (state.queue.length > 0) {
            const [next, ...rest] = state.queue;
            return {
                ...state,
                visible: true,
                message: next.message,
                type: next.type,
                queue: rest,
            };
        }
        return {
            ...state,
            visible: false,
        };
    }),
}));
