import * as helpers from 'dashboard/helper/automationHelper';
import {
  OPERATOR_TYPES_1,
  OPERATOR_TYPES_3,
  OPERATOR_TYPES_4,
  OPERATOR_TYPES_7,
  OPERATOR_TYPES_8,
} from 'dashboard/routes/dashboard/settings/automation/operators';
import {
  appointmentFieldDefinitions,
  dealFieldDefinitions,
  taskFieldDefinitions,
  customAttributes,
  labels,
  automation,
  contactAttrs,
  conversationAttrs,
  expectedOutputForCustomAttributeGenerator,
} from './fixtures/automationFixtures';
import {
  AUTOMATION_ACTION_TYPES,
  AUTOMATION_RULE_EVENTS,
  AUTOMATIONS,
} from 'dashboard/routes/dashboard/settings/automation/constants';

describe('getCustomAttributeInputType', () => {
  it('returns the attribute input type', () => {
    expect(helpers.getCustomAttributeInputType('date')).toEqual('date');
    expect(helpers.getCustomAttributeInputType('datetime')).toEqual('datetime');
    expect(helpers.getCustomAttributeInputType('date')).not.toEqual(
      'some_random_value'
    );
    expect(helpers.getCustomAttributeInputType('text')).toEqual('plain_text');
    expect(helpers.getCustomAttributeInputType('number')).toEqual('plain_text');
    expect(helpers.getCustomAttributeInputType('currency')).toEqual(
      'plain_text'
    );
    expect(helpers.getCustomAttributeInputType('percent')).toEqual(
      'plain_text'
    );
    expect(helpers.getCustomAttributeInputType('list')).toEqual(
      'search_select'
    );
    expect(helpers.getCustomAttributeInputType('multiselect')).toEqual(
      'multi_select'
    );
    expect(helpers.getCustomAttributeInputType('checkbox')).toEqual(
      'search_select'
    );
    expect(helpers.getCustomAttributeInputType('some_random_text')).toEqual(
      'plain_text'
    );
  });

  it('maps managed datetime fields to datetime inputs', () => {
    expect(
      helpers.generateManagedCustomAttributeTypes([
        {
          key: 'follow_up_at',
          label: 'Follow-up at',
          fieldType: 'datetime',
        },
      ])
    ).toEqual([
      {
        key: 'follow_up_at',
        name: 'Follow-up at',
        inputType: 'datetime',
        filterOperators: OPERATOR_TYPES_4,
        customAttributeType: 'managed_attribute',
      },
    ]);
  });
});

describe('AUTOMATIONS datetime inputs', () => {
  it('uses datetime inputs for standard CRM datetime fields', () => {
    expect(
      AUTOMATIONS.deal_updated.conditions.find(
        condition => condition.key === 'closed_at'
      )?.inputType
    ).toEqual('datetime');

    expect(
      AUTOMATIONS.task_updated.conditions.find(
        condition => condition.key === 'due_at'
      )?.inputType
    ).toEqual('datetime');
  });
});

const CONVERSATION_EVENTS = [
  'conversation_created',
  'conversation_updated',
  'conversation_resolved',
  'conversation_opened',
  'conversation_pending',
  'conversation_transferred_to_ai',
  'message_created',
];

const APPOINTMENT_EVENTS = [
  'appointment_created',
  'appointment_updated',
  'appointment_cancelled',
  'appointment_completed',
];

const DEAL_EVENTS = [
  'deal_created',
  'deal_updated',
  'deal_stage_changed',
  'deal_archived',
  'deal_unarchived',
];

const TASK_EVENTS = [
  'task_created',
  'task_updated',
  'task_status_changed',
  'task_archived',
  'task_unarchived',
];

const BACKEND_EVENT_NAMES = [
  ...CONVERSATION_EVENTS,
  ...DEAL_EVENTS,
  ...TASK_EVENTS,
  ...APPOINTMENT_EVENTS,
];

const BACKEND_CONVERSATION_ACTIONS = [
  'send_message',
  'add_label',
  'remove_label',
  'send_email_to_team',
  'assign_team',
  'assign_agent',
  'remove_assigned_agent',
  'remove_assigned_team',
  'send_webhook_event',
  'mute_conversation',
  'send_attachment',
  'change_status',
  'resolve_conversation',
  'open_conversation',
  'pending_conversation',
  'snooze_conversation',
  'change_priority',
  'send_email_transcript',
  'add_private_note',
  'apply_touch_plan',
  'create_touch',
  'cancel_touches',
];

