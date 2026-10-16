export class ApiError extends Error {
  constructor(message: string, public readonly status: number, public readonly retryAfterSeconds: number | null = null) {
    super(message);
    this.name = 'ApiError';
  }
}

export function parseRetryAfter(value: string | null, now = Date.now()): number | null {
  if (value === null) return null;
  const text = value.trim();
  if (/^\d+$/.test(text)) {
    const seconds = Number(text);
    return Number.isSafeInteger(seconds) ? seconds : null;
  }
  // Accept the HTTP date format, rather than Date.parse's ambiguous numeric dates.
  if (!/^[a-z]{3}, \d{2} [a-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/i.test(text)) return null;
  const date = Date.parse(text);
  return Number.isFinite(date) ? Math.max(0, Math.ceil((date - now) / 1000)) : null;
}

export async function apiRequest<T = Record<string, unknown>>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, { method: body === undefined ? 'GET' : 'POST', credentials: 'same-origin', headers: { Accept: 'application/json', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), 'X-SimpleSchedule': '1' }, body: body === undefined ? undefined : JSON.stringify(body), cache: 'no-store' });
  const parsed: unknown = await response.json().catch(() => ({}));
  const data = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  if (!response.ok) {
    const bodyDelay = typeof data.retryAfterSeconds === 'number' && Number.isSafeInteger(data.retryAfterSeconds) && data.retryAfterSeconds >= 0 ? data.retryAfterSeconds : null;
    throw new ApiError(typeof data.error === 'string' ? data.error : typeof data.message === 'string' ? data.message : `Запрос не выполнен (${response.status})`, response.status, parseRetryAfter(response.headers.get('Retry-After')) ?? bodyDelay);
  }
  return data as T;
}
