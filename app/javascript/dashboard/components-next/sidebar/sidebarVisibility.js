export const SIDEBAR_VISIBILITY_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items';
export const SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items_version';
export const SIDEBAR_ORDER_UI_SETTINGS_KEY = 'dashboard_sidebar_item_order';
export const SIDEBAR_VISIBILITY_CURRENT_VERSION = 19;

const CAPTAIN_PROMPTS_VISIBILITY_KEY = 'Captain:Prompts';
const LEGACY_CAPTAIN_RESTRICTIONS_VISIBILITY_KEY = 'Captain:Restrictions';
const TOUCHES_VISIBILITY_KEY = 'Campaigns:Touches';
const LEGACY_EMPLOYEES_VISIBILITY_KEY = 'Employees';
const MY_COMPANY_VISIBILITY_KEY = 'MyCompany';
const MY_COMPANY_VISIBILITY_ITEM_KEYS = Object.freeze([
  'MyCompany:Workspace',
  'MyCompany:ConversationClosure',
  'MyCompany:SLA',
  'MyCompany:AdditionalFields',
  'MyCompany:LeadForms',
  'MyCompany:Channels',
  'MyCompany:Tags',
  'MyCompany:Employees',
  'MyCompany:Teams',
  'MyCompany:Roles',
  'MyCompany:Policies',
  'MyCompany:AuditLogs',
]);
const MY_COMPANY_EMPLOYEES_VISIBILITY_KEY = 'MyCompany:Employees';
const CONVERSATION_STATUSES_VISIBILITY_KEY = 'Conversation:Statuses';
export const CONVERSATION_ASSIGNEE_VISIBILITY_KEY = 'Conversation:Assignee';
const CONVERSATION_ASSIGNEE_ITEM_KEYS = new Set([
  'Conversation:Assignee:all',
  'Conversation:Assignee:me',
  'Conversation:Assignee:unassigned',
]);
export const CONVERSATION_PIPELINES_VISIBILITY_KEY = 'Conversation:Pipelines';
export const CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY =
  'Conversation:AppointmentStatuses';
export const CONVERSATION_ORGANIZATION_VISIBILITY_KEY =
  'Conversation:Organization';
export const CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS = Object.freeze({
  scheduled: 'Conversation:AppointmentStatus:scheduled',
  confirmed: 'Conversation:AppointmentStatus:confirmed',
  completed: 'Conversation:AppointmentStatus:completed',
  cancelled: 'Conversation:AppointmentStatus:cancelled',
  no_show: 'Conversation:AppointmentStatus:no_show',
});
const LEGACY_CONVERSATION_DEFAULT_PIPELINE_VISIBILITY_KEY =
  'Conversation:DefaultPipeline';
const REPORTS_DEALS_VISIBILITY_KEY = 'Reports:Deals';
const LEGACY_REPORTS_FUNNELS_VISIBILITY_KEY = 'Reports:Funnels';
// Saved profile UI settings may still contain this pre-touch sidebar key.
const LEGACY_PERSONAL_BROADCASTS_VISIBILITY_KEY =
  'Campaigns:PersonalBroadcasts';
const MY_COMPANY_LEAD_FORMS_VISIBILITY_KEY = 'MyCompany:LeadForms';
const LEGACY_SMM_LEAD_FORMS_VISIBILITY_KEY = 'SMM:LeadForms';
const LEGACY_SETTINGS_LEAD_FORMS_VISIBILITY_KEY = 'Settings:LeadForms';

const item = (key, labelKey, children = [], configurable = true) => ({
  key,
  labelKey,
  ...(children.length ? { children } : {}),
  configurable,
});