const BACKEND_CONVERSATION_CONDITIONS = [
  'content',
  'email',
  'country_code',
  'status',
  'message_type',
  'browser_language',
  'assignee_id',
  'team_id',
  'referer',
  'city',
  'company',
  'inbox_id',
  'mail_subject',
  'phone_number',
  'priority',
  'conversation_language',
  'labels',
  'private_note',
];

const BACKEND_APPOINTMENT_ACTIONS = [
  'send_webhook_event',
  'change_appointment_status',
  'cancel_appointment_payment',
  'send_message',
  'apply_touch_plan',
  'create_touch',
  'cancel_touches',
];

const BACKEND_DEAL_ACTIONS = [
  'send_webhook_event',
  'change_deal_stage',
  'assign_deal_owner',
  'assign_deal_team',
  'archive_deal',
  'unarchive_deal',
  'send_message',
  'apply_touch_plan',
  'create_touch',
  'cancel_touches',
];

const BACKEND_TASK_ACTIONS = [
  'send_webhook_event',
  'change_task_status',
  'assign_task_assignee',
  'assign_task_team',
  'change_task_priority',
  'archive_task',
  'unarchive_task',
  'send_message',
  'apply_touch_plan',
  'create_touch',
  'cancel_touches',
];

const BACKEND_APPOINTMENT_CONDITIONS = [
  'status',
  'payment_status',
  'appointment_type',
  'source',
  'starts_at_weekday',
  'starts_at_time',
  'service_id',
];

const BACKEND_DEAL_CONDITIONS = [
  'pipeline_id',
  'stage_id',
  'owner_id',
  'team_id',
  'title',
  'description',
  'currency',
  'external_ref',
  'amount_minor',
  'win_probability',
  'expected_close_on',
  'closed_at',
  'archived_at',
];

const BACKEND_TASK_CONDITIONS = [
  'status_id',
  'assignee_id',
  'team_id',
  'priority',
  'title',
  'description',
  'external_ref',
  'start_at',
  'due_at',
  'completed_at',
  'archived_at',
];

const EXPECTED_BACKEND_ACTION_UNION = [
  ...new Set([
    ...BACKEND_CONVERSATION_ACTIONS,
    ...BACKEND_APPOINTMENT_ACTIONS,
    ...BACKEND_DEAL_ACTIONS,
    ...BACKEND_TASK_ACTIONS,
  ]),
];

const LEGACY_BACKEND_ONLY_ACTIONS = [
  'apply_touch_plan',
  'create_touch',
  'cancel_touches',
];
const publicAutomationActions = actions =>
  actions.filter(action => !LEGACY_BACKEND_ONLY_ACTIONS.includes(action));

const expectSameMembers = (actual, expected) => {
  expect([...actual].sort()).toEqual([...expected].sort());
  expect(new Set(actual).size).toEqual(actual.length);
};

describe('AUTOMATIONS conversation parity', () => {
  it('exposes public conversation actions for every conversation event', () => {
    CONVERSATION_EVENTS.forEach(eventName => {
      const actionKeys = AUTOMATIONS[eventName].actions.map(
        action => action.key
      );

      expect(actionKeys).toEqual(
        publicAutomationActions(BACKEND_CONVERSATION_ACTIONS)
      );
      expect(new Set(actionKeys).size).toEqual(actionKeys.length);
    });
  });

  it('exposes all backend-backed conversation conditions for every conversation event', () => {
    CONVERSATION_EVENTS.forEach(eventName => {
      const conditionKeys = AUTOMATIONS[eventName].conditions.map(
        condition => condition.key
      );

      expect(conditionKeys).toEqual(BACKEND_CONVERSATION_CONDITIONS);
      expect(new Set(conditionKeys).size).toEqual(conditionKeys.length);
    });
  });

  it('defines change_status as a selectable automation action', () => {
    expect(
      AUTOMATION_ACTION_TYPES.find(action => action.key === 'change_status')
    ).toEqual({
      key: 'change_status',
      label: 'CHANGE_STATUS',
      inputType: 'search_select',
    });
  });
});

