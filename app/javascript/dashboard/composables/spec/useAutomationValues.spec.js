import { createPinia, setActivePinia } from 'pinia';
import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';
import { useAutomationContactsStore } from 'dashboard/stores/automation/contacts';
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

  it('offers the Captain source in appointment automation conditions', () => {
    const { getConditionDropdownValues } = useAutomationValues();

    expect(
      getConditionDropdownValues('source', 'appointment_created')
    ).toContainEqual({
      id: 'captain',
      name: 'SCHEDULING.APPOINTMENT_SOURCE.captain',
    });
  });

  it('lists the account cabinets by name and number with the cabinet code as the value', () => {
    const schedulingReferencesStore = useSchedulingReferencesStore();
    schedulingReferencesStore.cabinets = [
      { code: '501', name: 'Терапевт', number: '1', type: 'consulting' },
      { code: '502', name: 'Процедурный', number: null, type: null },
      { code: '503', name: null, number: '3', type: null },
      { code: '504', name: null, number: null, type: null },
    ];
    const { appointmentCabinetOptions, getConditionDropdownValues } =
      useAutomationValues();

    const expected = [
      { id: '501', name: 'Терапевт · 1' },
      { id: '502', name: 'Процедурный' },
      { id: '503', name: '3' },
      { id: '504', name: '504' },
    ];

    expect(appointmentCabinetOptions.value).toEqual(expected);
    expect(
      getConditionDropdownValues(
        'medelement_cabinet_code',
        'appointment_created'
      )
    ).toEqual(expected);
  });

  it('offers no cabinets before they are loaded', () => {
    const { getConditionDropdownValues } = useAutomationValues();

    expect(
      getConditionDropdownValues(
        'medelement_cabinet_code',
        'appointment_updated'
      )
    ).toEqual([]);
  });

  describe('contact condition values', () => {
    it('offers the contacts met so far, and deleted ones flagged as such', () => {
      const contactsStore = useAutomationContactsStore();
      contactsStore.remember([
        { id: 7, name: 'Айгерим', description: '+77011234567' },
      ]);
      contactsStore.deletedIds = [9];
      const { contactOptions, getConditionDropdownValues } =
        useAutomationValues();

      const expected = [
        { id: 7, name: 'Айгерим', description: '+77011234567' },
        { id: 9, name: 'AUTOMATION.CONTACT_CONDITION.DELETED', deleted: true },
      ];

      expect(contactOptions.value).toEqual(expected);
      expect(
        getConditionDropdownValues('contact_id', 'conversation_created')
      ).toEqual(expected);
      expect(
        getConditionDropdownValues('contact_id', 'message_created')
      ).toEqual(expected);
      expect(
        getConditionDropdownValues('contact_id', 'appointment_updated')
      ).toEqual(expected);
    });

    it('has no contacts before any is searched or named', () => {
      const { getConditionDropdownValues } = useAutomationValues();

      expect(
        getConditionDropdownValues('contact_id', 'conversation_created')
      ).toEqual([]);
    });

    it('follows the contacts found by a later search', () => {
      const contactsStore = useAutomationContactsStore();
      const { getConditionDropdownValues } = useAutomationValues();

      contactsStore.remember([{ id: 3, name: 'Берик', description: '' }]);

      expect(
        getConditionDropdownValues('contact_id', 'conversation_created')
      ).toEqual([{ id: 3, name: 'Берик', description: '' }]);
    });
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
