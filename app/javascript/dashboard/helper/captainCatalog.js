const normalizeCatalogText = value =>
  String(value ?? '')
    .trim()
    .toLocaleLowerCase();

const extractReferenceIds = (content, scheme) => {
  const referenceRegexp = new RegExp(`${scheme}:\\/\\/([^\\s)]+)`, 'g');
  const ids = Array.from(
    String(content ?? '').matchAll(referenceRegexp),
    match => {
      const rawId = (match[1] || '').replace(/[.,;:!?]+$/g, '');
      try {
        return decodeURIComponent(rawId);
      } catch {
        return rawId;
      }
    }
  ).filter(Boolean);

  return Array.from(new Set(ids));
};

const FIELD_GROUP_KEY_MAP = {
  Contact: 'CONTACT',
  Conversation: 'CONVERSATION',
  Deal: 'DEAL',
  Task: 'TASK',
  Appointment: 'APPOINTMENT',
  'Contact Attributes': 'CONTACT_ATTRIBUTES',
  'Conversation Attributes': 'CONVERSATION_ATTRIBUTES',
  'Deal Attributes': 'DEAL_ATTRIBUTES',
  'Task Attributes': 'TASK_ATTRIBUTES',
  'Appointment Attributes': 'APPOINTMENT_ATTRIBUTES',
};

const FIELD_SCOPE_KEY_MAP = {
  contact: 'CONTACT',
  conversation: 'CONVERSATION',
  deal: 'DEAL',
  task: 'TASK',
  appointment: 'APPOINTMENT',
};

const TOOL_GROUP_KEY_MAP = {
  Knowledge: 'KNOWLEDGE',
  Conversations: 'CONVERSATIONS',
  Contacts: 'CONTACTS',
  Companies: 'COMPANIES',
  'CRM Deals': 'CRM_DEALS',
  'CRM Tasks': 'CRM_TASKS',
  Scheduling: 'SCHEDULING',
  Outbound: 'OUTBOUND',
  'Support content': 'SUPPORT_CONTENT',
  Automation: 'AUTOMATION',
  Operations: 'OPERATIONS',
  Confirmations: 'CONFIRMATIONS',
  'Help center': 'HELP_CENTER',
  Integrations: 'INTEGRATIONS',
};

const compareCatalogText = (leftValue, rightValue) =>
  String(leftValue ?? '').localeCompare(String(rightValue ?? ''), undefined, {
    sensitivity: 'base',
    numeric: true,
  });

const translateCatalogValue = ({ t, te }, key, fallback) => {
  if (typeof te === 'function' && te(key)) {
    // The catalog keys are derived from stable field/tool ids at runtime.
    // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
    return t(key);
  }

  return fallback;
};

