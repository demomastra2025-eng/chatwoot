export const SIDEBAR_VISIBILITY_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items';
export const SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items_version';
export const SIDEBAR_VISIBILITY_ACCOUNT_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items_by_account';
export const SIDEBAR_VISIBILITY_ACCOUNT_VERSION_UI_SETTINGS_KEY =
  'dashboard_sidebar_hidden_items_version_by_account';
export const SIDEBAR_VISIBILITY_CURRENT_VERSION = 16;

const CAPTAIN_PROMPTS_VISIBILITY_KEY = 'Captain:Prompts';
const LEGACY_CAPTAIN_RESTRICTIONS_VISIBILITY_KEY = 'Captain:Restrictions';
const TOUCHES_VISIBILITY_KEY = 'Campaigns:Touches';
const LEGACY_EMPLOYEES_VISIBILITY_KEY = 'Employees';
const MY_COMPANY_VISIBILITY_KEY = 'MyCompany';
const MY_COMPANY_VISIBILITY_ITEM_KEYS = Object.freeze([
  'MyCompany:Workspace',
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
export const CONVERSATION_PIPELINES_VISIBILITY_KEY = 'Conversation:Pipelines';
export const CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY =
  'Conversation:AppointmentStatuses';
export const CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS = Object.freeze({
  scheduled: 'Conversation:AppointmentStatus:scheduled',
  confirmed: 'Conversation:AppointmentStatus:confirmed',
  completed: 'Conversation:AppointmentStatus:completed',
  cancelled: 'Conversation:AppointmentStatus:cancelled',
  no_show: 'Conversation:AppointmentStatus:no_show',
});
const ACCOUNT_CONTROLLED_CONVERSATION_VISIBILITY_KEYS = Object.freeze([
  CONVERSATION_PIPELINES_VISIBILITY_KEY,
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  ...Object.values(CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS),
]);
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

const item = (key, labelKey, children = []) => ({
  key,
  labelKey,
  children,
});

const MY_COMPANY_VISIBILITY_ITEMS = Object.freeze([
  item('MyCompany:Workspace', 'SIDEBAR.ACCOUNT_SETTINGS'),
  item(MY_COMPANY_LEAD_FORMS_VISIBILITY_KEY, 'SIDEBAR.LEAD_FORMS'),
  item('MyCompany:Channels', 'SIDEBAR.CHANNELS'),
  item('MyCompany:Tags', 'SIDEBAR.LABELS'),
  item('MyCompany:Employees', 'EMPLOYEE_SETTINGS.TABS.EMPLOYEES'),
  item('MyCompany:Teams', 'EMPLOYEE_SETTINGS.TABS.TEAM'),
  item('MyCompany:Roles', 'EMPLOYEE_SETTINGS.TABS.ROLES'),
  item('MyCompany:Policies', 'EMPLOYEE_SETTINGS.TABS.ASSIGNMENT'),
  item('MyCompany:AuditLogs', 'SIDEBAR.AUDIT_LOGS'),
]);

export const SIDEBAR_VISIBILITY_ITEMS = Object.freeze([
  item('Inbox', 'SIDEBAR.INBOX'),
  item('Conversation', 'SIDEBAR.CONVERSATIONS', [
    item('Conversation:Assignee:all', 'CHAT_LIST.ASSIGNEE_TYPE_TABS.all'),
    item('Conversation:Assignee:me', 'CHAT_LIST.ASSIGNEE_TYPE_TABS.me'),
    item(
      'Conversation:Assignee:unassigned',
      'CHAT_LIST.ASSIGNEE_TYPE_TABS.unassigned'
    ),
    item(
      CONVERSATION_STATUSES_VISIBILITY_KEY,
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.STATUSES'
    ),
    item('Conversation:Pending', 'SIDEBAR.PENDING_CONVERSATIONS'),
    item('Conversation:Open', 'SIDEBAR.OPEN_CONVERSATIONS'),
    item('Conversation:Snoozed', 'SIDEBAR.SNOOZED_CONVERSATIONS'),
    item('Conversation:Resolved', 'SIDEBAR.RESOLVED_CONVERSATIONS'),
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
    item('Conversation:Folders', 'SIDEBAR.CUSTOM_VIEWS_FOLDER'),
    item('Conversation:Teams', 'SIDEBAR.TEAMS'),
    item('Conversation:Labels', 'SIDEBAR.LABELS'),
  ]),
  item('Campaigns', 'SIDEBAR.OUTBOUND', [
    item('Campaigns:Templates', 'SIDEBAR.TEMPLATES'),
    item(TOUCHES_VISIBILITY_KEY, 'SIDEBAR.TOUCHES'),
    item('Campaigns:MassBroadcasts', 'SIDEBAR.MASS_BROADCASTS'),
  ]),
  item('Captain', 'SIDEBAR.CAPTAIN', [
    item('Captain:Settings', 'PROFILE_SETTINGS.FORM.PROFILE_SECTION.TITLE'),
    item('Captain:Prompts', 'SIDEBAR.CAPTAIN_PROMPTS'),
    item('Captain:FollowUps', 'SIDEBAR.CAPTAIN_FOLLOW_UPS'),
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
  ]),
  item('Reports', 'SIDEBAR.REPORTS', [
    item('Reports:Overview', 'SIDEBAR.REPORTS_OVERVIEW'),
    item('Reports:Conversation', 'SIDEBAR.REPORTS_CONVERSATION'),
    item(REPORTS_DEALS_VISIBILITY_KEY, 'SIDEBAR.REPORTS_DEALS'),
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
    ...MY_COMPANY_VISIBILITY_ITEMS,
    item('Settings:Automation', 'SIDEBAR.AUTOMATION'),
    item('Settings:AgentBots', 'SIDEBAR.AGENT_BOTS'),
    item('Settings:Macros', 'SIDEBAR.MACROS'),
    item('Settings:Integrations', 'SIDEBAR.INTEGRATIONS'),
    item('Settings:Billing', 'SIDEBAR.BILLING'),
  ]),
]);

export const PERSONAL_SIDEBAR_VISIBILITY_ITEMS = Object.freeze(
  SIDEBAR_VISIBILITY_ITEMS.map(visibilityItem => {
    if (visibilityItem.key !== 'Conversation') {
      return visibilityItem;
    }

    return {
      ...visibilityItem,
      children: visibilityItem.children.filter(
        child =>
          !ACCOUNT_CONTROLLED_CONVERSATION_VISIBILITY_KEYS.includes(child.key)
      ),
    };
  })
);

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

const normalizePersonalSidebarHiddenItems = hiddenItems =>
  normalizeSidebarHiddenItems(hiddenItems).filter(
    key => !ACCOUNT_CONTROLLED_CONVERSATION_VISIBILITY_KEYS.includes(key)
  );

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

export const getSidebarHiddenItems = uiSettings =>
  normalizeSidebarHiddenItems(
    Array.from(
      normalizeLegacyLeadFormsVisibility(
        normalizeRemovedMyCompanyGroupVisibility(
          normalizeLegacyReportsDealsVisibility(
            normalizeLegacyConversationPipelinesVisibility(
              normalizeDefaultConversationStatusVisibility(
                normalizeLegacyMyCompanyVisibility(
                  normalizeLegacyTouchesVisibility(
                    normalizeLegacyCaptainPromptsVisibility(
                      uiSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY],
                      uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
                    ),
                    uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
                  ),
                  uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
                ),
                uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
              ),
              uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
            ),
            uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
          ),
          uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
        ),
        uiSettings?.[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]
      )
    )
  );

const accountScopedValue = (uiSettings, settingsKey, accountId) => {
  const scopedSettings = uiSettings?.[settingsKey];
  const accountKey = String(accountId || '');

  if (!accountKey || !scopedSettings || typeof scopedSettings !== 'object') {
    return undefined;
  }

  return scopedSettings[accountKey];
};

export const getAccountScopedSidebarHiddenItems = (uiSettings, accountId) => {
  const scopedHiddenItems = accountScopedValue(
    uiSettings,
    SIDEBAR_VISIBILITY_ACCOUNT_UI_SETTINGS_KEY,
    accountId
  );

  if (!Array.isArray(scopedHiddenItems)) {
    return normalizePersonalSidebarHiddenItems(
      Array.isArray(uiSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY])
        ? getSidebarHiddenItems(uiSettings)
        : getSidebarHiddenItems({})
    );
  }

  return normalizePersonalSidebarHiddenItems(
    getSidebarHiddenItems({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: scopedHiddenItems,
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        accountScopedValue(
          uiSettings,
          SIDEBAR_VISIBILITY_ACCOUNT_VERSION_UI_SETTINGS_KEY,
          accountId
        ) || SIDEBAR_VISIBILITY_CURRENT_VERSION,
    })
  );
};

