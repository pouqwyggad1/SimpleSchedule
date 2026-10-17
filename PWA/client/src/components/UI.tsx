import { createContext, useContext, useEffect, useId, useRef, useState, type ReactNode } from 'react';

export const FeedbackContext = createContext<{ text: string; error?: boolean } | null>(null);

export type IconName = 'calendar' | 'chevron-left' | 'chevron-right' | 'plus' | 'settings' | 'book' | 'refresh' | 'close' | 'check' | 'more' | 'edit' | 'trash' | 'layers' | 'clock' | 'pin' | 'person' | 'note' | 'arrow-left' | 'cloud' | 'offline' | 'download' | 'upload' | 'mail' | 'bell' | 'shield' | 'phone' | 'sun' | 'moon' | 'logout' | 'warning' | 'external';
const paths: Record<IconName, ReactNode> = {
  calendar: <><rect x="3" y="5" width="18" height="16" rx="4"/><path d="M7 3v4m10-4v4M3 10h18m-13 4h.01M12 14h.01M16 14h.01M8 17h.01M12 17h.01"/></>,
  'chevron-left': <path d="m14 6-6 6 6 6"/>, 'chevron-right': <path d="m10 6 6 6-6 6"/>, plus: <path d="M12 5v14M5 12h14"/>,
  settings: <><path d="m9 3-.6 2.2-2 .9-2-.6-2 3.5 1.6 1.6v2.3L2.5 15l2 3.5 2.2-.6 1.8 1L9 21h4l.6-2.2 2-.9 2 .6 2-3.5-1.6-1.6v-2.3L19.5 9l-2-3.5-2.2.6-1.8-1L13 3Z"/><circle cx="11" cy="12" r="3"/></>,
  book: <><path d="m2 8 10-5 10 5-10 5L2 8Zm4 2v7c4 3 8 3 12 0v-7m4-2v8"/></>, refresh: <><path d="M20 7v5h-5M4 17v-5h5"/><path d="M6 6a8 8 0 0 1 13 4M5 14a8 8 0 0 0 13 4"/></>,
  close: <path d="m6 6 12 12M6 18 18 6"/>, check: <path d="m5 12 4 4L19 6"/>, more: <><circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/></>,
  edit: <><path d="m14 5 5 5M4 20l5-1L20 8a2 2 0 0 0-5-5L4 14l-1 7Z"/></>, trash: <><path d="M3 6h18M9 6V3h6v3M6 6l1 15h10l1-15M10 10v7m4-7v7"/></>,
  layers: <><path d="m3 7 9-5 9 5-9 5-9-5Zm0 5 9 5 9-5M3 17l9 5 9-5"/></>, clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
  pin: <><path d="M18 10c0 5-6 11-6 11S6 15 6 10a6 6 0 1 1 12 0Z"/><circle cx="12" cy="10" r="2"/></>,
  person: <><circle cx="12" cy="7" r="4"/><path d="M4 21v-3a8 8 0 0 1 16 0v3Z"/></>, note: <><path d="M6 3h12v18l-6-4-6 4V3Z"/></>,
  'arrow-left': <path d="M20 12H4m6-6-6 6 6 6"/>, cloud: <path d="M7 18a5 5 0 1 1 1-9 6 6 0 0 1 11-1 5 5 0 0 1-1 10H7Z"/>,
  offline: <><path d="M3 3l18 18M2 9a16 16 0 0 1 4-2m4-1a16 16 0 0 1 12 3M5 13a10 10 0 0 1 5-2m5 .5a10 10 0 0 1 4 1.5M9 17a4 4 0 0 1 6 0"/><circle cx="12" cy="21" r=".5"/></>,
  download: <><path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/></>, upload: <><path d="M12 16V4m-5 5 5-5 5 5M4 16v5h16v-5"/></>,
  mail: <><rect x="2" y="4" width="20" height="16" rx="3"/><path d="m3 6 9 7 9-7"/></>,
  bell: <><path d="M5 17h14l-2-3V8a5 5 0 0 0-10 0v6l-2 3Zm5 4h4"/></>, shield: <><path d="m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6l9-4Z"/><path d="m8 12 3 3 5-6"/></>,
  phone: <><rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 18h4"/></>, sun: <><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1 1m12 12 1 1M5 19l1-1M18 6l1-1"/></>,
  moon: <path d="M20 15a9 9 0 0 1-11-11 9 9 0 1 0 11 11Z"/>, logout: <><path d="M10 3H4v18h6m4-15 6 6-6 6m-6-6h12"/></>, warning: <><path d="m12 3 10 18H2L12 3Z"/><path d="M12 9v5m0 3h.01"/></>, external: <><path d="M14 3h7v7m-9 2 9-9M10 5H3v16h16v-7"/></>
};
export function Icon({ name, size = 20, className = '' }: { name: IconName; size?: number; className?: string }) { return <svg className={className} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>; }

