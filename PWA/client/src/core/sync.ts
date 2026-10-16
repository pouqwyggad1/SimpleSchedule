import type { PlannerStore } from './store';
import type { Operation, SyncResponse } from './types';

export interface SyncSummary { revision: number; pending: number; conflicts: number }
export class SyncError extends Error {
  readonly status: number;
  constructor(message: string, status = 0) { super(message); this.name = 'SyncError'; this.status = status; }
}
// Two components/stores for one account must not race their full snapshots.
const locks = new Map<string, Promise<unknown>>();
export function createSyncEngine(store: PlannerStore, options: { fetcher?: typeof fetch; timeoutMs?: number } = {}) {
  const fetcher = options.fetcher ?? globalThis.fetch.bind(globalThis);
  async function exchange(): Promise<SyncSummary> {
    if (store.namespace === 'guest') return { revision: await store.revision(), pending: await store.pendingCount(), conflicts: (await store.listConflicts()).length };
    const candidates = await store.db.outbox.orderBy('order').limit(100).toArray();
    const batch = [] as typeof candidates;
    const encoder = new TextEncoder(); let payloadBytes = 32;
    for (const item of candidates) {
      const { operationId, entityId, kind, baseVersion, base, data } = item;
      const bytes = encoder.encode(JSON.stringify({ operationId, entityId, kind, baseVersion, base, data })).byteLength + 1;
      if (batch.length && payloadBytes + bytes > 1_500_000) break;
      batch.push(item); payloadBytes += bytes;
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 30000);
    try {
      const operations: Operation[] = batch.map(({ operationId, entityId, kind, baseVersion, base, data }) => ({ operationId, entityId, kind, baseVersion, base, data }));
      const response = await fetcher('/api/sync', {
        method: batch.length ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store', signal: controller.signal,
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-SimpleSchedule': '1', 'X-SimpleSchedule-Account': store.namespace },
        ...(batch.length ? { body: JSON.stringify({ operations }) } : {}),
      });
      if (!response.ok) {
        let message = response.status === 401 ? 'Войдите снова, чтобы продолжить синхронизацию' : `Синхронизация недоступна (${response.status})`;
        try { const error = await response.json() as { error?: unknown }; if (typeof error.error === 'string') message = error.error; } catch { /* Preserve the safe status description. */ }
        throw new SyncError(message, response.status);
      }
      const payload = await response.json() as SyncResponse;
      await store.acceptSync(payload, batch);
      return { revision: await store.revision(), pending: await store.pendingCount(), conflicts: (await store.listConflicts()).length };
    } catch (error) {
      if (error instanceof SyncError) throw error;
      if (error instanceof Error && error.name === 'AbortError') throw new SyncError('Сервер не ответил вовремя. Изменения сохранены на устройстве');
      if (error instanceof TypeError) throw new SyncError('Нет связи с сервером. Изменения сохранены на устройстве');
      throw error;
    } finally { clearTimeout(timer); }
  }
  return {
    async sync(): Promise<SyncSummary> {
      const previous = locks.get(store.namespace) ?? Promise.resolve();
      const current = previous.catch(() => undefined).then(async () => {
        let summary = await exchange();
        for (let page = 1; page < 20 && summary.pending > 0 && store.namespace !== 'guest'; page++) summary = await exchange();
        return summary;
      });
      locks.set(store.namespace, current);
      try { return await current; }
      finally { if (locks.get(store.namespace) === current) locks.delete(store.namespace); }
    },
  };
}
