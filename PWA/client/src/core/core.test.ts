import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  addDays, addMonths, createStore, createSyncEngine, dateFromCivil, dateToCivil, formatTime,
  isCivilDate, lessonVisible, mergeGuestIntoAccount, monthGrid, parseTime, sortTasks, startOfWeek, weekDates,
  type Entity, type PlannerStore, type SyncResponse, type TaskData,
} from './index';

const stores: PlannerStore[] = [];
function store(name: string = crypto.randomUUID()): PlannerStore { const value = createStore(name); stores.push(value); return value; }
const task = (patch: Partial<TaskData> = {}): TaskData => ({ title: 'Доклад', date: '2026-10-16', groupId: null, note: '', completed: false, ...patch });
const entity = (id = 'task-1', patch: Partial<Entity> = {}): Entity => ({ id, kind: 'task', data: { ...task() }, version: 1, deleted: false, ...patch });
function syncResponse(records: Entity[], revision = 1): SyncResponse { return { records, revision }; }
afterEach(async () => { for (const value of stores.splice(0)) { value.close(); await value.db.delete(); } vi.restoreAllMocks(); });

describe('civil calendar arithmetic', () => {
  it('keeps civil dates valid in DST boundaries and leap years', () => {
    expect(addDays('2024-02-28', 1)).toBe('2024-02-29');
    expect(addDays('2024-02-29', 1)).toBe('2024-03-01');
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDays('2026-01-01', -1)).toBe('2025-12-31');
    expect(isCivilDate('2026-02-29')).toBe(false);
    expect(isCivilDate('2026-13-01')).toBe(false);
    expect(isCivilDate('0000-01-01')).toBe(false);
    expect(dateToCivil(dateFromCivil('0099-02-28'))).toBe('0099-02-28');
    for (const value of ['2026-03-08', '2026-03-29', '2026-11-01']) expect(dateToCivil(dateFromCivil(value))).toBe(value);
  });
  it('clamps months and starts weeks on Monday across years', () => {
    expect(addMonths('2024-01-31', 1)).toBe('2024-02-29');
    expect(addMonths('2026-01-31', 1)).toBe('2026-02-28');
    expect(addMonths('2026-12-31', 1)).toBe('2027-01-31');
    expect(startOfWeek('2027-01-03')).toBe('2026-12-28');
    expect(weekDates('2027-01-03')).toEqual(['2026-12-28', '2026-12-29', '2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02', '2027-01-03']);
    const grid = monthGrid('2026-10-16'); expect(grid).toHaveLength(35); expect(grid[0]).toBe('2026-09-28'); expect(grid.at(-1)).toBe('2026-11-01');
  });
  it('validates wall times, tasks ordering and offline subgroup filters', () => {
    expect(parseTime('11:45')).toBe(705); expect(formatTime(795)).toBe('13:15');
    expect(() => parseTime('24:01')).toThrow(); expect(() => parseTime('10:65')).toThrow();
    expect(sortTasks([{ ...task({ completed: true }), id: 'a', version: 0 }, { ...task(), id: 'b', version: 0 }])[0].id).toBe('b');
    expect(lessonVisible({ subgroup: '2', sourceGroupId: 'group' }, { subgroup: '1', groupId: 'group' })).toBe(false);
    expect(lessonVisible({ subgroup: null, sourceGroupId: 'group' }, { subgroup: '1', groupId: 'group' })).toBe(true);
    expect(lessonVisible({ subgroup: '1', sourceGroupId: 'other' }, { subgroup: '1', groupId: 'group' })).toBe(false);
  });
});

