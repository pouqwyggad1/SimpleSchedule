import { expect, test } from '@playwright/test';

test('на iPhone предлагается установка; разрешение не запрашивается при открытии', async ({ page }, testInfo) => {
  await page.route('**/api/auth/session', route => route.fulfill({ json: { configured: true, user: { id: 'push-contract', email: 'test@example.test' } } }));
  await page.route('**/api/sync', route => route.fulfill({ json: { records: [], results: [], revision: 0 } }));
  await page.route('**/api/push/config', route => route.fulfill({ json: { configured: false, publicKey: '' } }));
  await page.goto('/?mode=schedule&date=2026-10-18');
  await expect(page.getByRole('button', { name: 'Переключиться к делам', exact: true })).toBeVisible();
  await expect(page.locator('input[type=date]').first()).toHaveValue('2026-10-18');
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Уведомления', exact: true }).click();
  await expect(settings.getByRole('heading', { name: 'На этом устройстве' })).toBeVisible();
  expect(await settings.evaluate(element => getComputedStyle(element).maxHeight)).not.toBe('none');
  expect((await settings.boundingBox())!.height).toBeLessThanOrEqual(page.viewportSize()!.height);
  if (testInfo.project.name === 'iphone-webkit') {
    await expect(settings.getByText(/На iPhone откройте сайт в Safari/)).toBeVisible();
    await expect(settings.getByRole('button', { name: 'Подключить уведомления' })).toHaveCount(0);
  }
  await expect(settings.getByText('Будущая функция.')).toHaveCount(0);
});

test('установленная PWA подключается только по нажатию; проверка и отключение привязаны к аккаунту', async ({ page }) => {
  let connected = false; const requests: string[] = [];
  await page.addInitScript(() => {
    let subscription: unknown = null;
    Object.defineProperty(navigator, 'standalone', { value: true });
    Object.defineProperty(window, 'PushManager', { value: class {} });
    Object.defineProperty(window, 'Notification', { value: class {
      static permission = 'default';
      static async requestPermission() { localStorage.setItem('testPermissionRequests', String(Number(localStorage.getItem('testPermissionRequests') || 0) + 1)); this.permission = 'granted'; return 'granted'; }
    } });
    const pushManager = { getSubscription: async () => subscription, subscribe: async () => {
      subscription = { endpoint: 'https://web.push.apple.com/test-contract', toJSON: () => ({ keys: { p256dh: 'test', auth: 'test' } }), unsubscribe: async () => { subscription = null; return true; } }; return subscription;
    } };
    Object.defineProperty(navigator.serviceWorker, 'ready', { get: () => Promise.resolve({ pushManager }) });
  });
  await page.route('**/api/**', async route => {
    const request = route.request(); const path = new URL(request.url()).pathname;
    if (path === '/api/auth/session') return route.fulfill({ json: { configured: true, user: { id: 'push-contract', email: 'test@example.test' } } });
    if (path === '/api/sync') return route.fulfill({ json: { records: [], results: [], revision: 0 } });
    if (path === '/api/push/config') return route.fulfill({ json: { configured: true, publicKey: 'BA' + 'A'.repeat(85) } });
    expect(request.headers()['x-simpleschedule-account']).toBe('push-contract');
    if (path === '/api/push/device') return route.fulfill({ json: { registered: connected } });
    requests.push(path);
    if (path === '/api/push/register') { expect(request.postDataJSON().deviceId).toMatch(/^[0-9a-f-]{36}$/); connected = true; return route.fulfill({ json: { registered: true } }); }
    if (path === '/api/push/unregister') { connected = false; return route.fulfill({ json: { removed: true } }); }
    if (path === '/api/push/test') return route.fulfill({ json: { sent: true } });
    return route.fulfill({ status: 404, json: {} });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Уведомления', exact: true }).click();
  const connect = settings.getByRole('button', { name: 'Подключить уведомления', exact: true });
  await expect(connect).toBeEnabled();
  expect(await page.evaluate(() => localStorage.getItem('testPermissionRequests'))).toBeNull();
  await connect.click();
  const disconnect = settings.getByRole('button', { name: 'Отключить это устройство', exact: true });
  await expect(disconnect).toBeEnabled();
  expect(await page.evaluate(() => localStorage.getItem('testPermissionRequests'))).toBe('1');
  await settings.getByRole('button', { name: 'Проверить уведомление', exact: true }).click();
  await expect(disconnect).toBeEnabled(); await disconnect.click();
  await expect(connect).toBeEnabled();
  expect(requests).toEqual(['/api/push/register', '/api/push/test', '/api/push/unregister']);
});
