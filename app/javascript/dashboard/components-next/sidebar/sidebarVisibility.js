// Company-wide left sidebar navigation.
//
// Administrators configure which primary sections are shown and in which
// order (Settings > Company > Navigation) and which lists are shown inside
// Conversations (Settings > Conversations > Conversation navigation). Both are
// stored in the account settings and apply to every employee of the account.
// Personal per-user sidebar settings are no longer read.
export const SIDEBAR_VISIBILITY_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items';
export const SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items_version';
export const SIDEBAR_ORDER_UI_SETTINGS_KEY = 'dashboard_sidebar_item_order';
// Version 21: the conversation status group left the sidebar (the status is
// picked in the list header) and the outbound group became the single
// administrator item «Рассылки» (Campaigns:MassBroadcasts).
export const SIDEBAR_VISIBILITY_CURRENT_VERSION = 21;

export const CONVERSATION_ASSIGNEE_VISIBILITY_KEY = 'Conversation:Assignee';
const CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY = 'Conversation:Assignee:all';
const CONVERSATION_ASSIGNEE_ME_VISIBILITY_KEY = 'Conversation:Assignee:me';
const CONVERSATION_ASSIGNEE_UNASSIGNED_VISIBILITY_KEY =
  'Conversation:Assignee:unassigned';
const CONVERSATION_ASSIGNEE_ITEM_KEYS = new Set([
  CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY,
  CONVERSATION_ASSIGNEE_ME_VISIBILITY_KEY,
  CONVERSATION_ASSIGNEE_UNASSIGNED_VISIBILITY_KEY,
]);
export const CONVERSATION_PIPELINES_VISIBILITY_KEY = 'Conversation:Pipelines';
// Section key grouping Folders, Teams and Tags; it is never hidden itself.
export const CONVERSATION_ORGANIZATION_VISIBILITY_KEY =
  'Conversation:Organization';
export const CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY =
  'Conversation:AppointmentStatuses';
export const CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS = Object.freeze({
  scheduled: 'Conversation:AppointmentStatus:scheduled',
  confirmed: 'Conversation:AppointmentStatus:confirmed',
  completed: 'Conversation:AppointmentStatus:completed',
  cancelled: 'Conversation:AppointmentStatus:cancelled',
  no_show: 'Conversation:AppointmentStatus:no_show',
});
const LEGACY_CONVERSATION_DEFAULT_PIPELINE_VISIBILITY_KEY =
  'Conversation:DefaultPipeline';
