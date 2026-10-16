/** Civil dates and wall-clock minutes deliberately never pass through UTC. */
export type CivilDate = string;
export type EntityKind = 'task' | 'group' | 'lesson' | 'preferences';
export interface TaskData { title: string; date: CivilDate; groupId: string | null; note: string; completed: boolean }
export interface GroupData { name: string; color: string }
export interface LessonData {
  date: CivilDate; startMinute: number; endMinute: number; subject: string; kind: string;
  teacher: string; room: string; subgroup: string | null; homework: string;
  sourceId?: string; sourceGroupId?: string; sourceBaseline?: Record<string, unknown>; sourceCancelled?: boolean;
}
export interface Preferences {
  instituteId: string | null; groupId: string | null; subgroup: string | null;
  durationMinutes: number; refreshMode: 'manual' | 'auto'; refreshIntervalHours: number;
  notificationsEnabled: boolean; beforeLessonEnabled: boolean; scheduleChangesEnabled: boolean;
  leadMinutes: number; mutedSubjects: string[]; mutedDates: CivilDate[];
}
export type Task = TaskData & { id: string; version: number };
export type Group = GroupData & { id: string; version: number };
export type Lesson = LessonData & { id: string; version: number };
export interface Entity {
  id: string; kind: EntityKind; data: Record<string, unknown>; version: number; deleted: boolean;
}
export interface Operation {
  operationId: string; entityId: string; kind: EntityKind; baseVersion: number;
  base: Record<string, unknown> | null; data: Record<string, unknown> | null;
}
export interface QueuedOperation extends Operation { order: number; queuedAt: number }
export interface OperationResult {
  operationId: string; status: 'applied' | 'conflict'; record: Entity; conflictingFields: string[];
}
export interface SyncResponse { records: Entity[]; results?: OperationResult[]; revision: number }
export interface SavedConflict {
  id: string; entityId: string; kind: EntityKind; localData: Record<string, unknown> | null;
  baseData: Record<string, unknown> | null; serverRecord: Entity; conflictingFields: string[]; createdAt: number;
}
export interface ImportMetadata { groupId: string; subgroups: string[]; coveredDays: CivilDate[]; updatedAt: number }
export type ImportedLesson = LessonData & { sourceId: string };
export interface ScheduleImport {
  lessons: ImportedLesson[]; coveredDays: CivilDate[]; subgroups: string[]; groupId: string;
}
export interface Backup {
  format: 'SimpleSchedule.PWA'; version: 1; exportedAt: string; records: Entity[];
  conflicts?: SavedConflict[]; pendingOperations?: Operation[]; importMetadata?: ImportMetadata | null;
}
export const DEFAULT_PREFERENCES: Preferences = {
  instituteId: null, groupId: null, subgroup: null, durationMinutes: 90,
  refreshMode: 'manual', refreshIntervalHours: 1, notificationsEnabled: false,
  beforeLessonEnabled: true, scheduleChangesEnabled: true, leadMinutes: 5,
  mutedSubjects: [], mutedDates: [],
};
