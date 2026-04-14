export const SIDEBAR_VISIBILITY_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items';

const item = (key, labelKey, children = []) => ({
  key,
  labelKey,
  children,
});

export const SIDEBAR_VISIBILITY_ITEMS = Object.freeze([
  item('Inbox', 'SIDEBAR.INBOX'),
  item('Conversation', 'SIDEBAR.CONVERSATIONS', [
    item('Conversation:Pending', 'SIDEBAR.PENDING_CONVERSATIONS'),
    item('Conversation:Open', 'SIDEBAR.OPEN_CONVERSATIONS'),
    item('Conversation:Snoozed', 'SIDEBAR.SNOOZED_CONVERSATIONS'),
    item('Conversation:Resolved', 'SIDEBAR.RESOLVED_CONVERSATIONS'),
    item('Conversation:Folders', 'SIDEBAR.CUSTOM_VIEWS_FOLDER'),
    item('Conversation:Teams', 'SIDEBAR.TEAMS'),
    item('Conversation:Channels', 'SIDEBAR.CHANNELS'),
    item('Conversation:Labels', 'SIDEBAR.LABELS'),
  ]),
  item('Campaigns', 'SIDEBAR.CAMPAIGNS', [
    item('Campaigns:MassBroadcasts', 'SIDEBAR.MASS_BROADCASTS'),
    item('Campaigns:PersonalBroadcasts', 'SIDEBAR.PERSONAL_BROADCASTS'),
    item('Campaigns:TouchPlans', 'SIDEBAR.TOUCH_PLANS'),
    item('Campaigns:Templates', 'SIDEBAR.TEMPLATES'),
  ]),
  item('Captain', 'SIDEBAR.CAPTAIN', [
    item('Captain:Settings', 'SIDEBAR.CAPTAIN_SETTINGS'),
    item('Captain:Prompts', 'SIDEBAR.CAPTAIN_PROMPTS'),
    item('Captain:Channels', 'SIDEBAR.CAPTAIN_CHANNELS'),
    item('Captain:Access', 'SIDEBAR.CAPTAIN_ACCESS'),
    item('Captain:Tools', 'SIDEBAR.CAPTAIN_TOOLS'),
    item('Captain:FAQs', 'SIDEBAR.CAPTAIN_RESPONSES'),
    item('Captain:Restrictions', 'SIDEBAR.CAPTAIN_RESTRICTIONS'),
    item('Captain:Documents', 'SIDEBAR.CAPTAIN_DOCUMENTS'),
    item('Captain:Playground', 'SIDEBAR.CAPTAIN_PLAYGROUND'),
  ]),
  item('Contacts', 'SIDEBAR.CONTACTS', [
    item('Contacts:All', 'SIDEBAR.ALL_CONTACTS'),
    item('Contacts:Active', 'SIDEBAR.ACTIVE'),
    item('Contacts:Segments', 'SIDEBAR.CUSTOM_VIEWS_SEGMENTS'),
    item('Contacts:Tagged', 'SIDEBAR.TAGGED_WITH'),
  ]),
  item('Companies', 'SIDEBAR.COMPANIES'),
  item('CRM', 'SIDEBAR.PIPELINES'),
  item('CRM Tasks', 'SIDEBAR.CRM_TASKS'),
  item('Scheduling', 'SIDEBAR.SCHEDULING', [
    item('Scheduling:Calendar', 'SIDEBAR.SCHEDULING_CALENDAR'),
    item('Scheduling:Resources', 'SIDEBAR.SCHEDULING_RESOURCES'),
    item('Scheduling:Services', 'SIDEBAR.SCHEDULING_SERVICES'),
    item('Scheduling:Exceptions', 'SIDEBAR.SCHEDULING_EXCEPTIONS'),
    item('Scheduling:Kassa', 'SIDEBAR.SCHEDULING_KASSA'),
  ]),
  item('Reports', 'SIDEBAR.REPORTS', [
    item('Reports:Overview', 'SIDEBAR.REPORTS_OVERVIEW'),
    item('Reports:Conversation', 'SIDEBAR.REPORTS_CONVERSATION'),
    item('Reports:Agent', 'SIDEBAR.REPORTS_AGENT'),
    item('Reports:Label', 'SIDEBAR.REPORTS_LABEL'),
    item('Reports:Inbox', 'SIDEBAR.REPORTS_INBOX'),
    item('Reports:Team', 'SIDEBAR.REPORTS_TEAM'),
    item('Reports:CSAT', 'SIDEBAR.CSAT'),
    item('Reports:SLA', 'SIDEBAR.REPORTS_SLA'),
    item('Reports:Bot', 'SIDEBAR.REPORTS_BOT'),
  ]),
  item('Portals', 'SIDEBAR.HELP_CENTER.TITLE', [
    item('Portals:Articles', 'SIDEBAR.HELP_CENTER.ARTICLES'),
    item('Portals:Categories', 'SIDEBAR.HELP_CENTER.CATEGORIES'),
    item('Portals:Locales', 'SIDEBAR.HELP_CENTER.LOCALES'),
    item('Portals:Settings', 'SIDEBAR.HELP_CENTER.SETTINGS'),
  ]),
  item('Settings', 'SIDEBAR.SETTINGS', [
    item('Settings:Workspace', 'SIDEBAR.ACCOUNT_SETTINGS'),
    item('Settings:Captain', 'SIDEBAR.CAPTAIN_AI'),
    item('Settings:Agents', 'SIDEBAR.AGENTS'),
    item('Settings:Teams', 'SIDEBAR.TEAMS'),
    item('Settings:AgentAssignment', 'SIDEBAR.AGENT_ASSIGNMENT'),
    item('Settings:Inboxes', 'SIDEBAR.INBOXES'),
    item('Settings:CRM', 'SIDEBAR.CRM'),
    item('Settings:CRMTasks', 'SIDEBAR.CRM_TASK_SETTINGS'),
    item('Settings:Labels', 'SIDEBAR.LABELS'),
    item('Settings:CustomAttributes', 'SIDEBAR.CUSTOM_ATTRIBUTES'),
    item('Settings:Automation', 'SIDEBAR.AUTOMATION'),
    item('Settings:AgentBots', 'SIDEBAR.AGENT_BOTS'),
    item('Settings:Macros', 'SIDEBAR.MACROS'),
    item('Settings:Integrations', 'SIDEBAR.INTEGRATIONS'),
    item('Settings:AuditLogs', 'SIDEBAR.AUDIT_LOGS'),
    item('Settings:CustomRoles', 'SIDEBAR.CUSTOM_ROLES'),
    item('Settings:Sla', 'SIDEBAR.SLA'),
    item('Settings:ConversationWorkflow', 'SIDEBAR.CONVERSATION_WORKFLOW'),
    item('Settings:Billing', 'SIDEBAR.BILLING'),
  ]),
]);

