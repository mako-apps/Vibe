/**
 * Privacy Settings Store
 * Controls metadata exposure to server and other users
 */

export interface PrivacySettings {
    // Online status - whether to show "online" indicator to other users
    showOnlineStatus: boolean;

    // Read receipts - whether to send read confirmations
    sendReadReceipts: boolean;

    // Typing indicators - whether to show "typing..." to other users
    showTypingIndicator: boolean;

    // Last seen - whether others can see when you were last active
    showLastSeen: boolean;
}

const STORAGE_KEY = 'vibe_privacy_settings';

const DEFAULT_SETTINGS: PrivacySettings = {
    showOnlineStatus: true,
    sendReadReceipts: true,
    showTypingIndicator: true,
    showLastSeen: true
};

class PrivacySettingsStore {
    private settings: PrivacySettings;
    private listeners: Set<(settings: PrivacySettings) => void> = new Set();

    constructor() {
        this.settings = this.load();
    }

    private load(): PrivacySettings {
        try {
            const stored = localStorage.getItem(STORAGE_KEY);
            if (stored) {
                return { ...DEFAULT_SETTINGS, ...JSON.parse(stored) };
            }
        } catch (e) {
            console.error('[Privacy] Failed to load settings:', e);
        }
        return { ...DEFAULT_SETTINGS };
    }

    private save(): void {
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify(this.settings));
            this.notifyListeners();
        } catch (e) {
            console.error('[Privacy] Failed to save settings:', e);
        }
    }

    private notifyListeners(): void {
        this.listeners.forEach(listener => listener(this.settings));
    }

    get(): PrivacySettings {
        return { ...this.settings };
    }

    update(partial: Partial<PrivacySettings>): void {
        this.settings = { ...this.settings, ...partial };
        this.save();
    }

    subscribe(listener: (settings: PrivacySettings) => void): () => void {
        this.listeners.add(listener);
        return () => this.listeners.delete(listener);
    }

    // Convenience getters
    canShowOnline(): boolean {
        return this.settings.showOnlineStatus;
    }

    canSendReadReceipts(): boolean {
        return this.settings.sendReadReceipts;
    }

    canShowTyping(): boolean {
        return this.settings.showTypingIndicator;
    }

    canShowLastSeen(): boolean {
        return this.settings.showLastSeen;
    }
}

export const privacySettings = new PrivacySettingsStore();
