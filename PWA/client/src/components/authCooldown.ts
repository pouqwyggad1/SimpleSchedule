const COOLDOWN_PREFIX = 'SimpleSchedule.authRetryAt.';
export const DEFAULT_AUTH_RETRY_SECONDS = 60;

export function normalizeAuthEmail(email: string): string { return email.trim().toLowerCase(); }

export function readAuthRetryAt(email: string, now = Date.now()): number {
  const key = COOLDOWN_PREFIX + encodeURIComponent(normalizeAuthEmail(email));
  try {
    const retryAt = Number(sessionStorage.getItem(key));
    if (Number.isSafeInteger(retryAt) && retryAt > now) return retryAt;
    sessionStorage.removeItem(key);
  } catch { /* The in-memory timer also works when browser storage is unavailable. */ }
  return 0;
}

export function rememberAuthCooldown(email: string, seconds: number, now = Date.now()): number {
  const delay = Number.isFinite(seconds) && seconds >= 0 ? Math.ceil(seconds) : DEFAULT_AUTH_RETRY_SECONDS;
  const candidate = now + delay * 1000;
  const retryAt = Number.isSafeInteger(candidate) ? candidate : now + DEFAULT_AUTH_RETRY_SECONDS * 1000;
  try { sessionStorage.setItem(COOLDOWN_PREFIX + encodeURIComponent(normalizeAuthEmail(email)), String(retryAt)); } catch { /* Storage is optional. */ }
  return retryAt;
}
