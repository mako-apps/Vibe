import { cleanupOutdatedCaches, precacheAndRoute } from 'workbox-precaching';

cleanupOutdatedCaches();
precacheAndRoute(self.__WB_MANIFEST);

self.addEventListener('install', (event) => {
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
    const data = event.data.json();
    const title = data.title || 'SecureChat';

    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
            const isFocused = clientList.some((client) => client.focused);

            // If app is open and focused, do NOT show system notification (optional UX)
            // But for now, let's show it but maybe silent?
            // Actually, usually users want to know even if focused if it's a different chat?
            // Let's Stick to checking focus. If focused, maybe send message to client to play sound?

            if (isFocused) {
                // Send message to client to handle (e.g. play sound)
                clientList.forEach(client => client.postMessage({ type: 'PUSH_RECEIVED', data }));
                return;
            }

            // Background: Show Notification
            // Background: Show Notification
            return self.registration.showNotification(title, {
                body: data.body || 'New message',
                icon: '/icon-192.png', // Ensure icon path is correct
                badge: '/icon-192.png',
                vibrate: [200, 100, 200],
                tag: 'secure-chat-msg', // grouping
                renotify: true,
                requireInteraction: true,
                data: { url: '/' }
            });
        })
    );
});

self.addEventListener('notificationclick', (event) => {
    event.notification.close();
    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
            if (clientList.length > 0) {
                let client = clientList[0];
                for (let i = 0; i < clientList.length; i++) {
                    if (clientList[i].focused) {
                        client = clientList[i];
                    }
                }
                return client.focus();
            }
            return clients.openWindow('/');
        })
    );
});
