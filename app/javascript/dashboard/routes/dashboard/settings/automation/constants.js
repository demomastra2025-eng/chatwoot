import {
  OPERATOR_TYPES_1,
  OPERATOR_TYPES_2,
  OPERATOR_TYPES_3,
  OPERATOR_TYPES_4,
  OPERATOR_TYPES_6,
  OPERATOR_TYPES_7,
  OPERATOR_TYPES_8,
} from './operators';

const APPOINTMENT_AUTOMATION_CONDITIONS = [
  {
    key: 'status',
    name: 'STATUS',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'payment_status',
    name: 'PAYMENT_STATUS',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'appointment_type',
    name: 'APPOINTMENT_TYPE',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'source',
    name: 'SOURCE',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'starts_at_weekday',
    name: 'APPOINTMENT_START_WEEKDAY',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'starts_at_time',
    name: 'APPOINTMENT_START_TIME',
    inputType: 'time',
    filterOperators: OPERATOR_TYPES_8,
  },
  {
    key: 'service_id',
    name: 'APPOINTMENT_SERVICE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_1,
  },
];

const APPOINTMENT_AUTOMATION_ACTIONS = [
  {
    key: 'change_appointment_status',
    name: 'CHANGE_APPOINTMENT_STATUS',
  },
  {
    key: 'cancel_appointment_payment',
    name: 'CANCEL_APPOINTMENT_PAYMENT',
  },
  {
    key: 'send_webhook_event',
    name: 'SEND_WEBHOOK_EVENT',
  },
  {
    key: 'send_message',
    name: 'SEND_MESSAGE',
  },
];

const DEAL_AUTOMATION_CONDITIONS = [
  {
    key: 'pipeline_id',
    name: 'DEAL_PIPELINE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'stage_id',
    name: 'DEAL_STAGE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'owner_id',
    name: 'DEAL_OWNER',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'team_id',
    name: 'TEAM_NAME',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'title',
    name: 'DEAL_TITLE',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'description',
    name: 'DEAL_DESCRIPTION',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'currency',
    name: 'DEAL_CURRENCY',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'external_ref',
    name: 'DEAL_EXTERNAL_REF',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'amount_minor',
    name: 'DEAL_AMOUNT',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'win_probability',
    name: 'DEAL_WIN_PROBABILITY',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'expected_close_on',
    name: 'DEAL_EXPECTED_CLOSE_ON',
    inputType: 'date',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'closed_at',
    name: 'DEAL_CLOSED_AT',
    inputType: 'datetime',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'archived_at',
    name: 'DEAL_ARCHIVED_AT',
    inputType: 'datetime',
    filterOperators: OPERATOR_TYPES_4,
  },
];

const DEAL_AUTOMATION_ACTIONS = [
  {
    key: 'change_deal_stage',
    name: 'CHANGE_DEAL_STAGE',
  },
  {
    key: 'assign_deal_owner',
    name: 'ASSIGN_DEAL_OWNER',
  },
  {
    key: 'assign_deal_team',
    name: 'ASSIGN_DEAL_TEAM',
  },
  {
    key: 'archive_deal',
    name: 'ARCHIVE_DEAL',
  },
  {
    key: 'unarchive_deal',
    name: 'UNARCHIVE_DEAL',
  },
  {
    key: 'send_webhook_event',
    name: 'SEND_WEBHOOK_EVENT',
  },
  {
    key: 'send_message',
    name: 'SEND_MESSAGE',
  },
];

const TASK_AUTOMATION_CONDITIONS = [
  {
    key: 'status_id',
    name: 'TASK_STATUS',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'assignee_id',
    name: 'TASK_ASSIGNEE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'team_id',
    name: 'TEAM_NAME',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'priority',
    name: 'PRIORITY',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'title',
    name: 'TASK_TITLE',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'description',
    name: 'TASK_DESCRIPTION',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'external_ref',
    name: 'TASK_EXTERNAL_REF',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_7,
  },
  {
    key: 'start_at',
    name: 'TASK_START_AT',
    inputType: 'datetime',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'due_at',
    name: 'TASK_DUE_AT',
    inputType: 'datetime',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'completed_at',
    name: 'TASK_COMPLETED_AT',
    inputType: 'datetime',
    filterOperators: OPERATOR_TYPES_4,
  },
  {
    key: 'archived_at',
    name: 'TASK_ARCHIVED_AT',
    inputType: 'datetime',
    filterOperators: OPERATOR_TYPES_4,
  },
];

