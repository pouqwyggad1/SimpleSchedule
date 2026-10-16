import { test, expect, type Browser, type BrowserContext, type Page, type TestInfo } from '@playwright/test';
import type { Entity, Operation, OperationResult } from '../../src/core/types';

// Contract simulations only: no Supabase, Resend, real email, or production tokens.
// The mock deliberately handles serial operations; database concurrency/conflicts
// remain covered by the server and core tests, rather than reimplemented here.
function contractServer() {
  const accounts = new Map<string, { id: string; email: string; revision: number; records: Map<string, Entity>; results: Map<string, OperationResult> }>();
  const sessions = new Map<string, string>();
  const requestedEmails: string[] = [];
  let sequence = 0;
  let acceptedOperations = 0;

  async function connect(context: BrowserContext) {
    await context.route('**/api/**', async route => {
      const request = route.request();
      const path = new URL(request.url()).pathname;
      const headers = Object.fromEntries(Object.entries(await request.allHeaders()).map(([name, value]) => [name.toLowerCase(), value]));
      // WebKit omits Cookie from intercepted request headers. Read the fake
      // session from its actual cookie jar in that case; this does not verify
      // production HTTP cookie transport, which belongs in server checks.
      const token = headers.cookie?.split(';').map(value => value.trim()).find(value => value.startsWith('SS_CONTRACT_SESSION='))?.split('=')[1]
        ?? (await context.cookies(request.url())).find(cookie => cookie.name === 'SS_CONTRACT_SESSION')?.value;
      const email = token && sessions.get(token);
      const account = email ? accounts.get(email) : undefined;
      const user = account ? { id: account.id, email: account.email } : null;
      const json = (body: unknown, status = 200, extraHeaders: Record<string, string> = {}) => route.fulfill({ status, json: body, headers: { 'Cache-Control': 'no-store', ...extraHeaders } });

      if (path === '/api/auth/session') return json({ configured: true, user });
      if (path === '/api/auth/request-code') {
        const body = request.postDataJSON() as { email: string };
        requestedEmails.push(body.email);
        return json({ retryAfterSeconds: 60 });
      }
      if (path === '/api/auth/verify-code') {
        const body = request.postDataJSON() as { email: string; code: string };
        if (!requestedEmails.includes(body.email) || body.code !== '123456') return json({ error: 'Неверный тестовый код' }, 400);
        let next = accounts.get(body.email);
        if (!next) {
          next = { id: `contract-account-${accounts.size + 1}`, email: body.email, revision: 0, records: new Map(), results: new Map() };
          accounts.set(body.email, next);
        }
        const nextToken = `contract-session-${++sequence}`;
        sessions.set(nextToken, body.email);
        return json({ configured: true, user: { id: next.id, email: next.email } }, 200, { 'Set-Cookie': `SS_CONTRACT_SESSION=${nextToken}; HttpOnly; SameSite=Strict; Path=/` });
      }
      if (path === '/api/auth/sign-out') {
        if (token) sessions.delete(token);
        return json({}, 200, { 'Set-Cookie': 'SS_CONTRACT_SESSION=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0' });
      }
      if (path === '/api/sync') {
        if (!account || headers['x-simpleschedule-account'] !== account.id) return json({ error: 'Требуется вход в этот аккаунт' }, 401);
        const operations = request.method() === 'POST' ? (request.postDataJSON() as { operations: Operation[] }).operations : [];
        const results = operations.map(operation => {
          const previousResult = account.results.get(operation.operationId);
          if (previousResult) return previousResult;
          const current = account.records.get(operation.entityId);
          const record: Entity = {
            id: operation.entityId, kind: operation.kind, version: ++account.revision,
            data: operation.data ?? current?.data ?? {}, deleted: operation.data === null,
          };
          const result: OperationResult = { operationId: operation.operationId, status: 'applied', record, conflictingFields: [] };
          account.records.set(record.id, record);
          account.results.set(operation.operationId, result);
          acceptedOperations++;
          return result;
        });
        return json({ records: [...account.records.values()], results, revision: account.revision });
      }
      return json({ error: `Unexpected contract route: ${path}` }, 501);
    });
  }

  return {
    connect,
    operationCount: () => acceptedOperations,
    tasks: (email: string) => [...(accounts.get(email)?.records.values() ?? [])].filter(record => record.kind === 'task' && !record.deleted),
  };
}

async function openClient(browser: Browser, baseURL: string, server: ReturnType<typeof contractServer>, contextOptions: Parameters<Browser['newContext']>[0] = {}) {
  // WebKit service-worker requests bypass Playwright routing. Actual offline
  // shell/reload behavior is tested by planner.spec.ts with the real worker;
  // these account contract tests keep every API request inside the fake server.
  const context = await browser.newContext({ ...contextOptions, baseURL, serviceWorkers: 'block' });
  await server.connect(context);
  const page = await context.newPage();
  await page.clock.setFixedTime(new Date('2026-10-16T04:00:00Z'));
  await page.goto('/');
  await expect(page.getByRole('link', { name: 'SimpleSchedule — сегодня' })).toBeVisible();
  return { context, page };
}

function deviceOptions(info: TestInfo) {
  const { viewport, screen, userAgent, deviceScaleFactor, isMobile, hasTouch, locale, timezoneId, colorScheme } = info.project.use;
  return { viewport, screen, userAgent, deviceScaleFactor, isMobile, hasTouch, locale, timezoneId, colorScheme };
}

