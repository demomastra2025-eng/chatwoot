import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: ref('en'),
    t: key => key,
  }),
}));

import CrmTaskBoard from './CrmTaskBoard.vue';

const mountBoard = (props = {}) =>
  shallowMount(CrmTaskBoard, {
    props,
    global: {
      mocks: {
        $t: key => key,
      },
    },
  });

describe('CrmTaskBoard', () => {
  it('keeps only today and tomorrow visible without optional tasks', () => {
    const wrapper = mountBoard();
    const columns = wrapper.findAll('.crm-task-board-column');
    const colorBars = wrapper.findAll('.crm-task-board-bucket-color');

    expect(columns).toHaveLength(2);
    expect(
      columns.every(column => column.classes().includes('w-[18rem]'))
    ).toBe(true);
    expect(colorBars).toHaveLength(2);
    expect(colorBars.map(bar => bar.attributes('style'))).toEqual([
      'background-color: rgb(135, 241, 192);',
      'background-color: rgb(231, 232, 234);',
    ]);
  });

  it('shows week, month, and future columns only when they have tasks', () => {
    const now = new Date();
    const dueInDays = days =>
      new Date(now.getTime() + days * 24 * 60 * 60 * 1000).toISOString();
    const wrapper = mountBoard({
      tasks: [
        { dueAt: dueInDays(5), id: 1, title: 'Next week' },
        { dueAt: dueInDays(15), id: 2, title: 'This month' },
        { dueAt: dueInDays(45), id: 3, title: 'Future' },
      ],
    });

    const colorBars = wrapper.findAll('.crm-task-board-bucket-color');
    expect(wrapper.findAll('.crm-task-board-column')).toHaveLength(5);
    expect(colorBars.slice(1).map(bar => bar.attributes('style'))).toEqual([
      'background-color: rgb(231, 232, 234);',
      'background-color: rgb(231, 232, 234);',
      'background-color: rgb(231, 232, 234);',
      'background-color: rgb(231, 232, 234);',
    ]);
  });

  it('exposes a native button for opening a task with the keyboard', async () => {
    const task = {
      dueAt: new Date().toISOString(),
      id: 1,
      title: 'Follow up',
    };
    const wrapper = mountBoard({ tasks: [task] });

    const openButton = wrapper.find('[data-test="open-task"]');
    expect(openButton.element.tagName).toBe('BUTTON');

    await openButton.trigger('click');

    expect(wrapper.emitted('selectTask')).toEqual([[task]]);
  });
});
