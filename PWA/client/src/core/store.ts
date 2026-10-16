import Dexie, { type Table } from 'dexie';
import { isCivilDate, sortLessons, sortTasks } from './dates';
import { equal, identifier, object, sanitizeData, sanitizeEntity, sanitizePreferences } from './validation';
import {
  type Backup, type Entity, type EntityKind, type Group, type GroupData,
  type ImportMetadata, type Lesson, type LessonData, type OperationResult, type Preferences,
  type QueuedOperation, type SavedConflict, type ScheduleImport, type SyncResponse, type Task, type TaskData,
} from './types';

interface Metadata { key: string; value: unknown }
export class PlannerDatabase extends Dexie {
  entities!: Table<Entity, string>;
  server!: Table<Entity, string>;
  outbox!: Table<QueuedOperation, string>;
  conflicts!: Table<SavedConflict, string>;
  meta!: Table<Metadata, string>;
  constructor(namespace: string) {
    super(`SimpleSchedule.PWA.v1.${encodeURIComponent(namespace)}`);
    this.version(1).stores({ entities: 'id,kind', server: 'id,kind', outbox: 'operationId,&order,entityId', conflicts: 'id,entityId', meta: 'key' });
  }
}
function uuid(): string { return crypto.randomUUID(); }
function flatten<T>(record: Entity): T { return { ...record.data, id: record.id, version: record.version } as T; }
function changedFields(base: Record<string, unknown> | null, data: Record<string, unknown>): string[] {
  return [...new Set([...Object.keys(base ?? {}), ...Object.keys(data)])].filter(key => !base || Object.hasOwn(base, key) !== Object.hasOwn(data, key) || !equal(base[key], data[key]));
}
function patchData(current: Record<string, unknown>, base: Record<string, unknown> | null, data: Record<string, unknown>): Record<string, unknown> {
  const result = { ...current };
  for (const key of changedFields(base, data)) {
    if (Object.hasOwn(data, key)) result[key] = data[key];
    else delete result[key];
  }
  return result;
}