describe('transactional local storage', () => {
  it('preserves tasks while deleting a group and queues the complete change', async () => {
    const db = store(); const group = await db.saveGroup({ name: 'Учёба', color: '#FFB300' });
    const item = await db.saveTask(task({ groupId: group.id })); await db.deleteGroup(group.id);
    expect(await db.listGroups()).toEqual([]); expect((await db.listTasks())[0]).toMatchObject({ id: item.id, groupId: null });
    const operations = await db.db.outbox.orderBy('order').toArray(); expect(operations).toHaveLength(3); expect(operations.at(-1)?.data).toBeNull();
  });
  it('rejects invalid writes without changing either data or queue', async () => {
    const db = store(); await expect(db.saveTask(task({ title: '  ' }))).rejects.toThrow();
    await expect(db.saveTask(task({ groupId: 'missing' }))).rejects.toThrow();
    expect(await db.listTasks()).toEqual([]); expect(await db.pendingCount()).toBe(0);
  });
  it('rolls back the outbox if saving the materialized record fails', async () => {
    const db = store(); vi.spyOn(db.db.entities, 'put').mockRejectedValueOnce(new DOMException('quota', 'QuotaExceededError'));
    await expect(db.saveTask(task())).rejects.toThrow(); expect(await db.pendingCount()).toBe(0); expect(await db.listTasks()).toEqual([]);
  });
  it('persists data/settings on reopen and isolates account namespaces', async () => {
    const name = crypto.randomUUID(), first = store(name), other = store();
    await first.saveTask(task()); await first.updatePreferences({ subgroup: '2', leadMinutes: 10 }); first.close();
    const reopened = store(name); expect(await reopened.listTasks()).toHaveLength(1); expect((await reopened.getPreferences()).subgroup).toBe('2');
    expect(await other.listTasks()).toEqual([]); expect((await other.getPreferences()).subgroup).toBeNull();
  });
  it('validates a whole backup before import and preserves guest/account collisions', async () => {
    const source = store('guest'), target = store();
    await source.saveTask(task({ note: 'Локальное ДЗ' }), 'same'); await target.saveTask(task({ note: 'Облачное ДЗ' }), 'same');
    const snapshot = await source.exportData(); const broken = JSON.parse(snapshot); broken.records.push({ ...broken.records[0], id: 'bad', data: { title: '' } });
    await expect(target.importData(JSON.stringify(broken))).rejects.toThrow(); expect(await target.listTasks()).toHaveLength(1);
    await mergeGuestIntoAccount(source, target); expect((await target.listTasks())[0].note).toBe('Облачное ДЗ');
    expect(await target.listConflicts()).toHaveLength(1); expect((await source.listTasks())[0].note).toBe('Локальное ДЗ');
    expect((await target.db.meta.toArray()).some(item => item.key.startsWith('backup-before-guest-merge:'))).toBe(true);
  });
});