const normalizeCatalogI18nSegment = value =>
  String(value ?? '')
    .trim()
    .replace(/[^a-zA-Z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toUpperCase();

const fieldGroupTranslationKey = field => {
  const groupKey = FIELD_GROUP_KEY_MAP[field?.group_name];

  if (groupKey) {
    if (FIELD_SCOPE_KEY_MAP[groupKey.toLowerCase()]) {
      return `CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.${groupKey}.TITLE`;
    }

    return `CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.${groupKey}`;
  }

  const scopeKey = FIELD_SCOPE_KEY_MAP[field?.table_name];

  return scopeKey
    ? `CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.${scopeKey}.TITLE`
    : null;
};

const fieldBaseTranslationKey = field => {
  if (field?.field_type !== 'field') {
    return null;
  }

  const scopeKey = FIELD_SCOPE_KEY_MAP[field?.table_name];
  const fieldKey = normalizeCatalogI18nSegment(field?.field_key);

  if (!scopeKey || !fieldKey) {
    return null;
  }

  return `CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELDS.${scopeKey}.${fieldKey}`;
};

const fieldTitleTranslationKey = field => {
  const baseKey = fieldBaseTranslationKey(field);
  return baseKey ? `${baseKey}.TITLE` : null;
};

const fieldDescriptionTranslationKey = field => {
  const baseKey = fieldBaseTranslationKey(field);
  return baseKey ? `${baseKey}.DESCRIPTION` : null;
};

const fieldFallbackDescription = (field, { t, te }) => {
  const scopeKey = FIELD_SCOPE_KEY_MAP[field?.table_name];

  if (!scopeKey) {
    return field?.description;
  }

  const entityKey = `CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.ENTITIES.${scopeKey}`;
  const fieldTypeKey =
    field?.field_type === 'custom_attribute'
      ? 'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELD_TYPES.CUSTOM'
      : 'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELD_TYPES.DEFAULT';

  if (typeof te === 'function' && te(entityKey) && te(fieldTypeKey)) {
    // The catalog keys are derived from stable field ids at runtime.
    // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
    return t(fieldTypeKey, { entity: t(entityKey) });
  }

  return field?.description;
};

const toolGroupTranslationKey = tool => {
  const groupKey = TOOL_GROUP_KEY_MAP[tool?.group_name || tool?.group_label];

  return groupKey
    ? `CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.${groupKey}`
    : null;
};

const toolTranslationBaseKey = tool => {
  const toolKey = String(tool?.id ?? '').trim();

  return toolKey
    ? `CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.${toolKey}`
    : null;
};

export const localizeCatalogField = (field, i18n) => {
  if (!field) {
    return field;
  }

  const groupKey = fieldGroupTranslationKey(field);
  const titleKey = fieldTitleTranslationKey(field);
  const descriptionKey = fieldDescriptionTranslationKey(field);

  return {
    ...field,
    original_title: field.title,
    original_description: field.description,
    title: titleKey
      ? translateCatalogValue(i18n, titleKey, field.title)
      : field.title,
    description: descriptionKey
      ? translateCatalogValue(
          i18n,
          descriptionKey,
          fieldFallbackDescription(field, i18n)
        )
      : fieldFallbackDescription(field, i18n),
    group_label: groupKey
      ? translateCatalogValue(
          i18n,
          groupKey,
          field.group_label || field.group_name || ''
        )
      : field.group_label || field.group_name || '',
  };
};

export const localizeCatalogTool = (tool, i18n) => {
  if (!tool) {
    return tool;
  }

  const groupKey = toolGroupTranslationKey(tool);
  const baseKey = toolTranslationBaseKey(tool);

  return {
    ...tool,
    original_title: tool.title,
    original_description: tool.description,
    title: baseKey
      ? translateCatalogValue(i18n, `${baseKey}.TITLE`, tool.title)
      : tool.title,
    description: baseKey
      ? translateCatalogValue(i18n, `${baseKey}.DESCRIPTION`, tool.description)
      : tool.description,
    group_label: groupKey
      ? translateCatalogValue(
          i18n,
          groupKey,
          tool.group_label || tool.group_name || ''
        )
      : tool.group_label || tool.group_name || '',
  };
};

export const extractCaptainToolReferenceIds = content =>
  extractReferenceIds(content, 'tool');

export const extractCaptainFieldReferenceIds = content =>
  extractReferenceIds(content, 'field');

export const matchesCatalogSearch = (item, search = '') => {
  const normalizedSearch = normalizeCatalogText(search);

  if (!normalizedSearch) {
    return true;
  }

  return [
    item?.title,
    item?.description,
    item?.original_title,
    item?.original_description,
    item?.group_label,
    item?.group_name,
    item?.id,
  ].some(value => normalizeCatalogText(value).includes(normalizedSearch));
};

export const sortCatalogItems = (items, { groupOrder = [] } = {}) => {
  const groupPriority = new Map(
    groupOrder.map((groupName, index) => [
      normalizeCatalogText(groupName),
      index,
    ])
  );

  return [...items].sort((leftItem, rightItem) => {
    const leftGroupName = normalizeCatalogText(leftItem?.group_name);
    const rightGroupName = normalizeCatalogText(rightItem?.group_name);

    const leftPriority = groupPriority.has(leftGroupName)
      ? groupPriority.get(leftGroupName)
      : Number.MAX_SAFE_INTEGER;
    const rightPriority = groupPriority.has(rightGroupName)
      ? groupPriority.get(rightGroupName)
      : Number.MAX_SAFE_INTEGER;

    if (leftPriority !== rightPriority) {
      return leftPriority - rightPriority;
    }

    const groupComparison = compareCatalogText(
      leftItem?.group_label || leftItem?.group_name,
      rightItem?.group_label || rightItem?.group_name
    );

    if (groupComparison !== 0) {
      return groupComparison;
    }

    return compareCatalogText(leftItem?.title, rightItem?.title);
  });
};

export const filterAndSortCatalogItems = (
  items,
  { search = '', groupOrder = [] } = {}
) =>
  sortCatalogItems(
    (Array.isArray(items) ? items : []).filter(item =>
      matchesCatalogSearch(item, search)
    ),
    { groupOrder }
  );
