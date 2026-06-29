import {
  SIDEBAR_VISIBILITY_ACCOUNT_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_ACCOUNT_VERSION_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_ITEMS,
  buildEffectiveSidebarVisibilitySettings,
  buildSidebarVisibilityState,
  filterSidebarMenuItems,
  getAccountScopedSidebarHiddenItems,
  getConversationSidebarHiddenItemsFromState,
  getSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
} from './sidebarVisibility';

describe('sidebarVisibility', () => {
  it('keeps conversation statuses hidden by default while other sidebar items stay visible', () => {
    const visibilityState = buildSidebarVisibilityState({});

    expect(visibilityState.Inbox).toBe(true);
    expect(visibilityState['Conversation:Assignee:all']).toBe(true);
    expect(visibilityState['Conversation:Assignee:me']).toBe(true);
    expect(visibilityState['Conversation:Assignee:unassigned']).toBe(true);
    expect(visibilityState['Conversation:Statuses']).toBe(false);
    expect(visibilityState['Conversation:Open']).toBe(true);
    expect(visibilityState['Conversation:Resolved']).toBe(true);
    expect(visibilityState['Conversation:Pipelines']).toBe(true);
    expect(visibilityState['Conversation:AppointmentStatuses']).toBe(true);
    expect(visibilityState['Conversation:AppointmentStatus:scheduled']).toBe(
      true
    );
    expect(visibilityState['Conversation:AppointmentStatus:confirmed']).toBe(
      true
    );
    expect(visibilityState['Conversation:AppointmentStatus:completed']).toBe(
      true
    );
    expect(visibilityState.Campaigns).toBe(true);
    expect(visibilityState['Campaigns:Templates']).toBe(true);
    expect(visibilityState['Campaigns:Touches']).toBe(true);
    expect(visibilityState['Campaigns:TouchPlans']).toBeUndefined();
    expect(visibilityState['Captain:FollowUps']).toBe(true);
    expect(visibilityState['Captain:Evaluations']).toBe(true);
    expect(visibilityState['Captain:Observability']).toBe(true);
    expect(visibilityState['Captain:FAQs']).toBe(true);
    expect(visibilityState['Captain:Documents']).toBeUndefined();
    expect(visibilityState['Conversation:Channels']).toBeUndefined();
    expect(visibilityState['Conversation:AllChannels']).toBeUndefined();
    expect(visibilityState.MyCompany).toBeUndefined();
    expect(visibilityState['MyCompany:Workspace']).toBe(true);
    expect(visibilityState['MyCompany:Tags']).toBe(true);
    expect(visibilityState['MyCompany:Employees']).toBe(true);
    expect(visibilityState.Employees).toBeUndefined();
    expect(visibilityState.Settings).toBe(true);
    expect(visibilityState['Settings:Automation']).toBe(true);
    expect(visibilityState.SMM).toBe(true);
    expect(visibilityState['SMM:LeadForms']).toBe(true);
    expect(visibilityState['Reports:Overview']).toBe(true);
  });

  it('normalizes saved hidden items to known sidebar sections', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Reports',
          'Unknown',
          'Employees',
          'Conversation:Assignee:all',
          'Conversation:DefaultPipeline',
          'Conversation:AppointmentStatuses',
          'Conversation:AppointmentStatus:completed',
          'Conversation:Channels',
          'Conversation:AllChannels',
          'Settings:CustomAttributes',
          'Settings:Macros',
          'Settings:Workspace',
          'MyCompany:Tags',
          'Reports',
        ],
      })
    ).toEqual([
      'Conversation:Assignee:all',
      'Conversation:Statuses',
      'Conversation:Pipelines',
      'Conversation:AppointmentStatuses',
      'Conversation:AppointmentStatus:completed',
      'Reports',
      'MyCompany:Tags',
      'MyCompany:Employees',
      'Settings:Macros',
    ]);
  });

  it('migrates the removed company group visibility to its moved children', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['MyCompany'],
      })
    ).toEqual([
      'Conversation:Statuses',
      'MyCompany:Workspace',
      'MyCompany:Channels',
      'MyCompany:Tags',
      'MyCompany:Employees',
      'MyCompany:Teams',
      'MyCompany:Roles',
      'MyCompany:Policies',
      'MyCompany:AuditLogs',
    ]);
  });

  it('places company settings first inside the settings visibility menu', () => {
    const itemKeys = SIDEBAR_VISIBILITY_ITEMS.map(item => item.key);
    const settingsItem = SIDEBAR_VISIBILITY_ITEMS.find(
      item => item.key === 'Settings'
    );
    const settingsChildKeys = settingsItem.children.map(item => item.key);

    expect(itemKeys).not.toContain('MyCompany');
    expect(settingsChildKeys.slice(0, 8)).toEqual([
      'MyCompany:Workspace',
      'MyCompany:Channels',
      'MyCompany:Tags',
      'MyCompany:Employees',
      'MyCompany:Teams',
      'MyCompany:Roles',
      'MyCompany:Policies',
      'MyCompany:AuditLogs',
    ]);
    expect(settingsChildKeys[8]).toBe('Settings:Automation');
    expect(settingsChildKeys).not.toContain('Settings:LeadForms');

    const smmItem = SIDEBAR_VISIBILITY_ITEMS.find(item => item.key === 'SMM');
    const smmChildKeys = smmItem.children.map(item => item.key);
    expect(smmChildKeys).toContain('SMM:LeadForms');
  });

  it('keeps merged prompts visible for legacy settings when only restrictions or prompts were hidden', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Captain:Prompts'],
      })
    ).toEqual(['Conversation:Statuses']);

    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Captain:Restrictions'],
      })
    ).toEqual(['Conversation:Statuses']);
  });

  it('keeps merged prompts hidden when both legacy items were hidden', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Captain:Prompts',
          'Captain:Restrictions',
        ],
      })
    ).toEqual(['Conversation:Statuses', 'Captain:Prompts']);
  });

  it('migrates the legacy personal broadcasts visibility key to touches', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Campaigns:PersonalBroadcasts'],
      })
    ).toEqual(['Conversation:Statuses', 'Campaigns:Touches']);
  });

  it('migrates the legacy settings lead forms visibility key to SMM', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings:LeadForms'],
      })
    ).toEqual(['Conversation:Statuses', 'SMM:LeadForms']);
  });

  it('respects explicitly saved conversation status visibility in the current schema', () => {
    expect(
      buildSidebarVisibilityState({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })['Conversation:Statuses']
    ).toBe(true);
  });

  it('migrates the legacy default pipeline visibility key to pipelines', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:DefaultPipeline'],
      })
    ).toEqual(['Conversation:Statuses', 'Conversation:Pipelines']);
  });

  it('preserves touches visibility once the new schema version is saved', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Campaigns:Touches'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toEqual(['Campaigns:Touches']);

    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Campaigns:PersonalBroadcasts'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toEqual([]);
  });

  it('preserves the current prompts visibility once the new schema version is saved', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Captain:Prompts'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toEqual(['Captain:Prompts']);
  });

  it('merges account policy visibility with account-scoped personal overrides', () => {
    const uiSettings = {
      [SIDEBAR_VISIBILITY_ACCOUNT_UI_SETTINGS_KEY]: {
        1: ['Reports'],
        2: ['Campaigns'],
      },
      [SIDEBAR_VISIBILITY_ACCOUNT_VERSION_UI_SETTINGS_KEY]: {
        1: SIDEBAR_VISIBILITY_CURRENT_VERSION,
        2: SIDEBAR_VISIBILITY_CURRENT_VERSION,
      },
    };
    const accountSettings = {
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:Teams'],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    };

    expect(getAccountScopedSidebarHiddenItems(uiSettings, 1)).toEqual([
      'Reports',
    ]);
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountId: 1,
        accountSettings,
        uiSettings,
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Teams', 'Reports']);
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountId: 2,
        accountSettings,
        uiSettings,
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Teams', 'Campaigns']);
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountId: 1,
        accountSettings: {},
        uiSettings,
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Reports']);
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountId: 3,
        accountSettings: {},
        uiSettings,
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Statuses']);
  });

  it('falls back to legacy personal sidebar visibility before account-scoped settings exist', () => {
    const uiSettings = {
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings:Macros'],
    };

    expect(getAccountScopedSidebarHiddenItems(uiSettings, 1)).toEqual([
      'Conversation:Statuses',
      'Settings:Macros',
    ]);
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountId: 1,
        accountSettings: {},
        uiSettings,
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Statuses', 'Settings:Macros']);
  });

  it('filters hidden sidebar sections and subsections from the rendered menu', () => {
    const filteredMenuItems = filterSidebarMenuItems(
      [
        { name: 'Inbox' },
        {
          name: 'Settings',
          children: [
            {
              name: 'Settings Macros',
              visibilityKey: 'Settings:Macros',
            },
            { name: 'Settings Agents', visibilityKey: 'Settings:Agents' },
          ],
        },
        {
          name: 'AppointmentStatuses',
          visibilityKey: 'Conversation:AppointmentStatuses',
          children: [
            {
              name: 'AppointmentStatus:scheduled',
              visibilityKey: 'Conversation:AppointmentStatus:scheduled',
            },
            {
              name: 'AppointmentStatus:confirmed',
              visibilityKey: 'Conversation:AppointmentStatus:confirmed',
            },
          ],
        },
      ],
      {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Settings:Macros',
          'Conversation:AppointmentStatus:confirmed',
        ],
      }
    );

    expect(filteredMenuItems).toEqual([
      { name: 'Inbox' },
      {
        name: 'Settings',
        children: [
          { name: 'Settings Agents', visibilityKey: 'Settings:Agents' },
        ],
      },
      {
        name: 'AppointmentStatuses',
        visibilityKey: 'Conversation:AppointmentStatuses',
        children: [
          {
            name: 'AppointmentStatus:scheduled',
            visibilityKey: 'Conversation:AppointmentStatus:scheduled',
          },
        ],
      },
    ]);
  });

  it('builds a hidden items payload from the draft state', () => {
    expect(
      getSidebarHiddenItemsFromState({
        Inbox: true,
        Campaigns: false,
        'Settings:Macros': false,
      })
    ).toEqual(['Campaigns', 'Settings:Macros']);
  });

  it('builds conversation-only hidden items from the draft state', () => {
    expect(
      getConversationSidebarHiddenItemsFromState({
        Reports: false,
        'Conversation:Teams': false,
        'Conversation:AppointmentStatuses': false,
        'Conversation:AppointmentStatus:scheduled': false,
        'Conversation:Assignee:me': false,
      })
    ).toEqual([
      'Conversation:Assignee:me',
      'Conversation:AppointmentStatuses',
      'Conversation:AppointmentStatus:scheduled',
      'Conversation:Teams',
    ]);
  });
});
