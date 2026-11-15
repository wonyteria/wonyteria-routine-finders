const CACHE_VERSION = 'v2';
const CACHE_NAME = `routine-finders-${CACHE_VERSION}`;
const OFFLINE_URL = '/offline';

// Assets to cache on install
const PRECACHE_ASSETS = [
    '/offline',
    '/icon-192.png',
    '/pwa-icon-512.png'
];

// Install event - cache essential assets
self.addEventListener('install', (event) => {
    event.waitUntil(
        Promise.all(PRECACHE_ASSETS.map(async path => {
            const response = await fetch(new Request(new URL(path, self.location.origin), {
                credentials: 'omit', cache: 'reload', redirect: 'error'
            }));
            if (!cacheableResponse(response)) throw new Error('Unsafe precache response');
            return [path, response];
        })).then(async entries => {
            const cache = await caches.open(CACHE_NAME);
            await Promise.all(entries.map(([path, response]) => cache.put(path, response)));
        }).then(() => self.skipWaiting())
    );
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then(cacheNames => {
            return Promise.all(
                cacheNames
                    .filter(cacheName => cacheName.startsWith('routine-finders-') && cacheName !== CACHE_NAME)
                    .map(cacheName => caches.delete(cacheName))
            );
        }).then(() => self.clients.claim())
    );
});

// Cache only app-owned public assets. Personalized documents, auth/API responses,
// mutations and redirects must never enter Cache Storage, even with HTTP 200.
function cacheableRequest(request) {
    const url = new URL(request.url);
    return request.method === 'GET' && url.origin === self.location.origin &&
        (url.pathname.startsWith('/assets/') || PRECACHE_ASSETS.includes(url.pathname));
}

function cacheableResponse(response) {
    return response.ok && response.type === 'basic' && !response.redirected &&
        !/(?:private|no-store)/i.test(response.headers.get('cache-control') || '') &&
        !/(?:cookie|authorization)/i.test(response.headers.get('vary') || '');
}

self.addEventListener('fetch', (event) => {
    const request = event.request;
    const url = new URL(request.url);
    if (request.method !== 'GET' || url.origin !== self.location.origin) return;

    event.respondWith((async () => {
        try {
            const response = await fetch(request, url.pathname === '/manifest.json' ? { cache: 'no-cache' } : undefined);
            if (cacheableRequest(request) && cacheableResponse(response)) {
                const responseForCache = response.clone();
                event.waitUntil(caches.open(CACHE_NAME)
                    .then(cache => cache.put(request, responseForCache))
                    .catch(() => {}));
            }
            return response;
        } catch {
            const cache = await caches.open(CACHE_NAME);
            if (request.mode === 'navigate') {
                return (await cache.match(OFFLINE_URL)) || new Response('오프라인 상태입니다.', {
                    status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' }
                });
            }
            if (cacheableRequest(request)) {
                const cached = await cache.match(request);
                if (cached) return cached;
            }
            return Response.error();
        }
    })());
});

// Push notification event
self.addEventListener("push", async (event) => {
    const data = event.data ? event.data.json() : {};
    const title = data.title || '루틴 파인더스';
    const options = {
        body: data.body || data.content || '새로운 알림이 있습니다.',
        icon: '/rf_logo.png',
        badge: '/rf_logo.png',
        data: {
            url: data.url || data.link || '/'
        },
        tag: data.tag || 'default',
        requireInteraction: false
    };

    event.waitUntil(
        self.registration.showNotification(title, options)
    );
});

// Notification click event
self.addEventListener("notificationclick", function (event) {
    event.notification.close();

    const urlToOpen = event.notification.data?.url || '/';

    event.waitUntil(
        clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
            // Check if there's already a window open
            for (let i = 0; i < clientList.length; i++) {
                let client = clientList[i];
                if (client.url === urlToOpen && 'focus' in client) {
                    return client.focus();
                }
            }

            // If no window is open, open a new one
            if (clients.openWindow) {
                return clients.openWindow(urlToOpen);
            }
        })
    );
});