export const buildAccountScopedSidebarUISettings = ({
  uiSettings,
  accountId,
  hiddenItems,
}) => {
  const accountKey = String(accountId || '');
  if (!accountKey) return {};

  return {
    [SIDEBAR_VISIBILITY_ACCOUNT_UI_SETTINGS_KEY]: {
      ...(uiSettings?.[SIDEBAR_VISIBILITY_ACCOUNT_UI_SETTINGS_KEY] || {}),
      [accountKey]: normalizePersonalSidebarHiddenItems(hiddenItems),
    },
    [SIDEBAR_VISIBILITY_ACCOUNT_VERSION_UI_SETTINGS_KEY]: {
      ...(uiSettings?.[SIDEBAR_VISIBILITY_ACCOUNT_VERSION_UI_SETTINGS_KEY] ||
        {}),
      [accountKey]: SIDEBAR_VISIBILITY_CURRENT_VERSION,
    },
  };
};

export const buildEffectiveSidebarVisibilitySettings = ({
  uiSettings,
  accountSettings,
  accountId,
}) => {
  const accountPolicyHiddenItems = Array.isArray(
    accountSettings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
  )
    ? getSidebarHiddenItems(accountSettings)
    : [];
  const personalHiddenItems = getAccountScopedSidebarHiddenItems(
    uiSettings,
    accountId
  );

  return {
    ...(uiSettings || {}),
    [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: normalizeSidebarHiddenItems([
      ...accountPolicyHiddenItems,
      ...personalHiddenItems,
    ]),
    [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
      SIDEBAR_VISIBILITY_CURRENT_VERSION,
  };
};

export const CONVERSATION_SIDEBAR_VISIBILITY_ITEMS = Object.freeze(
  SIDEBAR_VISIBILITY_ITEMS.find(
    visibilityItem => visibilityItem.key === 'Conversation'
  )?.children || []
);

export const getConversationSidebarHiddenItems = uiSettings =>
  getSidebarHiddenItems(uiSettings).filter(key =>
    CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.some(
      visibilityItem => visibilityItem.key === key
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

export const getConversationSidebarHiddenItemsFromState = state =>
  getSidebarHiddenItemsFromState(state).filter(key =>
    CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.some(
      visibilityItem => visibilityItem.key === key
    )
  );

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
