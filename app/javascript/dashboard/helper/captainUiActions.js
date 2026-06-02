const SIMPLE_ROUTE_ACTIONS = {
  open_home: 'home',
  open_contacts: 'contacts_dashboard_index',
  open_companies: 'companies_dashboard_index',
  open_tasks: 'crm_tasks_index',
  open_deals: 'crm_deals_index',
  open_notifications: 'notifications_index',
  open_outbound: 'outbound_broadcasts_index',
  open_touches: 'outbound_touches_index',
  open_outbound_personal: 'outbound_touches_index',
  open_touch_plans: 'outbound_touch_plans_index',
  open_templates: 'outbound_templates_index',
  open_automation_rules: 'automation_list',
  open_macros: 'macros_wrapper',
  open_canned_responses: 'outbound_templates_index',
  open_inboxes_settings: 'settings_inbox_list',
  open_agents_settings: 'agent_list',
  open_teams_settings: 'settings_teams_list',
  open_labels_settings: 'labels_list',
  open_account_settings: 'general_settings_index',
  open_scheduling_settings: 'scheduling_settings_index',
  open_assignment_policies: 'assignment_policy_index',
  open_integrations: 'settings_applications',
  open_webhooks: 'settings_integrations_webhook',
  open_kaspi_pay_settings: 'settings_integrations_kaspi_pay',
  open_reports: 'account_overview_reports',
  open_conversation_reports: 'conversation_reports',
  open_sla_reports: 'sla_reports',
  open_csat_reports: 'csat_reports',
  open_help_center: 'portals_index',
  open_captain_settings: 'captain_settings_index',
  open_captain_assistants: 'captain_assistants_create_index',
  open_captain_observability: 'captain_observability_index',
};

const TARGET_ROUTE_ACTIONS = {
  open_conversation: {
    name: 'inbox_conversation',
    paramName: 'conversation_id',
  },
  open_inbox: {
    name: 'inbox_dashboard',
    paramName: 'inbox_id',
  },
  open_inbox_settings: {
    name: 'settings_inbox_show',
    paramName: 'inboxId',
  },
  open_team_conversations: {
    name: 'team_conversations',
    paramName: 'teamId',
  },
  open_label_conversations: {
    name: 'label_conversations',
    paramName: 'label',
  },
  open_contact: {
    name: 'contacts_edit',
    paramName: 'contactId',
  },
};

const CAPTAIN_ASSISTANT_ROUTE_ACTIONS = {
  open_captain_responses: 'captain_assistants_responses_index',
  open_captain_documents: 'captain_assistants_documents_index',
  open_captain_tools: 'captain_tools_index',
  open_captain_scenarios: 'captain_assistants_scenarios_index',
  open_captain_playground: 'captain_assistants_prompts_index',
  open_captain_channels: 'captain_assistants_channels_index',
  open_captain_assistant_settings: 'captain_assistants_settings_index',
  open_captain_prompts: 'captain_assistants_prompts_index',
  open_assistant_settings: 'captain_assistants_settings_index',
  open_scenario_editor: 'captain_assistants_scenarios_index',
  open_documents_knowledge_panel: 'captain_assistants_documents_index',
  open_custom_tool_editor: 'captain_tools_index',
  open_tool_access_panel: 'captain_assistants_access_index',
  open_prompt_preview: 'captain_assistants_prompts_index',
  highlight_config_field: 'captain_assistants_settings_index',
};

const SHARED_CAPTAIN_ROUTE_NAMES = new Set([
  'captain_assistants_responses_index',
  'captain_assistants_documents_index',
  'captain_tools_index',
]);

const NON_ROUTE_ACTIONS = new Set(['show_confirmation']);

const QUERY_TARGET_ROUTE_ACTIONS = {
  open_company: {
    name: 'companies_dashboard_index',
    queryParam: 'companyId',
  },
  open_deal: {
    name: 'crm_deals_index',
    queryParam: 'dealId',
  },
};

const CREATE_ACTION_ROUTES = {
  create_contact: 'contacts_dashboard_index',
  create_company: 'companies_dashboard_index',
  create_task: 'crm_tasks_index',
  create_deal: 'crm_deals_index',
};

