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
    expect(visibilityState.Reports).toBe(true);
    expect(visibilityState.Settings).toBe(true);
  });

  it('normalizes saved hidden items to known sidebar sections', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Reports',
          'Unknown',
          'Settings',
          'Reports',
        ],
      })
    ).toEqual(['Reports', 'Settings']);
  });

  it('filters hidden sidebar sections from the rendered menu', () => {
    const filteredMenuItems = filterSidebarMenuItems(
      [{ name: 'Inbox' }, { name: 'Reports' }, { name: 'Settings' }],
      {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Reports'],
      }
    );

    expect(filteredMenuItems).toEqual([
      { name: 'Inbox' },
      { name: 'Settings' },
    ]);
  });

  it('builds a hidden items payload from the draft state', () => {
    expect(
      getSidebarHiddenItemsFromState({
        Inbox: true,
        Reports: false,
        Settings: false,
      })
    ).toEqual(['Reports', 'Settings']);
  });
});
