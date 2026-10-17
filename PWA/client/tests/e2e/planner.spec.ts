import { test, expect, type Page } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  await page.route('**/api/auth/session', route => route.fulfill({ json: { configured: false, user: null } }));
  await page.clock.setFixedTime(new Date('2026-10-16T04:00:00Z'));
  await page.goto('/');
  await expect(page.getByRole('link', { name: 'SimpleSchedule — сегодня' })).toBeVisible();
});

async function createTask(page: Page, title: string) {
  await page.locator('.main-add').click();
  const dialog = page.getByRole('dialog', { name: 'Новое дело', exact: true });
  await dialog.getByLabel('Название', { exact: true }).fill(title);
  await dialog.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(dialog).not.toBeVisible();
}

test('дата сохраняется, неделя содержит семь колонок, геометрия режимов одинакова', async ({ page }) => {
  await page.locator('.date-input').fill('2028-02-29');
  for (const label of ['Неделя', 'День', 'Месяц']) {
    await page.getByRole('button', { name: label, exact: true }).click();
    await expect(page.locator('.date-input')).toHaveValue('2028-02-29');
  }
  const before = await page.locator('.view-picker').boundingBox();
  const addBefore = await page.locator('.main-add').boundingBox();
  const gridBefore = await page.locator('.month-grid').boundingBox();
  await page.getByRole('button', { name: 'Включить режим расписания' }).click();
  const after = await page.locator('.view-picker').boundingBox();
  const addAfter = await page.locator('.main-add').boundingBox();
  const gridAfter = await page.locator('.month-grid').boundingBox();
  for (const key of ['x', 'y', 'width', 'height'] as const) {
    expect(Math.abs(before![key] - after![key])).toBeLessThanOrEqual(1);
    expect(Math.abs(addBefore![key] - addAfter![key])).toBeLessThanOrEqual(1);
    expect(Math.abs(gridBefore![key] - gridAfter![key])).toBeLessThanOrEqual(1);
  }
  await page.getByRole('button', { name: 'Неделя', exact: true }).click();
  await expect(page.locator('.week-column')).toHaveCount(7);
  await expect(page.locator('.week-column-heading.weekend')).toHaveCount(2);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
});

test('дело, группа из формы, выполнение, редактирование и удаление группы без потери дела', async ({ page }) => {
  await page.locator('.main-add').click();
  const task = page.getByRole('dialog', { name: 'Новое дело', exact: true });
  await expect(task.getByRole('button', { name: 'Сохранить', exact: true })).toBeDisabled();
  await task.getByLabel('Название', { exact: true }).fill('Подготовить лабораторную');
  await task.getByRole('button', { name: 'Создать новую группу' }).click();
  const group = page.getByRole('dialog', { name: 'Новая группа', exact: true });
  await group.getByLabel('Название группы').fill('Учёба');
  await group.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(group).not.toBeVisible();
  await task.getByLabel('Группа', { exact: true }).selectOption({ label: 'Учёба' });
  await task.getByLabel(/Заметка/).fill('Сохранённая личная заметка');
  await task.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Изменить дело «Подготовить лабораторную»' })).toBeVisible();
  await page.getByRole('button', { name: 'Выполнить «Подготовить лабораторную»' }).click();
  await expect(page.getByRole('button', { name: 'Вернуть «Подготовить лабораторную» в невыполненные' })).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('button', { name: 'Изменить дело «Подготовить лабораторную»' }).click();
  const edit = page.getByRole('dialog', { name: 'Изменить дело', exact: true });
  await expect(edit.getByLabel(/Заметка/)).toHaveValue('Сохранённая личная заметка');
  await edit.getByLabel('Название', { exact: true }).fill('Сдать лабораторную');
  await edit.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await page.locator('.groups-manage').click();
  await page.getByRole('button', { name: /Удалить группу/ }).click();
  const confirm = page.getByRole('dialog', { name: 'Удалить группу?', exact: true });
  await confirm.getByRole('button', { name: 'Удалить', exact: true }).click();
  await page.getByRole('dialog', { name: 'Группы', exact: true }).getByRole('button', { name: 'Готово' }).click();
  const row = page.locator('.task-row').filter({ hasText: 'Сдать лабораторную' });
  await expect(row).toContainText('Без группы');
  await page.reload();
  await expect(page.getByRole('button', { name: 'Изменить дело «Сдать лабораторную»' })).toBeVisible();
});