const CREATE_ACTION_QUERY_FIELDS = {
  create_contact: [
    ['name', ['name']],
    ['email', ['email']],
    ['phoneNumber', ['phoneNumber', 'phone_number', 'phone']],
    ['companyName', ['companyName', 'company_name']],
  ],
  create_company: [
    ['name', ['name']],
    ['domain', ['domain']],
    ['description', ['description']],
  ],
  create_task: [
    ['title', ['title']],
    ['description', ['description']],
    ['dueAt', ['dueAt', 'due_at']],
    ['startAt', ['startAt', 'start_at']],
    ['priority', ['priority']],
    ['dealId', ['dealId', 'deal_id']],
    ['statusId', ['statusId', 'status_id']],
    ['assigneeId', ['assigneeId', 'assignee_id']],
    ['teamId', ['teamId', 'team_id']],
    [
      'conversationDisplayId',
      ['conversationDisplayId', 'conversation_display_id'],
    ],
    [
      'originatingConversationId',
      ['originatingConversationId', 'originating_conversation_id'],
    ],
    ['contactName', ['contactName', 'contact_name']],
  ],
  create_deal: [
    ['title', ['title']],
    ['description', ['description']],
    ['amount', ['amount']],
    ['currency', ['currency']],
    ['expectedCloseOn', ['expectedCloseOn', 'expected_close_on']],
    ['contactId', ['contactId', 'contact_id']],
    ['contactName', ['contactName', 'contact_name']],
    ['companyId', ['companyId', 'company_id']],
    ['companyName', ['companyName', 'company_name']],
    ['ownerId', ['ownerId', 'owner_id']],
    ['teamId', ['teamId', 'team_id']],
    ['pipelineId', ['pipelineId', 'pipeline_id']],
    ['stageId', ['stageId', 'stage_id']],
    ['winProbability', ['winProbability', 'win_probability']],
    [
      'conversationDisplayId',
      ['conversationDisplayId', 'conversation_display_id'],
    ],
    [
      'originatingConversationId',
      ['originatingConversationId', 'originating_conversation_id'],
    ],
  ],
};

const SUPPORTED_ACTION_TYPES = new Set([
  ...Object.keys(SIMPLE_ROUTE_ACTIONS),
  ...Object.keys(TARGET_ROUTE_ACTIONS),
  ...Object.keys(CAPTAIN_ASSISTANT_ROUTE_ACTIONS),
  ...Object.keys(QUERY_TARGET_ROUTE_ACTIONS),
  ...Object.keys(CREATE_ACTION_ROUTES),
  ...NON_ROUTE_ACTIONS,
  'open_task',
]);

const DEFAULT_LABELS = {
  open_home: 'Open inbox',
  open_conversation: 'Open conversation',
  open_inbox: 'Open inbox',
  open_inbox_settings: 'Open inbox settings',
  open_team_conversations: 'Open team conversations',
  open_label_conversations: 'Open label conversations',
  open_contact: 'Open contact',
  open_company: 'Open company',
  open_deal: 'Open deal',
  open_task: 'Open task',
  open_contacts: 'Open contacts',
  open_companies: 'Open companies',
  open_tasks: 'Open tasks',
  open_deals: 'Open deals',
  open_notifications: 'Open notifications',
  open_outbound: 'Open outbound',
  open_touches: 'Open touches',
  open_outbound_personal: 'Open touches',
  open_touch_plans: 'Open touch plans',
  open_templates: 'Open templates',
  open_automation_rules: 'Open automation rules',
  open_macros: 'Open macros',
  open_canned_responses: 'Open canned responses',
  open_inboxes_settings: 'Open inboxes settings',
  open_agents_settings: 'Open agents settings',
  open_teams_settings: 'Open teams settings',
  open_labels_settings: 'Open labels settings',
  open_account_settings: 'Open account settings',
  open_scheduling_settings: 'Open scheduling settings',
  open_assignment_policies: 'Open assignment policies',
  open_integrations: 'Open integrations',
  open_webhooks: 'Open webhooks',
  open_kaspi_pay_settings: 'Open Kaspi Pay settings',
  open_reports: 'Open reports',
  open_conversation_reports: 'Open conversation reports',
  open_sla_reports: 'Open SLA reports',
  open_csat_reports: 'Open CSAT reports',
  open_help_center: 'Open help center',
  open_captain_settings: 'Open Captain settings',
  open_captain_assistants: 'Open Captain assistants',
  open_captain_responses: 'Open Captain responses',
  open_captain_documents: 'Open Captain documents',
  open_captain_tools: 'Open Captain tools',
  open_captain_scenarios: 'Open Captain scenarios',
  open_captain_playground: 'Open assistant prompts',
  open_captain_channels: 'Open Captain channels',
  open_captain_assistant_settings: 'Open assistant settings',
  open_captain_prompts: 'Open assistant prompts',
  open_assistant_settings: 'Open assistant settings',
  open_scenario_editor: 'Open scenario editor',
  open_documents_knowledge_panel: 'Open documents and knowledge',
  open_custom_tool_editor: 'Open custom tool editor',
  open_tool_access_panel: 'Open tool access',
  open_prompt_preview: 'Open prompt preview',
  highlight_config_field: 'Show setting',
  show_confirmation: 'Show confirmation',
  open_captain_observability: 'Open Captain observability',
  create_contact: 'Create contact',
  create_company: 'Create company',
  create_task: 'Create task',
  create_deal: 'Create deal',
};

