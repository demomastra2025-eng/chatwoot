import {
  OPERATOR_TYPES_1,
  OPERATOR_TYPES_3,
  OPERATOR_TYPES_4,
  OPERATOR_TYPES_7,
} from 'dashboard/routes/dashboard/settings/automation/operators';
import {
  DEFAULT_MESSAGE_CREATED_CONDITION,
  DEFAULT_CONVERSATION_CONDITION,
  DEFAULT_OTHER_CONDITION,
  DEFAULT_DEAL_CONDITION,
  DEFAULT_TASK_CONDITION,
  DEFAULT_ACTIONS,
  DEFAULT_APPOINTMENT_ACTIONS,
  DEFAULT_CRM_ACTIONS,
} from 'dashboard/constants/automation';
import filterQueryGenerator from './filterQueryGenerator';
import actionQueryGenerator from './actionQueryGenerator';

const getAttributeKey = attribute =>
  attribute?.attribute_key || attribute?.key || '';

const getAttributeLabel = attribute =>
  attribute?.attribute_display_name || attribute?.label || '';

const getAttributeType = attribute =>
  attribute?.attribute_display_type ||
  attribute?.fieldType ||
  attribute?.field_type;

const getAttributeValues = attribute =>
  attribute?.attribute_values || attribute?.options || [];

const mapAttributeOption = option => {
  if (typeof option === 'string') {
    return { id: option, name: option };
  }

  const value = option?.value ?? option?.id;
  if (value === undefined || value === null || value === '') {
    return null;
  }

  return {
    id: value,
    name: option?.label || option?.name || value,
  };
};

export const getCustomAttributeInputType = key => {
  const customAttributeMap = {
    date: 'date',
    datetime: 'datetime',
    text: 'plain_text',
    textarea: 'plain_text',
    number: 'plain_text',
    currency: 'plain_text',
    percent: 'plain_text',
    list: 'search_select',
    select: 'search_select',
    multiselect: 'multi_select',
    checkbox: 'search_select',
    url: 'plain_text',
  };

  return customAttributeMap[key] || 'plain_text';
};

export const isACustomAttribute = (customAttributes, key) => {
  return customAttributes.find(attr => {
    return getAttributeKey(attr) === key;
  });
};

export const getCustomAttributeListDropdownValues = (
  customAttributes,
  type
) => {
  const attribute = customAttributes.find(
    attr => getAttributeKey(attr) === type
  );
  return getAttributeValues(attribute).map(mapAttributeOption).filter(Boolean);
};

export const isCustomAttributeCheckbox = (customAttributes, key) => {
  return customAttributes.find(attr => {
    return (
      getAttributeKey(attr) === key && getAttributeType(attr) === 'checkbox'
    );
  });
};

export const isCustomAttributeList = (customAttributes, type) => {
  return customAttributes.find(attr => {
    return (
      ['list', 'select', 'multiselect'].includes(getAttributeType(attr)) &&
      getAttributeKey(attr) === type
    );
  });
};

export const getOperatorTypes = key => {
  const operatorMap = {
    list: OPERATOR_TYPES_1,
    text: OPERATOR_TYPES_3,
    textarea: OPERATOR_TYPES_7,
    number: OPERATOR_TYPES_4,
    currency: OPERATOR_TYPES_4,
    percent: OPERATOR_TYPES_4,
    link: OPERATOR_TYPES_1,
    date: OPERATOR_TYPES_4,
    datetime: OPERATOR_TYPES_4,
    checkbox: OPERATOR_TYPES_1,
    select: OPERATOR_TYPES_3,
    multiselect: OPERATOR_TYPES_3,
    url: OPERATOR_TYPES_7,
  };

  return operatorMap[key] || OPERATOR_TYPES_1;
};

export const generateCustomAttributeTypes = (customAttributes, type) => {
  return customAttributes.map(attr => {
    return {
      key: getAttributeKey(attr),
      name: getAttributeLabel(attr),
      inputType: getCustomAttributeInputType(getAttributeType(attr)),
      filterOperators: getOperatorTypes(getAttributeType(attr)),
      customAttributeType: type,
    };
  });
};

const getManagedFieldOperatorTypes = fieldType => {
  if (['select', 'multiselect', 'checkbox'].includes(fieldType)) {
    return OPERATOR_TYPES_3;
  }

  if (
    ['number', 'currency', 'percent', 'date', 'datetime'].includes(fieldType)
  ) {
    return OPERATOR_TYPES_4;
  }

  if (['text', 'textarea', 'url'].includes(fieldType)) {
    return OPERATOR_TYPES_7;
  }

  return OPERATOR_TYPES_1;
};

