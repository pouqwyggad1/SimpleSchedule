import React from 'react';
import ReactDOM from 'react-dom/client';
import { registerSW } from 'virtual:pwa-register';
import App from './App';
import './styles.css';

// Updates wait until the user saves or cancels open forms, then reloads manually.
const applyUpdate = registerSW({
  onNeedRefresh() { window.dispatchEvent(new Event('pwa-update-available')); },
  onOfflineReady() { window.dispatchEvent(new Event('pwa-offline-ready')); },
  onRegisterError() { /* Local planning remains available without a worker. */ },
});
window.addEventListener('pwa-apply-update', () => { void applyUpdate(true); });

class ErrorBoundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    if (this.state.failed) return <main style={{ padding: 'max(24px, env(safe-area-inset-top))', fontFamily: 'system-ui', maxWidth: 560, margin: 'auto' }}>
      <h1>Не удалось открыть календарь</h1><p>Локальные данные не удалены. Закройте и снова откройте приложение. Если ошибка повторяется, сохраните данные браузера и сообщите о проблеме.</p>
      <button onClick={() => location.reload()}>Открыть снова</button>
    </main>;
    return this.props.children;
  }
}
ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><ErrorBoundary><App /></ErrorBoundary></React.StrictMode>);
