import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { createStore } from 'vuex';

import inboxes from 'dashboard/store/modules/inboxes';
import TemplatesPicker from './TemplatesPicker.vue';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const template = (name, extra = {}) => ({
  name,
  language: 'ru',
  status: 'APPROVED',
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
  ...extra,
});

// The real inboxes getters: the picker must use the conversation getter,
// which drops templates an admin hid from conversations.
const buildStore = messageTemplates =>
  createStore({
    modules: {
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [
            {
              id: 7,
              channel_type: 'Channel::Whatsapp',
              message_templates: messageTemplates,
            },
          ],
        }),
      },
    },
  });

const mountPicker = store =>
  mount(TemplatesPicker, {
    props: { inboxId: 7 },
    global: {
      plugins: [store],
      stubs: { FluentIcon: true, 'fluent-icon': true, Icon: true },
    },
  });

describe('TemplatesPicker', () => {
  it('lists only the templates visible in conversations', () => {
    const wrapper = mountPicker(
      buildStore([
        template('order_update'),
        template('automation_only', { visible_in_conversation_picker: false }),
      ])
    );

    expect(wrapper.text()).toContain('order_update');
    expect(wrapper.text()).not.toContain('automation_only');
  });

  it('shows the empty state when every template is hidden', () => {
    const wrapper = mountPicker(
      buildStore([
        template('automation_only', { visible_in_conversation_picker: false }),
      ])
    );

    expect(wrapper.text()).toContain(
      'WHATSAPP_TEMPLATES.PICKER.NO_APPROVED_TEMPLATES'
    );
  });

  it('lists only approved templates, never one WhatsApp has not approved', () => {
    const wrapper = mountPicker(
      buildStore([
        template('order_update'),
        template('waiting_one', { status: 'PENDING' }),
        template('appeal_one', { status: 'IN_APPEAL' }),
        template('refused_one', { status: 'REJECTED' }),
        template('paused_one', { status: 'PAUSED' }),
        template('stopped_one', { status: 'DISABLED' }),
      ])
    );

    expect(wrapper.text()).toContain('order_update');
    [
      'waiting_one',
      'appeal_one',
      'refused_one',
      'paused_one',
      'stopped_one',
    ].forEach(name => expect(wrapper.text()).not.toContain(name));
  });

  it('shows the empty state, not a list, while every template waits for review', () => {
    const wrapper = mountPicker(
      buildStore([
        template('waiting_one', { status: 'PENDING' }),
        template('waiting_two', { status: 'PENDING' }),
        template('waiting_three', { status: 'PENDING' }),
      ])
    );

    expect(wrapper.text()).not.toContain('waiting_');
    expect(wrapper.text()).toContain(
      'WHATSAPP_TEMPLATES.PICKER.NO_APPROVED_TEMPLATES'
    );
    expect(wrapper.text()).toContain(
      'WHATSAPP_TEMPLATES.PICKER.TEMPLATES_IN_REVIEW'
    );
  });
});