const getManagedFieldInputType = fieldType => {
  if (fieldType === 'multiselect') {
    return 'multi_select';
  }

  return getCustomAttributeInputType(fieldType);
};

export const generateManagedCustomAttributeTypes = (
  fieldDefinitions,
  type = 'managed_attribute'
) => {
  return fieldDefinitions.map(fieldDefinition => ({
    key: fieldDefinition.key,
    name: fieldDefinition.label,
    inputType: getManagedFieldInputType(fieldDefinition.fieldType),
    filterOperators: getManagedFieldOperatorTypes(fieldDefinition.fieldType),
    customAttributeType: type,
  }));
};

const getManagedFieldDefinitionsForEvent = (
  eventName,
  appointmentFieldDefinitions,
  dealFieldDefinitions,
  taskFieldDefinitions
) => {
  if (eventName?.startsWith('appointment_')) {
    return appointmentFieldDefinitions || [];
  }

  if (eventName?.startsWith('deal_')) {
    return dealFieldDefinitions || [];
  }

  if (eventName?.startsWith('task_')) {
    return taskFieldDefinitions || [];
  }

  return [];
};

const getManagedConditionFilterMaps = ({
  appointmentPaymentStatusOptions,
  appointmentStatusOptions,
  appointmentTypeOptions,
  crmDealOwnerOptions,
  crmPipelineOptions,
  crmStageOptions,
  crmTaskAssigneeOptions,
  crmTaskStatusOptions,
  priorityOptions,
  teams,
}) => ({
  appointment: {
    status: appointmentStatusOptions,
    payment_status: appointmentPaymentStatusOptions,
    appointment_type: appointmentTypeOptions,
  },
  deal: {
    pipeline_id: crmPipelineOptions,
    stage_id: crmStageOptions,
    owner_id: crmDealOwnerOptions,
    team_id: teams,
  },
  task: {
    status_id: crmTaskStatusOptions,
    assignee_id: crmTaskAssigneeOptions,
    team_id: teams,
    priority: priorityOptions,
  },
});

export const generateConditionOptions = (options, key = 'id') => {
  if (!options || !Array.isArray(options)) return [];
  return options.map(i => {
    return {
      id: i[key],
      name: i.title,
    };
  });
};

export const getActionOptions = ({
  agents,
  appointmentStatusOptions,
  crmDealOwnerOptions,
  crmStageOptions,
  crmTaskStatusOptions,
  eventName,
  teams,
  labels,
  statusFilterOptions,
  touchPlans,
  type,
  addNoneToListFn,
  priorityOptions,
}) => {
  let entityKind = null;

  if (eventName?.startsWith('appointment_')) {
    entityKind = 'appointment';
  } else if (eventName?.startsWith('deal_')) {
    entityKind = 'deal';
  } else if (eventName?.startsWith('task_')) {
    entityKind = 'task';
  } else if (eventName) {
    entityKind = 'conversation';
  }

  const actionStatusOptions = (statusFilterOptions || []).filter(
    status => status.id !== 'all'
  );
  const entityTouchPlans = (touchPlans || []).filter(
    plan => !entityKind || (plan.entity_kinds || []).includes(entityKind)
  );

  const actionsMap = {
    assign_agent: addNoneToListFn ? addNoneToListFn(agents) : agents,
    assign_team: addNoneToListFn ? addNoneToListFn(teams) : teams,
    send_email_to_team: teams,
    add_label: generateConditionOptions(labels, 'title'),
    remove_label: generateConditionOptions(labels, 'title'),
    change_status: actionStatusOptions,
    change_priority: priorityOptions,
    change_appointment_status: appointmentStatusOptions,
    change_deal_stage: crmStageOptions,
    assign_deal_owner: addNoneToListFn
      ? addNoneToListFn(crmDealOwnerOptions)
      : crmDealOwnerOptions,
    assign_deal_team: addNoneToListFn ? addNoneToListFn(teams) : teams,
    change_task_status: crmTaskStatusOptions,
    assign_task_assignee: addNoneToListFn ? addNoneToListFn(agents) : agents,
    assign_task_team: addNoneToListFn ? addNoneToListFn(teams) : teams,
    change_task_priority: priorityOptions,
    apply_touch_plan: entityTouchPlans,
    cancel_touches: addNoneToListFn
      ? addNoneToListFn(entityTouchPlans)
      : entityTouchPlans,
  };
  return actionsMap[type];
};

