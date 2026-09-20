import { flushPromises, shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/crm/tasks', () => ({
  default: {
    get: vi.fn().mockResolvedValue({ data: { payload: [] } }),
  },
}));

vi.mock('dashboard/api/crm/deals', () => ({
  default: {
    clearWaiting: vi.fn(),
    setWaiting: vi.fn(),
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

import CrmDealTasksPanel from './CrmDealTasksPanel.vue';
import CrmTasksAPI from 'dashboard/api/crm/tasks';

const DialogStub = {
  name: 'Dialog',
  props: ['disableConfirmButton'],
  setup(_, { expose }) {
    expose({ close: vi.fn(), open: vi.fn() });
  },
  template: '<div><slot /></div>',
};

const deal = {
  id: 1,
  lockVersion: 0,
  title: 'First deal',
};

const mountPanel = props =>
  shallowMount(CrmDealTasksPanel, {
    props: {
      deal,
      ...props,
    },
    global: {
      mocks: { $t: key => key },
      stubs: { Dialog: DialogStub },
    },
  });

describe('CrmDealTasksPanel waiting controls', () => {
  it('allows deal managers to set waiting without task permissions', async () => {
    const wrapper = mountPanel({
      canManageDeals: true,
      canManageTasks: false,
    });
    await flushPromises();

    const actionLabels = wrapper
      .findAllComponents({ name: 'Button' })
      .map(button => button.props('label'));
    expect(actionLabels).toContain('CRM.DEALS.WAITING.SET_ACTION');
    expect(wrapper.text()).not.toContain(
      'CRM.DEALS.WAITING.CREATE_WAKE_UP_TASK'
    );
  });

  it('keeps confirmation disabled until the date and reason are present', async () => {
    const wrapper = mountPanel({ canManageDeals: true });
    await flushPromises();

    const waitingDialog = wrapper.findComponent({ name: 'Dialog' });
    expect(waitingDialog.props('disableConfirmButton')).toBe(true);
  });
});

describe('CrmDealTasksPanel load states', () => {
  it('shows a retryable error instead of the confirmed-empty state', async () => {
    CrmTasksAPI.get.mockRejectedValueOnce(new Error('Network unavailable'));
    const wrapper = mountPanel({ canManageTasks: true });
    await flushPromises();

    const errorState = wrapper.findComponent({ name: 'SchedulingErrorState' });
    expect(errorState.exists()).toBe(true);
    expect(wrapper.text()).not.toContain('CRM.DEALS.TASKS.EMPTY_TITLE');

    CrmTasksAPI.get.mockResolvedValueOnce({ data: { payload: [] } });
    await wrapper.vm.$.setupState.loadTasks();
    await flushPromises();

    expect(wrapper.vm.$.setupState.ui.error).toBeNull();
    expect(
      wrapper.findComponent({ name: 'SchedulingErrorState' }).exists()
    ).toBe(false);
    expect(wrapper.text()).toContain('CRM.DEALS.TASKS.EMPTY_TITLE');
  });

  it.each([
    ['reassigned', { dealId: 2 }],
    ['archived', { archivedAt: '2026-09-20T10:00:00Z' }],
    ['cancelled', { cancelledAt: '2026-09-20T10:00:00Z' }],
  ])(
    'closes a selected task after it is %s in realtime',
    async (_state, change) => {
      const task = {
        assigneeId: 1,
        dealId: deal.id,
        id: 7,
        lockVersion: 1,
        title: 'Follow up',
      };
      CrmTasksAPI.get.mockResolvedValueOnce({ data: { payload: [task] } });
      const wrapper = mountPanel({ canManageTasks: true });
      await flushPromises();
      const state = wrapper.vm.$.setupState;
      state.openTaskDialog(task);

      state.applyTaskRealtimeUpdate({
        ...task,
        ...change,
        lockVersion: 2,
      });

      expect(state.tasks).toEqual([]);
      expect(state.selectedTask).toBeNull();
    }
  );
});
