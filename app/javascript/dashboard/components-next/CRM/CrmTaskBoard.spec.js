import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';

import CrmTaskBoard from './CrmTaskBoard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'en' },
    t: key => key,
  }),
}));

const localIso = (year, month, day, hour, minute = 0, second = 0) =>
  new Date(year, month, day, hour, minute, second).toISOString();

const mountBoard = tasks =>
  mount(CrmTaskBoard, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        CrmCustomFieldsSummary: true,
        CrmTaskAssigneeMenu: true,
      },
    },
    props: { tasks },
  });

describe('CrmTaskBoard', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 2, 1, 10, 0, 0));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('identifies the planning board and excludes completed or archived tasks', () => {
    const wrapper = mountBoard([
      { id: 1, title: 'Open task', dueAt: localIso(2026, 2, 1, 11) },
      {
        completedAt: localIso(2026, 2, 1, 9),
        dueAt: localIso(2026, 2, 1, 11),
        id: 2,
        title: 'Completed task',
      },
      {
        archivedAt: localIso(2026, 2, 1, 9),
        dueAt: localIso(2026, 2, 1, 11),
        id: 3,
        title: 'Archived task',
      },
    ]);

    expect(wrapper.get('[data-test="planning-only-note"]').text()).toBe(
      'CRM.TASKS.BOARD.PLANNING_ONLY'
    );
    expect(wrapper.text()).toContain('Open task');
    expect(wrapper.text()).not.toContain('Completed task');
    expect(wrapper.text()).not.toContain('Archived task');
  });

  it('moves a task to overdue as time passes without reloading tasks', async () => {
    vi.setSystemTime(new Date(2026, 2, 1, 23, 59, 40));
    const wrapper = mountBoard([
      {
        dueAt: localIso(2026, 2, 2, 0, 0, 30),
        id: 1,
        title: 'Midnight follow-up',
      },
    ]);

    expect(wrapper.find('[data-test="bucket-tomorrow"] article').exists()).toBe(
      true
    );

    await vi.advanceTimersByTimeAsync(60_000);
    await nextTick();

    expect(wrapper.find('[data-test="bucket-tomorrow"] article').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-test="bucket-overdue"] article').exists()).toBe(
      true
    );

    wrapper.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('honors the selected position sort within a due-date bucket', () => {
    const wrapper = mount(CrmTaskBoard, {
      global: {
        mocks: { $t: key => key },
        stubs: {
          CrmCustomFieldsSummary: true,
          CrmTaskAssigneeMenu: true,
        },
      },
      props: {
        sortDirections: { today: 'desc' },
        sortKey: 'position',
        sortValueResolver: (task, key) => task[key],
        tasks: [
          {
            dueAt: localIso(2026, 2, 1, 11),
            id: 1,
            position: 2,
            title: 'Later due, second position',
          },
          {
            dueAt: localIso(2026, 2, 1, 12),
            id: 2,
            position: 1,
            title: 'Later due, first position',
          },
        ],
      },
    });

    expect(
      wrapper
        .findAll('[data-test="open-task"] h4')
        .map(element => element.text())
    ).toEqual(['Later due, first position', 'Later due, second position']);
  });
});