export class PlannerStore {
  readonly db: PlannerDatabase;
  readonly namespace: string;
  constructor(namespace = 'guest') {
    this.namespace = identifier(namespace, 'Учётная запись');
    this.db = new PlannerDatabase(this.namespace);
  }
  close(): void { this.db.close(); }
  async listTasks(): Promise<Task[]> { return sortTasks((await this.active('task')).map(flatten<Task>)); }
  async listGroups(): Promise<Group[]> {
    return (await this.active('group')).map(flatten<Group>).sort((a, b) => a.name.localeCompare(b.name, 'ru') || a.id.localeCompare(b.id));
  }
  async listLessons(): Promise<Lesson[]> { return sortLessons((await this.active('lesson')).map(flatten<Lesson>)); }
  private async active(kind: EntityKind): Promise<Entity[]> { return (await this.db.entities.where('kind').equals(kind).toArray()).filter(record => !record.deleted); }
  async getPreferences(): Promise<Preferences> {
    const record = await this.db.entities.get('preferences');
    return sanitizePreferences(record && !record.deleted ? record.data : {});
  }
  async pendingCount(): Promise<number> { return this.db.outbox.count(); }
  async listConflicts(): Promise<SavedConflict[]> { return (await this.db.conflicts.toArray()).sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id)); }
  async revision(): Promise<number> { return Number((await this.db.meta.get('revision'))?.value ?? 0); }
  async getImportMetadata(): Promise<ImportMetadata | null> {
    const saved = (await this.db.meta.get('import'))?.value as ImportMetadata | undefined;
    const preferences = await this.getPreferences();
    if (!preferences.groupId) return saved ?? null;
    const lessons = (await this.listLessons()).filter(lesson => lesson.sourceGroupId === preferences.groupId);
    const relevant = saved?.groupId === preferences.groupId ? saved : null;
    return {
      groupId: preferences.groupId, subgroups: [...new Set([...(relevant?.subgroups ?? []), ...lessons.flatMap(lesson => lesson.subgroup ? [lesson.subgroup] : [])])].sort((a, b) => a.localeCompare(b, 'ru', { numeric: true })),
      coveredDays: [...new Set([...(relevant?.coveredDays ?? []), ...lessons.map(lesson => lesson.date)])].sort(), updatedAt: relevant?.updatedAt ?? 0,
    };
  }
  async saveTask(input: TaskData, id = uuid()): Promise<Task> {
    const data = sanitizeData('task', input);
    return this.transaction(async () => {
      await this.checkGroup(data.groupId as string | null);
      return flatten<Task>(await this.writeInside('task', id, data));
    });
  }
  async saveGroup(input: GroupData, id = uuid()): Promise<Group> {
    const data = sanitizeData('group', input);
    return this.transaction(async () => flatten<Group>(await this.writeInside('group', id, data)));
  }
  async saveLesson(input: LessonData, id = uuid()): Promise<Lesson> {
    const data = sanitizeData('lesson', input);
    return this.transaction(async () => flatten<Lesson>(await this.writeInside('lesson', id, data)));
  }
  async setTaskCompleted(id: string, completed: boolean): Promise<void> {
    await this.transaction(async () => {
      const current = await this.requireActive(id, 'task');
      await this.writeInside('task', id, sanitizeData('task', { ...current.data, completed }));
    });
  }
  async deleteTask(id: string): Promise<void> { await this.deleteRecord(id, 'task'); }
  async deleteLesson(id: string): Promise<void> { await this.deleteRecord(id, 'lesson'); }
  private async deleteRecord(id: string, kind: EntityKind): Promise<void> {
    await this.transaction(async () => { await this.requireActive(id, kind); await this.writeInside(kind, id, null); });
  }
  async deleteGroup(id: string): Promise<void> {
    await this.transaction(async () => {
      await this.requireActive(id, 'group');
      const tasks = await this.active('task');
      await this.writeInside('group', id, null);
      // The one server command unlinks every task atomically, even across a 100-operation batch boundary.
      for (const task of tasks.filter(record => record.data.groupId === id)) await this.db.entities.put({ ...task, data: { ...task.data, groupId: null } });
    });
  }
  async updatePreferences(patch: Partial<Preferences>): Promise<Preferences> {
    return this.transaction(async () => {
      const data = sanitizeData('preferences', { ...await this.getPreferences(), ...patch });
      await this.writeInside('preferences', 'preferences', data);
      return sanitizePreferences(data);
    });
  }
  private async requireActive(id: string, kind: EntityKind): Promise<Entity> {
    const record = await this.db.entities.get(identifier(id));
    if (!record || record.deleted || record.kind !== kind) throw new Error('Запись уже удалена или недоступна');
    return record;
  }
  private async checkGroup(id: string | null): Promise<void> { if (id) await this.requireActive(id, 'group'); }
  private transaction<T>(callback: () => Promise<T>): Promise<T> {
    return this.db.transaction('rw', this.db.entities, this.db.server, this.db.outbox, this.db.conflicts, this.db.meta, callback);
  }
  private async writeInside(kind: EntityKind, id: string, data: Record<string, unknown> | null): Promise<Entity> {
    identifier(id);
    const current = await this.db.entities.get(id);
    if (current && current.kind !== kind) throw new Error('ID уже используется другой записью');
    if (current?.deleted && data) throw new Error('Удалённую запись можно восстановить только отдельной копией');
    if (current && ((data === null && current.deleted) || (data !== null && !current.deleted && equal(current.data, data)))) return current;
    const record: Entity = { id, kind, data: data ?? current?.data ?? {}, version: current?.version ?? 0, deleted: data === null };
    const order = Number((await this.db.meta.get('nextOrder'))?.value ?? 0) + 1;
    const operation: QueuedOperation = {
      operationId: uuid(), entityId: id, kind, baseVersion: current?.version ?? 0,
      base: current && !current.deleted ? current.data : null, data, order, queuedAt: Date.now(),
    };
    await this.db.outbox.add(operation);
    await this.db.entities.put(record);
    await this.db.meta.put({ key: 'nextOrder', value: order });
    return record;
  }
  /** A server snapshot is rebased under newer local operations, never over them. */
  async acceptSync(response: SyncResponse, submitted: QueuedOperation[]): Promise<void> {
    if (!Number.isSafeInteger(response.revision) || response.revision < 0 || !Array.isArray(response.records) || response.records.length > 100000) throw new Error('Некорректный ответ синхронизации');
    const records = response.records.map(sanitizeEntity);
    if (new Set(records.map(record => record.id)).size !== records.length) throw new Error('Повторяющиеся ID в ответе синхронизации');
    const sent = new Map(submitted.map(operation => [operation.operationId, operation]));
    const results: OperationResult[] = (response.results ?? []).map(value => {
      const raw = object(value), operationId = identifier(raw.operationId), status = raw.status;
      if (!sent.has(operationId) || (status !== 'applied' && status !== 'conflict') || !Array.isArray(raw.conflictingFields) || !raw.conflictingFields.every(field => typeof field === 'string')) throw new Error('Некорректное подтверждение операции');
      const record = sanitizeEntity(raw.record), operation = sent.get(operationId)!;
      if (record.id !== operation.entityId || record.kind !== operation.kind) throw new Error('Подтверждение относится к другой записи');
      return { operationId, status, record, conflictingFields: raw.conflictingFields as string[] };
    });
    if (new Set(results.map(result => result.operationId)).size !== results.length || (submitted.length && results.length !== submitted.length)) throw new Error('Неполное подтверждение операций');
    await this.transaction(async () => {
      if (response.revision >= await this.revision()) {
        await this.db.server.clear(); await this.db.server.bulkPut(records);
        await this.db.meta.put({ key: 'revision', value: response.revision });
      }
      for (const result of results) {
        const queued = await this.db.outbox.get(result.operationId);
        if (!queued) continue;
        if (result.status === 'conflict') await this.db.conflicts.put({
          id: result.operationId, entityId: queued.entityId, kind: queued.kind, localData: queued.data,
          baseData: queued.base, serverRecord: result.record, conflictingFields: result.conflictingFields, createdAt: Date.now(),
        });
        await this.db.outbox.delete(result.operationId);
      }
      await this.rebuildInside();
    });
  }
  private async rebuildInside(): Promise<void> {
    const materialized = new Map((await this.db.server.toArray()).map(record => [record.id, record]));
    for (const operation of await this.db.outbox.orderBy('order').toArray()) {
      const current = materialized.get(operation.entityId);
      if (operation.data === null) {
        if (current) materialized.set(current.id, { ...current, deleted: true });
        continue;
      }
      if (current?.deleted) continue;
      materialized.set(operation.entityId, {
        id: operation.entityId, kind: operation.kind, version: current?.version ?? 0, deleted: false,
        data: patchData(current?.data ?? {}, operation.base, operation.data),
      });
    }
    const groupIds = new Set([...materialized.values()].filter(record => record.kind === 'group' && !record.deleted).map(record => record.id));
    for (const [id, record] of materialized) if (record.kind === 'task' && !record.deleted && record.data.groupId && !groupIds.has(String(record.data.groupId))) materialized.set(id, { ...record, data: { ...record.data, groupId: null } });
    await this.db.entities.clear(); await this.db.entities.bulkPut([...materialized.values()]);
  }
  async resolveConflict(id: string, resolution: 'local' | 'server' | 'copy'): Promise<void> {
    await this.transaction(async () => {
      const conflict = await this.db.conflicts.get(id); if (!conflict) return;
      if (resolution !== 'server') {
        if (resolution === 'copy') {
          if (!conflict.localData || conflict.kind === 'preferences') throw new Error('Для этой записи нельзя создать копию');
          const data = { ...conflict.localData };
          if (conflict.kind === 'lesson') { delete data.sourceId; delete data.sourceGroupId; delete data.sourceBaseline; delete data.sourceCancelled; }
          if (conflict.kind === 'task' && data.groupId) {
            const group = await this.db.entities.get(String(data.groupId)); if (!group || group.deleted) data.groupId = null;
          }
          await this.writeInside(conflict.kind, uuid(), sanitizeData(conflict.kind, data));
        } else {
          const current = await this.db.entities.get(conflict.entityId);
          if (current?.deleted && conflict.localData) throw new Error('Запись удалена на другом устройстве. Сохраните отдельную копию');
          const desired = conflict.localData === null ? null : sanitizeData(conflict.kind, patchData(current?.data ?? {}, conflict.baseData, conflict.localData));
          await this.writeInside(conflict.kind, conflict.entityId, desired);
        }
      }
      await this.db.conflicts.delete(id);
    });
  }
  async exportData(): Promise<string> {
    return this.db.transaction('r', this.db.entities, this.db.outbox, this.db.conflicts, this.db.meta, async () => JSON.stringify({
      format: 'SimpleSchedule.PWA', version: 1, exportedAt: new Date().toISOString(),
      records: await this.db.entities.toArray(), conflicts: await this.db.conflicts.toArray(),
      pendingOperations: (await this.db.outbox.orderBy('order').toArray()).map(({ operationId, entityId, kind, baseVersion, base, data }) => ({ operationId, entityId, kind, baseVersion, base, data })),
      importMetadata: ((await this.db.meta.get('import'))?.value as ImportMetadata | undefined) ?? null,
    } satisfies Backup, null, 2));
  }
  /** Import is a deliberate user action; validate the entire file before changing anything. */
  async importData(json: string): Promise<void> {
    if (json.length > 20_000_000) throw new Error('Резервная копия слишком велика');
    let raw: Record<string, unknown>;
    try { raw = object(JSON.parse(json)); } catch { throw new Error('Не удалось прочитать JSON резервной копии'); }
    if (raw.format !== 'SimpleSchedule.PWA' || raw.version !== 1 || !Array.isArray(raw.records) || raw.records.length > 100000) throw new Error('Неподдерживаемый формат резервной копии');
    const records = raw.records.map(sanitizeEntity);
    if (new Set(records.map(record => record.id)).size !== records.length) throw new Error('В резервной копии повторяются ID');
    const rawConflicts = raw.conflicts ?? [];
    if (!Array.isArray(rawConflicts) || rawConflicts.length > 100000) throw new Error('Некорректные конфликты резервной копии');
    const conflicts: SavedConflict[] = rawConflicts.map(value => {
      const item = object(value), serverRecord = sanitizeEntity(item.serverRecord);
      if (item.entityId !== serverRecord.id || item.kind !== serverRecord.kind || !Array.isArray(item.conflictingFields) || !item.conflictingFields.every(field => typeof field === 'string')) throw new Error('Некорректный конфликт');
      return { id: identifier(item.id), entityId: serverRecord.id, kind: serverRecord.kind, serverRecord,
        localData: item.localData === null ? null : sanitizeData(serverRecord.kind, item.localData),
        baseData: item.baseData === null ? null : sanitizeData(serverRecord.kind, item.baseData),
        conflictingFields: item.conflictingFields as string[], createdAt: typeof item.createdAt === 'number' ? item.createdAt : Date.now() };
    });
    const metadata = raw.importMetadata ? validateImportMetadata(raw.importMetadata) : null;
    const pending = raw.pendingOperations ?? [];
    if (!Array.isArray(pending) || pending.length > 100000) throw new Error('Некорректные черновики резервной копии');
    const recordsById = new Map(records.map(record => [record.id, record]));
    for (const value of pending) {
      const operation = object(value), record = recordsById.get(identifier(operation.entityId));
      if (!record || operation.kind !== record.kind) throw new Error('Черновик ссылается на неизвестную запись');
      const data = operation.data === null ? null : sanitizeData(record.kind, operation.data);
      if (record.deleted && data) conflicts.push({
        id: uuid(), entityId: record.id, kind: record.kind, localData: data,
        baseData: operation.base === null ? null : sanitizeData(record.kind, operation.base),
        serverRecord: record, conflictingFields: ['deleted'], createdAt: Date.now(),
      });
    }
    await this.transaction(async () => {
      // Groups precede tasks, although the complete import is one atomic transaction.
      for (const record of records.sort((a, b) => Number(b.kind === 'group') - Number(a.kind === 'group'))) {
        const current = await this.db.entities.get(record.id);
        if (current?.deleted && !record.deleted) throw new Error('Копия содержит уже удалённую запись. Импортируйте её в пустое локальное пространство');
        if (record.deleted && !current) {
          // Keep source tombstones so the next timetable refresh will not resurrect a hidden lesson.
          await this.writeInside(record.kind, record.id, record.data);
        }
        await this.writeInside(record.kind, record.id, record.deleted ? null : record.data);
      }
      // Broken references from a backup are normalized, not allowed to leak to another account.
      const groups = new Set((await this.active('group')).map(group => group.id));
      for (const task of await this.active('task')) if (task.data.groupId && !groups.has(String(task.data.groupId))) await this.writeInside('task', task.id, { ...task.data, groupId: null });
      if (conflicts.length) await this.db.conflicts.bulkPut(conflicts);
      if (metadata) await this.db.meta.put({ key: 'import', value: metadata });
    });
  }
  /** Unknown/unpublished dates are absent from coveredDays and never clear saved lessons. */
  async mergeImportedLessons(payload: ScheduleImport): Promise<{ added: number; changed: number; removed: number }> {
    const groupId = identifier(payload.groupId, 'Учебная группа');
    const metadata = validateImportMetadata({ ...payload, updatedAt: Date.now() });
    if (!Array.isArray(payload.lessons) || payload.lessons.length > 20000) throw new Error('Некорректное расписание');
    const covered = new Set(metadata.coveredDays);
    const imported = payload.lessons.map(input => {
      const data = sanitizeData('lesson', { ...input, sourceGroupId: groupId });
      if (!covered.has(String(data.date))) throw new Error('Занятие находится вне подтверждённых дат');
      const sourceId = identifier(data.sourceId, 'Источник занятия');
      const id = typeof (input as { id?: unknown }).id === 'string' ? identifier((input as { id?: string }).id) : `source:${groupId}:${sourceId}`;
      identifier(id);
      return { id, data };
    });
    if (new Set(imported.map(record => record.id)).size !== imported.length) throw new Error('Повторяющиеся занятия в импорте');
    return this.transaction(async () => {
      let added = 0, changed = 0, removed = 0;
      const fresh = new Set(imported.map(record => record.id));
      for (const item of imported) {
        const current = await this.db.entities.get(item.id);
        if (current && current.kind !== 'lesson') throw new Error('ID занятия уже занят другой записью');
        if (current?.deleted) continue;
        const baseline: Record<string, unknown> = {};
        for (const key of ['date', 'startMinute', 'endMinute', 'subject', 'kind', 'teacher', 'room', 'subgroup', 'sourceId', 'sourceGroupId']) baseline[key] = item.data[key];
        if (!current) {
          await this.writeInside('lesson', item.id, { ...item.data, sourceBaseline: baseline, sourceCancelled: false }); added++;
        } else {
          const previous = current.data.sourceBaseline as Record<string, unknown> | undefined;
          const merged: Record<string, unknown> = { ...current.data, sourceBaseline: baseline, sourceCancelled: false };
          for (const key of Object.keys(baseline)) {
            // No baseline means an older/manual value must be kept rather than guessed away.
            if (previous && equal(current.data[key], previous[key])) merged[key] = baseline[key];
          }
          if (!equal(current.data, merged)) { await this.writeInside('lesson', item.id, sanitizeData('lesson', merged)); changed++; }
        }
      }
      for (const old of await this.active('lesson')) {
        if (old.data.sourceGroupId === groupId && covered.has(String(old.data.sourceBaseline && object(old.data.sourceBaseline).date || old.data.date)) && !fresh.has(old.id)) {
          const previous = old.data.sourceBaseline as Record<string, unknown> | undefined;
          const hasPersonalChanges = Boolean(old.data.homework) || !previous || Object.keys(previous).some(key => !equal(old.data[key], previous[key]));
          if (hasPersonalChanges) {
            // Retain homework/edits as a manual lesson when its source disappears.
            const retained = { ...old.data }; delete retained.sourceId; delete retained.sourceGroupId; delete retained.sourceBaseline; delete retained.sourceCancelled;
            await this.writeInside('lesson', old.id, retained);
            removed++;
          } else if (old.data.sourceCancelled !== true) {
            // Source cancellation is reversible; a user's own deletion remains a tombstone.
            await this.writeInside('lesson', old.id, { ...old.data, sourceCancelled: true }); removed++;
          }
        }
      }
      await this.db.meta.put({ key: 'import', value: metadata });
      return { added, changed, removed };
    });
  }
}
function validateImportMetadata(value: unknown): ImportMetadata {
  const item = object(value);
  if (!Array.isArray(item.subgroups) || !Array.isArray(item.coveredDays) || item.subgroups.length > 100 || item.coveredDays.length > 2000) throw new Error('Некорректные сведения импорта');
  return {
    groupId: identifier(item.groupId), subgroups: [...new Set(item.subgroups.map(value => identifier(value, 'Подгруппа')))].sort((a, b) => a.localeCompare(b, 'ru', { numeric: true })),
    coveredDays: [...new Set(item.coveredDays.map(value => { if (!isCivilDate(value)) throw new Error('Некорректная дата импорта'); return value; }))].sort(),
    updatedAt: typeof item.updatedAt === 'number' && Number.isFinite(item.updatedAt) ? item.updatedAt : Date.now(),
  };
}
export function createStore(namespace = 'guest'): PlannerStore { return new PlannerStore(namespace); }
/** The caller must obtain consent; keep a pre-merge backup available for download. */
export async function mergeGuestIntoAccount(guest: PlannerStore, account: PlannerStore): Promise<string> {
  if (guest.namespace !== 'guest' || account.namespace === 'guest') throw new Error('Выберите локальные данные и отдельный аккаунт');
  const backup = await guest.exportData();
  const stamp = Date.now();
  await guest.db.meta.put({ key: `backup-before-account-merge:${stamp}`, value: backup });
  await account.db.meta.put({ key: `backup-before-guest-merge:${stamp}`, value: await account.exportData() });
  const parsed = JSON.parse(backup) as Backup;
  await account.db.transaction('rw', account.db.entities, account.db.server, account.db.outbox, account.db.conflicts, account.db.meta, async () => {
    const additions: Entity[] = [], collisions: SavedConflict[] = [];
    for (const incoming of parsed.records) {
      const existing = await account.db.entities.get(incoming.id);
      if (!existing) additions.push(incoming);
      else if (existing.kind !== incoming.kind) throw new Error('Совпадающий ID принадлежит другому типу записи');
      else if (existing.deleted !== incoming.deleted || !equal(existing.data, incoming.data)) collisions.push({
        id: uuid(), entityId: incoming.id, kind: incoming.kind, localData: incoming.deleted ? null : incoming.data,
        baseData: null, serverRecord: existing, conflictingFields: ['Объединение локальных данных'], createdAt: stamp,
      });
    }
    const incomingIds = new Set(additions.map(record => record.id));
    await account.importData(JSON.stringify({ ...parsed, records: additions, pendingOperations: parsed.pendingOperations?.filter(operation => incomingIds.has(operation.entityId)), conflicts: parsed.conflicts ?? [], importMetadata: null }));
    if (collisions.length) await account.db.conflicts.bulkPut(collisions);
  });
  return backup;
}
