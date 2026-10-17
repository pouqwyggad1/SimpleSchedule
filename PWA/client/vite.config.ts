import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [react(), VitePWA({
    registerType: 'prompt',
    injectRegister: false,
    includeAssets: ['favicon.svg', 'icons/apple-touch-icon.png'],
    manifest: {
      id: '/', name: 'SimpleSchedule', short_name: 'SimpleSchedule',
      description: 'Ваши дела и расписание университета в одном календаре.',
      lang: 'ru', start_url: '/', scope: '/', display: 'standalone',
      background_color: '#F2F2F7', theme_color: '#F2F2F7',
      icons: [
        { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
        { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
        { src: '/icons/maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
      ],
    },
    workbox: {
      importScripts: ['/push-handler.js'],
      globPatterns: ['**/*.{js,css,html,svg,png,woff2,ico}'],
      navigateFallback: '/index.html',
      navigateFallbackDenylist: [/^\/api(?:\/|$)/, /^\/health(?:\/|$)/],
      // Cache only the app shell. Private API/auth data belongs in IndexedDB.
      runtimeCaching: [],
      cleanupOutdatedCaches: true,
    },
    devOptions: { enabled: false },
  })],
  server: { port: 5173, strictPort: true, proxy: { '/api': 'http://127.0.0.1:5080' } },
  preview: { port: 4173, strictPort: true },
  // Preserve both standard and WebKit glass filters in the production CSS.
  build: { target: 'safari17', cssTarget: ['safari17', 'chrome111'], sourcemap: false },
  test: { environment: 'node', include: ['src/**/*.test.ts', 'tests/**/*.unit.test.ts'] },
});
