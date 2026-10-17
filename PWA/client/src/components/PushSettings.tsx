import { useEffect, useState } from 'react';
import { apiRequest } from './api';
import { Icon } from './UI';

interface PushConfig { configured: boolean; publicKey: string }
export function pushDeviceId(): string {
  const key = 'SimpleSchedule.pushDevice';
  const saved = localStorage.getItem(key);
  if (saved && /^[0-9a-f-]{36}$/i.test(saved)) return saved;
  const id = crypto.randomUUID(); localStorage.setItem(key, id); return id;
}
export async function pushApi<T>(path: string, user: string, body: unknown): Promise<T> {
  const response = await fetch(path, { method: 'POST', credentials: 'same-origin', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'X-SimpleSchedule-Account': user }, body: JSON.stringify(body) });
  const data = await response.json() as T & { error?: string };
  if (!response.ok) throw new Error(data.error ?? 'Не удалось настроить уведомления. Повторите позже.');
  return data;
}
export function PushSettings({ userId, onError, onToast }: { userId?: string; onError: (error: unknown) => void; onToast: (text: string) => void }) {
  const [config, setConfig] = useState<PushConfig | null>(null);
  const [registration, setRegistration] = useState<ServiceWorkerRegistration | null>(null);
  const [registered, setRegistered] = useState(false);
  const [permission, setPermission] = useState<NotificationPermission>(() => 'Notification' in window ? Notification.permission : 'default');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const supported = isSecureContext && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1;
  const standalone = matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
  useEffect(() => {
    let active = true;
    if (!userId || !supported || (ios && !standalone)) return;
    void (async () => {
      try {
        const next = await apiRequest<PushConfig>('/api/push/config');
        if (!active) return;
        setConfig(next);
        const sw = await navigator.serviceWorker.ready;
        if (!active) return;
        setRegistration(sw);
        if (userId && next.configured) {
          const device = await pushApi<{ registered: boolean }>('/api/push/device', userId, { deviceId: pushDeviceId() });
          if (active) setRegistered(device.registered && !!await sw.pushManager.getSubscription());
        }
      } catch { if (active) setError('Не удалось проверить подключение. Откройте настройки снова при доступном интернете.'); }
    })();
    return () => { active = false; };
  }, [supported, ios, standalone, userId]);
  async function enable() {
    if (!userId || !config?.configured || !registration || busy) return;
    // This call must remain in the click handler, before any network await on iOS.
    const permissionRequest = Notification.requestPermission();
    setBusy(true); setError('');
    try {
      const result = await permissionRequest; setPermission(result);
      if (result !== 'granted') return;
      const binary = atob(config.publicKey.replace(/-/g, '+').replace(/_/g, '/'));
      const key = Uint8Array.from(binary, character => character.charCodeAt(0));
      const existing = await registration.pushManager.getSubscription();
      // A subscription is a device capability. Re-create it on explicit re-connection,
      // so another account's endpoint can never silently be reassigned.
      if (existing) await existing.unsubscribe();
      const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
      try {
        await pushApi('/api/push/register', userId, { deviceId: pushDeviceId(), endpoint: subscription.endpoint, keys: subscription.toJSON().keys });
      } catch (failure) { await subscription.unsubscribe(); throw failure; }
      setRegistered(true); onToast('Это устройство подключено к уведомлениям');
    } catch (failure) { onError(failure); }
    finally { setBusy(false); }
  }
  async function disable() {
    if (!userId || busy) return;
    setBusy(true);
    try {
      // Remove server capability first; a failed network request must not report success.
      await pushApi('/api/push/unregister', userId, { deviceId: pushDeviceId() });
      setRegistered(false);
      await (await registration?.pushManager.getSubscription())?.unsubscribe();
      onToast('Уведомления на этом устройстве отключены');
    } catch (failure) { onError(failure); } finally { setBusy(false); }
  }
  const help = !userId ? 'Войдите в аккаунт, чтобы получать уведомления на этом устройстве.'
    : ios && !standalone ? 'На iPhone откройте сайт в Safari → Поделиться → На экран «Домой». Запустите приложение с появившегося значка и подключите уведомления здесь.'
    : !supported ? 'Этот браузер не поддерживает Web Push. На iPhone используйте приложение с главного экрана.'
    : permission === 'denied' ? 'Доступ запрещён в системе. Разрешите уведомления SimpleSchedule в настройках iPhone, затем откройте приложение снова.'
    : config?.configured === false ? 'Сервер уведомлений ещё не настроен. Предпочтения сохраняются.'
    : registered ? 'Это устройство подключено. Включите общий переключатель ниже. Разрешение и подключение настраиваются на каждом устройстве отдельно.'
    : 'Подключите это устройство и разрешите уведомления в системном окне.';
  return <section className="settings-section"><div className="section-heading"><Icon name="bell"/><h3>На этом устройстве</h3></div>
    <p className="field-help" role="status">{help}</p>{error && <p className="inline-error" role="alert">{error}</p>}
    {userId && supported && (!ios || standalone) && <div className="settings-actions">
      <button className="button" disabled={busy || !config?.configured || !registration || (!registered && permission === 'denied')} onClick={() => void (registered ? disable() : enable())}>{busy ? 'Подождите…' : registered ? 'Отключить это устройство' : 'Подключить уведомления'}</button>
      {registered && <button className="button" disabled={busy || permission === 'denied'} onClick={async () => { setBusy(true); try { await pushApi('/api/push/test', userId, { deviceId: pushDeviceId() }); onToast('Push-служба приняла проверочное уведомление'); } catch (failure) { onError(failure); } finally { setBusy(false); } }}>Проверить уведомление</button>}
    </div>}
    <p className="field-help">Расписание использует время Иркутска. Уведомления приходят и при закрытом приложении. Сеть, режим фокусирования и энергосбережение могут задержать доставку. Отправка прекращается после выхода из аккаунта.</p>
  </section>;
}