describe('AUTOMATIONS backend parity', () => {
  it('exposes every backend-supported automation event in constants and the event dropdown', () => {
    expectSameMembers(Object.keys(AUTOMATIONS), BACKEND_EVENT_NAMES);
    expectSameMembers(
      AUTOMATION_RULE_EVENTS.map(event => event.key),
      BACKEND_EVENT_NAMES
    );
  });

  it('exposes public appointment actions and backend-backed conditions for every appointment event', () => {
    APPOINTMENT_EVENTS.forEach(eventName => {
      expectSameMembers(
        AUTOMATIONS[eventName].actions.map(action => action.key),
        publicAutomationActions(BACKEND_APPOINTMENT_ACTIONS)
      );
      expect(AUTOMATIONS[eventName].conditions.map(({ key }) => key)).toEqual(
        BACKEND_APPOINTMENT_CONDITIONS
      );
    });
  });

  it('uses backend-supported operators for appointment source conditions', () => {
    APPOINTMENT_EVENTS.forEach(eventName => {
      expect(
        AUTOMATIONS[eventName].conditions.find(({ key }) => key === 'source')
          .filterOperators
      ).toEqual(OPERATOR_TYPES_7);
    });
  });

  it('uses the exact backend operators and input types for appointment start time', () => {
    APPOINTMENT_EVENTS.forEach(eventName => {
      expect(
        AUTOMATIONS[eventName].conditions.find(
          ({ key }) => key === 'starts_at_time'
        )
      ).toMatchObject({ inputType: 'time', filterOperators: OPERATOR_TYPES_8 });
    });
  });

  it('exposes public deal actions and backend-backed conditions for every deal event', () => {
    DEAL_EVENTS.forEach(eventName => {
      expectSameMembers(
        AUTOMATIONS[eventName].actions.map(action => action.key),
        publicAutomationActions(BACKEND_DEAL_ACTIONS)
      );
      expect(AUTOMATIONS[eventName].conditions.map(({ key }) => key)).toEqual(
        BACKEND_DEAL_CONDITIONS
      );
    });
  });

  it('exposes public task actions and backend-backed conditions for every task event', () => {
    TASK_EVENTS.forEach(eventName => {
      expectSameMembers(
        AUTOMATIONS[eventName].actions.map(action => action.key),
        publicAutomationActions(BACKEND_TASK_ACTIONS)
      );
      expect(AUTOMATIONS[eventName].conditions.map(({ key }) => key)).toEqual(
        BACKEND_TASK_CONDITIONS
      );
    });
  });

  it('keeps action input metadata limited to backend-backed actions', () => {
    const actionTypeKeys = AUTOMATION_ACTION_TYPES.map(action => action.key);

    expectSameMembers(actionTypeKeys, EXPECTED_BACKEND_ACTION_UNION);
    expect(actionTypeKeys).not.toContain('add_sla');
  });

  it('keeps touch plans legacy-only and makes cancellation plan-independent', () => {
    expect(
      AUTOMATION_ACTION_TYPES.find(action => action.key === 'apply_touch_plan')
    ).toMatchObject({ inputType: null, legacyOnly: true });
    expect(
      AUTOMATION_ACTION_TYPES.find(action => action.key === 'cancel_touches')
    ).toMatchObject({ inputType: null });
  });
});

describe('isACustomAttribute', () => {
  it('returns the custom attribute value if true', () => {
    expect(
      helpers.isACustomAttribute(customAttributes, 'signed_up_at')
    ).toBeTruthy();
    expect(helpers.isACustomAttribute(customAttributes, 'status')).toBeFalsy();
  });
});

describe('getCustomAttributeListDropdownValues', () => {
  it('returns the attribute dropdown values', () => {
    const myListValues = [
      { id: 'item1', name: 'item1' },
      { id: 'item2', name: 'item2' },
      { id: 'item3', name: 'item3' },
    ];
    expect(
      helpers.getCustomAttributeListDropdownValues(customAttributes, 'my_list')
    ).toEqual(myListValues);
  });
});

describe('isCustomAttributeCheckbox', () => {
  it('checks if attribute is a checkbox', () => {
    expect(
      helpers.isCustomAttributeCheckbox(customAttributes, 'prime_user')
        .attribute_display_type
    ).toEqual('checkbox');
    expect(
      helpers.isCustomAttributeCheckbox(customAttributes, 'my_check')
        .attribute_display_type
    ).toEqual('checkbox');
    expect(
      helpers.isCustomAttributeCheckbox(customAttributes, 'my_list')
    ).not.toEqual('checkbox');
  });
});