const TASK_AUTOMATION_ACTIONS = [
  {
    key: 'change_task_status',
    name: 'CHANGE_TASK_STATUS',
  },
  {
    key: 'assign_task_assignee',
    name: 'ASSIGN_TASK_ASSIGNEE',
  },
  {
    key: 'assign_task_team',
    name: 'ASSIGN_TASK_TEAM',
  },
  {
    key: 'change_task_priority',
    name: 'CHANGE_TASK_PRIORITY',
  },
  {
    key: 'archive_task',
    name: 'ARCHIVE_TASK',
  },
  {
    key: 'unarchive_task',
    name: 'UNARCHIVE_TASK',
  },
  {
    key: 'send_webhook_event',
    name: 'SEND_WEBHOOK_EVENT',
  },
  {
    key: 'send_message',
    name: 'SEND_MESSAGE',
  },
];

const CONVERSATION_AUTOMATION_CONDITIONS = [
  {
    key: 'content',
    name: 'MESSAGE_CONTAINS',
    inputType: 'comma_separated_plain_text',
    filterOperators: OPERATOR_TYPES_2,
  },
  {
    key: 'email',
    name: 'EMAIL',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_2,
  },
  {
    key: 'country_code',
    name: 'COUNTRY_NAME',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'status',
    name: 'STATUS',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'message_type',
    name: 'MESSAGE_TYPE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'browser_language',
    name: 'BROWSER_LANGUAGE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'assignee_id',
    name: 'ASSIGNEE_NAME',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'team_id',
    name: 'TEAM_NAME',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'referer',
    name: 'REFERER_LINK',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_2,
  },
  {
    key: 'city',
    name: 'CITY',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_2,
  },
  {
    key: 'company',
    name: 'COMPANY',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_2,
  },
  {
    key: 'inbox_id',
    name: 'INBOX',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'mail_subject',
    name: 'MAIL_SUBJECT',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_2,
  },
  {
    key: 'phone_number',
    name: 'PHONE_NUMBER',
    inputType: 'plain_text',
    filterOperators: OPERATOR_TYPES_6,
  },
  {
    key: 'priority',
    name: 'PRIORITY',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'conversation_language',
    name: 'CONVERSATION_LANGUAGE',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_1,
  },
  {
    key: 'labels',
    name: 'LABELS',
    inputType: 'multi_select',
    filterOperators: OPERATOR_TYPES_3,
  },
  {
    key: 'private_note',
    name: 'PRIVATE_NOTE',
    inputType: 'search_select',
    filterOperators: OPERATOR_TYPES_1,
  },
];

const CONVERSATION_AUTOMATION_ACTIONS = [
  {
    key: 'send_message',
    name: 'SEND_MESSAGE',
  },
  {
    key: 'add_label',
    name: 'ADD_LABEL',
  },
  {
    key: 'remove_label',
    name: 'REMOVE_LABEL',
  },
  {
    key: 'send_email_to_team',
    name: 'SEND_EMAIL_TO_TEAM',
  },
  {
    key: 'assign_team',
    name: 'ASSIGN_TEAM',
  },
  {
    key: 'assign_agent',
    name: 'ASSIGN_AGENT',
  },
  {
    key: 'remove_assigned_agent',
    name: 'REMOVE_ASSIGNED_AGENT',
  },
  {
    key: 'remove_assigned_team',
    name: 'REMOVE_ASSIGNED_TEAM',
  },
  {
    key: 'send_webhook_event',
    name: 'SEND_WEBHOOK_EVENT',
  },
  {
    key: 'mute_conversation',
    name: 'MUTE_CONVERSATION',
  },
  {
    key: 'send_attachment',
    name: 'SEND_ATTACHMENT',
  },
  {
    key: 'change_status',
    name: 'CHANGE_STATUS',
  },
  {
    key: 'resolve_conversation',
    name: 'RESOLVE_CONVERSATION',
  },
  {
    key: 'open_conversation',
    name: 'OPEN_CONVERSATION',
  },
  {
    key: 'pending_conversation',
    name: 'PENDING_CONVERSATION',
  },
  {
    key: 'snooze_conversation',
    name: 'SNOOZE_CONVERSATION',
  },
  {
    key: 'change_priority',
    name: 'CHANGE_PRIORITY',
  },
  {
    key: 'send_email_transcript',
    name: 'SEND_EMAIL_TRANSCRIPT',
  },
  {
    key: 'add_private_note',
    name: 'ADD_PRIVATE_NOTE',
  },
];

