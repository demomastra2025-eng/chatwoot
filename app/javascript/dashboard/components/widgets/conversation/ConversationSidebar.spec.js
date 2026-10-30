import { beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive, ref } from 'vue';
import { createPinia } from 'pinia';
import { flushPromises, shallowMount } from '@vue/test-utils';

import ConversationSidebar from './ConversationSidebar.vue';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import {
  PATIENT_SELECTION_STORAGE_KEY,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';

const mocks = vi.hoisted(() => ({
  currentAccount: null,
  currentAccountId: null,
  uiSettings: null,
  width: null,
  updateUISettings: vi.fn(),
  isFeatureEnabledonAccount: { __v_isRef: true, value: () => true },
  permissions: ['administrator', 'crm_deal_manage', 'scheduling_manage'],
  route: { params: { accountId: '1' }, query: {} },
  replace: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({ replace: mocks.replace }),
}));
vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: { patients: vi.fn() },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: name => {
    const getters = {
      'accounts/isFeatureEnabledonAccount': mocks.isFeatureEnabledonAccount,
      getCurrentAccountId: mocks.currentAccountId,
      getCurrentUser: {
        __v_isRef: true,
        get value() {
          return {
            id: 9,
            accounts: [
              {
                id: mocks.currentAccountId.value,
                permissions: mocks.permissions,
              },
            ],
          };
        },
      },
    };
    return getters[name];
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
    updateUISettings: mocks.updateUISettings,
  }),
}));

vi.mock('@vueuse/core', () => ({
  useWindowSize: () => ({ width: mocks.width }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: mocks.currentAccountId,
    currentAccount: mocks.currentAccount,
  }),
}));

const mountComponent = (
  currentChat = { id: 1, inbox_id: 2 },
  pinia = createPinia()
) =>
  shallowMount(ConversationSidebar, {
    props: {
      currentChat,
    },
    global: {
      plugins: [pinia],
      stubs: {
        ContactPanel: {
          name: 'ContactPanel',
          props: [
            'conversationId',
            'inboxId',
            'selectedPatient',
            'patientContextEnabled',
            'patientEntry',
          ],
          template: '<div><slot name="after-profile" /></div>',
        },
        CrmConversationDealsSidebar: {
          name: 'CrmConversationDealsSidebar',
          props: ['currentChat', 'selectedPatient'],
          template: '<div />',
        },
        SchedulingConversationAppointmentsSidebar: {
          name: 'SchedulingConversationAppointmentsSidebar',
          props: [
            'currentChat',
            'selectedPatient',
            'patientContextEnabled',
            'patientContextKey',
          ],
          emits: ['patientBound'],
          template: '<div><slot name="after-header" /></div>',
        },
      },
    },
  });

