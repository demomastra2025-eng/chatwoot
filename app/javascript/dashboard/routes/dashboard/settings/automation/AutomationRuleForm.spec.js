import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import AutomationRuleForm from './AutomationRuleForm.vue';
import { AUTOMATIONS } from './constants';

const { contactOptionsMock } = vi.hoisted(() => ({
  contactOptionsMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
    tm: key =>
      key === 'AUTOMATION.ATTRIBUTES'
        ? {
            STATUS: 'Статус',
            APPOINTMENT_CABINET: 'Кабинет',
            CONTACT: 'Контакт',
          }
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
vi.mock('dashboard/api/automation', () => ({
  default: { contactOptions: contactOptionsMock },
}));

const CABINET_KEY = 'medelement_cabinet_code';
const CONTACT_KEY = 'contact_id';
const cabinetOptions = [
  { id: '501', name: 'Терапевт · 1' },
  { id: '502', name: 'Процедурный' },
];

const buildAutomation = (
  attributeKey = 'status',
  eventName = 'appointment_created'
) => ({
  name: 'Rule',
  description: 'Rule',
  event_name: eventName,
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

const mountForm = ({
  cabinets = [],
  contacts = [],
  automation = buildAutomation(),
  conditionRow = {
    name: 'ConditionRow',
    props: ['filterTypes'],
    template: '<li />',
  },
  nextButton = true,
}) =>
  mount(AutomationRuleForm, {
    props: {
      mode: 'create',
      automation,
      automationTypes: structuredClone(AUTOMATIONS),
      getConditionDropdownValues: key => {
        if (key === CABINET_KEY) return cabinets;
        if (key === CONTACT_KEY) return contacts;
        return [{ id: 'x', name: 'X' }];
      },
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
        ConditionRow: conditionRow,
        AutomationActionInput: true,
        NextButton: nextButton,
        'woot-input': true,
      },
    },
  });

const conditionFilterTypes = wrapper =>
  wrapper.findComponent({ name: 'ConditionRow' }).props('filterTypes');

const filterTypeFor = (wrapper, key) =>
  conditionFilterTypes(wrapper).find(
    filterType => filterType.attributeKey === key
  );

describe('AutomationRuleForm appointment conditions', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

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

describe('AutomationRuleForm contact condition', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

  it.each([
    'conversation_created',
    'conversation_updated',
    'conversation_resolved',
    'message_created',
    'appointment_created',
    'appointment_updated',
    'appointment_cancelled',
    'deal_created',
    'deal_stage_changed',
    'deal_archived',
    'task_created',
    'task_status_changed',
    'task_archived',
  ])('is offered for %s even before any contact is known', eventName => {
    const wrapper = mountForm({ automation: buildAutomation('', eventName) });

    expect(filterTypeFor(wrapper, CONTACT_KEY)).toMatchObject({
      label: 'Контакт',
      inputType: 'multiSelect',
      attributeModel: 'standard',
    });
  });

  it.each(['deal_created', 'task_created'])(
    'searches the contacts of a %s rule on the server like the other rules',
    eventName => {
      const wrapper = mountForm({ automation: buildAutomation('', eventName) });

      const contact = filterTypeFor(wrapper, CONTACT_KEY);

      expect(contact.fetchOptions).toEqual(expect.any(Function));
      expect(contact.searchPlaceholder).toBe(
        'AUTOMATION.CONTACT_CONDITION.SEARCH_PLACEHOLDER'
      );
      expect(contact.filterOperators.map(({ value }) => value)).toEqual([
        'equal_to',
        'not_equal_to',
      ]);
    }
  );

  it('reads "is / is not" and offers nothing else', () => {
    const wrapper = mountForm({});

    const { filterOperators } = filterTypeFor(wrapper, CONTACT_KEY);

    expect(filterOperators.map(({ value }) => value)).toEqual([
      'equal_to',
      'not_equal_to',
    ]);
    expect(filterOperators.map(({ label }) => label)).toEqual([
      'AUTOMATION.CONTACT_CONDITION.OPERATOR_IS',
      'AUTOMATION.CONTACT_CONDITION.OPERATOR_IS_NOT',
    ]);
    expect(filterOperators.every(({ hasInput }) => hasInput)).toBe(true);
  });

  it('leaves the operator wording of the other conditions alone', () => {
    const wrapper = mountForm({});

    const { filterOperators } = filterTypeFor(wrapper, 'status');

    expect(filterOperators.map(({ label }) => label)).not.toContain(
      'AUTOMATION.CONTACT_CONDITION.OPERATOR_IS'
    );
  });

  it('passes the contacts met so far as options and searches on the server', async () => {
    const known = [{ id: 7, name: 'Айгерим', description: '+77011234567' }];
    contactOptionsMock.mockResolvedValue({
      data: {
        payload: [{ id: 8, name: 'Берик', phone_number: '+77025550000' }],
        meta: { has_more: true },
      },
    });
    const wrapper = mountForm({ contacts: known });

    const contact = filterTypeFor(wrapper, CONTACT_KEY);

    expect(contact.options).toEqual(known);
    expect(contact.searchPlaceholder).toBe(
      'AUTOMATION.CONTACT_CONDITION.SEARCH_PLACEHOLDER'
    );
    expect(contactOptionsMock).not.toHaveBeenCalled();

    await expect(contact.fetchOptions('бер', 2)).resolves.toEqual({
      options: [{ id: 8, name: 'Берик', description: '+77025550000' }],
      hasMore: true,
    });
    expect(contactOptionsMock).toHaveBeenCalledWith({ q: 'бер', page: 2 });
  });

  it('does not search on the server for the other conditions', () => {
    const wrapper = mountForm({ cabinets: cabinetOptions });

    ['status', CABINET_KEY, 'service_id'].forEach(key => {
      const filterType = filterTypeFor(wrapper, key);

      expect(filterType.fetchOptions).toBeNull();
      expect(filterType.searchPlaceholder).toBe('');
    });
  });

  it('saves the chosen contacts as a list of contact ids', async () => {
    const automation = {
      ...buildAutomation(CONTACT_KEY, 'conversation_created'),
      conditions: [
        {
          attribute_key: CONTACT_KEY,
          filter_operator: 'not_equal_to',
          values: [
            { id: 7, name: 'Айгерим', description: '+77011234567' },
            { id: 9, name: 'Контакт удалён (№ 9)', deleted: true },
          ],
          query_operator: 'and',
        },
      ],
      actions: [{ action_name: 'send_message', action_params: ['Привет'] }],
    };
    const wrapper = mountForm({
      automation,
      conditionRow: {
        name: 'ConditionRow',
        props: ['filterTypes'],
        methods: { validate: () => true, resetValidation: () => {} },
        template: '<li />',
      },
      nextButton: {
        props: ['label'],
        emits: ['click'],
        template:
          '<button type="button" :data-label="label" @click="$emit(\'click\', $event)" />',
      },
    });

    await wrapper
      .find('button[data-label="AUTOMATION.ADD.SUBMIT"]')
      .trigger('click');

    const [payload, mode] = wrapper.emitted('save')[0];
    expect(mode).toBe('create');
    expect(payload.conditions).toEqual([
      {
        attribute_key: CONTACT_KEY,
        filter_operator: 'not_equal_to',
        values: [7, 9],
        custom_attribute_type: '',
      },
    ]);
  });
});