export const MASS_BROADCASTS_VISIBILITY_KEY = 'Campaigns:MassBroadcasts';
// Saved settings before version 21 may still name the removed outbound group
// («Исходящие») or its old children.
const LEGACY_OUTBOUND_VISIBILITY_KEYS = Object.freeze([
  'Campaigns',
  'Campaigns:Touches',
  'Campaigns:PersonalBroadcasts',
]);
// Notifications keep a product-defined first position and cannot be hidden.
const PINNED_FIRST_ITEM_KEY = 'Inbox';

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
  item(
    CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY,
    'CHAT_LIST.ASSIGNEE_TYPE_TABS.all'
  ),
  item(
    CONVERSATION_ASSIGNEE_ME_VISIBILITY_KEY,
    'CHAT_LIST.ASSIGNEE_TYPE_TABS.me'
  ),
  item(
    CONVERSATION_ASSIGNEE_UNASSIGNED_VISIBILITY_KEY,
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

// Primary sidebar sections in their default order. Settings stays visible so
// administrators can always reach the navigation settings again.
export const SIDEBAR_VISIBILITY_ITEMS = Object.freeze([
  item(
    'Conversation',
    'SIDEBAR.CONVERSATIONS',
    CONVERSATION_SIDEBAR_VISIBILITY_ITEMS
  ),
  item(MASS_BROADCASTS_VISIBILITY_KEY, 'SIDEBAR.MASS_BROADCASTS'),
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

// A saved order keeps «Рассылки» where the old outbound group («Исходящие»)
// used to be.
const migrateLegacySidebarOrderKey = key =>
  LEGACY_OUTBOUND_VISIBILITY_KEYS.includes(key)
    ? MASS_BROADCASTS_VISIBILITY_KEY
    : key;

export const normalizeSidebarItemOrder = order => {
  const supportedKeys = new Set(DEFAULT_SIDEBAR_ITEM_ORDER);
  const normalizedOrder = [];

  (Array.isArray(order) ? order : []).forEach(savedKey => {
    const key = migrateLegacySidebarOrderKey(savedKey);
    if (supportedKeys.has(key) && !normalizedOrder.includes(key)) {
      normalizedOrder.push(key);
    }
  });

  DEFAULT_SIDEBAR_ITEM_ORDER.forEach(key => {
    if (!normalizedOrder.includes(key)) normalizedOrder.push(key);
  });

  return normalizedOrder;
};

export const getSidebarItemOrder = settings =>
  normalizeSidebarItemOrder(settings?.[SIDEBAR_ORDER_UI_SETTINGS_KEY]);

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

// Before version 21 the outbound group («Исходящие», key Campaigns) held
// «Рассылки»; older settings may still name its former children. Hiding any
// of them keeps «Рассылки» hidden. The removed status group keys
// (Conversation:Statuses, Conversation:Open...) are simply dropped by
// normalizeSidebarHiddenItems.
const normalizeLegacyOutboundVisibility = (hiddenItems, version) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  if (Number(version || 0) >= 21) return hiddenItemsSet;

  const outboundWasHidden = LEGACY_OUTBOUND_VISIBILITY_KEYS.some(key =>
    hiddenItemsSet.has(key)
  );
  LEGACY_OUTBOUND_VISIBILITY_KEYS.forEach(key => hiddenItemsSet.delete(key));

  if (outboundWasHidden) {
    hiddenItemsSet.add(MASS_BROADCASTS_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

const normalizeLegacyConversationPipelinesVisibility = (
  hiddenItems,
  version
) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  if (Number(version || 0) >= 9) return hiddenItemsSet;

  const defaultPipelineWasHidden = hiddenItemsSet.has(
    LEGACY_CONVERSATION_DEFAULT_PIPELINE_VISIBILITY_KEY
  );
  hiddenItemsSet.delete(LEGACY_CONVERSATION_DEFAULT_PIPELINE_VISIBILITY_KEY);

  if (defaultPipelineWasHidden) {
    hiddenItemsSet.add(CONVERSATION_PIPELINES_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

// All, Mine and Unassigned can be hidden one by one (the old company
// Visibility page saved them like that, and the per-list switches keep doing
// so); those hides are honoured exactly. The group switch
// (Conversation:Assignee) additionally locks the list to All.
//
// Before version 20, an account that hid exactly Mine and Unassigned showed
// only All; it becomes the locked group, which shows the same navigation.
// Any other legacy combination stays as the per-list hides it was saved as.
const normalizeLegacyConversationAssigneeVisibility = (
  hiddenItems,
  version
) => {
  const hiddenItemsSet = toHiddenItemsSet(hiddenItems);
  if (Number(version || 0) >= 20) return hiddenItemsSet;

  if (
    hiddenItemsSet.has(CONVERSATION_ASSIGNEE_ME_VISIBILITY_KEY) &&
    hiddenItemsSet.has(CONVERSATION_ASSIGNEE_UNASSIGNED_VISIBILITY_KEY) &&
    !hiddenItemsSet.has(CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY)
  ) {
    hiddenItemsSet.add(CONVERSATION_ASSIGNEE_VISIBILITY_KEY);
  }

  return hiddenItemsSet;
};

export const getSidebarHiddenItems = settings => {
  const version = settings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY];
  let hiddenItems = settings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY];

  hiddenItems = normalizeLegacyConversationPipelinesVisibility(
    hiddenItems,
    version
  );
  hiddenItems = normalizeLegacyConversationAssigneeVisibility(
    hiddenItems,
    version
  );
  hiddenItems = normalizeLegacyOutboundVisibility(hiddenItems, version);
  hiddenItems.delete(CONVERSATION_ORGANIZATION_VISIBILITY_KEY);

  return normalizeSidebarHiddenItems(Array.from(hiddenItems));
};

// Callers may still pass { accountId, uiSettings }; only the account settings
// decide the navigation now.
export const buildEffectiveSidebarVisibilitySettings = ({
  accountSettings,
} = {}) => ({
  ...(accountSettings || {}),
  [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: getSidebarHiddenItems(
    accountSettings || {}
  ),
  [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
    SIDEBAR_VISIBILITY_CURRENT_VERSION,
});

// The locked group always shows All and hides Mine and Unassigned; without
// the lock, each list keeps its own saved visibility.
const normalizeConversationAssigneeHiddenItems = hiddenItems => {
  const normalizedHiddenItems = new Set(hiddenItems);

  if (normalizedHiddenItems.has(CONVERSATION_ASSIGNEE_VISIBILITY_KEY)) {
    normalizedHiddenItems.delete(CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY);
    normalizedHiddenItems.add(CONVERSATION_ASSIGNEE_ME_VISIBILITY_KEY);
    normalizedHiddenItems.add(CONVERSATION_ASSIGNEE_UNASSIGNED_VISIBILITY_KEY);
  }

  return normalizedHiddenItems;
};

export const buildSidebarVisibilityState = settings => {
  const hiddenItems = normalizeConversationAssigneeHiddenItems(
    getSidebarHiddenItems(settings)
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

export const getConversationSidebarHiddenItems = settings =>
  normalizeConversationSidebarHiddenItems(
    getSidebarHiddenItems(settings).filter(key =>
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

export const isConversationAssigneeSelectionLocked = settings =>
  getSidebarHiddenItems(settings).includes(
    CONVERSATION_ASSIGNEE_VISIBILITY_KEY
  );

export const filterSidebarMenuItems = (menuItems, settings) => {
  const hiddenItems = new Set(getSidebarHiddenItems(settings));
  const isAssigneeLocked = hiddenItems.has(
    CONVERSATION_ASSIGNEE_VISIBILITY_KEY
  );

  const isHidden = itemKey => {
    if (CONVERSATION_ASSIGNEE_ITEM_KEYS.has(itemKey) && isAssigneeLocked) {
      return itemKey !== CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY;
    }

    return hiddenItems.has(itemKey);
  };

  const filterItems = items =>
    items.flatMap(sidebarItem => {
      if (isHidden(getItemKey(sidebarItem))) {
        return [];
      }

      if (!Array.isArray(sidebarItem.children)) {
        return [sidebarItem];
      }

      let children = filterItems(sidebarItem.children);
      // Hiding every conversation list must not remove the whole «Диалоги»
      // section: fall back to «Все» (aset/dev keeps «Все» as the base list).
      if (!children.length && getItemKey(sidebarItem) === 'Conversation') {
        children = sidebarItem.children.filter(
          child =>
            getItemKey(child) === CONVERSATION_ASSIGNEE_ALL_VISIBILITY_KEY
        );
      }
      if (!children.length && !sidebarItem.to) {
        return [];
      }

      return [{ ...sidebarItem, children }];
    });

  const itemOrder = new Map(
    getSidebarItemOrder(settings).map((itemKey, index) => [itemKey, index])
  );

  return filterItems(menuItems).sort((firstItem, secondItem) => {
    const firstKey = getItemKey(firstItem);
    const secondKey = getItemKey(secondItem);

    if (firstKey === secondKey) return 0;
    if (firstKey === PINNED_FIRST_ITEM_KEY) return -1;
    if (secondKey === PINNED_FIRST_ITEM_KEY) return 1;

    const firstPosition = itemOrder.get(firstKey);
    const secondPosition = itemOrder.get(secondKey);

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