const flattenSidebarVisibilityItems = items =>
  items.flatMap(({ key, children = [] }) => [
    key,
    ...flattenSidebarVisibilityItems(children),
  ]);

const SIDEBAR_VISIBILITY_ITEM_KEYS = flattenSidebarVisibilityItems(
  SIDEBAR_VISIBILITY_ITEMS
);

const getItemKey = sidebarItem =>
  sidebarItem?.visibilityKey || sidebarItem?.name;

export const normalizeSidebarHiddenItems = hiddenItems => {
  const hiddenItemsSet = new Set(Array.isArray(hiddenItems) ? hiddenItems : []);

  return SIDEBAR_VISIBILITY_ITEM_KEYS.filter(key => hiddenItemsSet.has(key));
};

export const getSidebarHiddenItems = uiSettings =>
  normalizeSidebarHiddenItems(uiSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]);

export const buildSidebarVisibilityState = uiSettings => {
  const hiddenItems = new Set(getSidebarHiddenItems(uiSettings));

  return SIDEBAR_VISIBILITY_ITEM_KEYS.reduce((visibility, key) => {
    visibility[key] = !hiddenItems.has(key);
    return visibility;
  }, {});
};

export const getSidebarHiddenItemsFromState = state =>
  SIDEBAR_VISIBILITY_ITEM_KEYS.filter(key => state?.[key] === false);

export const filterSidebarMenuItems = (menuItems, uiSettings) => {
  const hiddenItems = new Set(getSidebarHiddenItems(uiSettings));

  const filterItems = items =>
    items.flatMap(sidebarItem => {
      if (hiddenItems.has(getItemKey(sidebarItem))) {
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

  return filterItems(menuItems);
};