export const CONVERSATION_SIDEBAR_VISIBILITY_ITEMS = Object.freeze([
  item(
    CONVERSATION_ASSIGNEE_VISIBILITY_KEY,
    'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ASSIGNEE'
  ),
  item('Conversation:Assignee:all', 'CHAT_LIST.ASSIGNEE_TYPE_TABS.all'),
  item('Conversation:Assignee:me', 'CHAT_LIST.ASSIGNEE_TYPE_TABS.me'),
  item(
    'Conversation:Assignee:unassigned',
    'CHAT_LIST.ASSIGNEE_TYPE_TABS.unassigned'
  ),
  item(
    CONVERSATION_PIPELINES_VISIBILITY_KEY,
    'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
  ),
  item(
    CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
    'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENTS'
  ),
  item(
    CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.scheduled,
    'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.SCHEDULED'
  ),
  item(
    CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.confirmed,
    'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.CONFIRMED'
  ),
  item(
    CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.completed,
    'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.COMPLETED'
  ),
  item(
    CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.cancelled,
    'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.CANCELLED'
  ),
  item(
    CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.no_show,
    'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.NO_SHOW'
  ),
  item(
    CONVERSATION_ORGANIZATION_VISIBILITY_KEY,
    'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ORGANIZATION'
  ),
  item('Conversation:Folders', 'SIDEBAR.CUSTOM_VIEWS_FOLDER'),
  item('Conversation:Teams', 'SIDEBAR.TEAMS'),
  item('Conversation:Labels', 'SIDEBAR.LABELS'),
]);

export const SIDEBAR_VISIBILITY_ITEMS = Object.freeze([
  item('Inbox', 'SIDEBAR.INBOX'),
  item(
    'Conversation',
    'SIDEBAR.CONVERSATIONS',
    CONVERSATION_SIDEBAR_VISIBILITY_ITEMS
  ),
  item('Campaigns:MassBroadcasts', 'SIDEBAR.MASS_BROADCASTS'),
  item('Captain', 'SIDEBAR.CAPTAIN'),
  item('Contacts', 'SIDEBAR.CONTACTS'),
  item('Companies', 'SIDEBAR.COMPANIES'),
  item('CRM', 'SIDEBAR.PIPELINES'),
  item('CRM Tasks', 'SIDEBAR.CRM_TASKS'),
  item('Scheduling', 'SIDEBAR.SCHEDULING'),
  item('Reports', 'SIDEBAR.REPORTS'),
  item('Portals', 'SIDEBAR.HELP_CENTER.TITLE'),
  item('Settings', 'SIDEBAR.ADDITIONAL', [], false),
]);

const DEFAULT_SIDEBAR_ITEM_ORDER = Object.freeze(
  SIDEBAR_VISIBILITY_ITEMS.map(sidebarItem => sidebarItem.key)
);

export const normalizeSidebarItemOrder = order => {
  const supportedKeys = new Set(DEFAULT_SIDEBAR_ITEM_ORDER);
  const normalizedOrder = [];

  (Array.isArray(order) ? order : []).forEach(key => {
    if (supportedKeys.has(key) && !normalizedOrder.includes(key)) {
      normalizedOrder.push(key);
    }
  });

  DEFAULT_SIDEBAR_ITEM_ORDER.forEach(key => {
    if (!normalizedOrder.includes(key)) normalizedOrder.push(key);
  });

  return normalizedOrder;
};

export const getSidebarItemOrder = uiSettings =>
  normalizeSidebarItemOrder(uiSettings?.[SIDEBAR_ORDER_UI_SETTINGS_KEY]);

const flattenSidebarVisibilityItems = items =>
  items.flatMap(({ key, children = [], configurable = true }) => [
    ...(configurable ? [key] : []),
    ...flattenSidebarVisibilityItems(children),
  ]);

const SIDEBAR_VISIBILITY_ITEM_KEYS = flattenSidebarVisibilityItems(
  SIDEBAR_VISIBILITY_ITEMS
);

const getItemKey = sidebarItem =>
  sidebarItem?.visibilityKey || sidebarItem?.name;

const conversationParentVisibilityKey = itemKey => {
  if (itemKey?.startsWith('Conversation:Assignee:')) {
    return CONVERSATION_ASSIGNEE_VISIBILITY_KEY;
  }

  return null;
};

