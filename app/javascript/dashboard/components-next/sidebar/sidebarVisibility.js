export const SIDEBAR_VISIBILITY_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items';
export const SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items_version';
export const SIDEBAR_VISIBILITY_CURRENT_VERSION = 6;

const CAPTAIN_PROMPTS_VISIBILITY_KEY = 'Captain:Prompts';
const LEGACY_CAPTAIN_RESTRICTIONS_VISIBILITY_KEY = 'Captain:Restrictions';
const TOUCHES_VISIBILITY_KEY = 'Campaigns:Touches';
const LEGACY_EMPLOYEES_VISIBILITY_KEY = 'Employees';
const MY_COMPANY_EMPLOYEES_VISIBILITY_KEY = 'MyCompany:Employees';
// Saved profile UI settings may still contain this pre-touch sidebar key.
const LEGACY_PERSONAL_BROADCASTS_VISIBILITY_KEY =
  'Campaigns:PersonalBroadcasts';

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
    item('Conversation:AllChannels', 'SIDEBAR.ALL_CHANNELS'),
    item('Conversation:Labels', 'SIDEBAR.LABELS'),
  ]),
  item('Campaigns', 'SIDEBAR.OUTBOUND', [
    item('Campaigns:Templates', 'SIDEBAR.TEMPLATES'),
    item(TOUCHES_VISIBILITY_KEY, 'SIDEBAR.TOUCHES'),
    item('Campaigns:TouchPlans', 'SIDEBAR.TOUCH_PLANS'),
    item('Campaigns:MassBroadcasts', 'SIDEBAR.MASS_BROADCASTS'),
  ]),
  item('Captain', 'SIDEBAR.CAPTAIN', [
    item('Captain:Settings', 'PROFILE_SETTINGS.FORM.PROFILE_SECTION.TITLE'),
    item('Captain:Prompts', 'SIDEBAR.CAPTAIN_PROMPTS'),
    item('Captain:Channels', 'SIDEBAR.CAPTAIN_CHANNELS'),
    item('Captain:Tools', 'SIDEBAR.CAPTAIN_TOOLS'),
    item('Captain:Observability', 'SIDEBAR.CAPTAIN_OBSERVABILITY'),
    item('Captain:Evaluations', 'SIDEBAR.CAPTAIN_EVALUATIONS'),
    item('Captain:FAQs', 'SIDEBAR.CAPTAIN_RESPONSES'),
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
  item('SMM', 'SIDEBAR.SMM', [
    item('SMM:Calendar', 'SIDEBAR.SMM_CALENDAR'),
    item('SMM:Posts', 'SIDEBAR.SMM_POSTS'),
    item('SMM:Channels', 'SIDEBAR.SMM_CHANNELS'),
    item('SMM:Media', 'SIDEBAR.SMM_MEDIA'),
    item('SMM:Analytics', 'SIDEBAR.SMM_ANALYTICS'),
    item('SMM:Settings', 'SIDEBAR.SMM_SETTINGS'),
  ]),
  item('MyCompany', 'SIDEBAR.MY_COMPANY', [
    item('MyCompany:Workspace', 'SIDEBAR.ACCOUNT_SETTINGS'),
    item('MyCompany:Employees', 'EMPLOYEE_SETTINGS.TABS.EMPLOYEES'),
    item('MyCompany:Teams', 'EMPLOYEE_SETTINGS.TABS.TEAM'),
    item('MyCompany:Roles', 'EMPLOYEE_SETTINGS.TABS.ROLES'),
    item('MyCompany:Policies', 'EMPLOYEE_SETTINGS.TABS.ASSIGNMENT'),
    item('MyCompany:AuditLogs', 'SIDEBAR.AUDIT_LOGS'),
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
  item('Settings', 'SIDEBAR.ADDITIONAL', [
    item('Settings:Automation', 'SIDEBAR.AUTOMATION'),
    item('Settings:AgentBots', 'SIDEBAR.AGENT_BOTS'),
    item('Settings:Macros', 'SIDEBAR.MACROS'),
    item('Settings:Integrations', 'SIDEBAR.INTEGRATIONS'),
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

export const getSidebarHiddenItems = uiSettings =>
  normalizeSidebarHiddenItems(
    Array.from(
      normalizeLegacyMyCompanyVisibility(
        normalizeLegacyTouchesVisibility(
          normalizeLegacyCaptainPromptsVisibility(
            uiSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY],
            uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
          ),
          uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
        ),
        uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
      )
    )
  );

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
