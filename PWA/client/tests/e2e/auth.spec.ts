import { test, expect, type Page } from '@playwright/test';

async function openAccount(page: Page) {
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  return page.getByRole('dialog', { name: 'Настройки', exact: true });
}

test.beforeEach(async ({ page }) => {
  // All auth traffic is local test data; these checks never send email.
  await page.route('**/api/**', route => route.fulfill({ status: 404, json: { error: 'Неизвестный тестовый запрос' } }));
  await page.route('**/api/auth/session', route => route.fulfill({ json: { configured: true, user: null } }));
  await page.clock.install({ time: new Date('2026-10-16T15:00:00Z') });
});

test('код: ожидание повторной отправки сохраняется после закрытия, проверка кода доступна', async ({ page }) => {
  let sends = 0; let verifications = 0;
  await page.route('**/api/auth/request-code', route => { sends++; return route.fulfill({ json: { retryAfterSeconds: 60 } }); });
  await page.route('**/api/auth/verify-code', route => { verifications++; return route.fulfill({ status: 400, json: { error: 'Тестовый код не подошёл' } }); });
  await page.goto('/');
  let settings = await openAccount(page);
  await settings.getByLabel('Ваша почта').fill('person@example.com');
  await settings.getByRole('button', { name: 'Получить код', exact: true }).click();
  await expect(settings.getByRole('status')).toContainText('через 60 с.');
  await expect(settings.getByRole('button', { name: 'Отправить код ещё раз' })).toBeDisabled();
  await settings.getByLabel('Код из письма').fill('123456');
  await expect(settings.getByRole('button', { name: 'Войти', exact: true })).toBeEnabled();
  await settings.getByRole('button', { name: 'Войти', exact: true }).click();
  await expect(settings.getByRole('alert')).toContainText('Тестовый код не подошёл');
  expect(verifications).toBe(1);
  expect(sends).toBe(1);
  await settings.getByRole('button', { name: 'Готово', exact: true }).click();
  settings = await openAccount(page);
  await settings.getByLabel('Ваша почта').fill('PERSON@example.com');
  await expect(settings.getByRole('button', { name: 'Получить код', exact: true })).toBeDisabled();
  await settings.getByRole('button', { name: 'У меня уже есть код' }).click();
  await settings.getByLabel('Код из письма').fill('123456');
  await expect(settings.getByRole('button', { name: 'Войти', exact: true })).toBeEnabled();
  await settings.getByLabel('Ваша почта').fill('another@example.com');
  await expect(settings.getByRole('button', { name: 'Получить код', exact: true })).toBeEnabled();
  await settings.getByLabel('Ваша почта').fill('person@example.com');
  await expect(settings.getByRole('button', { name: 'Получить код', exact: true })).toBeDisabled();
  await page.clock.fastForward(61_000);
  await expect(settings.getByRole('button', { name: 'Получить код', exact: true })).toBeEnabled();
  expect(sends).toBe(1);
});

test('ответ 429: показывается срок ожидания сервера, повторный запрос и двойное нажатие не отправляются', async ({ page }) => {
  let sends = 0;
  let releaseFirst!: () => void;
  const firstReady = new Promise<void>(resolve => { releaseFirst = resolve; });
  await page.route('**/api/auth/request-code', async route => {
    sends++;
    if (sends === 1) await firstReady;
    return route.fulfill({ status: 429, headers: { 'Retry-After': '25' }, json: { error: 'Почтовый сервис просит подождать', retryAfterSeconds: 60 } });
  });
  await page.goto('/');
  const settings = await openAccount(page);
  await settings.getByLabel('Ваша почта').fill('person@example.com');
  const send = settings.getByRole('button', { name: 'Получить код', exact: true });
  // Dispatch twice in one browser task, before React can rerender disabled state.
  await send.evaluate(button => { button.dispatchEvent(new MouseEvent('click', { bubbles: true })); button.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
  await expect.poll(() => sends).toBe(1);
  releaseFirst();
  await expect(settings.getByRole('alert')).toHaveText('Почтовый сервис просит подождать');
  await expect(settings.getByRole('status')).toContainText('через 25 с.');
  await expect(send).toBeDisabled();
  await settings.getByRole('button', { name: 'У меня уже есть код' }).click();
  await settings.getByLabel('Код из письма').fill('123456');
  await expect(settings.getByRole('button', { name: 'Войти', exact: true })).toBeEnabled();
  await settings.getByLabel('Ваша почта').fill('another@example.com');
  await settings.getByLabel('Ваша почта').fill('person@example.com');
  await page.clock.fastForward(24_000);
  await expect(send).toBeDisabled();
  await page.clock.fastForward(2000);
  await expect(send).toBeEnabled();
  await send.click();
  await expect.poll(() => sends).toBe(2);
});
