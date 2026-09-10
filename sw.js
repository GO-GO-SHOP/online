self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    await self.registration.unregister();
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    await Promise.all(windows.map(async (client) => {
      const source = new URL(client.url);
      const target = new URL("https://gogoshop.nz/");
      if (source.pathname.toLowerCase().endsWith("/pos.html")) target.pathname = "/pos.html";
      target.search = source.search;
      target.hash = source.pathname.toLowerCase().endsWith("/gogoshop-admin.html") && !source.hash
        ? "#admin"
        : source.hash;
      try {
        await client.navigate(target.href);
      } catch (error) {}
    }));
  })());
});
