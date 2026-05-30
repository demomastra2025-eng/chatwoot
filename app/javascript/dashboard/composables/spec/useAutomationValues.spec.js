import { createPinia, setActivePinia } from 'pinia';
import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import useAutomationValues from '../useAutomationValues';

vi.mock('dashboard/composables/store');
vi.mock('vue-i18n');

const emptyGetterMap = {
  'agents/getVerifiedAgents': [],
  'campaigns/getAllCampaigns': [],
  'contacts/getContacts': [],
  'inboxes/getInboxes': [],
  'labels/getLabels': [],
  'teams/getTeams': [],
  'sla/getSLA': [],
};

describe('useAutomationValues', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    useI18n.mockReturnValue({ t: key => key });
    useStoreGetters.mockReturnValue({
      'attributes/getAttributes': { value: [] },
      getCurrentAccountId: { value: 1 },
    });
    useMapGetter.mockImplementation(getter => ({
      value: emptyGetterMap[getter] || [],
    }));
  });

  it('renders only active CRM stages from active pipelines in automation dropdowns', () => {
    const crmReferencesStore = useCrmReferencesStore();
    crmReferencesStore.pipelines = [
      {
        id: 1,
        name: 'Sales',
        active: true,
        stages: [
          { id: 11, name: 'Qualified', active: true },
          { id: 12, name: 'Archived', active: false },
        ],
      },
      {
        id: 2,
        name: 'Archived pipeline',
        active: false,
        stages: [{ id: 21, name: 'Hidden', active: true }],
      },
    ];

    const {
      crmStageOptions,
      getActionDropdownValues,
      getConditionDropdownValues,
    } = useAutomationValues();

    const activeStageOptions = [{ id: 11, name: 'Sales / Qualified' }];

    expect(crmStageOptions.value).toEqual(activeStageOptions);
    expect(getConditionDropdownValues('stage_id', 'deal_created')).toEqual(
      activeStageOptions
    );
    expect(
      getActionDropdownValues('change_deal_stage', 'deal_created')
    ).toEqual(activeStageOptions);
  });
});
