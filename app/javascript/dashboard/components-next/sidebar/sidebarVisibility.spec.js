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
  it('exposes only primary sidebar sections', () => {
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
    expect(SIDEBAR_VISIBILITY_ITEMS.every(item => !item.children)).toBe(true);
    expect(itemKeys).not.toContain('Campaigns');
    expect(itemKeys).not.toContain('Campaigns:Touches');
    expect(itemKeys).not.toContain('Campaigns:Templates');
    expect(itemKeys).not.toContain('Settings:Macros');
    expect(
      SIDEBAR_VISIBILITY_ITEMS.find(item => item.key === 'Settings')
        .configurable
    ).toBe(false);
  });

  it('builds visibility state only for configurable primary sections', () => {
    const visibilityState = buildSidebarVisibilityState({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation', 'Reports'],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });

    expect(visibilityState.Conversation).toBe(false);
    expect(visibilityState.Reports).toBe(false);
    expect(visibilityState.Inbox).toBe(true);
    expect(visibilityState.Settings).toBeUndefined();
    expect(visibilityState['Conversation:Statuses']).toBeUndefined();
  });

  it('migrates legacy outbound visibility to broadcasts and drops nested keys', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Campaigns',
          'Campaigns:Touches',
          'Campaigns:Templates',
          'Conversation:Statuses',
          'Settings:Macros',
          'Reports',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 16,
      })
    ).toEqual(['Campaigns:MassBroadcasts', 'Reports']);
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

  it('persists only hidden configurable primary sections', () => {
    const state = buildSidebarVisibilityState({});
    state.Conversation = false;
    state['Campaigns:MassBroadcasts'] = false;
    state.Settings = false;
    state['Settings:Macros'] = false;

    expect(getSidebarHiddenItemsFromState(state)).toEqual([
      'Conversation',
      'Campaigns:MassBroadcasts',
    ]);

    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountSettings: {
          locale: 'ru',
          [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
            'Conversation',
            'Settings:Macros',
          ],
          [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
            SIDEBAR_VISIBILITY_CURRENT_VERSION,
        },
      })
    ).toEqual({
      locale: 'ru',
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation'],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });
  });
});