describe('isCustomAttributeList', () => {
  it('checks if attribute is a list', () => {
    expect(
      helpers.isCustomAttributeList(customAttributes, 'my_list')
        .attribute_display_type
    ).toEqual('list');
  });
});

describe('getOperatorTypes', () => {
  it('returns the correct custom attribute operators', () => {
    expect(helpers.getOperatorTypes('list')).toEqual(OPERATOR_TYPES_1);
    expect(helpers.getOperatorTypes('text')).toEqual(OPERATOR_TYPES_3);
    expect(helpers.getOperatorTypes('number')).toEqual(OPERATOR_TYPES_4);
    expect(helpers.getOperatorTypes('currency')).toEqual(OPERATOR_TYPES_4);
    expect(helpers.getOperatorTypes('percent')).toEqual(OPERATOR_TYPES_4);
    expect(helpers.getOperatorTypes('link')).toEqual(OPERATOR_TYPES_1);
    expect(helpers.getOperatorTypes('date')).toEqual(OPERATOR_TYPES_4);
    expect(helpers.getOperatorTypes('checkbox')).toEqual(OPERATOR_TYPES_1);
    expect(helpers.getOperatorTypes('some_random')).toEqual(OPERATOR_TYPES_1);
  });
});

describe('generateConditionOptions', () => {
  it('returns expected conditions options array', () => {
    const testConditions = [
      { id: 123, title: 'Fayaz', email: 'test@test.com' },
      { title: 'John', id: 324, email: 'test@john.com' },
    ];
    const expectedConditions = [
      { id: 123, name: 'Fayaz' },
      { id: 324, name: 'John' },
    ];
    expect(helpers.generateConditionOptions(testConditions)).toEqual(
      expectedConditions
    );
  });
});

describe('getActionOptions', () => {
  it('returns expected actions options array', () => {
    const expectedOptions = [
      { id: 'testlabel', name: 'testlabel' },
      { id: 'snoozes', name: 'snoozes' },
    ];
    expect(helpers.getActionOptions({ labels, type: 'add_label' })).toEqual(
      expectedOptions
    );
  });

  it('adds None option when addNoneToListFn is provided', () => {
    const mockAddNoneToListFn = list => [
      { id: 'nil', name: 'None' },
      ...(list || []),
    ];

    const agents = [
      { id: 1, name: 'Agent 1' },
      { id: 2, name: 'Agent 2' },
    ];

    const expectedOptions = [
      { id: 'nil', name: 'None' },
      { id: 1, name: 'Agent 1' },
      { id: 2, name: 'Agent 2' },
    ];

    expect(
      helpers.getActionOptions({
        agents,
        type: 'assign_agent',
        addNoneToListFn: mockAddNoneToListFn,
      })
    ).toEqual(expectedOptions);
  });

  it('does not add None option when addNoneToListFn is not provided', () => {
    const agents = [
      { id: 1, name: 'Agent 1' },
      { id: 2, name: 'Agent 2' },
    ];

    expect(
      helpers.getActionOptions({
        agents,
        type: 'assign_agent',
      })
    ).toEqual(agents);
  });

  it('returns conversation status options for generic status actions', () => {
    const statusFilterOptions = [
      { id: 'open', name: 'Open' },
      { id: 'resolved', name: 'Resolved' },
      { id: 'pending', name: 'Pending' },
      { id: 'snoozed', name: 'Snoozed' },
      { id: 'all', name: 'All' },
    ];

    expect(
      helpers.getActionOptions({
        statusFilterOptions,
        type: 'change_status',
      })
    ).toEqual([
      { id: 'open', name: 'Open' },
      { id: 'resolved', name: 'Resolved' },
      { id: 'pending', name: 'Pending' },
      { id: 'snoozed', name: 'Snoozed' },
    ]);
  });

  it('returns appointment status options for native appointment status actions', () => {
    const appointmentStatusOptions = [{ id: 'confirmed', name: 'Confirmed' }];

    expect(
      helpers.getActionOptions({
        appointmentStatusOptions,
        type: 'change_appointment_status',
      })
    ).toEqual(appointmentStatusOptions);
  });

  it('returns CRM action options for native deal and task actions', () => {
    const crmStageOptions = [{ id: 1, name: 'Pipeline / Won' }];
    const crmTaskStatusOptions = [{ id: 2, name: 'Done' }];
    const teams = [{ id: 9, name: 'Sales' }];

    expect(
      helpers.getActionOptions({
        crmStageOptions,
        type: 'change_deal_stage',
      })
    ).toEqual(crmStageOptions);

    expect(
      helpers.getActionOptions({
        crmTaskStatusOptions,
        type: 'change_task_status',
      })
    ).toEqual(crmTaskStatusOptions);

    expect(
      helpers.getActionOptions({
        teams,
        type: 'assign_deal_team',
      })
    ).toEqual(teams);
  });

  it('does not expose touch-plan dropdown values in generic automations', () => {
    expect(
      helpers.getActionOptions({ type: 'apply_touch_plan' })
    ).toBeUndefined();
    expect(
      helpers.getActionOptions({ type: 'cancel_touches' })
    ).toBeUndefined();
  });
});

