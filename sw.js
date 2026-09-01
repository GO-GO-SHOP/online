const ADMIN_FALLBACK_URL = new URL("./#admin", self.registration.scope).href;

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || ADMIN_FALLBACK_URL;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const existingWindow = windows.find((client) => new URL(client.url).origin === self.location.origin);
    if (existingWindow) {
      if ("navigate" in existingWindow) await existingWindow.navigate(targetUrl);
      return existingWindow.focus();
    }
    return self.clients.openWindow(targetUrl);
  })());
});
