import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { reactive, ref } from 'vue';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import CrmDealAppointmentsPanel from './CrmDealAppointmentsPanel.vue';

const state = vi.hoisted(() => ({ route: null }));
vi.mock('vue-router', () => ({ useRoute: () => state.route }));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: ref('en') }),
}));
vi.mock('dashboard/api/crm/deals', () => ({
  default: {
    appointments: vi.fn(),
    resumeAppointmentAutomation: vi.fn(),
  },
}));

const deal = () => ({
  id: 8,
  lockVersion: 2,
});
const rows = [
  {
    id: 41,
    starts_at: '2026-10-10T07:00:00Z',
    patient_contact_name: 'First child',
    service_name: 'Consultation',
    status: 'completed',
    actual_attended: true,
  },
  {
    id: 42,
    starts_at: '2026-10-11T07:00:00Z',
    patient_contact_name: 'Second child',
    status: 'cancelled',
    actual_attended: false,
  },
];
const mountPanel = (props = {}) =>
  mount(CrmDealAppointmentsPanel, {
    props: { deal: deal(), canManage: true, ...props },
    global: {
      mocks: {
        $t: (key, params) => `${key}${params ? JSON.stringify(params) : ''}`,
      },
      stubs: {
        Button: {
          props: ['label', 'disabled'],
          emits: ['click'],
          template:
            '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
    },
  });

describe('CrmDealAppointmentsPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.route = reactive({ params: { accountId: '1' } });
    CrmDealsAPI.appointments.mockResolvedValue({
      data: { payload: rows, meta: { timezone: 'Asia/Almaty' } },
    });
  });

  it('shows linked appointments without the required appointments plan editor', async () => {
    const wrapper = mountPanel();
    await flushPromises();

    expect(wrapper.text()).toContain('First child · Consultation');
    expect(wrapper.text()).toContain('Second child');
    expect(wrapper.text()).toContain(
      'CRM.DEAL_APPOINTMENTS.STATUSES.COMPLETED'
    );
    expect(wrapper.text()).toContain(
      'CRM.DEAL_APPOINTMENTS.STATUSES.CANCELLED'
    );
    expect(wrapper.text()).toContain('12:00');
    expect(wrapper.find('details').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('CRM.DEAL_APPOINTMENTS.PLAN_TITLE');
  });

  it('allows resuming paused stage automation', async () => {
    CrmDealsAPI.resumeAppointmentAutomation.mockResolvedValue({
      data: { payload: { ...deal(), lock_version: 3 } },
    });
    const wrapper = mountPanel({
      deal: {
        ...deal(),
        appointmentAutomationState: { pausedAt: '2026-10-10T08:00:00Z' },
      },
    });
    await flushPromises();

    const resumeButton = wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.DEAL_APPOINTMENTS.RESUME');
    expect(resumeButton).toBeTruthy();
    await resumeButton.trigger('click');
    await flushPromises();

    expect(CrmDealsAPI.resumeAppointmentAutomation).toHaveBeenCalledWith(8, {
      lock_version: 2,
    });
    expect(wrapper.emitted('dealUpdated')).toHaveLength(1);
  });

  it('does not show another account appointment response after context changes', async () => {
    let releaseOld;
    CrmDealsAPI.appointments.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          releaseOld = resolve;
        })
    );
    CrmDealsAPI.appointments.mockResolvedValueOnce({
      data: { payload: [], meta: { timezone: 'UTC' } },
    });
    const wrapper = mountPanel();
    state.route.params.accountId = '2';
    await flushPromises();
    releaseOld({ data: { payload: rows } });
    await flushPromises();

    expect(wrapper.text()).not.toContain('First child');
    expect(wrapper.text()).not.toContain('Second child');
  });
});
