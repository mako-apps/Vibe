
import ConnectionManager from './ConnectionManager';

export const getApiUrl = () => {
    const url = ConnectionManager.getInstance().getServerUrl();
    if (typeof window !== 'undefined' && window.location.protocol === 'https:' && url.startsWith('http:')) {
        const secureUrl = url.replace('http:', 'https:');
        // console.log('[UTILS] Upgraded API URL:', secureUrl);
        return secureUrl;
    }
    // console.log('[UTILS] API URL:', url);
    return url;
};

export const formatTime = (ts: number) => {
    const d = new Date(ts);
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
};

export const timeAgo = (timestamp: number | string) => {
    const timeVal = new Date(timestamp).getTime();
    if (isNaN(timeVal)) return '';
    const now = Date.now();
    const seconds = Math.floor((now - timeVal) / 1000);
    if (seconds < 60) return 'Just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    return new Date(timestamp).toLocaleDateString();
};

export const formatDuration = (s: number) => {
    const mins = Math.floor(s / 60);
    const secs = s % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
};
