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
    appointmentPlan: vi.fn(),
    resumeAppointmentAutomation: vi.fn(),
  },
}));

const deal = () => ({
  id: 8,
  lockVersion: 2,
  appointmentPlan: Array.from({ length: 8 }, (_, index) => ({
    id: `visit-${index}`,
    label: `Visit ${index}`,
    required: true,
    appointmentId: index === 0 ? 41 : null,
  })),
});
const rows = [
  {
    id: 41,
    starts_at: '2026-10-10T07:00:00Z',
    patient_contact_name: 'First child',
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
        Input: true,
        SchedulingSelectField: true,
        Button: {
          props: ['label', 'disabled'],
          emits: ['click'],
          template:
            '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
    },
  });

describe('deal appointment plan', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.route = reactive({ params: { accountId: '1' } });
    CrmDealsAPI.appointments.mockResolvedValue({
      data: { payload: rows, meta: { timezone: 'Asia/Almaty' } },
    });
    CrmDealsAPI.appointmentPlan.mockResolvedValue({
      data: { payload: { ...deal(), lock_version: 3 } },
    });
  });

  it('shows both clinical patients and cancellation while one attendance cannot fulfill an eight-visit plan', async () => {
    const wrapper = mountPanel();
    await flushPromises();

    expect(wrapper.text()).toContain('First child');
    expect(wrapper.text()).toContain('Second child');
    expect(wrapper.text()).toContain(
      'CRM.DEAL_APPOINTMENTS.STATUSES.CANCELLED'
    );
    expect(wrapper.text()).toContain('"completed":1,"total":8');
    expect(wrapper.text()).toContain('12:00');
    expect(wrapper.text()).not.toContain('Записать заново');
  });

  it('saves the explicitly selected target and all unfulfilled visits without inferring replacements', async () => {
    const wrapper = mountPanel();
    await flushPromises();
    const target = wrapper.findAllComponents({
      name: 'SchedulingSelectField',
    })[0];
    target.vm.$emit('update:modelValue', 42);
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.GENERAL.SAVE')
      .trigger('click');
    await flushPromises();

    const [, payload] = CrmDealsAPI.appointmentPlan.mock.calls[0];
    expect(payload.selected_appointment_id).toBe(42);
    expect(payload.appointment_plan).toHaveLength(8);
    expect(payload.appointment_plan[1].appointment_id).toBeNull();
    expect(payload.lock_version).toBe(2);
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
