export interface Appearance { theme: 'system' | 'light' | 'dark'; transparency: number }

export function readAppearance(): Appearance {
  try {
    const value = JSON.parse(localStorage.getItem('SimpleSchedule.appearance') ?? '{}');
    return { theme: ['light', 'dark', 'system'].includes(value.theme) ? value.theme : 'system', transparency: Number.isFinite(value.transparency) ? Math.max(0, Math.min(95, value.transparency)) : 35 };
  } catch { return { theme: 'system', transparency: 35 }; }
}

export function applyAppearance(appearance: Appearance) {
  const root = document.documentElement;
  if (appearance.theme === 'system') root.removeAttribute('data-theme');
  else root.dataset.theme = appearance.theme;
  root.dataset.reduceTransparency = String(appearance.transparency === 0);
  // Keep regular glass legible at either end; content surfaces stay opaque.
  root.style.setProperty('--glass-opacity', String(.9 - appearance.transparency / 95 * .22));
  const dark = appearance.theme === 'dark' || (appearance.theme === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#000000' : '#F2F2F7');
}
