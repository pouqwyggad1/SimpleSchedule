import { useId, useState } from 'react';
import { formatTime, parseTime, type Group, type Lesson, type LessonData, type Task, type TaskData } from '../core';
import { Icon, Modal } from './UI';

export function TaskEditor({ task, date, groupId, groups, onClose, onSave, onNewGroup }: { task?: Task; date: string; groupId: string | null; groups: Group[]; onClose: () => void; onSave: (data: TaskData, id?: string) => Promise<void>; onNewGroup: () => void }) {
  const formId = useId();
  const [title, setTitle] = useState(task?.title ?? '');
  const [taskDate, setTaskDate] = useState(task?.date ?? date);
  const [selectedGroup, setSelectedGroup] = useState(task?.groupId ?? groupId ?? '');
  const [note, setNote] = useState(task?.note ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  return <Modal title={task ? 'Изменить дело' : 'Новое дело'} description="Освободите голову — запишите важное" onClose={onClose} footer={<><span className="form-hint">Название и дата обязательны</span><button className="button" onClick={onClose} disabled={busy}>Отмена</button><button className="button primary" type="submit" form={formId} disabled={!title.trim() || !taskDate || busy}>{busy ? 'Сохранение…' : 'Сохранить'}</button></>}>
    <form id={formId} className="editor-form" onSubmit={async event => { event.preventDefault(); setBusy(true); setError(''); try { await onSave({ title: title.trim(), date: taskDate, groupId: selectedGroup || null, note: note.trim(), completed: task?.completed ?? false }, task?.id); onClose(); } catch (e) { setError(e instanceof Error ? e.message : 'Не удалось сохранить дело'); } finally { setBusy(false); } }}>
      <label className="field">Название<input autoFocus value={title} onChange={e => setTitle(e.target.value)} placeholder="Что нужно сделать?" required maxLength={300}/></label>
      <div className="form-columns"><label className="field">Дата<input type="date" required value={taskDate} onChange={e => setTaskDate(e.target.value)} min="0002-01-01" max="9998-12-31"/></label><label className="field">Группа<select aria-label="Группа" value={selectedGroup} onChange={e => setSelectedGroup(e.target.value)}><option value="">Без группы</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select></label></div>
      <button className="text-button create-group-link" type="button" onClick={onNewGroup}><Icon name="plus" size={17}/> Создать новую группу</button>
      <label className="field">Заметка <span className="optional">необязательно</span><textarea value={note} onChange={e => setNote(e.target.value)} placeholder="Подробности, ссылки и мысли" rows={5} maxLength={20000}/></label>
      {error && <p role="alert" className="inline-error">{error}</p>}
    </form>
  </Modal>;
}

const COLORS = ['#4F8DF7', '#22A576', '#E8A334', '#D46C93', '#9B7BE8', '#40A6B2', '#D96E51', '#8492A8'];
export function GroupEditor({ group, onClose, onSave }: { group?: Group; onClose: () => void; onSave: (data: { name: string; color: string }, id?: string) => Promise<void> }) {
  const formId = useId(); const [name, setName] = useState(group?.name ?? ''); const [color, setColor] = useState(group?.color ?? COLORS[0]); const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  return <Modal title={group ? 'Изменить группу' : 'Новая группа'} description="Соберите связанные дела под одной меткой" onClose={onClose} footer={<><button className="button" onClick={onClose}>Отмена</button><button form={formId} type="submit" className="button primary" disabled={!name.trim() || busy}>Сохранить</button></>}>
    <form id={formId} className="editor-form" onSubmit={async e => { e.preventDefault(); setBusy(true); try { await onSave({ name: name.trim(), color }, group?.id); onClose(); } catch (error) { setError(error instanceof Error ? error.message : 'Не удалось сохранить группу'); } finally { setBusy(false); } }}>
      <label className="field">Название группы<input value={name} onChange={e => setName(e.target.value)} autoFocus required maxLength={120} placeholder="Например, Учёба"/></label>
      <fieldset className="color-field"><legend>Цвет метки</legend><div className="color-options">{COLORS.map(value => <button key={value} type="button" className={`color-option ${color.toLowerCase() === value.toLowerCase() ? 'active' : ''}`} style={{ backgroundColor: value }} onClick={() => setColor(value)} aria-label={`Цвет ${value}`} aria-pressed={color.toLowerCase() === value.toLowerCase()}>{color.toLowerCase() === value.toLowerCase() && <Icon name="check"/>}</button>)}<label className="custom-color" title="Выбрать другой цвет"><Icon name="plus"/><input aria-label="Другой цвет группы" type="color" value={color} onChange={e => setColor(e.target.value)}/></label></div></fieldset>
      <div className="group-preview"><span className="group-dot" style={{ background: color }}/><strong>{name.trim() || 'Ваша группа'}</strong><span>Так метка выглядит в календаре</span></div>
      {error && <p role="alert" className="inline-error">{error}</p>}
    </form>
  </Modal>;
}

export function LessonEditor({ lesson, date, duration, onClose, onSave }: { lesson?: Lesson; date: string; duration: number; onClose: () => void; onSave: (data: LessonData, id?: string) => Promise<void> }) {
  const formId = useId();
  const [data, setData] = useState<LessonData>(lesson ? { ...lesson } : { date, startMinute: 9 * 60, endMinute: Math.min(1439, 9 * 60 + duration), subject: '', kind: 'Лекция', teacher: '', room: '', subgroup: null, homework: '' });
  const [endManuallySet, setEndManuallySet] = useState(Boolean(lesson));
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  function patch(values: Partial<LessonData>) { setData(previous => ({ ...previous, ...values })); }
  return <Modal title={lesson ? 'Изменить занятие' : 'Новое занятие'} description={lesson?.sourceId ? 'Личные изменения сохраняются при обновлении с сайта' : 'Расписание под вашим контролем'} onClose={onClose} footer={<><span className="form-hint">Предмет, дата и время обязательны</span><button className="button" onClick={onClose} disabled={busy}>Отмена</button><button className="button primary" type="submit" form={formId} disabled={!data.subject.trim() || !data.date || data.endMinute <= data.startMinute || busy}>{busy ? 'Сохранение…' : 'Сохранить'}</button></>}>
    <form id={formId} className="editor-form" onSubmit={async event => { event.preventDefault(); setBusy(true); setError(''); try { await onSave({ ...data, subject: data.subject.trim(), teacher: data.teacher.trim(), room: data.room.trim(), homework: data.homework.trim(), subgroup: data.subgroup?.trim() || null }, lesson?.id); onClose(); } catch (e) { setError(e instanceof Error ? e.message : 'Не удалось сохранить занятие'); } finally { setBusy(false); } }}>
      <label className="field">Предмет<input autoFocus value={data.subject} onChange={e => patch({ subject: e.target.value })} required maxLength={400} placeholder="Название дисциплины"/></label>
      <div className="form-columns"><label className="field">Дата<input type="date" required value={data.date} onChange={e => patch({ date: e.target.value })} min="0002-01-01" max="9998-12-31"/></label><label className="field">Вид занятия<input list="lesson-kinds" value={data.kind} onChange={e => patch({ kind: e.target.value })} placeholder="Лекция, практика…" maxLength={100}/><datalist id="lesson-kinds"><option value="Лекция"/><option value="Практика"/><option value="Лабораторная работа"/><option value="Семинар"/><option value="Консультация"/><option value="Экзамен"/><option value="Зачёт"/></datalist></label></div>
      <div className="form-columns"><label className="field">Начало<input type="time" required value={formatTime(data.startMinute)} onChange={e => { if (!e.target.value) return; const startMinute = parseTime(e.target.value); patch({ startMinute, ...(!endManuallySet ? { endMinute: Math.min(1439, startMinute + duration) } : {}) }); }}/></label><label className="field">Окончание<input type="time" required value={formatTime(data.endMinute)} onChange={e => { if (e.target.value) { patch({ endMinute: parseTime(e.target.value) }); setEndManuallySet(true); } }}/></label></div>
      <p className="field-help">Длительность по умолчанию — {duration} мин. Окончание можно изменить вручную.{endManuallySet && <button className="text-button inline" type="button" onClick={() => { patch({ endMinute: Math.min(1439, data.startMinute + duration) }); setEndManuallySet(false); }}>Рассчитать автоматически</button>}</p>
      {data.endMinute <= data.startMinute && <p className="inline-error">Окончание должно быть позже начала в пределах одного дня.</p>}
      <div className="form-columns"><label className="field">Аудитория<input value={data.room} onChange={e => patch({ room: e.target.value })} placeholder="Например, Б-100" maxLength={120}/></label><label className="field">Подгруппа <span className="optional">если есть</span><input value={data.subgroup ?? ''} onChange={e => patch({ subgroup: e.target.value || null })} placeholder="Общее занятие" maxLength={50}/></label></div>
      <label className="field">Преподаватель<input value={data.teacher} onChange={e => patch({ teacher: e.target.value })} placeholder="Фамилия и инициалы" maxLength={200}/></label>
      <label className="field">Домашнее задание<textarea value={data.homework} onChange={e => patch({ homework: e.target.value })} placeholder="Что подготовить к занятию?" rows={3} maxLength={20000}/></label>
      {error && <p role="alert" className="inline-error">{error}</p>}
    </form>
  </Modal>;
}
