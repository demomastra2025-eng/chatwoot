import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import { createStore } from 'vuex';

import inboxes from 'dashboard/store/modules/inboxes';
import enContact from 'dashboard/i18n/locale/en/contact.json';
import enTemplates from 'dashboard/i18n/locale/en/whatsappTemplates.json';
import WhatsAppOptions from './WhatsAppOptions.vue';

const OPTIONS = enContact.COMPOSE_NEW_CONVERSATION.FORM.WHATSAPP_OPTIONS;
const PICKER = enTemplates.WHATSAPP_TEMPLATES.PICKER;

const template = (name, status) => ({
  id: name,
  name,
  language: 'ru',
  status,
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
});

const buildStore = messageTemplates =>
  createStore({
    getters: {
      getCurrentRole: () => 'administrator',
      getCurrentAccountId: () => 97,
      'accounts/isFeatureEnabledonAccount': () => () => true,
    },
    modules: {
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [
            {
              id: 272,
              channel_type: 'Channel::Whatsapp',
              provider: 'whatsapp_cloud',
              message_templates: messageTemplates,
            },
          ],
        }),
      },
    },
  });

// the WhatsApp button of the «new conversation» form, with its menu open
const openMenu = async messageTemplates => {
  const wrapper = mount(WhatsAppOptions, {
    props: { inboxId: 272 },
    global: {
      plugins: [buildStore(messageTemplates)],
      stubs: { WhatsappTemplate: true },
    },
  });
  await wrapper.find('button').trigger('click');
  return wrapper;
};

const emptyState = wrapper =>
  wrapper.find('[data-test-id="whatsapp-templates-empty"]');

describe('new conversation WhatsApp templates menu', () => {
  it('explains the empty list the same way as a conversation does', async () => {
    const wrapper = await openMenu([
      template('reminder_24h', 'PENDING'),
      template('reminder_2h', 'PENDING'),
      template('hello', 'PENDING'),
    ]);

    expect(emptyState(wrapper).exists()).toBe(true);
    expect(emptyState(wrapper).text()).toContain(PICKER.NO_APPROVED_TEMPLATES);
    expect(emptyState(wrapper).text()).toContain(
      PICKER.TEMPLATES_IN_REVIEW.replace('{count}', '3')
    );
    // nothing that is still in review can be picked
    expect(wrapper.text()).not.toContain('reminder_24h');
    expect(wrapper.text()).not.toContain(OPTIONS.EMPTY_STATE);
  });

  it('lists the approved templates and nothing else', async () => {
    const wrapper = await openMenu([
      template('order_update', 'APPROVED'),
      template('reminder_24h', 'PENDING'),
      template('old_offer', 'REJECTED'),
    ]);

    expect(emptyState(wrapper).exists()).toBe(false);
    expect(wrapper.text()).toContain('order_update');
    expect(wrapper.text()).not.toContain('reminder_24h');
    expect(wrapper.text()).not.toContain('old_offer');
  });

  it('keeps «No templates found» for a search that finds nothing', async () => {
    const wrapper = await openMenu([template('order_update', 'APPROVED')]);

    await wrapper.find('input[type="search"]').setValue('zzz');

    expect(wrapper.text()).toContain(OPTIONS.EMPTY_STATE);
    expect(emptyState(wrapper).exists()).toBe(false);
  });
});