export const getConditionOptions = ({
  agents,
  appointmentFieldDefinitions,
  appointmentPaymentStatusOptions,
  appointmentStatusOptions,
  appointmentTypeOptions,
  booleanFilterOptions,
  campaigns,
  crmDealOwnerOptions,
  crmPipelineOptions,
  crmStageOptions,
  crmTaskStatusOptions,
  dealFieldDefinitions,
  contacts,
  countries,
  customAttributes,
  eventName,
  inboxes,
  languages,
  labels,
  statusFilterOptions,
  taskFieldDefinitions,
  teams,
  type,
  priorityOptions,
  messageTypeOptions,
}) => {
  if (isCustomAttributeCheckbox(customAttributes, type)) {
    return booleanFilterOptions;
  }

  if (isCustomAttributeList(customAttributes, type)) {
    return getCustomAttributeListDropdownValues(customAttributes, type);
  }

  const managedFieldDefinitions = getManagedFieldDefinitionsForEvent(
    eventName,
    appointmentFieldDefinitions,
    dealFieldDefinitions,
    taskFieldDefinitions
  );

  const managedField = managedFieldDefinitions.find(
    fieldDefinition => fieldDefinition.key === type
  );

  if (managedField) {
    if (managedField.fieldType === 'checkbox') {
      return booleanFilterOptions;
    }

    if (['select', 'multiselect'].includes(managedField.fieldType)) {
      return getCustomAttributeListDropdownValues(
        managedFieldDefinitions,
        type
      );
    }
  }

  const managedConditionFilterMaps = getManagedConditionFilterMaps({
    appointmentPaymentStatusOptions,
    appointmentStatusOptions,
    appointmentTypeOptions,
    crmDealOwnerOptions,
    crmPipelineOptions,
    crmStageOptions,
    crmTaskAssigneeOptions: agents,
    crmTaskStatusOptions,
    priorityOptions,
    teams,
  });

  if (eventName?.startsWith('appointment_')) {
    return managedConditionFilterMaps.appointment[type];
  }

  if (eventName?.startsWith('deal_')) {
    return managedConditionFilterMaps.deal[type];
  }

  if (eventName?.startsWith('task_')) {
    return managedConditionFilterMaps.task[type];
  }

  const conditionFilterMaps = {
    status: statusFilterOptions,
    assignee_id: agents,
    contact: contacts,
    inbox_id: inboxes,
    team_id: teams,
    campaigns: generateConditionOptions(campaigns),
    browser_language: languages,
    conversation_language: languages,
    country_code: countries,
    message_type: messageTypeOptions,
    private_note: booleanFilterOptions,
    priority: priorityOptions,
    labels: generateConditionOptions(labels, 'title'),
  };

  return conditionFilterMaps[type];
};

export const getFileName = (action, files = []) => {
  const blobId = action.action_params[0];
  if (!blobId) return '';
  if (action.action_name === 'send_attachment') {
    const file = files.find(item => item.blob_id === blobId);
    if (file) return file.filename.toString();
  }
  return '';
};

export const getDefaultConditions = eventName => {
  if (eventName === 'message_created') {
    return structuredClone(DEFAULT_MESSAGE_CREATED_CONDITION);
  }
  if (
    eventName === 'conversation_opened' ||
    eventName === 'conversation_pending' ||
    eventName === 'conversation_transferred_to_ai' ||
    eventName === 'conversation_resolved'
  ) {
    return structuredClone(DEFAULT_CONVERSATION_CONDITION);
  }
  if (eventName?.startsWith('deal_')) {
    return structuredClone(DEFAULT_DEAL_CONDITION);
  }
  if (eventName?.startsWith('task_')) {
    return structuredClone(DEFAULT_TASK_CONDITION);
  }
  return structuredClone(DEFAULT_OTHER_CONDITION);
};

export const getDefaultActions = eventName => {
  if (
    eventName?.startsWith('appointment_') ||
    eventName?.startsWith('deal_') ||
    eventName?.startsWith('task_')
  ) {
    if (eventName?.startsWith('appointment_')) {
      return structuredClone(DEFAULT_APPOINTMENT_ACTIONS);
    }

    return structuredClone(DEFAULT_CRM_ACTIONS);
  }

  return structuredClone(DEFAULT_ACTIONS);
};

