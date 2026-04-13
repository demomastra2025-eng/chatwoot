import {
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
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
    expect(visibilityState['Campaigns:Broadcasts']).toBe(true);
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