describe('getConditionOptions', () => {
  it('returns expected conditions options', () => {
    const testOptions = [
      { id: 'open', name: 'Open' },
      { id: 'resolved', name: 'Resolved' },
      { id: 'pending', name: 'Pending' },
      { id: 'snoozed', name: 'Snoozed' },
      { id: 'all', name: 'All' },
    ];
    expect(
      helpers.getConditionOptions({
        customAttributes,
        campaigns: [],
        statusFilterOptions: testOptions,
        type: 'status',
      })
    ).toEqual(testOptions);
  });

  it('returns appointment-specific options when the event is appointment-based', () => {
    const appointmentStatusOptions = [{ id: 'scheduled', name: 'Scheduled' }];
    const appointmentPaymentStatusOptions = [{ id: 'paid', name: 'Paid' }];
    const appointmentServiceOptions = [{ id: 7, name: 'Consultation' }];
    const appointmentWeekdayOptions = [{ id: '1', name: 'Monday' }];

    expect(
      helpers.getConditionOptions({
        customAttributes,
        eventName: 'appointment_created',
        appointmentStatusOptions,
        type: 'status',
      })
    ).toEqual(appointmentStatusOptions);

    expect(
      helpers.getConditionOptions({
        customAttributes,
        eventName: 'appointment_created',
        appointmentPaymentStatusOptions,
        type: 'payment_status',
      })
    ).toEqual(appointmentPaymentStatusOptions);

    expect(
      helpers.getConditionOptions({
        appointmentServiceOptions,
        customAttributes,
        eventName: 'appointment_created',
        type: 'service_id',
      })
    ).toEqual(appointmentServiceOptions);

    expect(
      helpers.getConditionOptions({
        appointmentWeekdayOptions,
        customAttributes,
        eventName: 'appointment_created',
        type: 'starts_at_weekday',
      })
    ).toEqual(appointmentWeekdayOptions);
  });

  it('returns managed appointment field options when the event is appointment-based', () => {
    expect(
      helpers.getConditionOptions({
        appointmentFieldDefinitions,
        booleanFilterOptions: [
          { id: true, name: 'True' },
          { id: false, name: 'False' },
        ],
        customAttributes,
        eventName: 'appointment_created',
        type: 'visit_reason',
      })
    ).toEqual([{ id: 'follow_up', name: 'Follow-up' }]);

    expect(
      helpers.getConditionOptions({
        appointmentFieldDefinitions,
        booleanFilterOptions: [
          { id: true, name: 'True' },
          { id: false, name: 'False' },
        ],
        customAttributes,
        eventName: 'appointment_created',
        type: 'needs_lab',
      })
    ).toEqual([
      { id: true, name: 'True' },
      { id: false, name: 'False' },
    ]);
  });

  it('returns deal-specific options when the event is deal-based', () => {
    const crmPipelineOptions = [{ id: 10, name: 'Sales' }];
    const crmStageOptions = [{ id: 11, name: 'Sales / Qualified' }];
    const crmDealOwnerOptions = [{ id: 12, name: 'Aigerim' }];

    expect(
      helpers.getConditionOptions({
        crmDealOwnerOptions,
        crmPipelineOptions,
        crmStageOptions,
        customAttributes,
        eventName: 'deal_created',
        type: 'stage_id',
      })
    ).toEqual(crmStageOptions);

    expect(
      helpers.getConditionOptions({
        crmDealOwnerOptions,
        crmPipelineOptions,
        crmStageOptions,
        customAttributes,
        eventName: 'deal_created',
        type: 'pipeline_id',
      })
    ).toEqual(crmPipelineOptions);

    expect(
      helpers.getConditionOptions({
        crmDealOwnerOptions,
        crmPipelineOptions,
        crmStageOptions,
        customAttributes,
        eventName: 'deal_created',
        type: 'owner_id',
      })
    ).toEqual(crmDealOwnerOptions);
  });

  it('returns task-specific options when the event is task-based', () => {
    const crmTaskStatusOptions = [{ id: 21, name: 'In Progress' }];
    const agents = [{ id: 22, name: 'Dina' }];

    expect(
      helpers.getConditionOptions({
        agents,
        crmTaskStatusOptions,
        customAttributes,
        eventName: 'task_created',
        type: 'status_id',
      })
    ).toEqual(crmTaskStatusOptions);

    expect(
      helpers.getConditionOptions({
        agents,
        crmTaskStatusOptions,
        customAttributes,
        eventName: 'task_created',
        type: 'assignee_id',
      })
    ).toEqual(agents);
  });

  it('returns managed deal and task field options when the event is CRM-based', () => {
    expect(
      helpers.getConditionOptions({
        booleanFilterOptions: [
          { id: true, name: 'True' },
          { id: false, name: 'False' },
        ],
        customAttributes,
        dealFieldDefinitions,
        eventName: 'deal_created',
        type: 'deal_region',
      })
    ).toEqual([{ id: 'emea', name: 'EMEA' }]);

    expect(
      helpers.getConditionOptions({
        booleanFilterOptions: [
          { id: true, name: 'True' },
          { id: false, name: 'False' },
        ],
        customAttributes,
        eventName: 'task_created',
        taskFieldDefinitions,
        type: 'task_channel',
      })
    ).toEqual([{ id: 'chat', name: 'Chat' }]);
  });

  it('returns boolean options for private_note', () => {
    const booleanOptions = [
      { id: true, name: 'True' },
      { id: false, name: 'False' },
    ];

    expect(
      helpers.getConditionOptions({
        booleanFilterOptions: booleanOptions,
        customAttributes,
        type: 'private_note',
      })
    ).toEqual(booleanOptions);
  });
});

