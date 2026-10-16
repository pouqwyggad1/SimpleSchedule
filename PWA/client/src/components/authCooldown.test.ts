import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readAuthRetryAt, rememberAuthCooldown } from './authCooldown';

const now = Date.parse('2026-10-16T15:00:00Z');
beforeEach(() => {
  const values = new Map<string, string>();
  vi.stubGlobal('sessionStorage', {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  });
});
afterEach(() => vi.unstubAllGlobals());

describe('email code send cooldown', () => {
  it('survives reopening for the same normalized email without affecting another email', () => {
    expect(rememberAuthCooldown(' Person@Example.com ', 60, now)).toBe(now + 60_000);
    expect(readAuthRetryAt('person@example.com', now + 1000)).toBe(now + 60_000);
    expect(readAuthRetryAt('someone@example.com', now)).toBe(0);
    expect(readAuthRetryAt('person@example.com', now + 60_000)).toBe(0);
  });
  it('honors the server delay and falls back safely for invalid delays', () => {
    expect(rememberAuthCooldown('person@example.com', 25, now)).toBe(now + 25_000);
    for (const seconds of [NaN, -1, Infinity, Number.MAX_VALUE]) expect(rememberAuthCooldown('person@example.com', seconds, now)).toBe(now + 60_000);
  });
  it('keeps the in-memory timer available if session storage is blocked', () => {
    vi.stubGlobal('sessionStorage', { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } });
    expect(readAuthRetryAt('person@example.com', now)).toBe(0);
    expect(rememberAuthCooldown('person@example.com', 60, now)).toBe(now + 60_000);
  });
});
