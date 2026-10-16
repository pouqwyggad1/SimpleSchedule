import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, apiRequest, parseRetryAfter } from './api';

const now = Date.parse('2026-10-16T15:00:00Z');
afterEach(() => vi.unstubAllGlobals());

describe('API retry information', () => {
  it('reads seconds and a future HTTP date, rounding remaining seconds up', () => {
    expect(parseRetryAfter('60', now)).toBe(60);
    expect(parseRetryAfter(' 0 ', now)).toBe(0);
    expect(parseRetryAfter('Fri, 16 Oct 2026 15:01:00 GMT', now + 500)).toBe(60);
    expect(parseRetryAfter('Fri, 16 Oct 2026 14:59:00 GMT', now)).toBe(0);
  });
  it('rejects missing, ambiguous, negative and unsafe values', () => {
    for (const value of [null, '', '-3', '1.5', 'Infinity', '1e4', 'NaN', 'invalid date', '99999999999999999999']) expect(parseRetryAfter(value, now)).toBeNull();
  });
  it('preserves HTTP status and retry metadata on a rejected request', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ error: 'Подождите', retryAfterSeconds: 30 }), { status: 429, headers: { 'Retry-After': '45' } })));
    const error = await apiRequest('/api/auth/request-code', { email: 'person@example.com' }).catch(error => error);
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({ message: 'Подождите', status: 429, retryAfterSeconds: 45 });
  });
  it('falls back to numeric body metadata when the header is absent or invalid', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ error: 'Подождите', retryAfterSeconds: 23 }), { status: 429, headers: { 'Retry-After': '-5' } })));
    await expect(apiRequest('/api/auth/request-code', {})).rejects.toMatchObject({ status: 429, retryAfterSeconds: 23 });
  });
  it('does not turn malformed error payloads into type errors', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('null', { status: 503 })));
    await expect(apiRequest('/api/auth/request-code', {})).rejects.toMatchObject({ status: 503, retryAfterSeconds: null, message: 'Запрос не выполнен (503)' });
  });
});
