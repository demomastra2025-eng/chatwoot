import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { createStore } from 'vuex';

import inboxes from 'dashboard/store/modules/inboxes';
import TemplatesEmptyState from './TemplatesEmptyState.vue';

// Show the values the sentences are built from, not a translation.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      params.count === undefined ? key : `${key}|${params.count}`,
  }),
}));

const template = (name, status, language = 'ru') => ({
  name,
  language,
  status,
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
});

const cloudInbox = (messageTemplates, extra = {}) => ({
  id: 272,
  channel_type: 'Channel::Whatsapp',
  provider: 'whatsapp_cloud',
  message_templates: messageTemplates,
  ...extra,
});

const buildStore = ({
  inbox,
  role = 'administrator',
  inboxManagement = true,
} = {}) =>
  createStore({
    getters: {
      getCurrentRole: () => role,
      getCurrentAccountId: () => 97,
      'accounts/isFeatureEnabledonAccount': () => () => inboxManagement,
    },
    modules: {
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [inbox],
        }),
      },
    },
  });

const mountEmptyState = options =>
  mount(TemplatesEmptyState, {
    props: { inboxId: 272 },
    global: { plugins: [buildStore(options)] },
  });

const link = wrapper =>
  wrapper.find('[data-test-id="whatsapp-templates-settings-link"]');

describe('WhatsApp templates empty state', () => {
  it('says there is nothing approved and how many are still in review', () => {
    // the production case: three templates, none approved yet
    const wrapper = mountEmptyState({
      inbox: cloudInbox([
        template('reminder_24h', 'PENDING'),
        template('reminder_2h', 'PENDING'),
        template('hello', 'PENDING'),
      ]),
    });

    expect(wrapper.find('p').text()).toBe(
      'WHATSAPP_TEMPLATES.PICKER.NO_APPROVED_TEMPLATES WHATSAPP_TEMPLATES.PICKER.TEMPLATES_IN_REVIEW|3'
    );
    expect(link(wrapper).text()).toBe(
      'WHATSAPP_TEMPLATES.PICKER.OPEN_TEMPLATES_SETTINGS'
    );
  });

  it('does not claim nothing is approved when approved templates cannot be sent', () => {
    // approved, but hidden from conversations / the survey template: WhatsApp
    // did approve them, so «нет одобренных» would be untrue
    const wrapper = mountEmptyState({
      inbox: cloudInbox([
        {
          ...template('hidden_offer', 'APPROVED'),
          visible_in_conversation_picker: false,
        },
        template('customer_satisfaction_survey', 'APPROVED'),
        template('hello', 'PENDING'),
      ]),
    });

    expect(wrapper.find('p').text()).toBe(
      'WHATSAPP_TEMPLATES.PICKER.NO_TEMPLATES_TO_SEND WHATSAPP_TEMPLATES.PICKER.TEMPLATES_IN_REVIEW|1'
    );
    expect(wrapper.text()).not.toContain('NO_APPROVED_TEMPLATES');
  });

  it('counts a template once even when it waits in several languages', () => {
    const wrapper = mountEmptyState({
      inbox: cloudInbox([
        template('reminder', 'PENDING', 'ru'),
        template('reminder', 'PENDING', 'kk'),
        template('hello', 'IN_APPEAL'),
      ]),
    });

    expect(wrapper.text()).toContain('TEMPLATES_IN_REVIEW|2');
  });

  it('leaves out the review sentence when no template is waiting', () => {
    const wrapper = mountEmptyState({
      inbox: cloudInbox([
        template('old_offer', 'REJECTED'),
        template('paused_one', 'PAUSED'),
      ]),
    });

    expect(wrapper.text()).toContain('NO_APPROVED_TEMPLATES');
    expect(wrapper.text()).not.toContain('TEMPLATES_IN_REVIEW');
  });

  it('leaves out the review sentence when the templates are not loaded', () => {
    const wrapper = mountEmptyState({ inbox: cloudInbox(undefined) });

    expect(wrapper.text()).toContain('NO_APPROVED_TEMPLATES');
    expect(wrapper.text()).not.toContain('TEMPLATES_IN_REVIEW');
  });

  it('links an administrator to the templates page of the inbox', () => {
    const wrapper = mountEmptyState({ inbox: cloudInbox([]) });

    expect(link(wrapper).attributes('href')).toBe(
      '/app/accounts/97/settings/inboxes/272/whatsapp-templates'
    );
    // a new tab keeps the conversation and the unsent draft open
    expect(link(wrapper).attributes('target')).toBe('_blank');
  });

  it('shows no link to someone who cannot open the inbox settings', () => {
    expect(
      link(mountEmptyState({ inbox: cloudInbox([]), role: 'agent' })).exists()
    ).toBe(false);
    expect(
      link(
        mountEmptyState({ inbox: cloudInbox([]), inboxManagement: false })
      ).exists()
    ).toBe(false);
  });

  it('shows no link when the inbox has no templates page', () => {
    // 360dialog and Twilio inboxes have no «Шаблоны» tab in the settings
    expect(
      link(
        mountEmptyState({ inbox: cloudInbox([], { provider: 'default' }) })
      ).exists()
    ).toBe(false);
    expect(
      link(
        mountEmptyState({
          inbox: {
            id: 272,
            channel_type: 'Channel::TwilioSms',
            medium: 'whatsapp',
          },
        })
      ).exists()
    ).toBe(false);
  });
});
