import { describe, expect, it } from 'vitest';
import {
  taskCatalogLabel,
  taskOutcomeLabel,
  taskStatusLabel,
  taskTypeLabel,
} from './taskCatalogLabels';

const t = key => key;

describe('task catalog labels', () => {
  it.each([
    ['Touch', 'touch'],
    ['Task', 'task'],
    ['Call', 'call'],
    ['Meeting', 'meeting'],
    ['Message', 'message'],
    ['Напоминание', 'touch'],
    ['Reminder', 'touch'],
    ['Еске салу', 'touch'],
    ['Звонок', 'call'],
    ['Қоңырау', 'call'],
  ])('shows the seeded type name %s by code through i18n', (name, code) => {
    expect(taskTypeLabel({ code, name }, t)).toBe(
      `CRM.TASKS.ACTIVITY_TYPE.${code}`
    );
  });

  it('keeps names an admin created or renamed', () => {
    expect(taskTypeLabel({ code: 'touch', name: 'Follow-up call' }, t)).toBe(
      'Follow-up call'
    );
    expect(taskTypeLabel({ code: 'visit', name: 'Touch' }, t)).toBe('Touch');
    expect(taskTypeLabel({ code: 'visit', name: 'Visit' }, t)).toBe('Visit');
    expect(taskTypeLabel({ code: 'visit' }, t)).toBe('visit');
  });

  it('falls back to the code translation when a system row has no name', () => {
    expect(taskTypeLabel({ code: 'call', name: '  ' }, t)).toBe(
      'CRM.TASKS.ACTIVITY_TYPE.call'
    );
    expect(taskTypeLabel(null, t)).toBe('');
  });

  it('translates seeded outcomes and keeps custom ones', () => {
    expect(taskOutcomeLabel({ code: 'no_answer', name: 'No answer' }, t)).toBe(
      'CRM.TASKS.OUTCOME.no_answer'
    );
    expect(taskOutcomeLabel({ code: 'no_show', name: 'No show' }, t)).toBe(
      'CRM.TASKS.OUTCOME.no_show'
    );
    expect(taskOutcomeLabel({ code: 'not_done', name: 'Not done' }, t)).toBe(
      'CRM.TASKS.OUTCOME.not_done'
    );
    expect(taskOutcomeLabel({ code: 'sent', name: 'Отправлено' }, t)).toBe(
      'CRM.TASKS.OUTCOME.sent'
    );
    expect(taskOutcomeLabel({ code: 'sent', name: 'Delivered' }, t)).toBe(
      'Delivered'
    );
  });

  it('translates seeded statuses and keeps custom ones', () => {
    expect(taskStatusLabel({ code: 'todo', name: 'To do' }, t)).toBe(
      'CRM.TASKS.STATUS_NAMES.todo'
    );
    expect(taskStatusLabel({ code: 'done', name: 'Завершено' }, t)).toBe(
      'CRM.TASKS.STATUS_NAMES.done'
    );
    expect(taskStatusLabel({ code: 'waiting', name: 'Waiting' }, t)).toBe(
      'Waiting'
    );
    expect(taskStatusLabel({ code: 'todo', name: 'Backlog' }, t)).toBe(
      'Backlog'
    );
  });

  it('never returns the word Touch for a seeded system row', () => {
    const rows = [
      taskCatalogLabel('type', { code: 'touch', name: 'Touch' }, t),
      taskCatalogLabel('type', { code: 'touch', name: 'touch' }, t),
    ];
    rows.forEach(label => expect(label).not.toMatch(/\bTouch\b/));
  });
});
