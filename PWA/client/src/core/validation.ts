import { isCivilDate } from './dates';
import { DEFAULT_PREFERENCES, type Entity, type EntityKind, type Preferences } from './types';

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Ожидался объект данных');
  return value as Record<string, unknown>;
}
export function text(value: unknown, name: string, max = 500, required = false): string {
  if (typeof value !== 'string' || value.length > max || (required && !value.trim())) throw new Error(`Некорректное поле «${name}»`);
  return required ? value.trim() : value;
}
export function identifier(value: unknown, name = 'ID'): string { return text(value, name, 200, true); }
function nullableText(value: unknown, name: string, max = 200): string | null {
  return value === null || value === undefined || value === '' ? null : text(value, name, max, true);
}
function integer(value: unknown, name: string, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min || value > max) throw new Error(`Некорректное поле «${name}»`);
  return value;
}
function bool(value: unknown, name: string): boolean {
  if (typeof value !== 'boolean') throw new Error(`Некорректное поле «${name}»`);
  return value;
}
function civil(value: unknown): string {
  if (!isCivilDate(value)) throw new Error('Некорректная дата'); return value;
}
export function sanitizePreferences(value: unknown): Preferences {
  const data = { ...DEFAULT_PREFERENCES, ...object(value) };
  if (data.refreshMode !== 'manual' && data.refreshMode !== 'auto') throw new Error('Некорректный режим обновления');
  if (!Array.isArray(data.mutedSubjects) || data.mutedSubjects.length > 1000 || !Array.isArray(data.mutedDates) || data.mutedDates.length > 1000) throw new Error('Некорректные настройки уведомлений');
  if (![1, 3, 6].includes(data.refreshIntervalHours)) throw new Error('Выберите интервал 1, 3 или 6 часов');
  return {
    instituteId: nullableText(data.instituteId, 'Институт', 12), groupId: nullableText(data.groupId, 'Учебная группа', 12),
    subgroup: nullableText(data.subgroup, 'Подгруппа', 50), durationMinutes: integer(data.durationMinutes, 'Длительность', 1, 360),
    refreshMode: data.refreshMode, refreshIntervalHours: integer(data.refreshIntervalHours, 'Интервал', 1, 168),
    notificationsEnabled: bool(data.notificationsEnabled, 'Уведомления'), beforeLessonEnabled: bool(data.beforeLessonEnabled, 'Перед занятиями'),
    scheduleChangesEnabled: bool(data.scheduleChangesEnabled, 'Изменения расписания'), leadMinutes: integer(data.leadMinutes, 'Напоминание', 1, 1440),
    mutedSubjects: [...new Set(data.mutedSubjects.map(value => text(value, 'Дисциплина', 500, true)))],
    mutedDates: [...new Set(data.mutedDates.map(civil))],
  };
}
export function sanitizeData(kind: EntityKind, value: unknown): Record<string, unknown> {
  const data = object(value);
  switch (kind) {
    case 'task': return {
      title: text(data.title, 'Название', 500, true), date: civil(data.date), groupId: nullableText(data.groupId, 'Группа'),
      note: text(data.note ?? '', 'Заметка', 20000), completed: bool(data.completed ?? false, 'Выполнено'),
    };
    case 'group': {
      const color = text(data.color, 'Цвет', 7, true);
      if (!/^#[\da-f]{6}$/i.test(color)) throw new Error('Цвет должен иметь формат #RRGGBB');
      return { name: text(data.name, 'Название группы', 120, true), color: color.toLowerCase() };
    }
    case 'lesson': {
      const startMinute = integer(data.startMinute, 'Начало', 0, 1439), endMinute = integer(data.endMinute, 'Окончание', 1, 1440);
      if (endMinute <= startMinute) throw new Error('Окончание занятия должно быть позже начала');
      const result: Record<string, unknown> = {
        date: civil(data.date), startMinute, endMinute, subject: text(data.subject, 'Предмет', 500, true),
        kind: text(data.kind ?? '', 'Вид занятия', 100), teacher: text(data.teacher ?? '', 'Преподаватель', 500),
        room: text(data.room ?? '', 'Аудитория', 200), subgroup: nullableText(data.subgroup, 'Подгруппа', 50),
        homework: text(data.homework ?? '', 'Домашнее задание', 20000),
      };
      if (data.sourceId !== undefined) result.sourceId = identifier(data.sourceId, 'Источник занятия');
      if (data.sourceGroupId !== undefined) result.sourceGroupId = text(data.sourceGroupId, 'Учебная группа источника', 12, true);
      if (data.sourceCancelled !== undefined) result.sourceCancelled = bool(data.sourceCancelled, 'Отмена в источнике');
      if (data.sourceBaseline !== undefined) {
        const baseline = object(data.sourceBaseline);
        const safe: Record<string, unknown> = {};
        for (const key of ['date', 'startMinute', 'endMinute', 'subject', 'kind', 'teacher', 'room', 'subgroup', 'sourceId', 'sourceGroupId']) {
          if (Object.hasOwn(baseline, key)) safe[key] = baseline[key];
        }
        if (JSON.stringify(safe).length > 10000) throw new Error('Слишком большой исходный снимок занятия');
        result.sourceBaseline = safe;
      }
      return result;
    }
    case 'preferences': return { ...sanitizePreferences(data) };
    default: throw new Error('Неизвестный тип записи');
  }
}
export function sanitizeEntity(value: unknown): Entity {
  const source = object(value), kind = source.kind;
  if (!['task', 'group', 'lesson', 'preferences'].includes(String(kind))) throw new Error('Неизвестный тип записи');
  const id = identifier(source.id);
  if (kind === 'preferences' && id !== 'preferences') throw new Error('Некорректный ID настроек');
  return { id, kind: kind as EntityKind, data: sanitizeData(kind as EntityKind, source.data), version: integer(source.version, 'Версия', 0, Number.MAX_SAFE_INTEGER), deleted: bool(source.deleted, 'Удаление') };
}
export function equal(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true;
  if (left === null || right === null || typeof left !== 'object' || typeof right !== 'object') return false;
  if (Array.isArray(left) || Array.isArray(right)) return Array.isArray(left) && Array.isArray(right) && left.length === right.length && left.every((value, i) => equal(value, right[i]));
  const a = left as Record<string, unknown>, b = right as Record<string, unknown>;
  const keys = Object.keys(a); return keys.length === Object.keys(b).length && keys.every(key => Object.hasOwn(b, key) && equal(a[key], b[key]));
}
