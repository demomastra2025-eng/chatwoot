import { useEditableAutomation } from '../useEditableAutomation';

const getConditionDropdownValues = vi.fn((type, eventName) => {
  if (eventName === 'appointment_created' && type === 'status') {
    return [{ id: 'scheduled', name: 'Scheduled' }];
  }

  if (eventName === 'appointment_created' && type === 'visit_reason') {
    return [{ id: 'follow_up', name: 'Follow-up' }];
  }

  if (eventName === 'deal_created' && type === 'stage_id') {
    return [{ id: 11, name: 'Sales / Qualified' }];
  }

  if (eventName === 'deal_created' && type === 'deal_region') {
    return [{ id: 'emea', name: 'EMEA' }];
  }

  if (eventName === 'task_updated' && type === 'status_id') {
    return [{ id: 21, name: 'Todo' }];
  }

  if (type === 'private_note') {
    return [
      { id: true, name: 'True' },
      { id: false, name: 'False' },
    ];
  }

  return [];
});

const getActionDropdownValues = vi.fn(type => {
  if (type === 'change_appointment_status') {
    return [{ id: 'confirmed', name: 'Confirmed' }];
  }

  if (type === 'change_deal_stage') {
    return [{ id: 11, name: 'Sales / Qualified' }];
  }

  if (type === 'change_task_status') {
    return [{ id: 21, name: 'Todo' }];
  }

  if (type === 'assign_agent') {
    return [
      { id: 'nil', name: 'None' },
      {
        id: 'last_responding_agent',
        name: 'Last Responding Agent',
      },
      { id: 1, name: 'Agent 1' },
    ];
  }

  return [];
});

vi.mock('../useAutomationValues', () => ({
  default: () => ({
    getConditionDropdownValues,
    getActionDropdownValues,
  }),
}));

