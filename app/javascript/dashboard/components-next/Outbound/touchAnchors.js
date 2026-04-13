export const TOUCH_CREATED_AT_ANCHOR = 'touch.created_at';

const ANCHOR_DEFINITIONS = {
  appointment: [
    {
      value: 'appointment.starts_at',
      labelKey: 'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.APPOINTMENT_STARTS_AT',
    },
    {
      value: 'appointment.ends_at',
      labelKey: 'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.APPOINTMENT_ENDS_AT',
    },
  ],
  conversation: [
    {
      value: 'conversation.created_at',
      labelKey:
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_CREATED_AT',
    },
    {
      value: 'conversation.last_activity_at',
      labelKey:
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_LAST_ACTIVITY_AT',
    },
    {
      value: 'conversation.last_incoming_message_at',
      labelKey:
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_LAST_INCOMING_MESSAGE_AT',
    },
    {
      value: 'conversation.last_outgoing_message_at',
      labelKey:
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_LAST_OUTGOING_MESSAGE_AT',
    },
    {
      value: 'conversation.waiting_since',
      labelKey:
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_WAITING_SINCE',
    },
  ],
  deal: [
    {
      value: 'deal.expected_close_on',
      labelKey:
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.DEAL_EXPECTED_CLOSE_ON',
    },
  ],
  task: [
    {
      value: 'task.due_at',
      labelKey: 'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.TASK_DUE_AT',
    },
  ],
};

const REMINDABLE_TYPE_TO_ENTITY_KIND = {
  Conversation: 'conversation',
  'Crm::Deal': 'deal',
  'Crm::Task': 'task',
  'Scheduling::Appointment': 'appointment',
};

const anchorLabelForValue = (t, anchorValue) => {
  switch (anchorValue) {
    case 'appointment.starts_at':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.APPOINTMENT_STARTS_AT');
    case 'appointment.ends_at':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.APPOINTMENT_ENDS_AT');
    case 'conversation.created_at':
      return t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_CREATED_AT'
      );
    case 'conversation.last_activity_at':
      return t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_LAST_ACTIVITY_AT'
      );
    case 'conversation.last_incoming_message_at':
      return t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_LAST_INCOMING_MESSAGE_AT'
      );
    case 'conversation.last_outgoing_message_at':
      return t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_LAST_OUTGOING_MESSAGE_AT'
      );
    case 'conversation.waiting_since':
      return t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.CONVERSATION_WAITING_SINCE'
      );
    case 'deal.expected_close_on':
      return t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.DEAL_EXPECTED_CLOSE_ON'
      );
    case 'task.due_at':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.TASK_DUE_AT');
    default:
      return anchorValue;
  }
};

const normalizeEntityKinds = entityKinds => {
  const list = Array.isArray(entityKinds) ? entityKinds : [entityKinds];
  return list.filter(Boolean);
};

export const touchAnchorEntityKindForRemindableType = remindableType => {
  return REMINDABLE_TYPE_TO_ENTITY_KIND[remindableType] || 'conversation';
};

export const buildTouchAnchorOptions = ({
  entityKinds,
  includeTouchCreatedAt = false,
  kindLabelResolver = kind => kind,
  prefixLabelWithKind = false,
  t,
}) => {
  const selectedKinds = normalizeEntityKinds(entityKinds);
  const effectiveKinds = selectedKinds.length
    ? selectedKinds
    : ['conversation'];
  const options = [];
  const seen = new Set();

  if (includeTouchCreatedAt) {
    options.push({
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.TOUCH_CREATED_AT'),
      shortLabel: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS.TOUCH_CREATED_AT'),
      value: TOUCH_CREATED_AT_ANCHOR,
    });
    seen.add(TOUCH_CREATED_AT_ANCHOR);
  }

  effectiveKinds.forEach(kind => {
    (ANCHOR_DEFINITIONS[kind] || []).forEach(definition => {
      if (seen.has(definition.value)) {
        return;
      }

      const shortLabel = anchorLabelForValue(t, definition.value);
      options.push({
        label: prefixLabelWithKind
          ? `${kindLabelResolver(kind)} · ${shortLabel}`
          : shortLabel,
        shortLabel,
        value: definition.value,
      });
      seen.add(definition.value);
    });
  });

  return options;
};

export const touchAnchorSupportedEntityKinds = anchorValue => {
  return Object.entries(ANCHOR_DEFINITIONS)
    .filter(([, options]) =>
      options.some(option => option.value === anchorValue)
    )
    .map(([entityKind]) => entityKind);
};
