export const SIDEBAR_VISIBILITY_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items';

export const SIDEBAR_VISIBILITY_ITEMS = Object.freeze([
  { name: 'Inbox', labelKey: 'SIDEBAR.INBOX' },
  { name: 'Conversation', labelKey: 'SIDEBAR.CONVERSATIONS' },
  { name: 'Captain', labelKey: 'SIDEBAR.CAPTAIN' },
  { name: 'Contacts', labelKey: 'SIDEBAR.CONTACTS' },
  { name: 'Companies', labelKey: 'SIDEBAR.COMPANIES' },
  { name: 'CRM', labelKey: 'SIDEBAR.PIPELINES' },
  { name: 'CRM Tasks', labelKey: 'SIDEBAR.CRM_TASKS' },
  { name: 'Scheduling', labelKey: 'SIDEBAR.SCHEDULING' },
  { name: 'Reports', labelKey: 'SIDEBAR.REPORTS' },
  { name: 'Campaigns', labelKey: 'SIDEBAR.CAMPAIGNS' },
  { name: 'Portals', labelKey: 'SIDEBAR.HELP_CENTER.TITLE' },
  { name: 'Settings', labelKey: 'SIDEBAR.SETTINGS' },
]);

const SIDEBAR_VISIBILITY_ITEM_NAMES = SIDEBAR_VISIBILITY_ITEMS.map(
  ({ name }) => name
);

export const normalizeSidebarHiddenItems = hiddenItems => {
  const hiddenItemsSet = new Set(Array.isArray(hiddenItems) ? hiddenItems : []);

  return SIDEBAR_VISIBILITY_ITEM_NAMES.filter(name => hiddenItemsSet.has(name));
};

export const getSidebarHiddenItems = uiSettings =>
  normalizeSidebarHiddenItems(uiSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]);

export const buildSidebarVisibilityState = uiSettings => {
  const hiddenItems = new Set(getSidebarHiddenItems(uiSettings));

  return SIDEBAR_VISIBILITY_ITEM_NAMES.reduce((visibility, itemName) => {
    visibility[itemName] = !hiddenItems.has(itemName);
    return visibility;
  }, {});
};

export const getSidebarHiddenItemsFromState = state =>
  SIDEBAR_VISIBILITY_ITEM_NAMES.filter(itemName => state?.[itemName] === false);

export const filterSidebarMenuItems = (menuItems, uiSettings) => {
  const hiddenItems = new Set(getSidebarHiddenItems(uiSettings));

  return menuItems.filter(item => !hiddenItems.has(item.name));
};