export const filterCustomAttributes = customAttributes => {
  return customAttributes.map(attr => {
    return {
      key: getAttributeKey(attr),
      name: getAttributeLabel(attr),
      type: getAttributeType(attr),
    };
  });
};

export const getStandardAttributeInputType = (automationTypes, event, key) => {
  return automationTypes[event].conditions.find(item => item.key === key)
    .inputType;
};

export const generateAutomationPayload = payload => {
  const automation = JSON.parse(JSON.stringify(payload));
  automation.conditions[automation.conditions.length - 1].query_operator = null;
  automation.conditions = filterQueryGenerator(automation.conditions).payload;
  automation.actions = actionQueryGenerator(automation.actions);
  return automation;
};

export const isCustomAttribute = (attrs, key) => {
  return attrs.find(attr => attr.key === key);
};

export const generateCustomAttributes = (
  // eslint-disable-next-line default-param-last
  conversationAttributes = [],
  // eslint-disable-next-line default-param-last
  contactAttributes = [],
  conversationlabel,
  contactlabel
) => {
  const customAttributes = [];
  if (conversationAttributes.length) {
    customAttributes.push(
      {
        key: `conversation_custom_attribute`,
        name: conversationlabel,
        disabled: true,
      },
      ...conversationAttributes
    );
  }
  if (contactAttributes.length) {
    customAttributes.push(
      {
        key: `contact_custom_attribute`,
        name: contactlabel,
        disabled: true,
      },
      ...contactAttributes
    );
  }
  return customAttributes;
};

/**
 * Get attributes for a given key from automation types.
 * @param {Object} automationTypes - Object containing automation types.
 * @param {string} key - The key to get attributes for.
 * @returns {Array} Array of condition objects for the given key.
 */
export const getAttributes = (automationTypes, key) => {
  return automationTypes[key].conditions;
};

/**
 * Get the automation type for a given key.
 * @param {Object} automationTypes - Object containing automation types.
 * @param {Object} automation - The automation object.
 * @param {string} key - The key to get the automation type for.
 * @returns {Object} The automation type object.
 */
export const getAutomationType = (automationTypes, automation, key) => {
  return automationTypes[automation.event_name].conditions.find(
    condition => condition.key === key
  );
};

/**
 * Get the input type for a given key.
 * @param {Array} allCustomAttributes - Array of all custom attributes.
 * @param {Object} automationTypes - Object containing automation types.
 * @param {Object} automation - The automation object.
 * @param {string} key - The key to get the input type for.
 * @returns {string} The input type.
 */
export const getInputType = (
  allCustomAttributes,
  automationTypes,
  automation,
  key
) => {
  const customAttribute = isACustomAttribute(allCustomAttributes, key);
  if (customAttribute) {
    return getCustomAttributeInputType(customAttribute.attribute_display_type);
  }
  const type = getAutomationType(automationTypes, automation, key);
  return type.inputType;
};

/**
 * Get operators for a given key.
 * @param {Array} allCustomAttributes - Array of all custom attributes.
 * @param {Object} automationTypes - Object containing automation types.
 * @param {Object} automation - The automation object.
 * @param {string} mode - The mode ('edit' or other).
 * @param {string} key - The key to get operators for.
 * @returns {Array} Array of operators.
 */
export const getOperators = (
  allCustomAttributes,
  automationTypes,
  automation,
  mode,
  key
) => {
  if (mode === 'edit') {
    const customAttribute = isACustomAttribute(allCustomAttributes, key);
    if (customAttribute) {
      return getOperatorTypes(customAttribute.attribute_display_type);
    }
  }
  const type = getAutomationType(automationTypes, automation, key);
  return type.filterOperators;
};

/**
 * Get the custom attribute type for a given key.
 * @param {Object} automationTypes - Object containing automation types.
 * @param {Object} automation - The automation object.
 * @param {string} key - The key to get the custom attribute type for.
 * @returns {string} The custom attribute type.
 */
export const getCustomAttributeType = (automationTypes, automation, key) => {
  return automationTypes[automation.event_name].conditions.find(
    i => i.key === key
  ).customAttributeType;
};

/**
 * Determine if an action input should be shown.
 * @param {Array} automationActionTypes - Array of automation action type objects.
 * @param {string} action - The action to check.
 * @returns {boolean} True if the action input should be shown, false otherwise.
 */
export const showActionInput = (automationActionTypes, action) => {
  if (action === 'send_email_to_team' || action === 'send_message')
    return false;
  const actionType = automationActionTypes.find(i => i.key === action);
  return !!actionType?.inputType;
};
