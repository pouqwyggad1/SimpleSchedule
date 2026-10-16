import type { CivilDate, Lesson, Preferences, Task } from './types';

const CIVIL_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
export function dateFromCivil(value: CivilDate): Date {
  const match = CIVIL_PATTERN.exec(value);
  if (!match) throw new Error('Укажите дату в формате ГГГГ-ММ-ДД');
  const year = Number(match[1]), month = Number(match[2]), day = Number(match[3]);
  const result = new Date(0);
  result.setHours(12, 0, 0, 0);
  result.setFullYear(year, month - 1, day);
  if (year < 1 || result.getFullYear() !== year || result.getMonth() !== month - 1 || result.getDate() !== day)
    throw new Error('Некорректная дата');
  return result;
}
export function isCivilDate(value: unknown): value is CivilDate {
  if (typeof value !== 'string') return false;
  try { dateFromCivil(value); return true; } catch { return false; }
}
export function dateToCivil(date: Date): CivilDate {
  if (!Number.isFinite(date.getTime())) throw new Error('Некорректная дата');
  const year = date.getFullYear();
  if (year < 1 || year > 9999) throw new Error('Дата вне поддерживаемого диапазона');
  return `${String(year).padStart(4, '0')}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}
export function today(): CivilDate { return dateToCivil(new Date()); }
export function addDays(value: CivilDate, amount: number): CivilDate {
  if (!Number.isInteger(amount)) throw new Error('Некорректный шаг даты');
  const date = dateFromCivil(value); date.setDate(date.getDate() + amount); return dateToCivil(date);
}
/** Jan 31 → Feb 28/29, rather than overflowing into March. */
export function addMonths(value: CivilDate, amount: number): CivilDate {
  if (!Number.isInteger(amount)) throw new Error('Некорректный шаг месяца');
  const date = dateFromCivil(value), day = date.getDate();
  date.setDate(1); date.setMonth(date.getMonth() + amount);
  const end = new Date(date); end.setMonth(end.getMonth() + 1, 0);
  date.setDate(Math.min(day, end.getDate())); return dateToCivil(date);
}
export function startOfWeek(value: CivilDate): CivilDate {
  const date = dateFromCivil(value); return addDays(value, -((date.getDay() + 6) % 7));
}
export function weekDates(value: CivilDate): CivilDate[] {
  const monday = startOfWeek(value); return Array.from({ length: 7 }, (_, day) => addDays(monday, day));
}
export function monthGrid(value: CivilDate): CivilDate[] {
  const date = dateFromCivil(value); date.setDate(1);
  const first = dateToCivil(date), start = startOfWeek(first);
  const last = new Date(date); last.setMonth(last.getMonth() + 1, 0);
  const leading = (date.getDay() + 6) % 7;
  const count = Math.ceil((leading + last.getDate()) / 7) * 7;
  return Array.from({ length: count }, (_, day) => addDays(start, day));
}
export function isWeekend(value: CivilDate): boolean { return [0, 6].includes(dateFromCivil(value).getDay()); }
export function formatDate(value: CivilDate, options: Intl.DateTimeFormatOptions = { day: 'numeric', month: 'long', year: 'numeric' }): string {
  return new Intl.DateTimeFormat('ru-RU', options).format(dateFromCivil(value));
}
export function formatTime(minute: number): string {
  if (!Number.isInteger(minute) || minute < 0 || minute > 1440) throw new Error('Некорректное время');
  return `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
}
export function parseTime(value: string): number {
  const match = /^(\d{1,2}):(\d{2})$/.exec(value);
  if (!match) throw new Error('Укажите время в формате ЧЧ:ММ');
  const minute = Number(match[1]) * 60 + Number(match[2]);
  if (Number(match[2]) > 59 || minute > 1440 || (Number(match[1]) === 24 && Number(match[2]) !== 0)) throw new Error('Некорректное время');
  return minute;
}
export function sortTasks(tasks: Task[]): Task[] {
  return [...tasks].sort((a, b) => Number(a.completed) - Number(b.completed) || a.date.localeCompare(b.date) || a.title.localeCompare(b.title, 'ru') || a.id.localeCompare(b.id));
}
export function sortLessons(lessons: Lesson[]): Lesson[] {
  return [...lessons].sort((a, b) => a.date.localeCompare(b.date) || a.startMinute - b.startMinute || a.subject.localeCompare(b.subject, 'ru') || a.id.localeCompare(b.id));
}
export function lessonVisible(lesson: Pick<Lesson, 'subgroup' | 'sourceGroupId' | 'sourceCancelled'>, preferences: Pick<Preferences, 'subgroup' | 'groupId'>): boolean {
  return !lesson.sourceCancelled && (!lesson.sourceGroupId || lesson.sourceGroupId === preferences.groupId)
    && (!lesson.subgroup || !preferences.subgroup || lesson.subgroup === preferences.subgroup);
}
export function lessonCountLabel(count: number): string {
  const n = Math.abs(count), ten = n % 10, hundred = n % 100;
  return `${count} ${hundred >= 11 && hundred <= 14 ? 'пар' : ten === 1 ? 'пара' : ten >= 2 && ten <= 4 ? 'пары' : 'пар'}`;
}
export function subjectKey(subject: string): string { return subject.trim().normalize('NFKC').toLocaleLowerCase('ru-RU').replace(/\s+/g, ' '); }