export const AUTOMATIONS = {
  message_created: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  conversation_created: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  conversation_updated: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  conversation_opened: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  conversation_pending: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  conversation_transferred_to_ai: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  conversation_resolved: {
    conditions: CONVERSATION_AUTOMATION_CONDITIONS,
    actions: CONVERSATION_AUTOMATION_ACTIONS,
  },
  appointment_created: {
    conditions: APPOINTMENT_AUTOMATION_CONDITIONS,
    actions: APPOINTMENT_AUTOMATION_ACTIONS,
  },
  appointment_updated: {
    conditions: APPOINTMENT_AUTOMATION_CONDITIONS,
    actions: APPOINTMENT_AUTOMATION_ACTIONS,
  },
  appointment_cancelled: {
    conditions: APPOINTMENT_AUTOMATION_CONDITIONS,
    actions: APPOINTMENT_AUTOMATION_ACTIONS,
  },
  appointment_completed: {
    conditions: APPOINTMENT_AUTOMATION_CONDITIONS,
    actions: APPOINTMENT_AUTOMATION_ACTIONS,
  },
  deal_created: {
    conditions: DEAL_AUTOMATION_CONDITIONS,
    actions: DEAL_AUTOMATION_ACTIONS,
  },
  deal_updated: {
    conditions: DEAL_AUTOMATION_CONDITIONS,
    actions: DEAL_AUTOMATION_ACTIONS,
  },
  deal_stage_changed: {
    conditions: DEAL_AUTOMATION_CONDITIONS,
    actions: DEAL_AUTOMATION_ACTIONS,
  },
  deal_archived: {
    conditions: DEAL_AUTOMATION_CONDITIONS,
    actions: DEAL_AUTOMATION_ACTIONS,
  },
  deal_unarchived: {
    conditions: DEAL_AUTOMATION_CONDITIONS,
    actions: DEAL_AUTOMATION_ACTIONS,
  },
  task_created: {
    conditions: TASK_AUTOMATION_CONDITIONS,
    actions: TASK_AUTOMATION_ACTIONS,
  },
  task_updated: {
    conditions: TASK_AUTOMATION_CONDITIONS,
    actions: TASK_AUTOMATION_ACTIONS,
  },
  task_status_changed: {
    conditions: TASK_AUTOMATION_CONDITIONS,
    actions: TASK_AUTOMATION_ACTIONS,
  },
  task_archived: {
    conditions: TASK_AUTOMATION_CONDITIONS,
    actions: TASK_AUTOMATION_ACTIONS,
  },
  task_unarchived: {
    conditions: TASK_AUTOMATION_CONDITIONS,
    actions: TASK_AUTOMATION_ACTIONS,
  },
};

export const AUTOMATION_RULE_EVENTS = [
  {
    key: 'conversation_created',
    value: 'CONVERSATION_CREATED',
  },
  {
    key: 'conversation_updated',
    value: 'CONVERSATION_UPDATED',
  },
  {
    key: 'conversation_resolved',
    value: 'CONVERSATION_RESOLVED',
  },
  {
    key: 'message_created',
    value: 'MESSAGE_CREATED',
  },
  {
    key: 'conversation_opened',
    value: 'CONVERSATION_OPENED',
  },
  {
    key: 'conversation_pending',
    value: 'CONVERSATION_PENDING',
  },
  {
    key: 'conversation_transferred_to_ai',
    value: 'CONVERSATION_TRANSFERRED_TO_AI',
  },
  {
    key: 'appointment_created',
    value: 'APPOINTMENT_CREATED',
  },
  {
    key: 'appointment_updated',
    value: 'APPOINTMENT_UPDATED',
  },
  {
    key: 'appointment_cancelled',
    value: 'APPOINTMENT_CANCELLED',
  },
  {
    key: 'appointment_completed',
    value: 'APPOINTMENT_COMPLETED',
  },
  {
    key: 'deal_created',
    value: 'DEAL_CREATED',
  },
  {
    key: 'deal_updated',
    value: 'DEAL_UPDATED',
  },
  {
    key: 'deal_stage_changed',
    value: 'DEAL_STAGE_CHANGED',
  },
  {
    key: 'deal_archived',
    value: 'DEAL_ARCHIVED',
  },
  {
    key: 'deal_unarchived',
    value: 'DEAL_UNARCHIVED',
  },
  {
    key: 'task_created',
    value: 'TASK_CREATED',
  },
  {
    key: 'task_updated',
    value: 'TASK_UPDATED',
  },
  {
    key: 'task_status_changed',
    value: 'TASK_STATUS_CHANGED',
  },
  {
    key: 'task_archived',
    value: 'TASK_ARCHIVED',
  },
  {
    key: 'task_unarchived',
    value: 'TASK_UNARCHIVED',
  },
];

