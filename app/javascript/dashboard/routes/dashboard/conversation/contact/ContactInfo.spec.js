import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactInfo from './ContactInfo.vue';
import SocialIcons from './SocialIcons.vue';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSIONS,
} from 'dashboard/constants/permissions';

const routerPushMock = vi.fn();
const dispatchMock = vi.fn();
const updateUISettingsMock = vi.fn();
const useAdminMock = vi.fn();
const useUISettingsMock = vi.fn();

vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: (...args) => useAdminMock(...args),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: (...args) => useUISettingsMock(...args),
}));

vi.mock('dashboard/components-next/Contacts/VoiceCallButton.vue', () => ({
  default: {
    name: 'VoiceCallButton',
    template: '<div />',
  },
}));

const createStore = (
  conversations,
  showActions = false,
  contactAttributes = [],
  contactsById = {}
) => ({
  getters: {
    getCurrentAccountId: 1,
    'attributes/getAttributesByModel': () => contactAttributes,
    'contacts/getContact': id => contactsById[id] || null,
    getCurrentUser: {
      accounts: [
        {
          id: 1,
          permissions: showActions
            ? [...CRM_DEAL_MANAGE_PERMISSIONS, ...CRM_TASK_MANAGE_PERMISSIONS]
            : [],
        },
      ],
    },
    'accounts/isFeatureEnabledonAccount': () => showActions,
    'contacts/getUIFlags': {},
    'agents/getVerifiedAgents': [
      { id: 7, name: 'Aigerim Agent' },
      { id: 9, name: 'Bob Agent' },
    ],
    'contactConversations/getAllConversationsByContactId': () => conversations,
  },
  state: {
    contactConversations: {
      records: {
        154: true,
      },
    },
  },
  dispatch: dispatchMock,
});

const buildWrapper = ({
  conversations = [],
  contact = {},
  showActions = false,
  canAddFamilyMember = false,
  contactAttributes = [],
  selectedPatient = null,
  patientContextEnabled = false,
  contactsById = {},
} = {}) =>
  shallowMount(ContactInfo, {
    props: {
      canAddFamilyMember,
      selectedPatient,
      patientContextEnabled,
      contact: {
        id: 154,
        name: 'Jane Doe',
        additional_attributes: {},
        ...contact,
      },
    },
    global: {
      mocks: {
        $route: {
          name: 'inbox_view_conversation',
          params: {
            accountId: '1',
            id: '138',
          },
        },
        $router: {
          push: routerPushMock,
        },
        $store: createStore(
          conversations,
          showActions,
          contactAttributes,
          contactsById
        ),
        $t: key => key,
      },
      stubs: {
        Avatar: true,
        ContactChannelLabels: true,
        ContactInfoRow: true,
        ContactMergeModal: true,
        CrmConversationDealsSidebar: true,
        CrmContactTaskDrawer: true,
        SchedulingConversationAppointmentsSidebar: true,
        ComboBox: true,
        EditContact: true,
        NextButton: true,
        SocialIcons: true,
        VoiceCallButton: true,
        'woot-delete-modal': true,
      },
    },
  });

