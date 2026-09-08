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