async function signIn(page: Page, email: string) {
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByLabel('Ваша почта', { exact: true }).fill(email);
  await settings.getByRole('button', { name: 'Получить код', exact: true }).click();
  await settings.getByLabel('Код из письма', { exact: true }).fill('123456');
  await settings.getByRole('button', { name: 'Войти', exact: true }).click();
  await expect(settings.locator('.account-card')).toContainText(email);
  await settings.getByRole('button', { name: 'Готово', exact: true }).click();
}

async function signOut(page: Page) {
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Выйти из аккаунта', exact: true }).click();
  await expect(settings.getByLabel('Ваша почта', { exact: true })).toBeVisible();
  await settings.getByRole('button', { name: 'Готово', exact: true }).click();
}

async function createTask(page: Page, title: string) {
  await page.locator('.main-add').click();
  const dialog = page.getByRole('dialog', { name: 'Новое дело', exact: true });
  await dialog.getByLabel('Название', { exact: true }).fill(title);
  await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(dialog).not.toBeVisible();
}

async function synchronize(page: Page) {
  const button = page.getByRole('button', { name: 'Синхронизировать', exact: true });
  await expect(button).toBeEnabled();
  const response = page.waitForResponse(response => new URL(response.url()).pathname === '/api/sync' && response.ok());
  await button.click();
  await response;
  await expect(button).toBeEnabled();
}

test('contract simulation: вход, сохранение сессии и обмен делом между двумя устройствами', async ({ browser, baseURL }, testInfo) => {
  const server = contractServer();
  const deviceA = await openClient(browser, baseURL!, server, deviceOptions(testInfo));
  const deviceB = await openClient(browser, baseURL!, server, deviceOptions(testInfo));
  const email = 'same-account@example.test';
  try {
    await signIn(deviceA.page, email);
    await signIn(deviceB.page, email);
    await deviceA.page.reload();
    await expect(deviceA.page.locator('.footer-sync')).toBeVisible();
    expect(await deviceA.page.evaluate(() => document.cookie)).not.toContain('SS_CONTRACT_SESSION');

    await createTask(deviceA.page, 'Проверить расписание вместе');
    await synchronize(deviceA.page);
    await expect.poll(() => server.tasks(email).length).toBe(1);
    await synchronize(deviceB.page);
    await expect(deviceB.page.getByRole('button', { name: 'Изменить дело «Проверить расписание вместе»' })).toBeVisible();

    await deviceB.page.getByRole('button', { name: 'Выполнить «Проверить расписание вместе»' }).click();
    await synchronize(deviceB.page);
    await synchronize(deviceA.page);
    await expect(deviceA.page.getByRole('button', { name: 'Вернуть «Проверить расписание вместе» в невыполненные' })).toHaveAttribute('aria-pressed', 'true');
    expect(server.tasks(email)[0].data.completed).toBe(true);
  } finally { await deviceA.context.close(); await deviceB.context.close(); }
});

test('contract simulation: офлайн-очередь отправляется после восстановления сети, аккаунт и гость изолированы', async ({ browser, baseURL }, testInfo) => {
  const server = contractServer();
  const deviceA = await openClient(browser, baseURL!, server, deviceOptions(testInfo));
  const deviceB = await openClient(browser, baseURL!, server, deviceOptions(testInfo));
  const ownerEmail = 'offline-owner@example.test';
  try {
    await signIn(deviceA.page, ownerEmail);
    await signIn(deviceB.page, ownerEmail);
    await deviceA.page.reload();
    await expect(deviceA.page.locator('.footer-sync')).toBeVisible();
    const beforeOffline = server.operationCount();
    await deviceA.context.setOffline(true);
    await expect(deviceA.page.locator('.sync-indicator')).toContainText('Без сети');
    await createTask(deviceA.page, 'Сохранено без интернета');
    await expect(deviceA.page.getByRole('button', { name: 'Изменить дело «Сохранено без интернета»' })).toBeVisible();
    expect(server.operationCount()).toBe(beforeOffline);
    expect(server.tasks(ownerEmail)).toHaveLength(0);

    await deviceA.context.setOffline(false);
    await expect.poll(() => server.tasks(ownerEmail).length).toBe(1);
    await deviceA.page.reload();
    await expect(deviceA.page.getByRole('button', { name: 'Изменить дело «Сохранено без интернета»' })).toBeVisible();
    await synchronize(deviceB.page);
    await expect(deviceB.page.getByRole('button', { name: 'Изменить дело «Сохранено без интернета»' })).toBeVisible();
    await signOut(deviceA.page);
    await expect(deviceA.page.getByRole('button', { name: 'Изменить дело «Сохранено без интернета»' })).toHaveCount(0);
    await deviceA.page.reload();
    await expect(deviceA.page.locator('.footer-sync')).toHaveCount(0);
    await signIn(deviceA.page, 'another-account@example.test');
    await expect(deviceA.page.getByRole('button', { name: 'Изменить дело «Сохранено без интернета»' })).toHaveCount(0);
    await createTask(deviceA.page, 'Только другой аккаунт');
    await synchronize(deviceA.page);
    await synchronize(deviceB.page);
    await expect(deviceB.page.getByRole('button', { name: 'Изменить дело «Только другой аккаунт»' })).toHaveCount(0);
    await expect(deviceB.page.getByRole('button', { name: 'Изменить дело «Сохранено без интернета»' })).toBeVisible();
  } finally { await deviceA.context.close(); await deviceB.context.close(); }
});
