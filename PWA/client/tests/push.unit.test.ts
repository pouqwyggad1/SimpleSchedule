import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

function worker() {
  const handlers: Record<string, (event: unknown) => void> = {};
  const shown: { title: string; options: { body: string; data: { url: string } } }[] = [];
  const posted: unknown[] = []; const opened: string[] = [];
  const client = { url: 'https://schedule.example/', focus: async () => client, postMessage: (value: unknown) => posted.push(value) };
  const self = { location: { origin: 'https://schedule.example' }, addEventListener: (name: string, handler: typeof handlers[string]) => { handlers[name] = handler; }, registration: { showNotification: async (title: string, options: typeof shown[number]['options']) => { shown.push({ title, options }); } }, clients: { matchAll: async () => [client], openWindow: async (url: string) => { opened.push(url); } } };
  runInNewContext(readFileSync(new URL('../public/push-handler.js', import.meta.url), 'utf8'), { self, URL, Date });
  return { handlers, self, shown, posted, opened };
}
describe('push service worker', () => {
  it('shows a visible notification without fetching private data; constrains navigation to the app', async () => {
    const w = worker(); let waiting: Promise<void> | undefined;
    w.handlers.push({ data: { json: () => ({ title: 'Пара', body: 'Аудитория Б-100', url: 'https://attacker.invalid/', expiresAt: Date.now() + 10000 }) }, waitUntil: (promise: Promise<void>) => { waiting = promise; } });
    await waiting;
    expect(w.shown[0]).toMatchObject({ title: 'Пара', options: { body: 'Аудитория Б-100', data: { url: '/?mode=schedule' } } });
    w.handlers.notificationclick({ notification: { close() {}, data: { url: '/?mode=schedule&date=2026-10-18' } }, waitUntil: (promise: Promise<void>) => { waiting = promise; } });
    await waiting;
    expect(w.posted).toEqual([{ type: 'OPEN_SCHEDULE', url: '/?mode=schedule&date=2026-10-18' }]);
    expect(w.opened).toEqual([]);
  });
  it('opens the correct day when the app is closed; expired push remains visible without stale lesson details', async () => {
    const w = worker(); w.self.clients.matchAll = async () => [];
    let waiting: Promise<void> | undefined;
    w.handlers.notificationclick({ notification: { close() {}, data: { url: '/?mode=schedule&date=2026-10-18' } }, waitUntil: (promise: Promise<void>) => { waiting = promise; } }); await waiting;
    expect(w.opened).toEqual(['/?mode=schedule&date=2026-10-18']);
    w.handlers.push({ data: { json: () => ({ title: 'Через 5 минут', body: 'Уже прошедшая пара', expiresAt: 0 }) }, waitUntil: (promise: Promise<void>) => { waiting = promise; } }); await waiting;
    expect(w.shown[0].title).toBe('SimpleSchedule');
    expect(w.shown[0].options.body).not.toContain('Уже прошедшая');
  });
});
