import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { ref } from 'vue';

import ru from 'dashboard/i18n/locale/ru/conversation.json';
import PersonDialogEmptyState from './PersonDialogEmptyState.vue';

const openPersonDialog = vi.hoisted(() => vi.fn());
const routerResolve = vi.hoisted(() => vi.fn());
const chat = vi.hoisted(() => ({ value: {} }));

const EMPTY = ru.PERSON_DIALOG.EMPTY;
const text = (template, params = {}) =>
  Object.entries(params).reduce(
    (result, [key, value]) => result.replaceAll(`{${key}}`, value),
    template
  );

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => {
      const leaf = key.split('.').pop();
      return text(ru.PERSON_DIALOG.EMPTY[leaf] ?? key, params);
    },
  }),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ resolve: routerResolve }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref(chat.value),
  useStore: () => ({}),
}));

vi.mock('dashboard/composables/useOpenPersonDialog', () => ({
  useOpenPersonDialog: () => ({ openPersonDialog }),
}));

const ButtonStub = {
  props: ['label'],
  emits: ['click'],
  template: '<button @click="$emit(\'click\')">{{ label }}</button>',
};

const mountState = (draft, props = {}) => {
  chat.value = {
    id: 'draft-5',
    is_draft: true,
    is_communication_thread: true,
    person_contact_id: 5,
    meta: { sender: { id: 5, phone_number: '+77011234567' } },
    channels: [],
    ...draft,
  };
  return mount(PersonDialogEmptyState, {
    props,
    global: { stubs: { Button: ButtonStub, Icon: true } },
  });
};

const templateOnlyWhatsapp = {
  conversation_id: null,
  inbox_id: 12,
  channel: 'Channel::Whatsapp',
  channel_key: 'inbox:12',
  requires_template: true,
  can_reply: false,
  can_send_text: false,
};

describe('PersonDialogEmptyState', () => {
  beforeEach(() => {
    openPersonDialog.mockReset();
    routerResolve.mockReset();
    routerResolve.mockReturnValue({ href: '/app/accounts/3/contacts/5' });
  });

  it('says the first message can be written and the dialog will appear in the list', () => {
    const wrapper = mountState({
      channels: [
        {
          conversation_id: null,
          inbox_id: 13,
          channel: 'Channel::Sms',
          channel_key: 'inbox:13',
          can_reply: true,
          can_send_text: true,
        },
      ],
    });

    expect(wrapper.find('[data-kind]').attributes('data-kind')).toBe('default');
    expect(wrapper.text()).toContain(EMPTY.DEFAULT);
  });

  it('explains that WhatsApp opens with a template when that is the channel in front', () => {
    const wrapper = mountState({ channels: [templateOnlyWhatsapp] });

    expect(wrapper.text()).toContain(EMPTY.WHATSAPP_TEMPLATE);
  });

  it('follows the channel the reply box has selected', () => {
    const sms = {
      conversation_id: null,
      inbox_id: 13,
      channel: 'Channel::Sms',
      channel_key: 'inbox:13',
      can_reply: true,
      can_send_text: true,
    };

    const onWhatsapp = mountState({ channels: [templateOnlyWhatsapp, sms] });
    const onSms = mountState(
      { channels: [templateOnlyWhatsapp, sms] },
      { selectedChannelKey: 'inbox:13' }
    );

    expect(onWhatsapp.text()).toContain(EMPTY.WHATSAPP_TEMPLATE);
    expect(onSms.text()).toContain(EMPTY.DEFAULT);
  });

  it('asks for a phone number and opens the card in a new tab', async () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    const wrapper = mountState({
      channels: [],
      meta: { sender: { id: 5 } },
    });

    expect(wrapper.text()).toContain(EMPTY.NEEDS_PHONE);

    await wrapper
      .find('[data-test-id="person-dialog-open-card"]')
      .trigger('click');

    expect(routerResolve).toHaveBeenCalledWith({
      name: 'contacts_edit',
      params: { contactId: 5 },
    });
    expect(open).toHaveBeenCalledWith(
      '/app/accounts/3/contacts/5',
      '_blank',
      'noopener'
    );
    open.mockRestore();
  });

  it('offers to write to the holder of a shared number, naming the patient', async () => {
    const wrapper = mountState({
      channels: [],
      meta: { sender: { id: 5 } },
      shared_phone_holder: { id: 9, name: 'Aigul' },
    });

    expect(wrapper.text()).toContain(
      text(EMPTY.SHARED_PHONE, { name: 'Aigul' })
    );

    await wrapper
      .find('[data-test-id="person-dialog-write-to-holder"]')
      .trigger('click');

    expect(openPersonDialog).toHaveBeenCalledWith(9, { patientContactId: 5 });
  });

  it('says the user has no messenger for the person', () => {
    const wrapper = mountState({ channels: [] });

    expect(wrapper.text()).toContain(EMPTY.NO_ACCESS);
  });

  it('says a blocked contact must be unblocked first', () => {
    const wrapper = mountState({
      channels: [templateOnlyWhatsapp],
      blocked: true,
    });

    expect(wrapper.text()).toContain(EMPTY.BLOCKED);
  });
});