export const supportedCaptainUiActionTypes = [...SUPPORTED_ACTION_TYPES];

const stripMarkup = value =>
  value
    .toString()
    .replace(/<[^>]*>/g, '')
    .replace(/[\r\n]+/g, ' ')
    .trim();

const actionTargetId = action =>
  action.target_id ??
  action.targetId ??
  action.entity_id ??
  action.entityId ??
  action.conversation_id ??
  action.conversationId ??
  action.contact_id ??
  action.contactId ??
  action.company_id ??
  action.companyId ??
  action.deal_id ??
  action.dealId ??
  action.task_id ??
  action.taskId ??
  action.inbox_id ??
  action.inboxId ??
  action.team_id ??
  action.teamId ??
  action.assistant_id ??
  action.assistantId ??
  '';

const safeString = value => stripMarkup(value ?? '').slice(0, 500);

const parsedTargetObject = action => {
  const rawTarget = actionTargetId(action).toString().trim();
  if (!rawTarget.startsWith('{')) return {};

  try {
    const parsed = JSON.parse(rawTarget);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch {
    return {};
  }
};

const parseTargetPrefill = action => parsedTargetObject(action);

const actionPrefill = action => {
  const parsedTarget = parseTargetPrefill(action);
  const fields = CREATE_ACTION_QUERY_FIELDS[action.type] || [];

  return fields.reduce((result, [queryKey, sourceKeys]) => {
    const value = sourceKeys
      .map(key => action[key] ?? parsedTarget[key])
      .find(item => item !== undefined && item !== null && item !== '');

    if (value !== undefined && value !== null && value !== '') {
      result[queryKey] = safeString(value);
    }

    return result;
  }, {});
};

const normalizedActionPayload = action => {
  const normalized = {
    type: action.type,
    label: stripMarkup(action.label || DEFAULT_LABELS[action.type]).slice(
      0,
      80
    ),
    targetId: safeString(actionTargetId(action)),
  };

  const prefill = actionPrefill(action);
  if (Object.keys(prefill).length) {
    normalized.prefill = prefill;
  }

  normalized.label = normalized.label || DEFAULT_LABELS[action.type];
  return normalized;
};

export const normalizeCaptainUiActions = actions => {
  if (!Array.isArray(actions)) return [];

  return actions
    .filter(action => action && SUPPORTED_ACTION_TYPES.has(action.type))
    .slice(0, 5)
    .map(normalizedActionPayload)
    .filter(action => action.label);
};

const simpleRoute = (name, accountId) => ({
  name,
  params: { accountId },
});

const targetRoute = (action, accountId, routeConfig) => {
  const targetId = safeString(action.targetId);
  if (!targetId) return null;

  return {
    name: routeConfig.name,
    params: { accountId, [routeConfig.paramName]: targetId },
  };
};

const compactQuery = query =>
  Object.entries(query).reduce((result, [key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      result[key] = value.toString();
    }
    return result;
  }, {});

const createActionRoute = (action, accountId) => ({
  name: CREATE_ACTION_ROUTES[action.type],
  params: { accountId },
  query: compactQuery({
    action: 'new',
    source: 'captain_ui_action',
    ...(action.prefill || actionPrefill(action)),
  }),
});

const queryTargetRoute = (action, accountId, routeConfig) => {
  const targetId = safeString(action.targetId || actionTargetId(action));
  if (!targetId) return null;

  return {
    name: routeConfig.name,
    params: { accountId },
    query: { [routeConfig.queryParam]: targetId, source: 'captain_ui_action' },
  };
};

const compactUiActionQuery = query =>
  compactQuery({ source: 'captain_ui_action', ...query });

const compactSafeUiActionQuery = query =>
  Object.entries(compactUiActionQuery(query)).reduce((result, [key, value]) => {
    result[key] = safeString(value);
    return result;
  }, {});

const assistantRouteTarget = action => {
  const parsedTarget = parsedTargetObject(action);
  const targetId = action.targetId || actionTargetId(action).toString().trim();
  const assistantId =
    action.assistantId ||
    action.assistant_id ||
    parsedTarget.assistantId ||
    parsedTarget.assistant_id;

  return {
    assistantId: safeString(
      assistantId || (targetId.startsWith('{') ? '' : targetId)
    ),
    parsedTarget,
  };
};

const assistantActionQuery = (action, parsedTarget) => {
  const query = {};

  if (action.type === 'open_scenario_editor') {
    query.scenarioId =
      parsedTarget.scenarioId ||
      parsedTarget.scenario_id ||
      action.scenarioId ||
      action.scenario_id;
  }

  if (action.type === 'open_custom_tool_editor') {
    query.customToolId =
      parsedTarget.customToolId ||
      parsedTarget.custom_tool_id ||
      action.customToolId ||
      action.custom_tool_id;
    query.action =
      parsedTarget.action ||
      action.action ||
      (query.customToolId ? 'edit' : 'new');
  }

  if (action.type === 'open_prompt_preview') {
    query.promptPreview = 'true';
  }

  if (action.type === 'highlight_config_field') {
    query.highlight =
      parsedTarget.field ||
      parsedTarget.configField ||
      action.field ||
      action.configField;
    query.panel = parsedTarget.panel || action.panel;
  }

  return compactSafeUiActionQuery(query);
};

const captainAssistantRoute = (action, accountId) => {
  const routeName = CAPTAIN_ASSISTANT_ROUTE_ACTIONS[action.type];
  const { assistantId, parsedTarget } = assistantRouteTarget(action);
  const query = assistantActionQuery(action, parsedTarget);

  if (SHARED_CAPTAIN_ROUTE_NAMES.has(routeName)) {
    return {
      name: routeName,
      params: { accountId },
      ...(Object.keys(query).length ? { query } : {}),
    };
  }

  if (!assistantId) return null;

  return {
    name: routeName,
    params: { accountId, assistantId },
    ...(Object.keys(query).length ? { query } : {}),
  };
};

export const routeForCaptainUiAction = (action, accountId) => {
  if (SIMPLE_ROUTE_ACTIONS[action.type]) {
    return simpleRoute(SIMPLE_ROUTE_ACTIONS[action.type], accountId);
  }

  if (TARGET_ROUTE_ACTIONS[action.type]) {
    return targetRoute(action, accountId, TARGET_ROUTE_ACTIONS[action.type]);
  }

  if (CAPTAIN_ASSISTANT_ROUTE_ACTIONS[action.type]) {
    return captainAssistantRoute(action, accountId);
  }

  if (QUERY_TARGET_ROUTE_ACTIONS[action.type]) {
    return queryTargetRoute(
      action,
      accountId,
      QUERY_TARGET_ROUTE_ACTIONS[action.type]
    );
  }

  if (CREATE_ACTION_ROUTES[action.type]) {
    return createActionRoute(action, accountId);
  }

  if (action.type === 'open_task') {
    const targetId = safeString(action.targetId);
    if (!targetId) return null;

    return {
      name: 'crm_tasks_index',
      params: { accountId },
      query: { taskId: targetId, source: 'captain_ui_action' },
    };
  }

  return null;
};

export const executeCaptainUiAction = async (
  action,
  { router, accountId, showConfirmation } = {}
) => {
  if (action.type === 'show_confirmation') {
    const message = safeString(
      action.targetId || actionTargetId(action) || action.label
    );
    if (showConfirmation && message) showConfirmation(message);
    return Boolean(message);
  }

  const target = routeForCaptainUiAction(action, accountId);
  if (!target) return false;

  await router.push(target);
  return true;
};