describe('default automation factories', () => {
  it('returns CRM defaults for deal and task events', () => {
    expect(helpers.getDefaultConditions('deal_created')).toEqual([
      expect.objectContaining({ attribute_key: 'stage_id' }),
    ]);
    expect(helpers.getDefaultConditions('task_created')).toEqual([
      expect.objectContaining({ attribute_key: 'status_id' }),
    ]);
    expect(helpers.getDefaultActions('deal_created')).toEqual([
      expect.objectContaining({ action_name: 'send_webhook_event' }),
    ]);
    expect(helpers.getDefaultActions('task_created')).toEqual([
      expect.objectContaining({ action_name: 'send_webhook_event' }),
    ]);
  });
});

describe('getFileName', () => {
  it('returns the correct file name', () => {
    expect(
      helpers.getFileName(automation.actions[0], automation.files)
    ).toEqual('pfp.jpeg');
  });
});

describe('getDefaultConditions', () => {
  it('returns the resp default condition model', () => {
    const messageCreatedModel = [
      {
        attribute_key: 'message_type',
        filter_operator: 'equal_to',
        values: '',
        query_operator: 'and',
        custom_attribute_type: '',
      },
    ];
    const conversationConditionModel = [
      {
        attribute_key: 'browser_language',
        filter_operator: 'equal_to',
        values: '',
        query_operator: 'and',
        custom_attribute_type: '',
      },
    ];
    const genericConditionModel = [
      {
        attribute_key: 'status',
        filter_operator: 'equal_to',
        values: '',
        query_operator: 'and',
        custom_attribute_type: '',
      },
    ];
    expect(helpers.getDefaultConditions('message_created')).toEqual(
      messageCreatedModel
    );
    expect(
      helpers.getDefaultConditions('conversation_transferred_to_ai')
    ).toEqual(conversationConditionModel);
    expect(helpers.getDefaultConditions()).toEqual(genericConditionModel);
  });
});

describe('getDefaultActions', () => {
  it('returns the resp default action model', () => {
    const genericActionModel = [
      {
        action_name: 'assign_agent',
        action_params: [],
      },
    ];
    expect(helpers.getDefaultActions()).toEqual(genericActionModel);
  });

  it('returns appointment webhook defaults for appointment automation events', () => {
    expect(helpers.getDefaultActions('appointment_created')).toEqual([
      {
        action_name: 'send_webhook_event',
        action_params: [],
      },
    ]);
  });
});

