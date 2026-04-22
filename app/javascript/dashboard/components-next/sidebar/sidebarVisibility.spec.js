import {
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
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
    expect(visibilityState.Settings).toBe(true);
    expect(visibilityState['Settings:Workspace']).toBe(true);
    expect(visibilityState['Reports:Overview']).toBe(true);
  });

  it('normalizes saved hidden items to known sidebar sections', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Reports',
          'Unknown',
          'Settings:Workspace',
          'Reports',
        ],
      })
    ).toEqual(['Reports', 'Settings:Workspace']);
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
              name: 'Settings Account Settings',
              visibilityKey: 'Settings:Workspace',
            },
            { name: 'Settings Agents', visibilityKey: 'Settings:Agents' },
          ],
        },
      ],
      {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Settings:Workspace'],
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
        'Settings:Workspace': false,
      })
    ).toEqual(['Campaigns', 'Settings:Workspace']);
  });
});
