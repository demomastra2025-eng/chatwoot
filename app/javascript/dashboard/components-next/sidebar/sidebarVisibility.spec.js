import {
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_ITEMS,
  buildSidebarVisibilityState,
  filterSidebarMenuItems,
  getSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
} from './sidebarVisibility';

describe('sidebarVisibility', () => {
  it('keeps all sidebar items visible by default', () => {
    const visibilityState = buildSidebarVisibilityState({});

    expect(visibilityState.Inbox).toBe(true);
    expect(visibilityState.Campaigns).toBe(true);
    expect(visibilityState['Campaigns:Templates']).toBe(true);
    expect(visibilityState['Campaigns:Touches']).toBe(true);
    expect(visibilityState['Captain:Evaluations']).toBe(true);
    expect(visibilityState['Captain:Observability']).toBe(true);
    expect(visibilityState['Captain:FAQs']).toBe(true);
    expect(visibilityState['Captain:Documents']).toBeUndefined();
    expect(visibilityState['Conversation:Channels']).toBeUndefined();
    expect(visibilityState['Conversation:AllChannels']).toBeUndefined();
    expect(visibilityState.MyCompany).toBe(true);
    expect(visibilityState['MyCompany:Tags']).toBe(true);
    expect(visibilityState['MyCompany:Employees']).toBe(true);
    expect(visibilityState.Employees).toBeUndefined();
    expect(visibilityState.Settings).toBe(true);
    expect(visibilityState['Settings:Automation']).toBe(true);
    expect(visibilityState['Reports:Overview']).toBe(true);
  });

  it('normalizes saved hidden items to known sidebar sections', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Reports',
          'Unknown',
          'Employees',
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
      'MyCompany:Tags',
      'MyCompany:Employees',
      'Reports',
      'Settings:Macros',
    ]);
  });

  it('keeps company settings immediately before reports in the visibility menu', () => {
    const itemKeys = SIDEBAR_VISIBILITY_ITEMS.map(item => item.key);

    expect(itemKeys.indexOf('MyCompany')).toBe(itemKeys.indexOf('Reports') - 1);
  });

  it('keeps merged prompts visible for legacy settings when only restrictions or prompts were hidden', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Captain:Prompts'],
      })
    ).toEqual([]);

    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Captain:Restrictions'],
      })
    ).toEqual([]);
  });

  it('keeps merged prompts hidden when both legacy items were hidden', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Captain:Prompts',
          'Captain:Restrictions',
        ],
      })
    ).toEqual(['Captain:Prompts']);
  });

  it('migrates the legacy personal broadcasts visibility key to touches', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Campaigns:PersonalBroadcasts'],
      })
    ).toEqual(['Campaigns:Touches']);
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
      ],
      {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings:Macros'],
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