describe('filterCustomAttributes', () => {
  it('filters the raw custom attributes', () => {
    const filteredAttributes = [
      { key: 'signed_up_at', name: 'Signed Up At', type: 'date' },
      { key: 'prime_user', name: 'Prime User', type: 'checkbox' },
      { key: 'test', name: 'Test', type: 'text' },
      { key: 'link', name: 'Link', type: 'link' },
      { key: 'my_list', name: 'My List', type: 'list' },
      { key: 'my_check', name: 'My Check', type: 'checkbox' },
      { key: 'conlist', name: 'ConList', type: 'list' },
      { key: 'asdf', name: 'asdf', type: 'link' },
    ];
    expect(helpers.filterCustomAttributes(customAttributes)).toEqual(
      filteredAttributes
    );
  });
});

describe('generateManagedCustomAttributeTypes', () => {
  it('maps managed field definitions into automation conditions', () => {
    expect(
      helpers.generateManagedCustomAttributeTypes(
        appointmentFieldDefinitions,
        'appointment_attribute'
      )
    ).toEqual([
      {
        key: 'visit_reason',
        name: 'Visit reason',
        inputType: 'search_select',
        filterOperators: OPERATOR_TYPES_3,
        customAttributeType: 'appointment_attribute',
      },
      {
        key: 'visit_tags',
        name: 'Visit tags',
        inputType: 'multi_select',
        filterOperators: OPERATOR_TYPES_3,
        customAttributeType: 'appointment_attribute',
      },
      {
        key: 'needs_lab',
        name: 'Needs lab',
        inputType: 'search_select',
        filterOperators: OPERATOR_TYPES_3,
        customAttributeType: 'appointment_attribute',
      },
      {
        key: 'triage_note',
        name: 'Triage note',
        inputType: 'plain_text',
        filterOperators: OPERATOR_TYPES_7,
        customAttributeType: 'appointment_attribute',
      },
    ]);

    expect(
      helpers.generateManagedCustomAttributeTypes(
        dealFieldDefinitions,
        'deal_attribute'
      )
    ).toEqual([
      {
        key: 'deal_region',
        name: 'Deal region',
        inputType: 'search_select',
        filterOperators: OPERATOR_TYPES_3,
        customAttributeType: 'deal_attribute',
      },
    ]);

    expect(
      helpers.generateManagedCustomAttributeTypes(
        taskFieldDefinitions,
        'task_attribute'
      )
    ).toEqual([
      {
        key: 'task_channel',
        name: 'Task channel',
        inputType: 'search_select',
        filterOperators: OPERATOR_TYPES_3,
        customAttributeType: 'task_attribute',
      },
    ]);
  });
});

describe('getStandardAttributeInputType', () => {
  it('returns the resp default action model', () => {
    expect(
      helpers.getStandardAttributeInputType(
        AUTOMATIONS,
        'message_created',
        'message_type'
      )
    ).toEqual('search_select');
    expect(
      helpers.getStandardAttributeInputType(
        AUTOMATIONS,
        'conversation_created',
        'status'
      )
    ).toEqual('multi_select');
    expect(
      helpers.getStandardAttributeInputType(
        AUTOMATIONS,
        'conversation_updated',
        'referer'
      )
    ).toEqual('plain_text');
  });
});

describe('generateAutomationPayload', () => {
  it('returns the resp default action model', () => {
    const testPayload = {
      name: 'Test',
      description: 'This is a test',
      event_name: 'conversation_created',
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: [{ id: 'open', name: 'Open' }],
          query_operator: 'and',
        },
      ],
      actions: [
        {
          action_name: 'add_label',
          action_params: [{ id: 2, name: 'testlabel' }],
        },
      ],
    };
    const expectedPayload = {
      name: 'Test',
      description: 'This is a test',
      event_name: 'conversation_created',
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['open'],
        },
      ],
      actions: [
        {
          action_name: 'add_label',
          action_params: [2],
        },
      ],
    };
    expect(helpers.generateAutomationPayload(testPayload)).toEqual(
      expectedPayload
    );
  });
});

