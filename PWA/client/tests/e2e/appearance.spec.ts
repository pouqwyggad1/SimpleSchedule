import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  await page.route('**/api/auth/session', route => route.fulfill({ json: { configured: false, user: null } }));
  await page.clock.setFixedTime(new Date('2026-10-17T04:00:00Z'));
  await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'reduce' });
  await page.goto('/');
});

test('системная тема меняется на лету; ручной выбор и непрозрачное стекло сохраняются', async ({ page }) => {
  await expect(page.locator('html')).not.toHaveAttribute('data-theme');
  await expect(page.locator('html')).toHaveCSS('background-color', 'rgb(242, 242, 247)');
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
  await expect(page.locator('html')).toHaveCSS('background-color', 'rgb(0, 0, 0)');
  await expect(page.locator('meta[name="theme-color"]')).toHaveAttribute('content', '#000000');
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await dialog.getByRole('button', { name: 'Оформление', exact: true }).click();
  await dialog.getByRole('radio', { name: 'Светлая', exact: true }).check();
  await expect(page.locator('html')).toHaveCSS('background-color', 'rgb(242, 242, 247)');
  await dialog.getByRole('slider').press('Home');
  await expect(page.locator('html')).toHaveAttribute('data-reduce-transparency', 'true');
  await expect(page.locator('.view-picker')).toHaveCSS('backdrop-filter', 'none');
  await dialog.getByRole('button', { name: 'Готово', exact: true }).click();
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(page.locator('html')).toHaveAttribute('data-reduce-transparency', 'true');
});

test('адаптивные панели без переполнения, цели касания и стабильный центр', async ({ page }) => {
  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    const picker = await page.locator('.view-picker').boundingBox();
    expect(Math.abs(picker!.x + picker!.width / 2 - width / 2)).toBeLessThanOrEqual(1);
    for (const selector of ['.date-navigation .icon-button', '.today-button', '.main-add', '.settings-button']) {
      const bounds = await page.locator(selector).first().boundingBox();
      expect(bounds!.width, selector).toBeGreaterThanOrEqual(44);
      expect(bounds!.height, selector).toBeGreaterThanOrEqual(44);
    }
    await page.getByRole('button', { name: 'Включить режим расписания', exact: true }).click();
    expect(await page.locator('.view-picker').boundingBox()).toEqual(picker);
    await page.getByRole('button', { name: 'Переключиться к делам', exact: true }).click();
  }
});

test('формы удерживают и возвращают фокус; светлая и тёмная темы, reduced motion', async ({ page }, testInfo) => {
  await page.locator('.main-add').click();
  const dialog = page.getByRole('dialog', { name: 'Новое дело', exact: true });
  await dialog.getByLabel('Название', { exact: true }).fill('Подготовить проект');
  await dialog.getByLabel(/Заметка/).fill('Проверить материалы и записать идеи');
  await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await page.getByRole('button', { name: 'День', exact: true }).click();
  for (const colorScheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' });
    await expect(page.locator('.single-day')).toHaveCSS('backdrop-filter', 'none');
    const contrast = await page.locator('.single-day').evaluate(element => {
      const luminance = (value: string) => {
        const rgb = value.match(/[\d.]+/g)!.slice(0, 3).map(Number).map(n => n / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4);
        return .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2];
      };
      const style = getComputedStyle(element), a = luminance(style.color), b = luminance(style.backgroundColor);
      return (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
    });
    expect(contrast).toBeGreaterThan(7);
    await page.screenshot({ path: testInfo.outputPath(`glass-${colorScheme}.png`), fullPage: true });
  }
  await page.getByRole('button', { name: 'Настройки', exact: true }).focus();
  await page.keyboard.press('Enter');
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Оформление', exact: true }).click();
  await page.screenshot({ path: testInfo.outputPath('glass-appearance.png') });
  await settings.getByRole('button', { name: 'Готово', exact: true }).focus();
  await page.keyboard.press('Tab');
  expect(await settings.evaluate(element => element.contains(document.activeElement))).toBe(true);
  await page.keyboard.press('Escape');
  await expect(settings).not.toBeVisible();
  await expect(page.getByRole('button', { name: 'Настройки', exact: true })).toBeFocused();
  await page.emulateMedia({ contrast: 'more', reducedMotion: 'reduce' });
  await expect(page.locator('.view-picker')).toHaveCSS('backdrop-filter', 'none');
  await expect(page.locator('.view-picker')).toHaveCSS('transition-duration', '0s');
});