type ModalContent = ReactNode | ((dismiss: () => void) => ReactNode);
let openModalCount = 0;
let previousRootOverflow = '';

export function Modal({ title, description, children, footer, onClose, wide = false, dismissDisabled = false }: { title: string; description?: string; children: ModalContent; footer?: ModalContent; onClose: () => void; wide?: boolean; dismissDisabled?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const descriptionId = useId();
  const feedback = useContext(FeedbackContext);
  const [closing, setClosing] = useState(false);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  function dismiss() {
    if (closeTimer.current) return;
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) { closeRef.current(); return; }
    setClosing(true);
    closeTimer.current = setTimeout(() => closeRef.current(), 220);
  }
  function requestDismiss() { if (!dismissDisabled) dismiss(); }
  useEffect(() => {
    const dialog = ref.current;
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (openModalCount++ === 0) { previousRootOverflow = document.documentElement.style.overflow; document.documentElement.style.overflow = 'hidden'; }
    dialog?.showModal();
    return () => {
      if (closeTimer.current) { clearTimeout(closeTimer.current); closeTimer.current = null; }
      dialog?.close();
      if (opener?.isConnected) opener.focus({ preventScroll: true });
      if (--openModalCount === 0) document.documentElement.style.overflow = previousRootOverflow;
    };
  }, []);
  return <dialog ref={ref} className={`modal ${wide ? 'modal-wide' : ''}`} data-state={closing ? 'closing' : 'open'} onKeyDown={event => {
    if (event.key !== 'Tab') return;
    const targets = [...event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), a[href], summary, [tabindex="0"]')].filter(element => element.getClientRects().length > 0);
    const first = targets[0], last = targets[targets.length - 1];
    if (!first) { event.preventDefault(); return; }
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }} onCancel={event => { event.preventDefault(); requestDismiss(); }} onClick={event => { if (event.target === event.currentTarget) { const bounds = event.currentTarget.getBoundingClientRect(); if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) requestDismiss(); } }} aria-labelledby={titleId} aria-describedby={description ? descriptionId : undefined}>
    <header className="modal-header"><div><h2 id={titleId}>{title}</h2>{description && <p id={descriptionId}>{description}</p>}</div><button className="icon-button subtle" aria-label="Закрыть окно" onClick={requestDismiss} disabled={dismissDisabled}><Icon name="close"/></button></header>
    <div className="modal-body">{feedback?.error && <div className="modal-feedback" role="alert"><Icon name="warning" size={18}/><span>{feedback.text}</span></div>}{typeof children === 'function' ? children(dismiss) : children}</div>
    {footer && <footer className="modal-footer">{typeof footer === 'function' ? footer(dismiss) : footer}</footer>}
  </dialog>;
}
export function EmptyState({ schedule = false, title, detail, action }: { schedule?: boolean; title?: string; detail?: string; action?: ReactNode }) {
  return <div className="empty-state"><div className="empty-icon"><Icon name={schedule ? 'book' : 'calendar'} size={34}/><span><Icon name="check" size={12}/></span></div><h3>{title ?? (schedule ? 'На этот день занятий нет' : 'На этот день дел нет')}</h3>{detail && <p>{detail}</p>}{action}</div>;
}
export function Toggle({ checked, onChange, label, detail, disabled = false }: { checked: boolean; onChange: (checked: boolean) => void; label: string; detail?: string; disabled?: boolean }) {
  return <label className={`toggle-row ${disabled ? 'is-disabled' : ''}`}><span><strong>{label}</strong>{detail && <small>{detail}</small>}</span><input type="checkbox" role="switch" aria-label={label} checked={checked} onChange={event => onChange(event.target.checked)} disabled={disabled}/><span className="switch" aria-hidden="true"/></label>;
}
