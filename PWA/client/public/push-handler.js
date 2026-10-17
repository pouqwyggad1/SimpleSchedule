/* Imported into the generated Workbox worker; no private API caching. */
self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { /* Always show a visible fallback on iOS. */ }
  const expired = typeof data.expiresAt === 'number' && data.expiresAt < Date.now();
  // Web Push is userVisibleOnly: never silently discard an event on iOS.
  event.waitUntil(self.registration.showNotification(expired ? 'SimpleSchedule' : String(data.title || 'SimpleSchedule').slice(0, 240), {
    body: expired ? 'В расписании есть обновление. Откройте приложение, чтобы увидеть актуальные занятия.' : String(data.body || 'Откройте приложение, чтобы посмотреть расписание.').slice(0, 600),
    icon: '/icons/icon-192.png', badge: '/icons/icon-192.png', tag: String(data.tag || 'simpleschedule').slice(0, 600),
    data: { url: safePushUrl(data.url) },
  }));
});
function safePushUrl(value) {
  try {
    const url = new URL(value, self.location.origin);
    if (url.origin !== self.location.origin || url.pathname !== '/') return '/?mode=schedule';
    const result = new URL('/?mode=schedule', self.location.origin);
    if (/^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get('date') || '')) result.searchParams.set('date', url.searchParams.get('date'));
    return result.pathname + result.search;
  } catch { return '/?mode=schedule'; }
}
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = safePushUrl(event.notification.data?.url);
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const existing = clients.find(client => new URL(client.url).origin === self.location.origin);
    if (existing) { await existing.focus(); existing.postMessage({ type: 'OPEN_SCHEDULE', url }); return; }
    await self.clients.openWindow(url);
  })());
});