test('ручное занятие, автоокончание и личное домашнее задание', async ({ page }) => {
  await page.getByRole('button', { name: 'Включить режим расписания' }).click();
  await page.locator('.main-add').click();
  const editor = page.getByRole('dialog', { name: 'Новое занятие' });
  await editor.getByLabel('Предмет', { exact: true }).fill('Лабораторная по физике');
  await editor.getByLabel('Вид занятия', { exact: true }).fill('Лабораторная работа');
  await editor.getByLabel('Начало', { exact: true }).fill('11:45');
  await expect(editor.getByLabel('Окончание', { exact: true })).toHaveValue('13:15');
  await editor.getByLabel('Окончание', { exact: true }).fill('13:20');
  await editor.getByLabel('Начало', { exact: true }).fill('11:50');
  await expect(editor.getByLabel('Окончание', { exact: true })).toHaveValue('13:20');
  await editor.getByLabel('Аудитория', { exact: true }).fill('Б-100');
  await editor.getByLabel('Преподаватель', { exact: true }).fill('Иванов И. И.');
  await editor.getByLabel('Домашнее задание', { exact: true }).fill('Прочитать раздел 3');
  await editor.getByRole('button', { name: 'Сохранить', exact: true }).click();
  const card = page.locator('.lesson-card');
  await expect(card).toHaveClass(/laboratory/);
  await expect(card).toContainText('11:50');
  await expect(card).toContainText('Б-100');
  await expect(card).toContainText('Прочитать раздел 3');
  await page.getByRole('button', { name: 'День', exact: true }).click();
  await expect(page.locator('.lesson-card')).toContainText('Прочитать раздел 3');
  await page.getByRole('button', { name: 'Лабораторная по физике', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Изменить занятие' }).getByLabel('Домашнее задание')).toHaveValue('Прочитать раздел 3');
});

test('импорт всех подгрупп и мгновенная фильтрация без повторной загрузки', async ({ page }) => {
  let imports = 0;
  await page.route('**/api/university/institutes', route => route.fulfill({ json: { options: [{ id: '683', name: 'Институт ИТ' }] } }));
  await page.route('**/api/university/groups?*', route => route.fulfill({ json: { options: [{ id: '478229', name: 'ИСИб-23-1' }] } }));
  await page.route('**/api/schedule/refresh', route => {
    imports++;
    const common = { date: '2026-10-13', startMinute: 705, endMinute: 795, kind: 'Практика', teacher: 'Наумов И.В.', room: 'Б-100', homework: '' };
    return route.fulfill({ json: { lessons: [
      { ...common, sourceId: 'common', subject: 'История России', subgroup: null },
      { ...common, sourceId: 'lab-1', subject: 'Лабораторная первой', kind: 'Лабораторная работа', subgroup: '1' },
      { ...common, sourceId: 'lab-2', subject: 'Лабораторная второй', kind: 'Лабораторная работа', subgroup: '2' },
    ], coveredDays: ['2026-10-13', '2026-10-14'], subgroups: ['1', '2'] } });
  });
  await page.locator('.date-input').fill('2026-10-13');
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  let settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Расписание', exact: true }).click();
  await settings.getByRole('button', { name: 'Обновить институты' }).click();
  await settings.getByLabel('Институт', { exact: true }).selectOption('683');
  await expect(settings.getByLabel('Учебная группа')).toBeEnabled();
  await settings.getByLabel('Учебная группа').selectOption('478229');
  await settings.getByRole('button', { name: 'Готово', exact: true }).click();
  await page.getByRole('button', { name: 'Включить режим расписания' }).click();
  await page.getByRole('button', { name: 'Обновить расписание', exact: true }).click();
  await expect(page.locator('.lesson-card')).toHaveCount(3);
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Расписание', exact: true }).click();
  await settings.getByLabel('Подгруппа', { exact: true }).selectOption('1');
  await settings.getByRole('button', { name: 'Готово', exact: true }).click();
  await expect(page.locator('.lesson-card')).toHaveCount(2);
  await expect(page.locator('.lesson-card').filter({ hasText: 'Лабораторная второй' })).toHaveCount(0);
  expect(imports).toBe(1);
  await page.locator('.date-input').fill('2026-10-14');
  await expect(page.locator('.lesson-card')).toHaveCount(0);
  await expect(page.getByText('На этот день занятий нет', { exact: true })).toBeVisible();
});

test('тема и настройки уведомлений сохраняются, формы помещаются в экран', async ({ page }) => {
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Настройки', exact: true });
  await settings.getByRole('button', { name: 'Оформление', exact: true }).click();
  await settings.getByRole('radio', { name: 'Тёмная', exact: true }).check();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await settings.getByRole('button', { name: 'Уведомления', exact: true }).click();
  await expect(settings.getByRole('heading', { name: 'На этом устройстве', exact: true })).toBeVisible();
  await settings.getByRole('switch', { name: 'Включить уведомления', exact: true }).click();
  await expect(settings.getByRole('switch', { name: 'Включить уведомления', exact: true })).toBeChecked();
  await settings.getByLabel('За сколько минут напоминать').fill('10');
  const bounds = await settings.boundingBox(); const viewport = page.viewportSize()!;
  expect(bounds!.x).toBeGreaterThanOrEqual(0);
  expect(bounds!.y).toBeGreaterThanOrEqual(0);
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(viewport.width + 1);
  expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(viewport.height + 1);
  await settings.getByRole('button', { name: 'Готово', exact: true }).click();
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  await settings.getByRole('button', { name: 'Уведомления', exact: true }).click();
  await expect(settings.getByLabel('За сколько минут напоминать')).toHaveValue('10');
});

test('офлайн: сохранённые ресурсы открываются повторно, локальные правки остаются', async ({ page, context }) => {
  await createTask(page, 'Офлайн-план');
  await page.evaluate(async () => { await navigator.serviceWorker.ready; });
  await page.reload();
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole('button', { name: 'Изменить дело «Офлайн-план»' })).toBeVisible();
  await page.getByRole('button', { name: 'Выполнить «Офлайн-план»' }).click();
  await expect(page.getByRole('button', { name: 'Вернуть «Офлайн-план» в невыполненные' })).toBeVisible();
  await page.reload();
  await expect(page.getByRole('button', { name: 'Вернуть «Офлайн-план» в невыполненные' })).toBeVisible();
  await context.setOffline(false);
});