describe('synchronization and conflicts', () => {
  it('rebases unsent edits made during an in-flight request', async () => {
    const db = store(); await db.acceptSync(syncResponse([entity()]), []);
    await db.saveTask(task({ title: 'Локальный заголовок' }), 'task-1');
    let respond!: (value: Response) => void; let requestStarted!: () => void;
    const started = new Promise<void>(resolve => { requestStarted = resolve; });
    let beforeDrain: unknown;
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async (_url, init) => {
      const operations = JSON.parse(String(init?.body)).operations;
      if (fetcher.mock.calls.length === 1) {
        requestStarted(); return new Promise<Response>(resolve => { respond = resolve; });
      }
      beforeDrain = (await db.listTasks())[0];
      const final = entity('task-1', { version: 3, data: { ...task({ title: 'Локальный заголовок', note: 'Правка во время синхронизации', completed: true }) } });
      return new Response(JSON.stringify({ revision: 3, records: [final], results: [{ operationId: operations[0].operationId, status: 'applied', record: final, conflictingFields: [] }] }));
    });
    const engine = createSyncEngine(db, { fetcher }); const inFlight = engine.sync(); await started;
    const sent = (await db.db.outbox.orderBy('order').toArray())[0];
    await db.saveTask(task({ title: 'Локальный заголовок', note: 'Правка во время синхронизации' }), 'task-1');
    const remote = entity('task-1', { version: 2, data: { ...task({ title: 'Локальный заголовок' }), completed: true } });
    respond(new Response(JSON.stringify({ revision: 2, records: [remote], results: [{ operationId: sent.operationId, status: 'applied', record: remote, conflictingFields: [] }] })));
    await inFlight; expect((await db.listTasks())[0]).toMatchObject({ title: 'Локальный заголовок', note: 'Правка во время синхронизации', completed: true });
    expect(beforeDrain).toMatchObject({ title: 'Локальный заголовок', note: 'Правка во время синхронизации', completed: true });
    expect(await db.pendingCount()).toBe(0); expect(fetcher).toHaveBeenCalledTimes(2);
  });
  it('keeps stable operation IDs after a failed request', async () => {
    const db = store(); await db.saveTask(task(), 'task-1'); const first = (await db.db.outbox.toArray())[0];
    const fetcher = vi.fn<typeof fetch>().mockRejectedValue(new TypeError('network'));
    await expect(createSyncEngine(db, { fetcher }).sync()).rejects.toThrow('Нет связи');
    expect((await db.db.outbox.toArray())[0].operationId).toBe(first.operationId);
    expect(await db.listTasks()).toHaveLength(1);
  });
  it('stores both conflicting notes and permits explicit local resolution', async () => {
    const db = store(); await db.acceptSync(syncResponse([entity()]), []); await db.saveTask(task({ note: 'Моя заметка' }), 'task-1');
    const batch = await db.db.outbox.toArray(), remote = entity('task-1', { version: 2, data: { ...task({ note: 'Заметка другого устройства' }) } });
    await db.acceptSync({ revision: 2, records: [remote], results: [{ operationId: batch[0].operationId, status: 'conflict', record: remote, conflictingFields: ['note'] }] }, batch);
    expect((await db.listTasks())[0].note).toBe('Заметка другого устройства');
    const conflict = (await db.listConflicts())[0]; expect(conflict.localData?.note).toBe('Моя заметка');
    await db.resolveConflict(conflict.id, 'local'); expect((await db.listTasks())[0].note).toBe('Моя заметка'); expect(await db.pendingCount()).toBe(1); expect(await db.listConflicts()).toEqual([]);
  });
  it('does not resurrect a remotely deleted task and saves its draft as a copy', async () => {
    const db = store(); await db.acceptSync(syncResponse([entity()]), []); await db.saveTask(task({ note: 'Не потерять' }), 'task-1');
    const batch = await db.db.outbox.toArray(), remote = entity('task-1', { version: 2, deleted: true });
    await db.acceptSync({ revision: 2, records: [remote], results: [{ operationId: batch[0].operationId, status: 'conflict', record: remote, conflictingFields: ['deleted'] }] }, batch);
    expect(await db.listTasks()).toEqual([]); const conflict = (await db.listConflicts())[0];
    await expect(db.resolveConflict(conflict.id, 'local')).rejects.toThrow('Сохраните отдельную копию');
    await db.resolveConflict(conflict.id, 'copy'); const copy = (await db.listTasks())[0]; expect(copy.id).not.toBe('task-1'); expect(copy.note).toBe('Не потерять');
  });
  it('ignores an older snapshot while applying valid acknowledgements', async () => {
    const db = store(); await db.acceptSync(syncResponse([entity('task-1', { version: 3, data: { ...task({ title: 'Свежий' }) } })], 3), []);
    await db.acceptSync(syncResponse([entity()], 1), []); expect((await db.listTasks())[0].title).toBe('Свежий'); expect(await db.revision()).toBe(3);
  });
  it('preserves a newer full snapshot when a previous push acknowledgement arrives late', async () => {
    const db = store(); await db.acceptSync(syncResponse([entity()]), []); await db.saveTask(task({ note: 'Отправлено' }), 'task-1');
    const batch = await db.db.outbox.toArray();
    const fresh = entity('task-1', { version: 3, data: { ...task({ title: 'Новейший заголовок', note: 'Отправлено' }) } });
    await db.acceptSync(syncResponse([fresh], 3), []);
    const stale = entity('task-1', { version: 2, data: { ...task({ note: 'Отправлено' }) } });
    await db.acceptSync({ records: [stale], revision: 2, results: [{ operationId: batch[0].operationId, status: 'applied', record: stale, conflictingFields: [] }] }, batch);
    expect((await db.listTasks())[0]).toMatchObject({ title: 'Новейший заголовок', note: 'Отправлено', version: 3 }); expect(await db.pendingCount()).toBe(0);
  });
  it('keeps later fields in a same-record operation chain when the first field conflicts', async () => {
    const db = store(); await db.acceptSync(syncResponse([entity()]), []);
    await db.saveTask(task({ title: 'Мой заголовок' }), 'task-1'); await db.saveTask(task({ title: 'Мой заголовок', note: 'Моя новая заметка' }), 'task-1');
    const batch = await db.db.outbox.orderBy('order').toArray();
    const serverConflict = entity('task-1', { version: 2, data: { ...task({ title: 'Другой заголовок' }) } });
    const final = entity('task-1', { version: 3, data: { ...task({ title: 'Другой заголовок', note: 'Моя новая заметка' }) } });
    await db.acceptSync({ records: [final], revision: 3, results: [
      { operationId: batch[0].operationId, status: 'conflict', record: serverConflict, conflictingFields: ['title'] },
      { operationId: batch[1].operationId, status: 'applied', record: final, conflictingFields: [] },
    ] }, batch);
    await db.resolveConflict((await db.listConflicts())[0].id, 'local');
    expect((await db.listTasks())[0]).toMatchObject({ title: 'Мой заголовок', note: 'Моя новая заметка' });
  });
  it('exports an unacknowledged edit hidden by a newer remote tombstone', async () => {
    const db = store(), restored = store(); await db.acceptSync(syncResponse([entity()]), []); await db.saveTask(task({ note: 'Черновик нельзя терять' }), 'task-1');
    await db.acceptSync(syncResponse([entity('task-1', { version: 2, deleted: true })], 2), []);
    expect(await db.listTasks()).toEqual([]); await restored.importData(await db.exportData());
    expect((await restored.listConflicts()).some(conflict => conflict.localData?.note === 'Черновик нельзя терять')).toBe(true);
  });
  it('drains a long offline queue using the API limit of 100 operations per request', async () => {
    const db = store();
    for (let index = 0; index < 205; index++) await db.saveTask(task({ title: `Дело ${index}` }), `task-${index}`);
    const remote = new Map<string, Entity>(); const sizes: number[] = []; let revision = 0;
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async (_url, init) => {
      const { operations } = JSON.parse(String(init?.body)); sizes.push(operations.length);
      const results = operations.map((operation: { operationId: string; entityId: string; data: Record<string, unknown> }) => {
        const record: Entity = { id: operation.entityId, kind: 'task', data: operation.data, deleted: false, version: ++revision }; remote.set(record.id, record);
        return { operationId: operation.operationId, status: 'applied', record, conflictingFields: [] };
      });
      return new Response(JSON.stringify({ records: [...remote.values()], results, revision }));
    });
    const result = await createSyncEngine(db, { fetcher }).sync(); expect(sizes).toEqual([100, 100, 5]); expect(result.pending).toBe(0); expect(await db.listTasks()).toHaveLength(205);
  });
  it('rejects incomplete acknowledgements without deleting unsent changes', async () => {
    const db = store(); await db.saveTask(task(), 'task-1'); const batch = await db.db.outbox.toArray();
    await expect(db.acceptSync({ records: [], revision: 0, results: [] }, batch)).rejects.toThrow('Неполное');
    expect(await db.pendingCount()).toBe(1); expect(await db.listTasks()).toHaveLength(1);
  });
  it('bounds large UTF-8 requests and binds them to the intended account', async () => {
    const db = store(); for (let index = 0; index < 40; index++) await db.saveTask(task({ note: 'я'.repeat(20000) }), `large-${index}`);
    const sizes: number[] = [], remote = new Map<string, Entity>(); let revision = 0;
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async (_url, init) => {
      expect(new Headers(init?.headers).get('X-SimpleSchedule-Account')).toBe(db.namespace);
      sizes.push(new TextEncoder().encode(String(init?.body)).byteLength);
      const { operations } = JSON.parse(String(init?.body));
      const results = operations.map((operation: { operationId: string; entityId: string; data: Record<string, unknown> }) => {
        const record: Entity = { id: operation.entityId, kind: 'task', data: operation.data, version: ++revision, deleted: false }; remote.set(record.id, record);
        return { operationId: operation.operationId, status: 'applied', record, conflictingFields: [] };
      });
      return new Response(JSON.stringify({ records: [...remote.values()], results, revision }));
    });
    await createSyncEngine(db, { fetcher }).sync(); expect(sizes.length).toBeGreaterThan(1); expect(sizes.every(size => size <= 1500000)).toBe(true); expect(await db.pendingCount()).toBe(0);
  });
  it('never calls account sync for a guest', async () => {
    const db = store('guest'), fetcher = vi.fn<typeof fetch>(); await db.saveTask(task()); await createSyncEngine(db, { fetcher }).sync(); expect(fetcher).not.toHaveBeenCalled();
  });
});

