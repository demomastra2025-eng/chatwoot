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
import { buildTaskTypeResolver } from './taskTypeMetadata';

const DraggableStub = {
  name: 'Draggable',
  props: ['list'],
  template:
    '<div><slot v-for="item in list" name="item" :element="item" /></div>',
};

const mountBoard = (props = {}) =>
  shallowMount(CrmTaskBoard, {
    props,
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: { Draggable: DraggableStub },
    },
  });

describe('CrmTaskBoard', () => {
  it('renders the same indexed catalogue metadata as the list and accepts refreshed metadata', async () => {
    const resolve = name =>
      buildTaskTypeResolver(
        [{ id: 7, code: 'custom', name, icon: 'i-lucide-star', active: false }],
        key => key
      );
    const wrapper = mountBoard({
      taskTypeResolver: resolve('Custom label'),
      tasks: [
        {
          id: 1,
          taskTypeId: 7,
          activityType: 'custom',
          dueAt: new Date().toISOString(),
          title: 'Task',
        },
      ],
    });
    expect(wrapper.text()).toContain('Custom label');
    expect(wrapper.find('.i-lucide-star').exists()).toBe(true);
    await wrapper.setProps({ taskTypeResolver: resolve('Renamed label') });
    expect(wrapper.text()).toContain('Renamed label');
    expect(wrapper.text()).not.toContain('Custom label');
  });

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

  it('shows authoritative bucket totals and requests the next bucket page', async () => {
    const now = new Date();
    now.setHours(12, 0, 0, 0);
    const wrapper = mountBoard({
      bucketMeta: {
        today: { count: 26, hasMore: true, page: 1, perPage: 25 },
      },
      tasks: [{ dueAt: now.toISOString(), id: 1, title: 'Today' }],
    });

    expect(wrapper.text()).toContain('26');
    const loadMore = wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.TASKS.LOAD_MORE');
    await loadMore.trigger('click');

    expect(wrapper.emitted('loadMore')).toEqual([['today']]);
  });

  it('distinguishes confirmed empty buckets from filtered empty buckets', () => {
    const emptyBoard = mountBoard();
    const filteredBoard = mountBoard({ filtered: true });

    expect(emptyBoard.text()).toContain('CRM.TASKS.BOARD.EMPTY_COLUMN');
    expect(filteredBoard.text()).toContain('CRM.TASKS.LIST.EMPTY_FILTERED');
  });

  it('does not claim a bucket is empty while unloaded tasks remain', () => {
    const wrapper = mountBoard({
      bucketMeta: { today: { count: 3, hasMore: true, page: 1, perPage: 25 } },
    });
    const emptyBuckets = wrapper.findAll('[data-test="empty-task-bucket"]');

    expect(emptyBuckets).toHaveLength(1);
    expect(emptyBuckets[0].text()).toBe('CRM.TASKS.BOARD.EMPTY_COLUMN');
  });

  it('turns a failed incremental bucket load into a manual retry', async () => {
    const now = new Date();
    now.setHours(12, 0, 0, 0);
    const wrapper = mountBoard({
      bucketLoadFailed: { today: true },
      bucketMeta: {
        today: { count: 26, hasMore: true, page: 1, perPage: 25 },
      },
      tasks: [{ dueAt: now.toISOString(), id: 1, title: 'Today' }],
    });

    const retry = wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.TASKS.RETRY_LOAD');
    await retry.trigger('click');

    expect(wrapper.emitted('loadMore')).toEqual([['today']]);
  });

  it('announces an incremental bucket load as busy', () => {
    const wrapper = mountBoard({
      bucketLoading: { today: true },
      bucketMeta: {
        today: { count: 26, hasMore: true, page: 1, perPage: 25 },
      },
    });

    const loadMore = wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.TASKS.LOADING_MORE');

    expect(loadMore.attributes('aria-live')).toBe('polite');
    expect(loadMore.attributes('aria-busy')).toBe('true');
    expect(loadMore.attributes('disabled')).toBeDefined();
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

  it('moves a task with a native keyboard and touch due-date selector', async () => {
    const task = {
      boardTimeBucket: 'today',
      dueAt: new Date().toISOString(),
      id: 1,
      title: 'Follow up',
    };
    const wrapper = mountBoard({ canManage: true, tasks: [task] });

    const selector = wrapper.find('[data-test="move-task-bucket"]');
    expect(selector.element.tagName).toBe('SELECT');
    expect(selector.findAll('option')).toHaveLength(7);
    expect(selector.attributes('aria-label')).toBe(
      'CRM.TASKS.BOARD.MOVE_TO_BUCKET'
    );

    await selector.setValue('tomorrow');

    expect(wrapper.emitted('changeDueDate')).toEqual([
      [{ bucket: 'tomorrow', task }],
    ]);
    expect(wrapper.emitted('selectTask')).toBeUndefined();
  });

  it('disables only the selector for a task with a pending deadline mutation', () => {
    const wrapper = mountBoard({
      canManage: true,
      pendingTaskIds: new Set([1]),
      tasks: [
        {
          boardTimeBucket: 'today',
          dueAt: new Date().toISOString(),
          id: 1,
          title: 'Pending task',
        },
        {
          boardTimeBucket: 'tomorrow',
          dueAt: new Date(Date.now() + 86400000).toISOString(),
          id: 2,
          title: 'Ready task',
        },
      ],
    });

    const selectors = wrapper.findAll('[data-test="move-task-bucket"]');
    expect(selectors[0].attributes('disabled')).toBeDefined();
    expect(selectors[1].attributes('disabled')).toBeUndefined();
  });

  it('renders the task assignee as read-only text', () => {
    const wrapper = mountBoard({
      assignees: [{ label: 'Alex Assignee', value: 7 }],
      tasks: [
        {
          assigneeId: 7,
          dueAt: new Date().toISOString(),
          id: 1,
          title: 'Follow up',
        },
      ],
    });

    expect(wrapper.text()).toContain('Alex Assignee');
    expect(wrapper.emitted('changeAssignee')).toBeUndefined();
  });

  it('emits the target time bucket when a task is dropped', async () => {
    const tomorrow = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    tomorrow.setHours(12, 0, 0, 0);
    const task = { id: 9, dueAt: tomorrow.toISOString() };
    const wrapper = mountBoard({ canManage: true, tasks: [task] });
    const draggable = wrapper
      .findAllComponents({ name: 'Draggable' })
      .find(component =>
        component.props('list').some(item => item.id === task.id)
      );

    await draggable.vm.$emit('change', { added: { newIndex: 0 } });

    expect(wrapper.emitted('changeDueDate')).toEqual([
      [{ bucket: 'tomorrow', task }],
    ]);
  });

  it('keeps an emptied optional source column mounted until the drag finishes', async () => {
    const nextWeek = new Date();
    nextWeek.setDate(nextWeek.getDate() + 5);
    const task = { id: 10, dueAt: nextWeek.toISOString() };
    const wrapper = mountBoard({ canManage: true, tasks: [task] });
    const source = wrapper
      .findAllComponents({ name: 'Draggable' })
      .find(component =>
        component.props('list').some(item => item.id === task.id)
      );

    source.props('list').splice(0, 1);
    await wrapper.vm.$nextTick();

    expect(wrapper.findAll('.crm-task-board-column')).toHaveLength(3);
  });
});
