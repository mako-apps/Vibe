import { Check, Copy, Pencil, Pin, Reply, RotateCcw, Trash2 } from 'lucide-react-native';

export type BubbleMenuAction = 'reply' | 'copy' | 'edit' | 'pin' | 'delete' | 'select' | 'resend';

export interface BubbleMenuItem {
    id: BubbleMenuAction;
    label: string;
    icon: any;
    destructive?: boolean;
    dividerBefore?: boolean;
    onlyMine?: boolean;
    onlyText?: boolean;
    active?: boolean;
}

export const REACTION_PRESETS = ['❤️', '👍', '⭐', '👏', '🔥', '⚡'] as const;

const BASE_BUBBLE_MENU_ITEMS: BubbleMenuItem[] = [
    { id: 'reply', label: 'Reply', icon: Reply },
    { id: 'copy', label: 'Copy', icon: Copy, onlyText: true },
    { id: 'edit', label: 'Edit', icon: Pencil, onlyMine: true, onlyText: true },
    { id: 'pin', label: 'Pin', icon: Pin },
    { id: 'delete', label: 'Delete', icon: Trash2, destructive: true },
    { id: 'select', label: 'Select', icon: Check, dividerBefore: true },
];

interface ResolveOptions {
    isMine: boolean;
    hasText: boolean;
    isPinned: boolean;
    hasError: boolean;
}

export const resolveBubbleMenuItems = ({
    isMine,
    hasText,
    isPinned,
    hasError,
}: ResolveOptions): BubbleMenuItem[] => {
    const filtered = BASE_BUBBLE_MENU_ITEMS
        .filter((entry) => {
            if (entry.onlyMine && !isMine) return false;
            if (entry.onlyText && !hasText) return false;
            return true;
        })
        .map((entry) => {
            if (entry.id !== 'pin') return entry;
            return {
                ...entry,
                label: isPinned ? 'Unpin' : 'Pin',
                active: isPinned,
            };
        });

    if (hasError) {
        return [{ id: 'resend', label: 'Resend', icon: RotateCcw }, ...filtered];
    }

    return filtered;
};