describe('ContactInfo', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    routerPushMock.mockReset();
    updateUISettingsMock.mockReset();

    useAdminMock.mockReturnValue({
      isAdmin: false,
    });
    useUISettingsMock.mockReturnValue({
      updateUISettings: updateUISettingsMock,
    });

    window.history.replaceState({}, '', '/');
  });

  it('keeps name and phone beside the avatar without inline pencil icon and omits MedElement or country subtitle', async () => {
    const wrapper = buildWrapper({
      contact: {
        phone_number: '+77000000001',
        additional_attributes: { country: 'Kazakhstan' },
      },
    });
    const header = wrapper.get('[data-test="contact-header"]');
    const heading = header.find('h3');
    expect(heading.classes()).toContain('line-clamp-2');
    expect(heading.find('.i-lucide-pencil').exists()).toBe(false);
    expect(header.findComponent({ name: 'ContactInfoRow' }).exists()).toBe(
      true
    );
    expect(header.find('[data-test="contact-header-meta"]').exists()).toBe(
      false
    );
    expect(
      wrapper.findComponent({ name: 'ContactChannelLabels' }).exists()
    ).toBe(false);

    await heading.trigger('click');
    expect(wrapper.vm.isEditingName).toBe(true);
  });

  it('shows 3 grey square NextButton profile actions without delete button even for admins', async () => {
    useAdminMock.mockReturnValue({ isAdmin: true });
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null);
    const wrapper = buildWrapper({
      showActions: true,
      canAddFamilyMember: true,
    });
    const actions = wrapper.get('[data-test="contact-panel-actions"]');
    const buttons = actions.findAllComponents({ name: 'NextButton' });
    expect(buttons).toHaveLength(3);
    expect(buttons.map(btn => btn.props('icon'))).toEqual([
      'i-ph-pencil-simple',
      'i-ph-arrows-merge',
      'i-lucide-external-link',
    ]);
    buttons.forEach(btn => {
      expect(btn.attributes('slate')).toBeDefined();
      expect(btn.attributes('faded')).toBeDefined();
      expect(btn.attributes('sm')).toBeDefined();
    });
    expect(actions.find('.i-lucide-trash-2').exists()).toBe(false);

    await buttons[2].vm.$emit('click');
    expect(openSpy).toHaveBeenCalledWith(
      '/app/accounts/1/contacts/154',
      '_blank',
      'noopener,noreferrer'
    );
    openSpy.mockRestore();
  });

  it('renders monochrome social profile chips with @handle text, without double @, and ignores whitespace/@-only values', () => {
    const wrapper = shallowMount(SocialIcons, {
      props: {
        socialProfiles: {
          telegram: 'asselya_k',
          instagram: '@clinic_kz',
          twitter: '   ',
          tiktok: '@@@',
        },
      },
      global: {
        mocks: {
          $t: key => key,
        },
        stubs: {
          'fluent-icon': true,
        },
      },
    });
    const tg = wrapper.get('[data-test="social-profile-telegram"]');
    const ig = wrapper.get('[data-test="social-profile-instagram"]');
    expect(tg.text()).toBe('@asselya_k');
    expect(tg.get('a').attributes('href')).toBe('https://t.me/asselya_k');
    expect(ig.text()).toBe('@clinic_kz');
    expect(ig.get('a').attributes('href')).toBe(
      'https://instagram.com/clinic_kz'
    );
    expect(wrapper.find('[data-test="social-profile-twitter"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-test="social-profile-tiktok"]').exists()).toBe(
      false
    );

    const contactWrapper = buildWrapper({
      contact: {
        additional_attributes: {
          social_instagram_user_name: 'dent_almaty',
        },
        channel_profiles: [
          { provider: 'telegram_personal', username: 'onelink_manager' },
        ],
      },
    });
    expect(contactWrapper.vm.socialProfiles).toMatchObject({
      telegram: 'onelink_manager',
      instagram: 'dent_almaty',
    });
  });

  it('has no button that opens a message to the person whose dialog is already open', () => {
    const wrapper = buildWrapper();

    expect(
      wrapper.findComponent({ name: 'ComposeConversation' }).exists()
    ).toBe(false);
    expect(wrapper.vm.openChannelConversation).toBeUndefined();
  });

  it('marks only non-resolved inbox conversations as active', () => {
    const wrapper = buildWrapper({
      conversations: [
        { id: 42, inboxId: 7, status: 'resolved' },
        { id: 43, inboxId: 8, status: 'open' },
      ],
    });

    expect(wrapper.vm.existingConversationInboxIds).toEqual([8]);
  });

  it('closes the edit contact modal when the modal show model is set to false', async () => {
    const wrapper = buildWrapper();

    await wrapper.setData({ showEditModal: true });
    wrapper
      .findComponent({ name: 'EditContact' })
      .vm.$emit('update:show', false);

    expect(wrapper.vm.showEditModal).toBe(false);
  });

  it('keeps the contact owner in the edit modal instead of the panel', async () => {
    const wrapper = buildWrapper({
      contact: {
        owner_id: 7,
        owner: { id: 7, name: 'Aigerim Agent' },
      },
    });

    expect(wrapper.findComponent({ name: 'ComboBox' }).exists()).toBe(false);
    wrapper.vm.openEditModal();
    await wrapper.vm.$nextTick();
    expect(
      wrapper.findComponent({ name: 'EditContact' }).props('contact').owner_id
    ).toBe(7);
  });

  it('does not request contactable inboxes or conversations when contact id is missing', () => {
    buildWrapper({ contact: { id: undefined } });

    expect(dispatchMock).not.toHaveBeenCalledWith(
      'contacts/fetchContactableInbox',
      undefined
    );
    expect(dispatchMock).not.toHaveBeenCalledWith(
      'contactConversations/get',
      undefined
    );
  });
  it('renders automatic read-only client language percentage breakdown without manual dropdown', () => {
    const bilingualWrapper = buildWrapper({
      contact: {
        additional_attributes: {
          client_language: 'ru',
          client_language_source: 'ai',
          client_language_confidence: 70,
          client_language_breakdown: [
            { code: 'ru', percentage: 70 },
            { code: 'kk', percentage: 30 },
          ],
        },
      },
    });

    const row = bilingualWrapper.get(
      '[data-test="contact-client-language-row"]'
    );
    expect(row.text()).toContain('Язык');
    expect(
      bilingualWrapper
        .get('[data-testid="contact-client-language-badge"]')
        .text()
    ).toBe('Русский 70% · Казахский 30%');
    expect(
      bilingualWrapper
        .find('[data-testid="contact-preferred-language-select"]')
        .exists()
    ).toBe(false);

    const emptyWrapper = buildWrapper({
      contact: { additional_attributes: {} },
    });
    expect(
      emptyWrapper.get('[data-testid="contact-client-language-badge"]').text()
    ).toBe('—');
  });

  it('renders always-open Contact Dossier with formatted birth date, IIN, gender, secondary phones, address, extra custom attributes, and filters out MedElement sync keys', async () => {
    const wrapper = buildWrapper({
      contact: {
        identifier: 'captain-playground-d446541d-98b6-43b9-bc63-dd6b8398caf6',
        custom_attributes: {
          iin: '900515300123',
          birth_date: '1990-05-15',
          gender: 'female',
          secondary_phones: '+77019998877',
          address: 'г. Алматы, пр. Абая 10',
          allergies: 'Пенициллин',
          medelement_patient_code: 'ME-991',
          medelement_last_synced_at: '2026-10-28T10:00:00Z',
          medelement_first_name: 'Алия',
          medelement_last_name: 'Смагулова',
          medelement_middle_name: 'Сериковна',
          medelement_patient_lookup_at: '2026-10-28T10:00:00Z',
          medelement_patient_context_creation_requests: { req: 1 },
          phone_conflict_comment: 'conflict',
        },
      },
    });

    const dossier = wrapper.get('[data-testid="contact-dossier"]');
    expect(dossier.text()).toContain('Досье контакта');
    expect(
      dossier.get('[data-testid="contact-dossier-birth-date"]').text()
    ).toMatch(/15\.05\.1990 \(\d+ (лет|год|года)\)/);
    expect(dossier.get('[data-testid="contact-dossier-iin"]').text()).toContain(
      '900515300123'
    );
    expect(dossier.text()).not.toContain('captain-playground');
    expect(
      dossier.find('[data-testid="contact-dossier-iin-copy"]').exists()
    ).toBe(true);
    expect(
      dossier.get('[data-testid="contact-dossier-gender"]').text()
    ).toContain('Женский');
    expect(
      dossier.get('[data-testid="contact-dossier-secondary-phones"]').text()
    ).toContain('+77019998877');
    expect(
      dossier.get('[data-testid="contact-dossier-address"]').text()
    ).toContain('г. Алматы, пр. Абая 10');
    expect(
      dossier.get('[data-testid="contact-dossier-attr-allergies"]').text()
    ).toContain('Пенициллин');

    const wrapperWithAttrMeta = buildWrapper({
      contact: { custom_attributes: { allergies: 'Пенициллин' } },
      contactAttributes: [
        {
          attribute_key: 'allergies',
          attribute_display_name: 'Аллергии',
          attribute_description: 'Укажите лекарственную аллергию пациента',
        },
      ],
    });
    const attrRow = wrapperWithAttrMeta.get(
      '[data-testid="contact-dossier-attr-allergies"]'
    );
    expect(attrRow.text()).toContain('Аллергии');
    const hintStub = attrRow.findComponent({
      name: 'CrmCustomFieldDescriptionHint',
    });
    expect(hintStub.exists()).toBe(true);
    expect(hintStub.props('description')).toBe(
      'Укажите лекарственную аллергию пациента'
    );

    expect(dossier.text()).not.toContain('ME-991');
    expect(dossier.text()).not.toContain('medelement_patient_code');
    expect(dossier.text()).not.toContain('medelement_last_synced_at');
    expect(dossier.text()).not.toContain('medelement_patient_lookup_at');
    expect(dossier.text()).not.toContain('[object Object]');
    expect(dossier.text()).not.toContain('phone_conflict_comment');
    expect(
      dossier.find('[data-testid="contact-preferred-language-select"]').exists()
    ).toBe(false);
  });

  it('toggles contact notifications_muted in one click and shows muted status when enabled', async () => {
    dispatchMock.mockResolvedValue({ id: 154, notifications_muted: true });
    const wrapper = buildWrapper({
      contact: { notifications_muted: false },
    });

    const toggle = wrapper.getComponent(
      '[data-testid="contact-notifications-muted-toggle"]'
    );
    expect(toggle.props('modelValue')).toBe(false);
    expect(
      wrapper
        .find('[data-testid="contact-notifications-muted-status"]')
        .exists()
    ).toBe(false);

    await toggle.vm.$emit('change', true);
    expect(dispatchMock).toHaveBeenCalledWith('contacts/update', {
      id: 154,
      notifications_muted: true,
    });

    const mutedWrapper = buildWrapper({
      contact: { notifications_muted: true },
    });
    expect(
      mutedWrapper
        .getComponent('[data-testid="contact-notifications-muted-toggle"]')
        .props('modelValue')
    ).toBe(true);
    expect(
      mutedWrapper
        .find('[data-testid="contact-notifications-muted-status"]')
        .exists()
    ).toBe(true);
  });

  it('allows muting a separate selected shared-phone patient card without muting the chat owner', async () => {
    dispatchMock.mockResolvedValue({ id: 999, notifications_muted: true });
    const wrapper = buildWrapper({
      contact: { id: 154, name: 'Phone Holder', notifications_muted: false },
      patientContextEnabled: true,
      selectedPatient: {
        id: 999,
        full_name: 'Пмсп',
        notifications_muted: false,
      },
    });

    const patientRow = wrapper.find(
      '[data-testid="patient-notifications-muted-row"]'
    );
    expect(patientRow.exists()).toBe(true);
    const patientToggle = wrapper.getComponent(
      '[data-testid="patient-notifications-muted-toggle"]'
    );
    expect(patientToggle.props('modelValue')).toBe(false);

    await patientToggle.vm.$emit('change', true);
    expect(dispatchMock).toHaveBeenCalledWith('contacts/update', {
      id: 999,
      notifications_muted: true,
    });
  });
});
