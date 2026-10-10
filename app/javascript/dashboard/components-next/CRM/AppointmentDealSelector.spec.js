import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { reactive, ref } from 'vue';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import AppointmentDealSelector from './AppointmentDealSelector.vue';

const state = vi.hoisted(() => ({ route: null, enabled: true }));
vi.mock('vue-router', () => ({ useRoute: () => state.route }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref(() => state.enabled),
}));
vi.mock('dashboard/api/crm/deals', () => ({
  default: { appointmentOptions: vi.fn() },
}));

const mountSelector = (props = {}) =>
  mount(AppointmentDealSelector, {
    props: { modelValue: {}, communicationContactId: 20, ...props },
    global: {
      mocks: { $t: key => key },
      stubs: { SchedulingSelectField: true, Button: true },
    },
  });
const response = payload => ({
  data: { payload: { deals: [], pipelines: [], ...payload } },
});
const latestSelection = wrapper =>
  wrapper.emitted('update:modelValue').at(-1)[0];

describe('appointment deal selection', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.route = reactive({ params: { accountId: '1' } });
    state.enabled = true;
  });

  it('automatically binds one eligible active deal without adding an unnecessary field', async () => {
    CrmDealsAPI.appointmentOptions.mockResolvedValue(
      response({
        deals: [{ id: 8, pipeline_id: 3, title: 'Request' }],
        automatic_deal_id: 8,
      })
    );
    const wrapper = mountSelector();
    await flushPromises();

    expect(latestSelection(wrapper)).toEqual({
      crm_deal_id: 8,
      crm_pipeline_id: 3,
      crm_deal_selection: null,
    });
    expect(
      wrapper.find('[data-testid="appointment-deal-selector"]').exists()
    ).toBe(false);
  });

  it('keeps multiple matches unselected and permits explicit deal or create selection', async () => {
    CrmDealsAPI.appointmentOptions.mockResolvedValue(
      response({
        deals: [
          { id: 8, pipeline_id: 3, title: 'First' },
          { id: 9, pipeline_id: 3, title: 'Second' },
        ],
        pipelines: [{ id: 3, name: 'Appointments' }],
        requires_selection: true,
      })
    );
    const wrapper = mountSelector();
    await flushPromises();

    expect(latestSelection(wrapper).crm_deal_id).toBeNull();
    const field = wrapper.findComponent({ name: 'SchedulingSelectField' });
    field.vm.$emit('update:modelValue', 'deal:9');
    expect(latestSelection(wrapper)).toEqual({
      crm_deal_id: 9,
      crm_pipeline_id: 3,
      crm_deal_selection: null,
    });
    field.vm.$emit('update:modelValue', 'create:3');
    expect(latestSelection(wrapper)).toEqual({
      crm_deal_id: null,
      crm_pipeline_id: 3,
      crm_deal_selection: 'create',
    });
  });

  it('passes the explicit source and communication contact separately from the clinical patient', async () => {
    CrmDealsAPI.appointmentOptions.mockResolvedValue(
      response({
        deals: [{ id: 8, pipeline_id: 3, title: 'Source' }],
        automatic_deal_id: 8,
      })
    );
    const wrapper = mountSelector({
      sourceDealId: 8,
      conversationDisplayId: 44,
    });
    await flushPromises();

    expect(CrmDealsAPI.appointmentOptions).toHaveBeenCalledWith({
      contact_id: 20,
      conversation_display_id: 44,
      source_deal_id: 8,
    });
    expect(latestSelection(wrapper).crm_deal_id).toBe(8);
  });

  it('ignores an old account response after the booking context changes', async () => {
    let releaseOld;
    CrmDealsAPI.appointmentOptions.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          releaseOld = resolve;
        })
    );
    CrmDealsAPI.appointmentOptions.mockResolvedValueOnce(
      response({
        deals: [{ id: 15, pipeline_id: 4, title: 'Current' }],
        automatic_deal_id: 15,
      })
    );
    const wrapper = mountSelector();
    state.route.params.accountId = '2';
    await flushPromises();
    releaseOld(
      response({
        deals: [{ id: 8, pipeline_id: 3, title: 'Old' }],
        automatic_deal_id: 8,
      })
    );
    await flushPromises();

    expect(latestSelection(wrapper).crm_deal_id).toBe(15);
  });

  it('does not request deals when CRM is disabled', async () => {
    state.enabled = false;
    const wrapper = mountSelector();
    await flushPromises();

    expect(CrmDealsAPI.appointmentOptions).not.toHaveBeenCalled();
    expect(
      wrapper.find('[data-testid="appointment-deal-selector"]').exists()
    ).toBe(false);
  });
});
