import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { computed, h, ref } from 'vue';

import { messageTimestamp } from 'shared/helpers/timeHelper';
import { MESSAGE_TYPES, MESSAGE_VARIANTS, ORIENTATION } from '../constants';
import { provideMessageContext } from '../provider.js';
import VoiceCall from './VoiceCall.vue';

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref(() => []),
}));

vi.mock('dashboard/composables/useTransformKeys', () => ({
  useSnakeCase: value => value,
}));

const buildWrapper = contextOverrides => {
  const context = {
    content: ref('WhatsApp Call'),
    conversationId: ref(42),
    createdAt: ref(1776346354),
    currentUserId: ref(7),
    id: ref(100),
    inboxId: ref(84),
    groupWithNext: ref(false),
    isEmailInbox: ref(false),
    private: ref(false),
    senderId: ref(9),
    error: ref(null),
    attachments: ref([]),
    contentAttributes: ref({
      data: {
        status: 'ringing',
        meta: {
          created_at: 1776346354,
          ringing_at: 1776346354,
        },
      },
    }),
    contentType: ref('voice_call'),
    status: ref('sent'),
    messageType: ref(MESSAGE_TYPES.INCOMING),
    inReplyTo: ref(null),
    senderType: ref('Contact'),
    sender: ref(null),
    orientation: computed(() => ORIENTATION.LEFT),
    variant: computed(() => MESSAGE_VARIANTS.USER),
    isBotOrAgentMessage: computed(() => false),
    isPrivate: computed(() => false),
    shouldGroupWithNext: computed(() => false),
    ...contextOverrides,
  };

  const Host = {
    setup() {
      provideMessageContext(context);
      return () => h(VoiceCall);
    },
  };

  return mount(Host, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        BaseBubble: {
          template: '<div><slot /></div>',
        },
        Icon: {
          template: '<i />',
        },
      },
    },
  });
};

describe('VoiceCall bubble', () => {
  it('renders the saved call time', () => {
    const wrapper = buildWrapper();

    expect(wrapper.text()).toContain(messageTimestamp(1776346354, 'HH:mm'));
  });

  it('renders duration when it can be derived reliably from call metadata', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          meta: {
            created_at: 1776346354,
            started_at: 1776346364,
            ended_at: 1776346365,
          },
        },
      }),
    });

    expect(wrapper.text()).toContain('00:01');
  });

  it('normalizes Rails voice call statuses before rendering labels', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'in_progress',
        },
      }),
    });

    expect(wrapper.text()).toContain(
      'CONVERSATION.VOICE_CALL.CALL_IN_PROGRESS'
    );
  });

  it('normalizes Rails no_answer status before rendering missed call state', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'no_answer',
        },
      }),
    });

    expect(wrapper.text()).toContain('CONVERSATION.VOICE_CALL.MISSED_CALL');
    expect(wrapper.text()).toContain('CONVERSATION.VOICE_CALL.NO_ANSWER');
  });
});