const toHiddenItemsSet = hiddenItems => {
  if (hiddenItems instanceof Set) {
    return new Set(hiddenItems);
  }

  return new Set(Array.isArray(hiddenItems) ? hiddenItems : []);
};

export const normalizeSidebarHiddenItems = hiddenItems => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);

  return SIDEBAR_VISIBILITY_ITEM_KEYS.filter(key => hiddenItemsSet.has(key));
};

const normalizeLegacyCaptainPromptsVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateLegacyVisibility = Number(version || 0) < 2;

  if (!shouldMigrateLegacyVisibility) {
    return hiddenItemsSet;
  }

  const promptsWasHidden = hiddenItemsSet.has(CAPTAIN_PROMPTS_VISIBILITY_KEY);
  const restrictionsWasHidden = hiddenItemsSet.has(
    LEGACY_CAPTAIN_RESTRICTIONS_VISIBILITY_KEY
  );

  hiddenItemsSet.delete(CAPTAIN_PROMPTS_VISIBILITY_KEY);
  hiddenItemsSet.delete(LEGACY_CAPTAIN_RESTRICTIONS_VISIBILITY_KEY);

  if (promptsWasHidden && restrictionsWasHidden) {
    hiddenItemsSet.add(CAPTAIN_PROMPTS_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeLegacyTouchesVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateLegacyVisibility = Number(version || 0) < 3;

  if (!shouldMigrateLegacyVisibility) {
    return hiddenItemsSet;
  }

  const legacyPersonalBroadcastsWasHidden = hiddenItemsSet.has(
    LEGACY_PERSONAL_BROADCASTS_VISIBILITY_KEY
  );
  const touchesWasHidden = hiddenItemsSet.has(TOUCHES_VISIBILITY_KEY);

  hiddenItemsSet.delete(LEGACY_PERSONAL_BROADCASTS_VISIBILITY_KEY);

  if (legacyPersonalBroadcastsWasHidden || touchesWasHidden) {
    hiddenItemsSet.add(TOUCHES_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeLegacyMyCompanyVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateLegacyVisibility = Number(version || 0) < 6;

  if (!shouldMigrateLegacyVisibility) {
    return hiddenItemsSet;
  }

  const employeesWasHidden = hiddenItemsSet.has(
    LEGACY_EMPLOYEES_VISIBILITY_KEY
  );
  hiddenItemsSet.delete(LEGACY_EMPLOYEES_VISIBILITY_KEY);

  if (employeesWasHidden) {
    hiddenItemsSet.add(MY_COMPANY_EMPLOYEES_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeRemovedMyCompanyGroupVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateRemovedGroup = Number(version || 0) < 11;

  if (!shouldMigrateRemovedGroup) {
    return hiddenItemsSet;
  }

  const groupWasHidden = hiddenItemsSet.has(MY_COMPANY_VISIBILITY_KEY);
  hiddenItemsSet.delete(MY_COMPANY_VISIBILITY_KEY);

  if (groupWasHidden) {
    MY_COMPANY_VISIBILITY_ITEM_KEYS.forEach(key => hiddenItemsSet.add(key));
  }

  return hiddenItemsSet;
};

const normalizeDefaultConversationStatusVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldApplyDefaultVisibility = Number(version || 0) < 8;

  if (shouldApplyDefaultVisibility) {
    hiddenItemsSet.add(CONVERSATION_STATUSES_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeLegacyConversationPipelinesVisibility = (
  hiddenItems,
  version
) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateLegacyVisibility = Number(version || 0) < 9;

  if (!shouldMigrateLegacyVisibility) {
    return hiddenItemsSet;
  }

  const defaultPipelineWasHidden = hiddenItemsSet.has(
    LEGACY_CONVERSATION_DEFAULT_PIPELINE_VISIBILITY_KEY
  );
  hiddenItemsSet.delete(LEGACY_CONVERSATION_DEFAULT_PIPELINE_VISIBILITY_KEY);

  if (defaultPipelineWasHidden) {
    hiddenItemsSet.add(CONVERSATION_PIPELINES_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeLegacyReportsDealsVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateLegacyVisibility = Number(version || 0) < 10;

  if (!shouldMigrateLegacyVisibility) {
    return hiddenItemsSet;
  }

  const legacyFunnelsWasHidden = hiddenItemsSet.has(
    LEGACY_REPORTS_FUNNELS_VISIBILITY_KEY
  );
  hiddenItemsSet.delete(LEGACY_REPORTS_FUNNELS_VISIBILITY_KEY);

  if (legacyFunnelsWasHidden) {
    hiddenItemsSet.add(REPORTS_DEALS_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeLegacyLeadFormsVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  const shouldMigrateLegacyVisibility = Number(version || 0) < 16;

  if (!shouldMigrateLegacyVisibility) {
    return hiddenItemsSet;
  }

  const legacyLeadFormsWasHidden =
    hiddenItemsSet.has(LEGACY_SETTINGS_LEAD_FORMS_VISIBILITY_KEY) ||
    hiddenItemsSet.has(LEGACY_SMM_LEAD_FORMS_VISIBILITY_KEY);
  hiddenItemsSet.delete(LEGACY_SETTINGS_LEAD_FORMS_VISIBILITY_KEY);
  hiddenItemsSet.delete(LEGACY_SMM_LEAD_FORMS_VISIBILITY_KEY);

  if (legacyLeadFormsWasHidden) {
    hiddenItemsSet.add(MY_COMPANY_LEAD_FORMS_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeMainMenuVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  if (Number(version || 0) >= 17) return hiddenItemsSet;

  const broadcastsWereHidden =
    hiddenItemsSet.has('Campaigns') ||
    hiddenItemsSet.has(TOUCHES_VISIBILITY_KEY) ||
    hiddenItemsSet.has(LEGACY_PERSONAL_BROADCASTS_VISIBILITY_KEY) ||
    hiddenItemsSet.has('Campaigns:MassBroadcasts');

  hiddenItemsSet.delete('Campaigns');
  hiddenItemsSet.delete(TOUCHES_VISIBILITY_KEY);
  hiddenItemsSet.delete(LEGACY_PERSONAL_BROADCASTS_VISIBILITY_KEY);
  if (broadcastsWereHidden) {
    hiddenItemsSet.add('Campaigns:MassBroadcasts');
  }

  return hiddenItemsSet;
};

export const getSidebarHiddenItems = uiSettings => {
  const version = uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY];
  let hiddenItems = uiSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY];

  hiddenItems = normalizeLegacyCaptainPromptsVisibility(hiddenItems, version);
  hiddenItems = normalizeLegacyTouchesVisibility(hiddenItems, version);
  hiddenItems = normalizeLegacyMyCompanyVisibility(hiddenItems, version);
  hiddenItems = normalizeDefaultConversationStatusVisibility(
    hiddenItems,
    version
  );
  hiddenItems = normalizeLegacyConversationPipelinesVisibility(
    hiddenItems,
    version
  );
  hiddenItems = normalizeLegacyReportsDealsVisibility(hiddenItems, version);
  hiddenItems = normalizeRemovedMyCompanyGroupVisibility(hiddenItems, version);
  hiddenItems = normalizeLegacyLeadFormsVisibility(hiddenItems, version);
  hiddenItems = normalizeMainMenuVisibility(hiddenItems, version);

  return normalizeSidebarHiddenItems(Array.from(hiddenItems));
};

export const buildEffectiveSidebarVisibilitySettings = ({
  accountSettings,
}) => ({
  ...(accountSettings || {}),
  [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: getSidebarHiddenItems(
    accountSettings || {}
  ),
  [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
    SIDEBAR_VISIBILITY_CURRENT_VERSION,
});

const normalizeConversationAssigneeHiddenItems = hiddenItems => {
  const normalizedHiddenItems = new Set(hiddenItems);

  if (normalizedHiddenItems.has(CONVERSATION_ASSIGNEE_VISIBILITY_KEY)) {
    normalizedHiddenItems.delete('Conversation:Assignee:all');
    normalizedHiddenItems.add('Conversation:Assignee:me');
    normalizedHiddenItems.add('Conversation:Assignee:unassigned');
  } else {
    CONVERSATION_ASSIGNEE_ITEM_KEYS.forEach(key => {
      normalizedHiddenItems.delete(key);
    });
  }

  return normalizedHiddenItems;
};

export const buildSidebarVisibilityState = uiSettings => {
  const hiddenItems = normalizeConversationAssigneeHiddenItems(
    getSidebarHiddenItems(uiSettings)
  );

  return SIDEBAR_VISIBILITY_ITEM_KEYS.reduce((visibility, key) => {
    visibility[key] = !hiddenItems.has(key);
    return visibility;
  }, {});
};

const conversationVisibilityItemKeys = new Set(
  CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.map(
    visibilityItem => visibilityItem.key
  )
);

const normalizeConversationSidebarHiddenItems = hiddenItems => {
  const normalizedHiddenItems =
    normalizeConversationAssigneeHiddenItems(hiddenItems);
  normalizedHiddenItems.delete(CONVERSATION_ORGANIZATION_VISIBILITY_KEY);

  return CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.map(
    visibilityItem => visibilityItem.key
  ).filter(key => normalizedHiddenItems.has(key));
};

export const getConversationSidebarHiddenItems = uiSettings =>
  normalizeConversationSidebarHiddenItems(
    getSidebarHiddenItems(uiSettings).filter(key =>
      conversationVisibilityItemKeys.has(key)
    )
  );

export const getSidebarHiddenItemsFromState = state =>
  SIDEBAR_VISIBILITY_ITEM_KEYS.filter(key => state?.[key] === false);

export const getConversationSidebarHiddenItemsFromState = state =>
  normalizeConversationSidebarHiddenItems(
    getSidebarHiddenItemsFromState(state).filter(key =>
      conversationVisibilityItemKeys.has(key)
    )
  );

export const isConversationAssigneeSelectionLocked = uiSettings =>
  getSidebarHiddenItems(uiSettings).includes(
    CONVERSATION_ASSIGNEE_VISIBILITY_KEY
  );

export const filterSidebarMenuItems = (menuItems, uiSettings) => {
  const hiddenItems = new Set(getSidebarHiddenItems(uiSettings));

  const filterItems = items =>
    items.flatMap(sidebarItem => {
      const itemKey = getItemKey(sidebarItem);
      const parentVisibilityKey = conversationParentVisibilityKey(itemKey);
      const isAssigneeItem = CONVERSATION_ASSIGNEE_ITEM_KEYS.has(itemKey);
      const isAssigneeLocked = hiddenItems.has(
        CONVERSATION_ASSIGNEE_VISIBILITY_KEY
      );
      if (
        isAssigneeItem
          ? isAssigneeLocked && itemKey !== 'Conversation:Assignee:all'
          : hiddenItems.has(itemKey) ||
            (parentVisibilityKey && hiddenItems.has(parentVisibilityKey))
      ) {
        return [];
      }

      if (!Array.isArray(sidebarItem.children)) {
        return [sidebarItem];
      }

      const children = filterItems(sidebarItem.children);
      if (!children.length && !sidebarItem.to) {
        return [];
      }

      return [{ ...sidebarItem, children }];
    });

  const itemOrder = new Map(
    getSidebarItemOrder(uiSettings).map((itemKey, index) => [itemKey, index])
  );

  return filterItems(menuItems).sort((firstItem, secondItem) => {
    const firstPosition = itemOrder.get(getItemKey(firstItem));
    const secondPosition = itemOrder.get(getItemKey(secondItem));

    if (
      typeof firstPosition === 'undefined' &&
      typeof secondPosition === 'undefined'
    ) {
      return 0;
    }
    if (typeof firstPosition === 'undefined') return 1;
    if (typeof secondPosition === 'undefined') return -1;
    return firstPosition - secondPosition;
  });
};
