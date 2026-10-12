import { mount } from '@vue/test-utils';
import AutomationRuleForm from './AutomationRuleForm.vue';
import { AUTOMATIONS } from './constants';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
    tm: key =>
      key === 'AUTOMATION.ATTRIBUTES'
        ? { STATUS: 'Статус', APPOINTMENT_CABINET: 'Кабинет' }
        : {},
  }),
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isCloudFeatureEnabled: () => false }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({
    getCurrentAccountId: { value: 1 },
    'accounts/isFeatureEnabledonAccount': { value: () => true },
  }),
}));

const CABINET_KEY = 'medelement_cabinet_code';
const cabinetOptions = [
  { id: '501', name: 'Терапевт · 1' },
  { id: '502', name: 'Процедурный' },
];

const buildAutomation = (attributeKey = 'status') => ({
  name: 'Rule',
  description: 'Rule',
  event_name: 'appointment_created',
  conditions: [
    {
      attribute_key: attributeKey,
      filter_operator: 'equal_to',
      values: [],
      query_operator: 'and',
    },
  ],
  actions: [{ action_name: 'send_webhook_event', action_params: [] }],
});

const mountForm = ({ cabinets, automation = buildAutomation() }) =>
  mount(AutomationRuleForm, {
    props: {
      mode: 'create',
      automation,
      automationTypes: structuredClone(AUTOMATIONS),
      getConditionDropdownValues: key =>
        key === CABINET_KEY ? cabinets : [{ id: 'x', name: 'X' }],
      getActionDropdownValues: () => [],
      appendNewCondition: vi.fn(),
      appendNewAction: vi.fn(),
      removeFilter: vi.fn(),
      removeAction: vi.fn(),
      resetAction: vi.fn(),
      onEventChange: vi.fn(),
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Dialog: { template: '<div><slot /></div>' },
        ConditionRow: {
          name: 'ConditionRow',
          props: ['filterTypes'],
          template: '<li />',
        },
        AutomationActionInput: true,
        NextButton: true,
        'woot-input': true,
      },
    },
  });

const conditionFilterTypes = wrapper =>
  wrapper.findComponent({ name: 'ConditionRow' }).props('filterTypes');

describe('AutomationRuleForm appointment conditions', () => {
  it('offers the cabinet with its options in a searchable list', () => {
    const wrapper = mountForm({ cabinets: cabinetOptions });

    const cabinet = conditionFilterTypes(wrapper).find(
      filterType => filterType.attributeKey === CABINET_KEY
    );

    expect(cabinet).toMatchObject({
      label: 'Кабинет',
      inputType: 'multiSelect',
      searchable: true,
      options: cabinetOptions,
      attributeModel: 'standard',
    });
    expect(cabinet.filterOperators.map(({ value }) => value)).toEqual([
      'equal_to',
      'not_equal_to',
    ]);
  });

  it('does not offer the cabinet when the account has no cabinets', () => {
    const wrapper = mountForm({ cabinets: [] });

    const keys = conditionFilterTypes(wrapper).map(
      filterType => filterType.attributeKey
    );

    expect(keys).toContain('status');
    expect(keys).toContain('service_id');
    expect(keys).not.toContain(CABINET_KEY);
  });

  it('keeps the cabinet for a rule that already filters by it', () => {
    const wrapper = mountForm({
      cabinets: [],
      automation: buildAutomation(CABINET_KEY),
    });

    const keys = conditionFilterTypes(wrapper).map(
      filterType => filterType.attributeKey
    );

    expect(keys).toContain(CABINET_KEY);
  });
});