describe('useEditableAutomation', () => {
  it('formats appointment standard and managed custom field conditions with appointment-aware dropdown options', () => {
    const { formatAutomation } = useEditableAutomation();

    const automation = {
      event_name: 'appointment_created',
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: 'and',
          custom_attribute_type: '',
        },
        {
          attribute_key: 'visit_reason',
          filter_operator: 'equal_to',
          values: ['follow_up'],
          query_operator: null,
          custom_attribute_type: 'appointment_attribute',
        },
      ],
      actions: [
        {
          action_name: 'send_webhook_event',
          action_params: [],
        },
      ],
    };

    const allCustomAttributes = [
      {
        key: 'visit_reason',
        label: 'Visit reason',
        fieldType: 'select',
        options: [{ label: 'Follow-up', value: 'follow_up' }],
      },
    ];

    const automationTypes = {
      appointment_created: {
        conditions: [
          {
            key: 'status',
            inputType: 'multi_select',
            filterOperators: [],
          },
          {
            key: 'visit_reason',
            inputType: 'search_select',
            filterOperators: [],
            customAttributeType: 'appointment_attribute',
          },
        ],
      },
    };

    const formatted = formatAutomation(
      automation,
      allCustomAttributes,
      automationTypes,
      [{ key: 'send_webhook_event' }]
    );

    expect(formatted.conditions[0].values).toEqual([
      { id: 'scheduled', name: 'Scheduled' },
    ]);
    expect(formatted.conditions[1].values).toEqual([
      { id: 'follow_up', name: 'Follow-up' },
    ]);
  });

  it('hydrates native appointment actions with appointment-aware dropdown values', () => {
    const { formatAutomation } = useEditableAutomation();

    const automation = {
      event_name: 'appointment_updated',
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: null,
          custom_attribute_type: '',
        },
      ],
      actions: [
        {
          action_name: 'change_appointment_status',
          action_params: ['confirmed'],
        },
        {
          action_name: 'cancel_appointment_payment',
          action_params: [],
        },
      ],
    };

    const automationTypes = {
      appointment_updated: {
        conditions: [
          {
            key: 'status',
            inputType: 'multi_select',
            filterOperators: [],
          },
        ],
      },
    };

    const formatted = formatAutomation(automation, [], automationTypes, [
      { key: 'change_appointment_status', inputType: 'search_select' },
      { key: 'cancel_appointment_payment', inputType: null },
    ]);

    expect(formatted.actions[0].action_params).toEqual([
      { id: 'confirmed', name: 'Confirmed' },
    ]);
    expect(formatted.actions[1].action_params).toEqual([]);
  });

  it('formats deal standard and managed conditions with CRM-aware dropdown values', () => {
    const { formatAutomation } = useEditableAutomation();

    const automation = {
      event_name: 'deal_created',
      conditions: [
        {
          attribute_key: 'stage_id',
          filter_operator: 'equal_to',
          values: [11],
          query_operator: 'and',
          custom_attribute_type: '',
        },
        {
          attribute_key: 'deal_region',
          filter_operator: 'equal_to',
          values: ['emea'],
          query_operator: null,
          custom_attribute_type: 'deal_attribute',
        },
      ],
      actions: [
        {
          action_name: 'change_deal_stage',
          action_params: [11],
        },
      ],
    };

    const allCustomAttributes = [
      {
        key: 'deal_region',
        label: 'Deal region',
        fieldType: 'select',
        options: [{ label: 'EMEA', value: 'emea' }],
      },
    ];

    const automationTypes = {
      deal_created: {
        conditions: [
          { key: 'stage_id', inputType: 'search_select', filterOperators: [] },
          {
            key: 'deal_region',
            inputType: 'search_select',
            filterOperators: [],
            customAttributeType: 'deal_attribute',
          },
        ],
      },
    };

    const formatted = formatAutomation(
      automation,
      allCustomAttributes,
      automationTypes,
      [{ key: 'change_deal_stage', inputType: 'search_select' }]
    );

    expect(formatted.conditions[0].values).toEqual([
      { id: 11, name: 'Sales / Qualified' },
    ]);
    expect(formatted.conditions[1].values).toEqual([
      { id: 'emea', name: 'EMEA' },
    ]);
    expect(formatted.actions[0].action_params).toEqual([
      { id: 11, name: 'Sales / Qualified' },
    ]);
  });

  it('keeps archived deal stage references visible as legacy selections', () => {
    const { formatAutomation } = useEditableAutomation();

    const automation = {
      event_name: 'deal_created',
      conditions: [
        {
          attribute_key: 'stage_id',
          filter_operator: 'equal_to',
          values: [99],
          query_operator: null,
          custom_attribute_type: '',
        },
      ],
      actions: [
        {
          action_name: 'change_deal_stage',
          action_params: [99],
        },
      ],
    };

    const automationTypes = {
      deal_created: {
        conditions: [
          { key: 'stage_id', inputType: 'search_select', filterOperators: [] },
        ],
      },
    };

    const formatted = formatAutomation(automation, [], automationTypes, [
      { key: 'change_deal_stage', inputType: 'search_select' },
    ]);

    expect(formatted.conditions[0].values).toEqual([
      { id: 99, legacy: true, name: 'Archived stage #99' },
    ]);
    expect(formatted.actions[0].action_params).toEqual([
      { id: 99, legacy: true, name: 'Archived stage #99' },
    ]);
  });

  it('rehydrates boolean conditions as a single selected option', () => {
    const { formatAutomation } = useEditableAutomation();

    const automation = {
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'private_note',
          filter_operator: 'equal_to',
          values: [false],
          query_operator: null,
        },
      ],
      actions: [],
    };
    const automationTypes = {
      message_created: {
        conditions: [{ key: 'private_note', inputType: 'search_select' }],
      },
    };

    const formatted = formatAutomation(automation, [], automationTypes, []);

    expect(formatted.conditions).toEqual([
      {
        attribute_key: 'private_note',
        filter_operator: 'equal_to',
        values: { id: false, name: 'False' },
        query_operator: 'and',
      },
    ]);
  });

  it('rehydrates last responding agent as a selected action option', () => {
    const { formatAutomation } = useEditableAutomation();

    const automation = {
      event_name: 'conversation_created',
      conditions: [],
      actions: [
        {
          action_name: 'assign_agent',
          action_params: ['last_responding_agent'],
        },
      ],
    };

    const formatted = formatAutomation(automation, [], {}, [
      { key: 'assign_agent', inputType: 'search_select' },
    ]);

    expect(formatted.actions).toEqual([
      {
        action_name: 'assign_agent',
        action_params: [
          {
            id: 'last_responding_agent',
            name: 'Last Responding Agent',
          },
        ],
      },
    ]);
  });
});