const deferredRequest = () => {
  let resolve;
  const promise = new Promise(resolvePromise => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
};

const patientsResponse = (accountId = 1, ownerId = 42, patientId = 84) => ({
  data: {
    payload: {
      contact_id: ownerId,
      patients: [ownerId, patientId, 85].map(id => ({
        id,
        account_id: accountId,
        communication_contact_id: ownerId,
        patient_contact_id: id === ownerId ? null : id,
        full_name: `Patient ${id}`,
      })),
    },
  },
});

describe('ConversationSidebar', () => {
  beforeEach(() => {
    mocks.currentAccount = ref({ settings: {} });
    mocks.currentAccountId = ref(1);
    mocks.isFeatureEnabledonAccount.value = () => true;
    mocks.permissions = [
      'administrator',
      'crm_deal_manage',
      'scheduling_manage',
    ];
    mocks.width = ref(1024);
    mocks.updateUISettings.mockClear();
    mocks.route = reactive({
      params: { accountId: '1', conversation_id: '1' },
      query: {},
    });
    mocks.replace.mockClear();
    window.localStorage.clear();
    SchedulingContactsAPI.patients.mockReset();
    SchedulingContactsAPI.patients.mockResolvedValue({
      data: {
        payload: {
          contact_id: 42,
          patients: [
            {
              id: 42,
              account_id: 1,
              communication_contact_id: 42,
              full_name: 'Owner',
            },
            {
              id: 84,
              account_id: 1,
              communication_contact_id: 42,
              patient_contact_id: 84,
              full_name: 'Patient',
            },
          ],
        },
      },
    });
  });

  it('passes the sole patient to the contact panel and hides the top selector in appointments when there is only one patient', async () => {
    mocks.uiSettings = ref({ is_contact_sidebar_open: true });
    SchedulingContactsAPI.patients.mockResolvedValueOnce({
      data: {
        payload: {
          contact_id: 42,
          patients: [{ id: 42, account_id: 1, communication_contact_id: 42 }],
        },
      },
    });
    const wrapper = mountComponent({
      id: 123,
      inbox_id: 2,
      meta: { sender: { id: 42 } },
    });
    await flushPromises();
    const panel = wrapper.findComponent({ name: 'ContactPanel' });
    expect(panel.props('patientEntry').patients).toHaveLength(1);
    expect(panel.props('selectedPatient').id).toBe(42);

    mocks.uiSettings.value = { is_scheduling_appointments_panel_open: true };
    await flushPromises();
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationPatientSelector' })
        .exists()
    ).toBe(false);
  });

  it('omits narrow sidebar patient selector when 2+ patients exist and passes selectedPatient to deals & appointments', async () => {
    mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
    const pinia = createPinia();
    const wrapper = mountComponent(
      {
        id: 123,
        inbox_id: 2,
        meta: { sender: { id: 42 } },
      },
      pinia
    );
    await flushPromises();
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationPatientSelector' })
        .exists()
    ).toBe(false);
    const store = useConversationPatientContextStore(pinia);
    store.select('1:9:conversation:123', 84);
    mocks.uiSettings.value = { is_crm_deal_panel_open: true };
    await flushPromises();
    const dealsSidebar = wrapper.findComponent({
      name: 'CrmConversationDealsSidebar',
    });
    expect(dealsSidebar.exists()).toBe(true);
    expect(dealsSidebar.props('selectedPatient')).toMatchObject({
      id: 84,
    });
  });

  it('passes selected clinical context while keeping the chat recipient intact', async () => {
    mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
    const chat = {
      id: 123,
      inbox_id: 2,
      meta: { sender: { id: 42, name: 'Owner' } },
    };
    const wrapper = mountComponent(chat);
    await flushPromises();
    const store = useConversationPatientContextStore();
    store.select('1:9:conversation:123', 84);
    await flushPromises();
    const sidebar = wrapper.findComponent({
      name: 'SchedulingConversationAppointmentsSidebar',
    });
    expect(sidebar.props('selectedPatient').id).toBe(84);
    expect(sidebar.props('currentChat').meta.sender.id).toBe(42);
  });

  it('uses a calendar patient request only for the matching original owner', async () => {
    mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
    mocks.route.query = {
      patientContactId: '84',
      patientChatContactId: '42',
      status: 'open',
    };
    const wrapper = mountComponent({ id: 123, meta: { sender: { id: 42 } } });
    await flushPromises();
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
        .props('selectedPatient').id
    ).toBe(84);
    expect(mocks.replace).toHaveBeenCalledWith({ query: { status: 'open' } });
  });

  it('refreshes an admitted binding in the current account and original chat owner', async () => {
    mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
    const chat = { id: 123, meta: { sender: { id: 42 } } };
    const wrapper = mountComponent(chat);
    await flushPromises();
    wrapper
      .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
      .vm.$emit('patientBound', {
        account_id: 1,
        contact_id: 42,
        patient_contact_id: 84,
      });
    await flushPromises();
    const store = useConversationPatientContextStore();
    expect(store.selectedPatient('1:9:conversation:123').id).toBe(84);
    expect(SchedulingContactsAPI.patients).toHaveBeenCalledTimes(2);
    expect(wrapper.props('currentChat')).toEqual(chat);
  });

  it.each([
    { accountId: 2, contactId: 42 },
    { accountId: 1, contactId: 77 },
    {},
  ])(
    'rejects a binding outside the current account/contact scope: %j',
    async scope => {
      mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
      SchedulingContactsAPI.patients.mockResolvedValue(patientsResponse());
      const wrapper = mountComponent({ id: 123, meta: { sender: { id: 42 } } });
      await flushPromises();
      const store = useConversationPatientContextStore();
      const key = '1:9:conversation:123';
      store.select(key, 85);
      await flushPromises();
      const previousSelections = window.localStorage.getItem(
        PATIENT_SELECTION_STORAGE_KEY
      );
      wrapper
        .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
        .vm.$emit('patientBound', { ...scope, patientContactId: 84 });
      await flushPromises();
      expect(SchedulingContactsAPI.patients).toHaveBeenCalledTimes(1);
      expect(store.selectedPatient(key).id).toBe(85);
      expect(window.localStorage.getItem(PATIENT_SELECTION_STORAGE_KEY)).toBe(
        previousSelections
      );
    }
  );

  it.each(['patient', 'chat', 'account'])(
    'keeps patient B selected when an admitted binding refresh finishes after a %s switch',
    async changedScope => {
      mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
      SchedulingContactsAPI.patients.mockResolvedValue(patientsResponse());
      const wrapper = mountComponent({ id: 123, meta: { sender: { id: 42 } } });
      await flushPromises();
      const store = useConversationPatientContextStore();
      const key = '1:9:conversation:123';
      store.select(key, 84);
      const pending = deferredRequest();
      SchedulingContactsAPI.patients.mockReturnValueOnce(pending.promise);
      const refreshing = wrapper.vm.refreshBoundPatient({
        accountId: 1,
        contactId: 42,
        patientContactId: 84,
      });
      expect(SchedulingContactsAPI.patients).toHaveBeenCalledTimes(2);

      let nextKey = key;
      if (changedScope !== 'patient') {
        if (changedScope === 'account') {
          mocks.currentAccountId.value = 2;
          mocks.route.params.accountId = '2';
        }
        SchedulingContactsAPI.patients.mockResolvedValue(
          patientsResponse(changedScope === 'account' ? 2 : 1, 77)
        );
        await wrapper.setProps({
          currentChat: { id: 999, meta: { sender: { id: 77 } } },
        });
        nextKey = `${changedScope === 'account' ? 2 : 1}:9:conversation:999`;
        await flushPromises();
      }
      store.select(nextKey, 85);
      await flushPromises();
      const selectedBefore = window.localStorage.getItem(
        PATIENT_SELECTION_STORAGE_KEY
      );
      pending.resolve(patientsResponse());
      await refreshing;
      await flushPromises();
      expect(store.selectedPatient(nextKey).id).toBe(85);
      expect(store.selections[nextKey]).toBe(85);
      expect(
        JSON.parse(window.localStorage.getItem(PATIENT_SELECTION_STORAGE_KEY))
      ).toEqual(JSON.parse(selectedBefore));
      expect(
        wrapper
          .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
          .props('selectedPatient').id
      ).toBe(85);
    }
  );

  it('refreshes a cached patient list when returning to an appointment added by another operator', async () => {
    mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
    const chat = { id: 123, meta: { sender: { id: 42 } } };
    const pinia = createPinia();
    const first = mountComponent(chat, pinia);
    await flushPromises();
    const store = useConversationPatientContextStore();
    const cached = store.contexts['1:9:conversation:123'];
    cached.patients = cached.patients.filter(patient => patient.id === 42);
    first.unmount();
    mocks.route.query = { patientContactId: '84', patientChatContactId: '42' };
    const wrapper = mountComponent(chat, pinia);
    await flushPromises();
    expect(SchedulingContactsAPI.patients).toHaveBeenCalledTimes(2);
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
        .props('selectedPatient').id
    ).toBe(84);
  });

  it('moves the mobile drawer off-canvas when no sidebar tab is open', () => {
    mocks.width.value = 390;
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toContain('ltr:translate-x-full');
    expect(wrapper.classes()).toContain('rtl:-translate-x-full');
    expect(wrapper.classes()).toContain('pointer-events-none');
  });

  it('keeps the mobile drawer visible after the contact button is used', async () => {
    mocks.width.value = 390;
    mocks.uiSettings = ref({
      is_contact_sidebar_open: true,
    });

    const wrapper = mountComponent();
    const panel = useConversationSidepanelAvailability();
    panel.openPanel('contact');
    expect(panel.activePanel.value).toBe('contact');
    await flushPromises();

    expect(wrapper.classes()).toContain('translate-x-0');
    expect(wrapper.classes()).not.toContain('pointer-events-none');
  });

  it('uses contact-sized width for the deal sidebar', () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: true,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toEqual(
      expect.arrayContaining([
        'max-w-sm',
        'md:w-[320px]',
        'md:min-w-[320px]',
        '2xl:w-[360px]',
        '2xl:min-w-[360px]',
      ])
    );
    expect(wrapper.classes()).not.toContain('md:w-[28rem]');
    expect(wrapper.classes()).not.toContain('xl:w-[30rem]');
  });

  it('renders the deals panel independently from navigation visibility', () => {
    mocks.currentAccount.value = {
      settings: {
        dashboard_sidebar_hidden_items: [
          'Conversation:Pipelines',
          'Conversation:AppointmentStatuses',
        ],
        dashboard_sidebar_hidden_items_version: 13,
      },
    };
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: true,
      is_scheduling_appointments_panel_open: false,
    });

    const wrapper = mountComponent();

    expect(
      wrapper.findComponent({ name: 'CrmConversationDealsSidebar' }).exists()
    ).toBe(true);
  });

  it('renders the appointments panel independently from navigation visibility', () => {
    mocks.currentAccount.value = {
      settings: {
        dashboard_sidebar_hidden_items: [
          'Conversation:Pipelines',
          'Conversation:AppointmentStatuses',
        ],
        dashboard_sidebar_hidden_items_version: 13,
      },
    };
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: true,
    });

    const wrapper = mountComponent();

    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
        .exists()
    ).toBe(true);
  });

  it('does not render persisted deals or appointments panels that are unavailable', () => {
    mocks.permissions = ['custom_role'];
    mocks.isFeatureEnabledonAccount.value = (_accountId, feature) =>
      feature !== 'scheduling';
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: true,
      is_scheduling_appointments_panel_open: true,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toContain('ltr:translate-x-full');
    expect(wrapper.classes()).toContain('pointer-events-none');
    expect(
      wrapper.findComponent({ name: 'CrmConversationDealsSidebar' }).exists()
    ).toBe(false);
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
        .exists()
    ).toBe(false);
  });

  it('uses the active reply conversation for communication thread contact sidebar', async () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: true,
    });

    const wrapper = mountComponent({
      id: 10,
      inbox_id: 2,
      is_communication_thread: true,
      active_reply_channel: {
        conversation_id: 101,
        inbox_id: 202,
      },
    });
    await flushPromises();

    const contactPanel = wrapper.findComponent({ name: 'ContactPanel' });
    expect(contactPanel.props('conversationId')).toBe(101);
    expect(contactPanel.props('inboxId')).toBe(202);
  });

  it('keeps the drawer closed for a persisted reminders panel flag', async () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_touch_sidebar_open: true,
    });

    const wrapper = mountComponent({ id: 12, inbox_id: 2 });
    await flushPromises();

    expect(wrapper.classes()).toContain('ltr:translate-x-full');
    expect(wrapper.classes()).toContain('pointer-events-none');
    expect(wrapper.findComponent({ name: 'ContactPanel' }).exists()).toBe(
      false
    );
    expect(wrapper.text()).toBe('');
  });

  describe('the empty dialog of a person', () => {
    const draft = {
      id: 'draft-42',
      is_draft: true,
      person_contact_id: 42,
      is_communication_thread: true,
      meta: { sender: { id: 42, name: 'Owner' } },
      channels: [],
    };

    it('gives the contact panel no conversation id: no request may carry the screen id', async () => {
      mocks.uiSettings = ref({ is_contact_sidebar_open: true });

      const wrapper = mountComponent(draft);
      await flushPromises();

      expect(
        wrapper.findComponent({ name: 'ContactPanel' }).props('conversationId')
      ).toBe('');
    });

    it('shows no deals panel, which belongs to a conversation', async () => {
      mocks.uiSettings = ref({ is_crm_deal_panel_open: true });

      const wrapper = mountComponent(draft);
      await flushPromises();

      expect(
        wrapper.findComponent({ name: 'CrmConversationDealsSidebar' }).exists()
      ).toBe(false);
    });

    it('shows the patients of the person in the appointments panel', async () => {
      mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });

      const wrapper = mountComponent(draft);
      await flushPromises();

      expect(SchedulingContactsAPI.patients).toHaveBeenCalledWith(42);
      expect(
        wrapper
          .findComponent({ name: 'SchedulingConversationAppointmentsSidebar' })
          .exists()
      ).toBe(true);
    });

    it('keeps the patient that was selected for the empty dialog once the first message made the dialog', async () => {
      mocks.uiSettings = ref({ is_scheduling_appointments_panel_open: true });
      const wrapper = mountComponent(draft);
      await flushPromises();
      const store = useConversationPatientContextStore();
      store.select('1:9:person:42', 84);
      await flushPromises();

      await wrapper.setProps({
        currentChat: {
          id: 77,
          is_communication_thread: true,
          meta: { sender: { id: 42, name: 'Owner' } },
        },
      });
      await flushPromises();

      expect(store.selectedPatient('1:9:thread:77').id).toBe(84);
    });
  });
});
