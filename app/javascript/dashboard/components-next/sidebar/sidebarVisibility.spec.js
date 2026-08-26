import {
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_ITEMS,
  buildEffectiveSidebarVisibilitySettings,
  buildSidebarVisibilityState,
  filterSidebarMenuItems,
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
    expect(visibilityState['Captain:Usage']).toBe(true);
    expect(visibilityState['Captain:AISettings']).toBe(true);
    expect(visibilityState['Captain:Documents']).toBeUndefined();
    expect(visibilityState['Conversation:Channels']).toBeUndefined();
    expect(visibilityState['Conversation:AllChannels']).toBeUndefined();
    expect(visibilityState.MyCompany).toBeUndefined();
    expect(visibilityState['MyCompany:Workspace']).toBe(true);
    expect(visibilityState['MyCompany:LeadForms']).toBe(true);
    expect(visibilityState['MyCompany:Tags']).toBe(true);
    expect(visibilityState['MyCompany:Employees']).toBe(true);
    expect(visibilityState.Employees).toBeUndefined();
    expect(visibilityState.Settings).toBeUndefined();
    expect(visibilityState['Settings:Automation']).toBe(true);
    expect(visibilityState.SMM).toBeUndefined();
    expect(visibilityState['SMM:LeadForms']).toBeUndefined();
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
          'Settings',
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
  });

  it('places company settings first inside the settings visibility menu', () => {
    const itemKeys = SIDEBAR_VISIBILITY_ITEMS.map(item => item.key);
    const settingsItem = SIDEBAR_VISIBILITY_ITEMS.find(
      item => item.key === 'Settings'
    );
    const settingsChildKeys = settingsItem.children.map(item => item.key);

    expect(itemKeys).not.toContain('MyCompany');
    expect(settingsChildKeys.slice(0, 12)).toEqual([
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
    expect(settingsChildKeys[12]).toBe('Settings:Automation');
    expect(settingsChildKeys).not.toContain('Settings:LeadForms');
    expect(itemKeys).not.toContain('SMM');
    expect(settingsItem.configurable).toBe(false);
  });

  it('keeps the settings container visible for access to visibility management', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toEqual([]);

    expect(
      filterSidebarMenuItems(
        [
          {
            name: 'Settings',
            children: [{ name: 'Visibility' }],
          },
        ],
        {
          [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings'],
          [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
            SIDEBAR_VISIBILITY_CURRENT_VERSION,
        }
      )
    ).toEqual([
      {
        name: 'Settings',
        children: [{ name: 'Visibility' }],
      },
    ]);
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

  it('migrates legacy lead forms visibility keys to company settings', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings:LeadForms'],
      })
    ).toEqual(['Conversation:Statuses', 'MyCompany:LeadForms']);

    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['SMM:LeadForms'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 15,
      })
    ).toEqual(['MyCompany:LeadForms']);
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

  it('uses only the account-wide visibility policy', () => {
    const accountSettings = {
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        'Conversation:Pipelines',
        'Reports',
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    };

    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountSettings,
        uiSettings: {
          dashboard_sidebar_hidden_items_by_account: {
            1: ['Campaigns'],
          },
        },
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Pipelines', 'Reports']);
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountSettings: {},
      })[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Statuses']);
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
});
