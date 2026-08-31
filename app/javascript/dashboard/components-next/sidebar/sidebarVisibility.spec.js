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
  isConversationAssigneeSelectionLocked,
} from './sidebarVisibility';

describe('sidebarVisibility', () => {
  it('exposes primary sections and conversation navigation items', () => {
    const itemKeys = SIDEBAR_VISIBILITY_ITEMS.map(item => item.key);

    expect(itemKeys).toEqual([
      'Inbox',
      'Conversation',
      'Campaigns:MassBroadcasts',
      'Captain',
      'Contacts',
      'Companies',
      'CRM',
      'CRM Tasks',
      'Scheduling',
      'Reports',
      'Portals',
      'Settings',
    ]);
    expect(
      SIDEBAR_VISIBILITY_ITEMS.find(item => item.key === 'Conversation')
        .children
    ).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ key: 'Conversation:Assignee' }),
        expect.objectContaining({ key: 'Conversation:Assignee:all' }),
        expect.objectContaining({ key: 'Conversation:Pipelines' }),
        expect.objectContaining({ key: 'Conversation:AppointmentStatuses' }),
        expect.objectContaining({ key: 'Conversation:Organization' }),
        expect.objectContaining({ key: 'Conversation:Folders' }),
        expect.objectContaining({ key: 'Conversation:Teams' }),
        expect.objectContaining({ key: 'Conversation:Labels' }),
      ])
    );
    expect(itemKeys).not.toContain('Campaigns');
    expect(itemKeys).not.toContain('Campaigns:Touches');
    expect(itemKeys).not.toContain('Campaigns:Templates');
    expect(itemKeys).not.toContain('Settings:Macros');
    expect(
      SIDEBAR_VISIBILITY_ITEMS.find(item => item.key === 'Settings')
        .configurable
    ).toBe(false);
  });

  it('builds visibility state for primary and conversation navigation items', () => {
    const visibilityState = buildSidebarVisibilityState({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        'Conversation:Pipelines',
        'Reports',
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });

    expect(visibilityState.Conversation).toBe(true);
    expect(visibilityState['Conversation:Pipelines']).toBe(false);
    expect(visibilityState.Reports).toBe(false);
    expect(visibilityState.Inbox).toBe(true);
    expect(visibilityState.Settings).toBeUndefined();
    expect(visibilityState['Conversation:Statuses']).toBeUndefined();
  });

  it('migrates legacy outbound visibility and preserves supported conversation keys', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Campaigns',
          'Campaigns:Touches',
          'Campaigns:Templates',
          'Conversation:Statuses',
          'Conversation:Pipelines',
          'Settings:Macros',
          'Reports',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 16,
      })
    ).toEqual([
      'Conversation:Pipelines',
      'Campaigns:MassBroadcasts',
      'Reports',
    ]);
  });

  it('keeps settings visible and filters a hidden primary section as a whole', () => {
    const items = [
      { name: 'Conversation', children: [{ name: 'Conversation:Open' }] },
      { name: 'Reports' },
      { name: 'Settings', children: [{ name: 'Settings:Macros' }] },
    ];

    expect(
      filterSidebarMenuItems(items, {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toEqual([
      { name: 'Reports' },
      { name: 'Settings', children: [{ name: 'Settings:Macros' }] },
    ]);
  });

  it('locks hidden primary lists to All while hiding their other filters', () => {
    const items = [
      { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
      { name: 'Assignee:me', visibilityKey: 'Conversation:Assignee:me' },
      {
        name: 'Assignee:unassigned',
        visibilityKey: 'Conversation:Assignee:unassigned',
      },
      { name: 'Folders', visibilityKey: 'Conversation:Folders' },
      { name: 'Teams', visibilityKey: 'Conversation:Teams' },
      { name: 'Labels', visibilityKey: 'Conversation:Labels' },
      {
        name: 'Appointments',
        visibilityKey: 'Conversation:AppointmentStatuses',
      },
    ];

    expect(
      filterSidebarMenuItems(items, {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Conversation:Assignee',
          'Conversation:Assignee:all',
          'Conversation:Organization',
          'Conversation:Teams',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toEqual([
      {
        name: 'Assignee:all',
        visibilityKey: 'Conversation:Assignee:all',
      },
      { name: 'Folders', visibilityKey: 'Conversation:Folders' },
      { name: 'Labels', visibilityKey: 'Conversation:Labels' },
      {
        name: 'Appointments',
        visibilityKey: 'Conversation:AppointmentStatuses',
      },
    ]);

    expect(
      isConversationAssigneeSelectionLocked({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Conversation:Assignee',
          'Conversation:Assignee:all',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toBe(true);

    expect(
      buildSidebarVisibilityState({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Conversation:Assignee',
          'Conversation:Assignee:all',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      })
    ).toMatchObject({
      'Conversation:Assignee': false,
      'Conversation:Assignee:all': true,
      'Conversation:Assignee:me': false,
      'Conversation:Assignee:unassigned': false,
    });
  });

  it('keeps all primary lists together when their group is enabled', () => {
    const items = [
      { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
      { name: 'Assignee:me', visibilityKey: 'Conversation:Assignee:me' },
      {
        name: 'Assignee:unassigned',
        visibilityKey: 'Conversation:Assignee:unassigned',
      },
    ];
    const settings = {
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        'Conversation:Assignee:all',
        'Conversation:Assignee:me',
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    };

    expect(filterSidebarMenuItems(items, settings)).toEqual(items);
    expect(buildSidebarVisibilityState(settings)).toMatchObject({
      'Conversation:Assignee': true,
      'Conversation:Assignee:all': true,
      'Conversation:Assignee:me': true,
      'Conversation:Assignee:unassigned': true,
    });
  });

  it('persists hidden primary and conversation navigation items', () => {
    const state = buildSidebarVisibilityState({});
    state.Conversation = false;
    state['Conversation:Pipelines'] = false;
    state['Campaigns:MassBroadcasts'] = false;
    state.Settings = false;
    state['Settings:Macros'] = false;

    expect(getSidebarHiddenItemsFromState(state)).toEqual([
      'Conversation',
      'Conversation:Pipelines',
      'Campaigns:MassBroadcasts',
    ]);

    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountSettings: {
          locale: 'ru',
          [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
            'Conversation',
            'Conversation:Pipelines',
            'Settings:Macros',
          ],
          [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
            SIDEBAR_VISIBILITY_CURRENT_VERSION,
        },
      })
    ).toEqual({
      locale: 'ru',
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        'Conversation',
        'Conversation:Pipelines',
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });
  });
});
