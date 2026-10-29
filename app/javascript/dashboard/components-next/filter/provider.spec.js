import { ref } from 'vue';
import { useConversationFilterContext } from './provider';

const crmReferencesStoreMock = vi.hoisted(() => ({
  pipelines: [],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      key === 'FILTER.ATTRIBUTES.CRM_STAGE_FOR_PIPELINE'
        ? `Воронка: ${params.pipeline}`
        : key,
  }),
}));

vi.mock('dashboard/composables/store.js', () => ({
  useMapGetter: key => {
    const getters = {
      'attributes/getConversationAttributes': [],
      'labels/getLabels': [],
      'agents/getAgents': [],
      'inboxes/getInboxes': [],
      'teams/getTeams': [],
      'campaigns/getAllCampaigns': [],
    };

    return ref(getters[key] || []);
  },
}));

vi.mock('next/icon/provider', () => ({
  useChannelIcon: () => ref(null),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => crmReferencesStoreMock,
}));

describe('useConversationFilterContext', () => {
  beforeEach(() => {
    crmReferencesStoreMock.pipelines = [];
  });

  it('exposes only concrete conversation statuses', () => {
    const { filterTypes } = useConversationFilterContext();
    const statusFilter = filterTypes.value.find(
      filter => filter.attributeKey === 'status'
    );

    expect(statusFilter.options.map(option => option.id)).toEqual([
      'open',
      'resolved',
      'pending',
      'snoozed',
    ]);
  });

  it('exposes active stages from the default CRM pipeline as a conversation filter', () => {
    crmReferencesStoreMock.pipelines = [
      {
        id: 2,
        active: true,
        default: false,
        position: 1,
        name: 'Secondary',
        stages: [{ id: 21, name: 'Other', active: true, position: 1 }],
      },
      {
        id: 1,
        active: true,
        default: true,
        position: 2,
        name: 'Sales',
        stages: [
          { id: 13, name: 'Hidden', active: false, position: 1 },
          { id: 12, name: 'Qualified', active: true, position: 3 },
          { id: 11, name: 'New', active: true, position: 2 },
        ],
      },
    ];

    const { filterTypes } = useConversationFilterContext();
    const crmStageFilter = filterTypes.value.find(
      filter => filter.attributeKey === 'crm_stage_id'
    );

    expect(crmStageFilter.label).toBe('Воронка: Sales');
    expect(crmStageFilter.options).toEqual([
      { id: 11, name: 'New' },
      { id: 12, name: 'Qualified' },
    ]);
  });

  it('exposes meta_ad_referral and meta_ad_source_id filters for conversations and dialogs', () => {
    const { filterTypes } = useConversationFilterContext();
    const referralFilter = filterTypes.value.find(
      filter => filter.attributeKey === 'meta_ad_referral'
    );
    const sourceFilter = filterTypes.value.find(
      filter => filter.attributeKey === 'meta_ad_source_id'
    );

    expect(referralFilter).toBeDefined();
    expect(referralFilter.inputType).toBe('searchSelect');
    expect(referralFilter.options).toEqual([
      { id: 'true', name: 'FILTER.ATTRIBUTE_LABELS.YES' },
      { id: 'false', name: 'FILTER.ATTRIBUTE_LABELS.NO' },
    ]);
    expect(referralFilter.filterOperators.map(op => op.value)).toEqual([
      'equal_to',
      'not_equal_to',
      'is_present',
      'is_not_present',
    ]);

    expect(sourceFilter).toBeDefined();
    expect(sourceFilter.inputType).toBe('plainText');
    expect(sourceFilter.filterOperators.map(op => op.value)).toEqual([
      'equal_to',
      'not_equal_to',
      'contains',
      'does_not_contain',
      'is_present',
      'is_not_present',
    ]);
  });
});
