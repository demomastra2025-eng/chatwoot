import { describe, expect, it } from 'vitest';
import { createStore } from 'vuex';

import inboxes from 'dashboard/store/modules/inboxes';
import ReplyBox from './ReplyBox.vue';

const template = (name, extra = {}) => ({
  name,
  language: 'ru',
  status: 'APPROVED',
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
  ...extra,
});

const storeWithTemplates = messageTemplates =>
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

// The template button of the reply box follows the same templates as the
// picker it opens: the ones visible in conversations.
const showWhatsappTemplates = store =>
  ReplyBox.computed.showWhatsappTemplates.call({
    $store: store,
    inboxId: 7,
    isCommunicationCallReplyAction: false,
    isPrivate: false,
  });

describe('ReplyBox WhatsApp template button', () => {
  it('is offered while a template is visible in conversations', () => {
    expect(
      showWhatsappTemplates(
        storeWithTemplates([
          template('order_update'),
          template('automation_only', {
            visible_in_conversation_picker: false,
          }),
        ])
      )
    ).toBe(true);
  });

  it('is hidden when an admin hid every template from conversations', () => {
    expect(
      showWhatsappTemplates(
        storeWithTemplates([
          template('automation_only', {
            visible_in_conversation_picker: false,
          }),
        ])
      )
    ).toBe(false);
  });
});