describe('isCustomAttribute', () => {
  it('returns the resp default action model', () => {
    const attrs = helpers.filterCustomAttributes(customAttributes);
    expect(helpers.isCustomAttribute(attrs, 'my_list')).toBeTruthy();
    expect(helpers.isCustomAttribute(attrs, 'my_check')).toBeTruthy();
    expect(helpers.isCustomAttribute(attrs, 'signed_up_at')).toBeTruthy();
    expect(helpers.isCustomAttribute(attrs, 'link')).toBeTruthy();
    expect(helpers.isCustomAttribute(attrs, 'prime_user')).toBeTruthy();
    expect(helpers.isCustomAttribute(attrs, 'hello')).toBeFalsy();
  });
});

describe('generateCustomAttributes', () => {
  it('generates and returns correct condition attribute', () => {
    expect(
      helpers.generateCustomAttributes(
        conversationAttrs,
        contactAttrs,
        'Conversation Custom Attributes',
        'Contact Custom Attributes'
      )
    ).toEqual(expectedOutputForCustomAttributeGenerator);
  });
});

describe('getAttributes', () => {
  it('returns the conditions for the given automation type', () => {
    const result = helpers.getAttributes(AUTOMATIONS, 'message_created');
    expect(result).toEqual(AUTOMATIONS.message_created.conditions);
  });
});

describe('getAttributes', () => {
  it('returns the conditions for the given automation type', () => {
    const result = helpers.getAttributes(AUTOMATIONS, 'message_created');
    expect(result).toEqual(AUTOMATIONS.message_created.conditions);
  });
});

describe('getAutomationType', () => {
  it('returns the automation type for the given key', () => {
    const mockAutomation = { event_name: 'message_created' };
    const result = helpers.getAutomationType(
      AUTOMATIONS,
      mockAutomation,
      'message_type'
    );
    expect(result).toEqual(
      AUTOMATIONS.message_created.conditions.find(c => c.key === 'message_type')
    );
  });
});

describe('getInputType', () => {
  it('returns the input type for a custom attribute', () => {
    const mockAutomation = { event_name: 'message_created' };
    const result = helpers.getInputType(
      customAttributes,
      AUTOMATIONS,
      mockAutomation,
      'signed_up_at'
    );
    expect(result).toEqual('date');
  });

  it('returns the input type for a standard attribute', () => {
    const mockAutomation = { event_name: 'message_created' };
    const result = helpers.getInputType(
      customAttributes,
      AUTOMATIONS,
      mockAutomation,
      'message_type'
    );
    expect(result).toEqual('search_select');
  });
});

describe('getOperators', () => {
  it('returns operators for a custom attribute in edit mode', () => {
    const mockAutomation = { event_name: 'message_created' };
    const result = helpers.getOperators(
      customAttributes,
      AUTOMATIONS,
      mockAutomation,
      'edit',
      'signed_up_at'
    );
    expect(result).toEqual(OPERATOR_TYPES_4);
  });

  it('returns operators for a standard attribute', () => {
    const mockAutomation = { event_name: 'message_created' };
    const result = helpers.getOperators(
      customAttributes,
      AUTOMATIONS,
      mockAutomation,
      'create',
      'message_type'
    );
    expect(result).toEqual(
      AUTOMATIONS.message_created.conditions.find(c => c.key === 'message_type')
        .filterOperators
    );
  });
});

describe('getCustomAttributeType', () => {
  it('returns the custom attribute type for the given key', () => {
    const mockAutomation = { event_name: 'message_created' };
    const result = helpers.getCustomAttributeType(
      AUTOMATIONS,
      mockAutomation,
      'message_type'
    );
    expect(result).toEqual(
      AUTOMATIONS.message_created.conditions.find(c => c.key === 'message_type')
        .customAttributeType
    );
  });
});

describe('showActionInput', () => {
  it('returns false for send_email_to_team and send_message actions', () => {
    expect(helpers.showActionInput([], 'send_email_to_team')).toBe(false);
    expect(helpers.showActionInput([], 'send_message')).toBe(false);
  });

  it('returns true if the action has an input type', () => {
    const mockActionTypes = [{ key: 'add_label', inputType: 'select' }];
    expect(helpers.showActionInput(mockActionTypes, 'add_label')).toBe(true);
  });

  it('returns false if the action does not have an input type', () => {
    const mockActionTypes = [{ key: 'some_action', inputType: null }];
    expect(helpers.showActionInput(mockActionTypes, 'some_action')).toBe(false);
  });
});
