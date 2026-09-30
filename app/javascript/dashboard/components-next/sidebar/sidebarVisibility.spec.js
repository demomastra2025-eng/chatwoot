import {
  SIDEBAR_ORDER_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_ITEMS,
  buildEffectiveSidebarVisibilitySettings,
  buildSidebarVisibilityState,
  filterSidebarMenuItems,
  getConversationSidebarHiddenItems,
  getConversationSidebarHiddenItemsFromState,
  getSidebarItemOrder,
  getSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
  isConversationAssigneeSelectionLocked,
  normalizeSidebarItemOrder,
} from './sidebarVisibility';

const currentSettings = (hiddenItems, extra = {}) => ({
  [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: hiddenItems,
  [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
    SIDEBAR_VISIBILITY_CURRENT_VERSION,
  ...extra,
});

describe('sidebarVisibility', () => {
  it('exposes primary sections and conversation navigation items', () => {
    const itemKeys = SIDEBAR_VISIBILITY_ITEMS.map(item => item.key);

    expect(itemKeys).toEqual([
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
    expect(itemKeys).not.toContain('Inbox');
    expect(itemKeys).not.toContain('Campaigns');
    expect(
      SIDEBAR_VISIBILITY_ITEMS.find(item => item.key === 'Settings')
        .configurable
    ).toBe(false);
    expect(
      SIDEBAR_VISIBILITY_ITEMS.find(
        item => item.key === 'Conversation'
      ).children.map(child => child.key)
    ).toEqual(
      expect.arrayContaining([
        'Conversation:Assignee',
        'Conversation:Assignee:all',
        'Conversation:Pipelines',
        'Conversation:AppointmentStatuses',
        'Conversation:AppointmentStatus:no_show',
        'Conversation:Folders',
        'Conversation:Teams',
        'Conversation:Organization',
        'Conversation:Labels',
      ])
    );
    const conversationKeys = SIDEBAR_VISIBILITY_ITEMS.find(
      item => item.key === 'Conversation'
    ).children.map(child => child.key);
    [
      'Conversation:Statuses',
      'Conversation:Pending',
      'Conversation:Open',
      'Conversation:Snoozed',
      'Conversation:Resolved',
    ].forEach(statusKey => expect(conversationKeys).not.toContain(statusKey));
  });

  it('shows the lists and broadcasts by default for unsaved accounts', () => {
    const visibilityState = buildSidebarVisibilityState({});

    expect(visibilityState['Conversation:Statuses']).toBeUndefined();
    expect(visibilityState['Conversation:Open']).toBeUndefined();
    expect(visibilityState['Conversation:Pipelines']).toBe(true);
    expect(visibilityState['Conversation:Organization']).toBe(true);
    expect(visibilityState['Campaigns:MassBroadcasts']).toBe(true);
    expect(visibilityState.Campaigns).toBeUndefined();
    expect(visibilityState.Inbox).toBeUndefined();
    expect(visibilityState.Settings).toBeUndefined();
    expect(visibilityState['Settings:Macros']).toBeUndefined();
  });

  it.each([undefined, 7, 17, 20, SIDEBAR_VISIBILITY_CURRENT_VERSION])(
    'drops the removed status group keys saved with version %s',
    version => {
      const settings = {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Conversation:Statuses',
          'Conversation:Pending',
          'Conversation:Open',
          'Conversation:Snoozed',
          'Conversation:Resolved',
          'Conversation:Teams',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: version,
      };

      expect(getSidebarHiddenItems(settings)).toEqual(['Conversation:Teams']);
      expect(getConversationSidebarHiddenItems(settings)).toEqual([
        'Conversation:Teams',
      ]);
    }
  );

  describe('legacy outbound group (before version 21)', () => {
    const legacySettings = (hiddenItems, version, extra = {}) => ({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: hiddenItems,
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: version,
      ...extra,
    });

    it.each([
      [['Campaigns'], 20],
      [['Campaigns'], 17],
      [['Campaigns'], 7],
      [['Campaigns:Touches'], 16],
      [['Campaigns:PersonalBroadcasts'], 2],
      [['Campaigns:MassBroadcasts'], 17],
    ])(
      'keeps broadcasts hidden for hidden %j (version %s)',
      (hidden, version) => {
        const settings = legacySettings(hidden, version);

        expect(getSidebarHiddenItems(settings)).toEqual([
          'Campaigns:MassBroadcasts',
        ]);
        expect(
          buildSidebarVisibilityState(settings)['Campaigns:MassBroadcasts']
        ).toBe(false);
        expect(
          filterSidebarMenuItems(
            [
              {
                name: 'Mass broadcasts',
                visibilityKey: 'Campaigns:MassBroadcasts',
              },
              { name: 'Reports' },
            ],
            settings
          ).map(item => item.name)
        ).toEqual(['Reports']);
      }
    );

    it.each([7, 17, 20])(
      'shows broadcasts when the outbound group was visible (version %s)',
      version => {
        expect(
          getSidebarHiddenItems(legacySettings(['Reports'], version))
        ).toEqual(['Reports']);
      }
    );

    it('keeps the saved position of the old outbound group for broadcasts', () => {
      const order = [
        'Contacts',
        'Campaigns',
        'Conversation',
        'Statuses',
        'Captain',
      ];

      expect(
        getSidebarItemOrder(
          legacySettings([], 20, { [SIDEBAR_ORDER_UI_SETTINGS_KEY]: order })
        ).slice(0, 4)
      ).toEqual([
        'Contacts',
        'Campaigns:MassBroadcasts',
        'Conversation',
        'Captain',
      ]);
      expect(
        normalizeSidebarItemOrder([
          'Campaigns:MassBroadcasts',
          'Reports',
          'Campaigns',
        ]).filter(key => key === 'Campaigns:MassBroadcasts')
      ).toHaveLength(1);
      expect(normalizeSidebarItemOrder(['Reports', 'Campaigns'])[1]).toBe(
        'Campaigns:MassBroadcasts'
      );
    });

    it('saves migrated settings back without legacy keys', () => {
      const settings = legacySettings(
        ['Campaigns', 'Conversation:Statuses', 'Conversation:Labels'],
        20
      );
      const state = buildSidebarVisibilityState(settings);

      expect(getSidebarHiddenItemsFromState(state)).toEqual([
        'Conversation:Labels',
        'Campaigns:MassBroadcasts',
      ]);
      expect(state.Campaigns).toBeUndefined();
    });
  });

  it('never hides the main navigation section key itself', () => {
    const settings = currentSettings([
      'Conversation:Organization',
      'Conversation:Folders',
    ]);

    expect(getSidebarHiddenItems(settings)).toEqual(['Conversation:Folders']);
    expect(getConversationSidebarHiddenItems(settings)).toEqual([
      'Conversation:Folders',
    ]);
    expect(
      getConversationSidebarHiddenItemsFromState({
        'Conversation:Organization': false,
        'Conversation:Folders': false,
      })
    ).toEqual(['Conversation:Folders']);
  });

  it('drops keys that are no longer configurable, including notifications and personal-only items', () => {
    expect(
      getSidebarHiddenItems(
        currentSettings([
          'Inbox',
          'Settings',
          'Settings:Macros',
          'Captain:Prompts',
          'MyCompany:Tags',
          'Reports',
          'Conversation:Teams',
          'Unknown',
        ])
      )
    ).toEqual(['Conversation:Teams', 'Reports']);
  });

  it('migrates the legacy default pipeline key', () => {
    expect(
      getSidebarHiddenItems({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:DefaultPipeline'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 8,
      })
    ).toEqual(['Conversation:Pipelines']);
  });

  it('locks legacy accounts to All when Mine and Unassigned were both hidden', () => {
    const legacySettings = {
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        'Conversation:Assignee:me',
        'Conversation:Assignee:unassigned',
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 16,
    };

    expect(isConversationAssigneeSelectionLocked(legacySettings)).toBe(true);
    expect(
      isConversationAssigneeSelectionLocked({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:Assignee:me'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 16,
      })
    ).toBe(false);
  });

  it('keeps settings visible and filters a hidden primary section as a whole', () => {
    const items = [
      { name: 'Conversation', children: [{ name: 'Conversation:Open' }] },
      { name: 'Reports' },
      { name: 'Settings', children: [{ name: 'Settings:Macros' }] },
    ];

    expect(
      filterSidebarMenuItems(
        items,
        currentSettings(['Conversation', 'Settings', 'Settings:Macros'])
      )
    ).toEqual([
      { name: 'Reports' },
      { name: 'Settings', children: [{ name: 'Settings:Macros' }] },
    ]);
  });

  it('keeps «Все» and the «Диалоги» section when every conversation list is hidden', () => {
    const items = [
      {
        name: 'Conversation',
        children: [
          { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
          { name: 'Assignee:me', visibilityKey: 'Conversation:Assignee:me' },
          { name: 'Folders', visibilityKey: 'Conversation:Folders' },
        ],
      },
      { name: 'Reports' },
    ];

    const filtered = filterSidebarMenuItems(
      items,
      currentSettings([
        'Conversation:Assignee:all',
        'Conversation:Assignee:me',
        'Conversation:Folders',
      ])
    );

    expect(filtered.map(item => item.name)).toEqual([
      'Conversation',
      'Reports',
    ]);
    expect(filtered[0].children.map(item => item.name)).toEqual([
      'Assignee:all',
    ]);
  });

  it('normalizes saved order and appends new or missing sections', () => {
    expect(
      normalizeSidebarItemOrder(['Contacts', 'Conversation', 'Contacts', 'Old'])
    ).toEqual([
      'Contacts',
      'Conversation',
      'Campaigns:MassBroadcasts',
      'Captain',
      'Companies',
      'CRM',
      'CRM Tasks',
      'Scheduling',
      'Reports',
      'Portals',
      'Settings',
    ]);
    expect(getSidebarItemOrder({})).toEqual(
      SIDEBAR_VISIBILITY_ITEMS.map(item => item.key)
    );
  });

  it('applies the saved order after filtering and keeps notifications first', () => {
    const items = [
      { name: 'Inbox' },
      { name: 'Conversation' },
      { name: 'Contacts' },
      { name: 'Reports' },
      { name: 'Settings' },
    ];

    expect(
      filterSidebarMenuItems(
        items,
        currentSettings(['Reports'], {
          [SIDEBAR_ORDER_UI_SETTINGS_KEY]: [
            'Settings',
            'Contacts',
            'Inbox',
            'Conversation',
            'Reports',
          ],
        })
      ).map(item => item.name)
    ).toEqual(['Inbox', 'Settings', 'Contacts', 'Conversation']);
  });

  it('does not reorder nested items', () => {
    const items = [
      {
        name: 'Settings',
        children: [{ name: 'Workspace' }, { name: 'Contacts' }],
      },
    ];

    expect(
      filterSidebarMenuItems(
        items,
        currentSettings([], {
          [SIDEBAR_ORDER_UI_SETTINGS_KEY]: ['Contacts', 'Settings'],
        })
      )[0].children.map(child => child.name)
    ).toEqual(['Workspace', 'Contacts']);
  });

  it('locks the primary lists to All while hiding the other assignee lists', () => {
    const items = [
      { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
      { name: 'Assignee:me', visibilityKey: 'Conversation:Assignee:me' },
      {
        name: 'Assignee:unassigned',
        visibilityKey: 'Conversation:Assignee:unassigned',
      },
      { name: 'Folders', visibilityKey: 'Conversation:Folders' },
      { name: 'Teams', visibilityKey: 'Conversation:Teams' },
    ];
    const settings = currentSettings([
      'Conversation:Assignee',
      'Conversation:Assignee:all',
      'Conversation:Teams',
    ]);

    expect(filterSidebarMenuItems(items, settings)).toEqual([
      { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
      { name: 'Folders', visibilityKey: 'Conversation:Folders' },
    ]);
    expect(isConversationAssigneeSelectionLocked(settings)).toBe(true);
    expect(buildSidebarVisibilityState(settings)).toMatchObject({
      'Conversation:Assignee': false,
      'Conversation:Assignee:all': true,
      'Conversation:Assignee:me': false,
      'Conversation:Assignee:unassigned': false,
    });
  });

  it('honours lists hidden one by one while the group is enabled', () => {
    const items = [
      { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
      { name: 'Assignee:me', visibilityKey: 'Conversation:Assignee:me' },
      {
        name: 'Assignee:unassigned',
        visibilityKey: 'Conversation:Assignee:unassigned',
      },
    ];
    const settings = currentSettings([
      'Conversation:Assignee:all',
      'Conversation:Assignee:me',
    ]);

    expect(filterSidebarMenuItems(items, settings)).toEqual([items[2]]);
    expect(isConversationAssigneeSelectionLocked(settings)).toBe(false);
    expect(buildSidebarVisibilityState(settings)).toMatchObject({
      'Conversation:Assignee': true,
      'Conversation:Assignee:all': false,
      'Conversation:Assignee:me': false,
      'Conversation:Assignee:unassigned': true,
    });
  });

  // Company settings saved by the old Visibility page (version 16) hid All,
  // Mine and Unassigned one by one; they must look the same after deploy.
  describe('legacy company assignee settings (version 16)', () => {
    const assigneeItems = [
      { name: 'Assignee:all', visibilityKey: 'Conversation:Assignee:all' },
      { name: 'Assignee:me', visibilityKey: 'Conversation:Assignee:me' },
      {
        name: 'Assignee:unassigned',
        visibilityKey: 'Conversation:Assignee:unassigned',
      },
    ];
    const legacySettings = hiddenItems => ({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: hiddenItems,
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: 16,
    });
    const visibleLists = settings =>
      filterSidebarMenuItems(assigneeItems, settings).map(item => item.name);

    it.each([
      [['Conversation:Assignee:unassigned'], ['Assignee:all', 'Assignee:me']],
      [['Conversation:Assignee:me'], ['Assignee:all', 'Assignee:unassigned']],
      [['Conversation:Assignee:all'], ['Assignee:me', 'Assignee:unassigned']],
      [
        ['Conversation:Assignee:all', 'Conversation:Assignee:unassigned'],
        ['Assignee:me'],
      ],
      [
        [
          'Conversation:Assignee:all',
          'Conversation:Assignee:me',
          'Conversation:Assignee:unassigned',
        ],
        [],
      ],
    ])('hidden %j still shows exactly %j', (hidden, visible) => {
      const settings = legacySettings(hidden);

      expect(visibleLists(settings)).toEqual(visible);
      expect(isConversationAssigneeSelectionLocked(settings)).toBe(false);
    });

    it('shows only All for Mine and Unassigned hidden, now as the locked group', () => {
      const settings = legacySettings([
        'Conversation:Assignee:me',
        'Conversation:Assignee:unassigned',
      ]);

      expect(visibleLists(settings)).toEqual(['Assignee:all']);
      expect(isConversationAssigneeSelectionLocked(settings)).toBe(true);
    });

    it('opens the new settings with the saved lists and saves them back unchanged', () => {
      const settings = legacySettings([
        'Conversation:Assignee:unassigned',
        'Conversation:Teams',
      ]);
      const state = buildSidebarVisibilityState(settings);

      expect(state).toMatchObject({
        'Conversation:Assignee': true,
        'Conversation:Assignee:all': true,
        'Conversation:Assignee:me': true,
        'Conversation:Assignee:unassigned': false,
      });
      expect(getConversationSidebarHiddenItemsFromState(state)).toEqual(
        getConversationSidebarHiddenItems(settings)
      );
      expect(getConversationSidebarHiddenItems(settings)).toEqual([
        'Conversation:Assignee:unassigned',
        'Conversation:Teams',
      ]);
      // The company Navigation page saves the whole list: nothing is lost.
      expect(getSidebarHiddenItemsFromState(state)).toEqual(
        getSidebarHiddenItems(settings)
      );
    });
  });

  it('filters hidden conversation subsections from the rendered menu', () => {
    expect(
      filterSidebarMenuItems(
        [
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
        currentSettings(['Conversation:AppointmentStatus:confirmed'])
      )
    ).toEqual([
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

  it('builds hidden item payloads from the draft state', () => {
    const state = buildSidebarVisibilityState(currentSettings([]));
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
    expect(getConversationSidebarHiddenItemsFromState(state)).toEqual([
      'Conversation:Pipelines',
    ]);
  });

  it('reads conversation hidden items from account settings only', () => {
    expect(
      getConversationSidebarHiddenItems(
        currentSettings([
          'Reports',
          'Conversation:Labels',
          'Conversation:Folders',
        ])
      )
    ).toEqual(['Conversation:Folders', 'Conversation:Labels']);
  });

  it('builds effective settings from the account and ignores personal overrides', () => {
    expect(
      buildEffectiveSidebarVisibilitySettings({
        accountId: 1,
        accountSettings: {
          locale: 'ru',
          ...currentSettings(['Conversation', 'Settings:Macros']),
        },
        uiSettings: {
          dashboard_sidebar_hidden_items_by_account: { 1: ['Reports'] },
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