export const AUTOMATION_ACTION_TYPES = [
  {
    key: 'assign_agent',
    label: 'ASSIGN_AGENT',
    inputType: 'search_select',
  },
  {
    key: 'assign_team',
    label: 'ASSIGN_TEAM',
    inputType: 'search_select',
  },
  {
    key: 'remove_assigned_agent',
    label: 'REMOVE_ASSIGNED_AGENT',
    inputType: null,
  },
  {
    key: 'remove_assigned_team',
    label: 'REMOVE_ASSIGNED_TEAM',
    inputType: null,
  },
  {
    key: 'add_label',
    label: 'ADD_LABEL',
    inputType: 'multi_select',
  },
  {
    key: 'remove_label',
    label: 'REMOVE_LABEL',
    inputType: 'multi_select',
  },
  {
    key: 'send_email_to_team',
    label: 'SEND_EMAIL_TO_TEAM',
    inputType: 'team_message',
  },
  {
    key: 'send_email_transcript',
    label: 'SEND_EMAIL_TRANSCRIPT',
    inputType: 'email',
  },
  {
    key: 'mute_conversation',
    label: 'MUTE_CONVERSATION',
    inputType: null,
  },
  {
    key: 'snooze_conversation',
    label: 'SNOOZE_CONVERSATION',
    inputType: null,
  },
  {
    key: 'change_status',
    label: 'CHANGE_STATUS',
    inputType: 'search_select',
  },
  {
    key: 'resolve_conversation',
    label: 'RESOLVE_CONVERSATION',
    inputType: null,
  },
  {
    key: 'open_conversation',
    label: 'OPEN_CONVERSATION',
    inputType: null,
  },
  {
    key: 'pending_conversation',
    label: 'PENDING_CONVERSATION',
    inputType: null,
  },
  {
    key: 'change_appointment_status',
    label: 'CHANGE_APPOINTMENT_STATUS',
    inputType: 'search_select',
  },
  {
    key: 'change_deal_stage',
    label: 'CHANGE_DEAL_STAGE',
    inputType: 'search_select',
  },
  {
    key: 'assign_deal_owner',
    label: 'ASSIGN_DEAL_OWNER',
    inputType: 'search_select',
  },
  {
    key: 'assign_deal_team',
    label: 'ASSIGN_DEAL_TEAM',
    inputType: 'search_select',
  },
  {
    key: 'archive_deal',
    label: 'ARCHIVE_DEAL',
    inputType: null,
  },
  {
    key: 'unarchive_deal',
    label: 'UNARCHIVE_DEAL',
    inputType: null,
  },
  {
    key: 'change_task_status',
    label: 'CHANGE_TASK_STATUS',
    inputType: 'search_select',
  },
  {
    key: 'assign_task_assignee',
    label: 'ASSIGN_TASK_ASSIGNEE',
    inputType: 'search_select',
  },
  {
    key: 'assign_task_team',
    label: 'ASSIGN_TASK_TEAM',
    inputType: 'search_select',
  },
  {
    key: 'change_task_priority',
    label: 'CHANGE_TASK_PRIORITY',
    inputType: 'search_select',
  },
  {
    key: 'archive_task',
    label: 'ARCHIVE_TASK',
    inputType: null,
  },
  {
    key: 'unarchive_task',
    label: 'UNARCHIVE_TASK',
    inputType: null,
  },
  {
    key: 'cancel_appointment_payment',
    label: 'CANCEL_APPOINTMENT_PAYMENT',
    inputType: null,
  },
  {
    key: 'send_webhook_event',
    label: 'SEND_WEBHOOK_EVENT',
    inputType: 'url',
  },
  {
    key: 'apply_touch_plan',
    label: 'APPLY_TOUCH_PLAN',
    inputType: null,
    legacyOnly: true,
  },
  {
    key: 'create_touch',
    label: 'CREATE_TOUCH',
    inputType: 'touch',
    legacyOnly: true,
  },
  {
    key: 'cancel_touches',
    label: 'CANCEL_TOUCHES',
    inputType: null,
    legacyOnly: true,
  },
  {
    key: 'send_attachment',
    label: 'SEND_ATTACHMENT',
    inputType: 'attachment',
  },
  {
    key: 'send_message',
    label: 'SEND_MESSAGE',
    inputType: 'touch',
  },
  {
    key: 'add_private_note',
    label: 'ADD_PRIVATE_NOTE',
    inputType: 'textarea',
  },
  {
    key: 'change_priority',
    label: 'CHANGE_PRIORITY',
    inputType: 'search_select',
  },
];
