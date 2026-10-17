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
  await expect(page.locator('html')).toHaveCSS('background-color', 'rgb(24, 24, 26)');
  await expect(page.locator('meta[name="theme-color"]')).toHaveAttribute('content', '#18181A');
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

test('кнопки используют единое прозрачное стекло и контрастный цвет в обеих темах', async ({ page }, testInfo) => {
  for (const colorScheme of ['light', 'dark'] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' });
    const color = colorScheme === 'light' ? 'rgb(28, 28, 30)' : 'rgb(245, 245, 247)';
    for (const selector of ['.main-add', '.today-button', '.date-navigation .icon-button', '.settings-button', '.date-input', 'button.group-chip']) {
      for (const control of await page.locator(selector).all()) {
        if (!await control.isVisible()) continue;
        await expect(control, selector).toHaveCSS('color', color);
        const style = await control.evaluate(element => {
          const style = getComputedStyle(element);
          return { fill: style.backgroundColor, blur: style.backdropFilter, shadow: style.boxShadow };
        });
        const alpha = Number(style.fill.match(/[\d.]+/g)![3] ?? 1);
        expect(alpha, selector).toBeGreaterThan(0);
        expect(alpha, selector).toBeLessThan(.6);
        expect(style.blur, selector).toContain('blur');
        expect(style.shadow, selector).not.toBe('none');
      }
    }
    for (const control of await page.locator('.view-picker button, .mobile-mode-picker button').all()) {
      if (await control.isVisible()) await expect(control).toHaveCSS('color', color);
    }
    await page.screenshot({ path: testInfo.outputPath(`unified-${colorScheme}.png`) });
    await page.getByRole('button', { name: 'Настройки', exact: true }).click();
    const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
    for (const label of ['Готово', 'Закрыть окно', 'Аккаунт', 'Расписание']) {
      await expect(settings.getByRole('button', { name: label, exact: true })).toHaveCSS('color', color);
    }
    await page.screenshot({ path: testInfo.outputPath(`unified-settings-${colorScheme}.png`) });
    await settings.getByRole('button', { name: 'Готово', exact: true }).click();
    await page.locator('.main-add').click();
    const editor = page.getByRole('dialog', { name: 'Новое дело', exact: true });
    await editor.getByLabel('Название', { exact: true }).fill('Проверка вида кнопки');
    for (const label of ['Отмена', 'Сохранить']) await expect(editor.getByRole('button', { name: label, exact: true })).toHaveCSS('color', color);
    await editor.getByRole('button', { name: 'Отмена', exact: true }).click();
  }
});

test('настройки не сдвигаются горизонтально с длинным названием института и группы', async ({ page }, testInfo) => {
  await page.route('**/api/university/institutes', route => route.fulfill({ json: { options: [{ id: '683', name: 'Институт информационных технологий и анализа данных — образовательные программы и кафедры университета' }] } }));
  await page.route('**/api/university/groups?*', route => route.fulfill({ json: { options: [{ id: '478229', name: 'ИСИб-23-1 — Информационные системы и технологии' }] } }));
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Расписание', exact: true }).click();
  await settings.getByRole('button', { name: 'Обновить институты' }).click();
  await settings.getByLabel('Институт', { exact: true }).selectOption('683');
  await settings.getByLabel('Учебная группа', { exact: true }).selectOption('478229');
  for (const width of [320, 390, 600, 768]) {
    await page.setViewportSize({ width, height: 844 });
    for (const tab of ['Аккаунт', 'Расписание', 'Оформление', 'Уведомления', 'Данные и установка']) {
      await settings.getByRole('button', { name: tab, exact: true }).click();
      for (const selector of ['.modal-body', '.settings-layout', '.settings-tabs', '.settings-content', '.settings-section']) {
        for (const element of await settings.locator(selector).all()) {
          expect(await element.evaluate(node => node.scrollWidth <= node.clientWidth + 1), `${width}px ${tab} ${selector}`).toBe(true);
        }
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await settings.getByRole('button', { name: 'Расписание', exact: true }).click();
  await expect(settings.getByLabel('Учебная группа', { exact: true })).toHaveValue('478229');
  await page.screenshot({ path: testInfo.outputPath('settings-no-horizontal-shift.png') });
});