describe('timetable import', () => {
  const lesson = { date: '2026-10-13', startMinute: 705, endMinute: 795, subject: 'История России', kind: 'практика', teacher: 'Наумов И.В.', room: 'Б-100', subgroup: null, homework: '', sourceId: 'pair-1' };
  it('imports every subgroup, preserves manual edits and never clears unknown dates', async () => {
    const db = store(); await db.updatePreferences({ groupId: '478229', subgroup: '1' });
    await db.mergeImportedLessons({ groupId: '478229', coveredDays: ['2026-10-13'], subgroups: ['1', '2'], lessons: [lesson, { ...lesson, sourceId: 'pair-2', subgroup: '2', startMinute: 825, endMinute: 915 }] });
    expect(await db.listLessons()).toHaveLength(2); const first = (await db.listLessons())[0];
    await db.saveLesson({ ...first, homework: 'Выучить', room: 'Мой кабинет' }, first.id);
    await db.mergeImportedLessons({ groupId: '478229', coveredDays: ['2026-10-13'], subgroups: ['1', '2'], lessons: [{ ...lesson, room: 'Б-101', teacher: 'Новый преподаватель' }, { ...lesson, sourceId: 'pair-2', subgroup: '2', startMinute: 825, endMinute: 915 }] });
    expect((await db.listLessons())[0]).toMatchObject({ homework: 'Выучить', room: 'Мой кабинет', teacher: 'Новый преподаватель' });
    await db.mergeImportedLessons({ groupId: '478229', coveredDays: ['2026-10-14'], subgroups: ['1', '2'], lessons: [] });
    expect(await db.listLessons()).toHaveLength(2); expect((await db.getImportMetadata())?.subgroups).toEqual(['1', '2']);
  });
  it('respects user deletion and retains homework if a source lesson is cancelled', async () => {
    const db = store(); const payload = { groupId: '478229', coveredDays: ['2026-10-13'], subgroups: [], lessons: [lesson] };
    await db.mergeImportedLessons(payload); const first = (await db.listLessons())[0]; await db.deleteLesson(first.id); await db.mergeImportedLessons(payload); expect(await db.listLessons()).toEqual([]);
    await db.mergeImportedLessons({ ...payload, lessons: [{ ...lesson, sourceId: 'other' }] }); const other = (await db.listLessons())[0]; await db.saveLesson({ ...other, homework: 'Личная запись' }, other.id);
    await db.mergeImportedLessons({ ...payload, lessons: [] }); expect((await db.listLessons())[0].homework).toBe('Личная запись'); expect((await db.listLessons())[0]).not.toHaveProperty('sourceId');
  });
  it('discovers new subgroup numbers from server snapshots despite older local import metadata', async () => {
    const db = store(); await db.updatePreferences({ groupId: '478229' });
    await db.mergeImportedLessons({ groupId: '478229', coveredDays: ['2026-10-13'], subgroups: ['1'], lessons: [{ ...lesson, subgroup: '1' }] });
    const queued = await db.db.outbox.orderBy('order').toArray(), records = await db.db.entities.toArray();
    const source: Entity = { id: 'source:478229:new-subgroup', kind: 'lesson', deleted: false, version: 20, data: { ...lesson, sourceId: 'new-subgroup', sourceGroupId: '478229', subgroup: '2' } };
    const updated = [...records.map((record, index) => ({ ...record, version: index + 1 })), source];
    await db.acceptSync({ records: updated, revision: 20, results: queued.map(operation => ({ operationId: operation.operationId, status: 'applied' as const, record: updated.find(record => record.id === operation.entityId)!, conflictingFields: [] })) }, queued);
    expect((await db.getImportMetadata())?.subgroups).toEqual(['1', '2']);
  });
  it('restores a source-cancelled lesson under its original ID when the site publishes it again', async () => {
    const db = store(), preferences = { groupId: '478229', subgroup: null };
    const payload = { groupId: '478229', coveredDays: ['2026-10-13'], subgroups: [], lessons: [lesson] };
    await db.mergeImportedLessons(payload); const original = (await db.listLessons())[0];
    await db.mergeImportedLessons({ ...payload, lessons: [] });
    const cancelled = (await db.listLessons())[0];
    expect(cancelled.id).toBe(original.id); expect(cancelled.sourceCancelled).toBe(true);
    expect(lessonVisible(cancelled, preferences)).toBe(false);
    expect((await db.db.entities.get(original.id))?.deleted).toBe(false);
    await db.mergeImportedLessons({ ...payload, lessons: [{ ...lesson, room: 'Б-101' }] });
    const restored = (await db.listLessons())[0];
    expect(restored).toMatchObject({ id: original.id, sourceCancelled: false, room: 'Б-101' });
    expect(lessonVisible(restored, preferences)).toBe(true);
  });
  it('never restores an explicitly deleted lesson, including one that was first cancelled by the source', async () => {
    const db = store(); const payload = { groupId: '478229', coveredDays: ['2026-10-13'], subgroups: [], lessons: [lesson] };
    await db.mergeImportedLessons(payload); const original = (await db.listLessons())[0];
    await db.mergeImportedLessons({ ...payload, lessons: [] }); await db.deleteLesson(original.id);
    await db.mergeImportedLessons(payload); expect(await db.listLessons()).toEqual([]);
    expect((await db.db.entities.get(original.id))?.deleted).toBe(true);
  });
  it('preserves source cancellation across backup restore and ignores an unknown period', async () => {
    const db = store(), restored = store(); const payload = { groupId: '478229', coveredDays: ['2026-10-13'], subgroups: [], lessons: [lesson] };
    await db.mergeImportedLessons(payload); await db.mergeImportedLessons({ ...payload, lessons: [] });
    await restored.importData(await db.exportData());
    expect((await restored.listLessons())[0].sourceCancelled).toBe(true);
    await restored.mergeImportedLessons({ ...payload, coveredDays: ['2026-10-14'], lessons: [] });
    expect((await restored.listLessons())[0].sourceCancelled).toBe(true);
    await restored.mergeImportedLessons(payload); expect((await restored.listLessons())[0].sourceCancelled).toBe(false);
    await expect(restored.saveLesson({ ...lesson, sourceCancelled: 'invalid' as unknown as boolean })).rejects.toThrow('Отмена в источнике');
  });
});
