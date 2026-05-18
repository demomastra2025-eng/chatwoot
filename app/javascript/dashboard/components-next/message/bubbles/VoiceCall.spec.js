import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { computed, h, ref } from 'vue';

import { messageTimestamp } from 'shared/helpers/timeHelper';
import { MESSAGE_TYPES, MESSAGE_VARIANTS, ORIENTATION } from '../constants';
import { provideMessageContext } from '../provider.js';

const { routerPushMock, acceptWhatsappCallByIdMock } = vi.hoisted(() => ({
  routerPushMock: vi.fn(),
  acceptWhatsappCallByIdMock: vi.fn(),
}));

vi.mock('next/message/chips/Audio.vue', () => ({
  default: {
    name: 'AudioChip',
    props: ['attachment', 'showTranscribedText'],
    template:
      '<div data-testid="voice-call-recording" :data-url="attachment.dataUrl" :data-extension="attachment.extension" :data-show-transcribed-text="String(showTranscribedText)" />',
  },
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: routerPushMock }),
}));

vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  acceptWhatsappCallById: acceptWhatsappCallByIdMock,
}));

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
  beforeEach(() => {
    vi.clearAllMocks();
  });

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

  it('expands the call bubble width for longer call recordings', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          duration: 240,
          recordingUrl:
            '/api/v1/accounts/1/telephony/calls/call-1/recording.wav',
        },
      }),
    });

    expect(
      wrapper.find('.voice-call-bubble-body').attributes('style')
    ).toContain('--voice-call-bubble-width: min(48rem, calc(100vw - 8rem));');
  });

  it('keeps the compact call bubble width when no recording is available', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'no_answer',
          duration: 240,
        },
      }),
    });

    expect(
      wrapper.find('.voice-call-bubble-body').attributes('style')
    ).toContain('--voice-call-bubble-width: 20rem;');
  });

  it('keeps the compact call bubble width before the recording is renderable', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'ringing',
          duration: 240,
          recordingUrl:
            '/api/v1/accounts/1/telephony/calls/call-1/recording.wav',
        },
      }),
    });

    expect(
      wrapper.find('.voice-call-bubble-body').attributes('style')
    ).toContain('--voice-call-bubble-width: 20rem;');
  });

  it('uses the Captain icon for AI voice status inside call bubbles', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          aiVoice: {
            enabled: true,
            answered: true,
          },
        },
      }),
    });

    expect(wrapper.find('.i-woot-captain').exists()).toBe(true);
    expect(wrapper.find('.i-ph-robot-bold').exists()).toBe(false);
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

  it('renders the shared audio waveform chip for completed calls with an authorized recording URL', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          recordingUrl:
            '/api/v1/accounts/1/telephony/calls/call-1/recording.wav',
        },
      }),
    });

    const recording = wrapper.find('[data-testid="voice-call-recording"]');
    expect(recording.exists()).toBe(true);
    expect(recording.attributes('data-url')).toBe(
      '/api/v1/accounts/1/telephony/calls/call-1/recording.wav'
    );
    expect(recording.attributes('data-extension')).toBe('wav');
    expect(recording.attributes('data-show-transcribed-text')).toBe('false');
  });

  it('renders the shared audio waveform chip for cancelled terminal calls with an authorized recording URL', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'cancelled',
          recordingUrl:
            '/api/v1/accounts/1/telephony/calls/call-cancelled/recording.wav',
        },
      }),
    });

    const recording = wrapper.find('[data-testid="voice-call-recording"]');
    expect(recording.exists()).toBe(true);
    expect(recording.attributes('data-url')).toBe(
      '/api/v1/accounts/1/telephony/calls/call-cancelled/recording.wav'
    );
  });

  it('renders the shared audio waveform chip when Rails sends snake_case recording_url', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          recording_url:
            '/api/v1/accounts/1/telephony/calls/call-2/recording.mp3',
        },
      }),
    });

    const recording = wrapper.find('[data-testid="voice-call-recording"]');
    expect(recording.exists()).toBe(true);
    expect(recording.attributes('data-url')).toBe(
      '/api/v1/accounts/1/telephony/calls/call-2/recording.mp3'
    );
    expect(recording.attributes('data-extension')).toBe('mp3');
  });

  it('preserves signed native playback query params for internal call recordings', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          recordingUrl:
            '/api/v1/accounts/1/telephony/calls/call-3/recording?recording_token=signed-token',
        },
      }),
    });

    const recording = wrapper.find('[data-testid="voice-call-recording"]');
    expect(recording.exists()).toBe(true);
    expect(recording.attributes('data-url')).toBe(
      '/api/v1/accounts/1/telephony/calls/call-3/recording?recording_token=signed-token'
    );
    expect(recording.attributes('data-extension')).toBe('wav');
  });

  it('routes WhatsApp accept from bubble by conversation display id', async () => {
    acceptWhatsappCallByIdMock.mockResolvedValue({
      success: true,
      call: {
        conversationId: 13743,
        conversationDisplayId: 481,
      },
    });
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'ringing',
          callSource: 'whatsapp',
          callId: 42,
          mediaServerEnabled: true,
        },
      }),
    });

    await wrapper.find('button').trigger('click');
    await Promise.resolve();

    expect(acceptWhatsappCallByIdMock).toHaveBeenCalledWith(42);
    expect(routerPushMock).toHaveBeenCalledWith({
      name: 'inbox_conversation',
      params: { conversation_id: 481 },
    });
  });

  it('hides embedded transcript and tool blocks when native timeline messages are enabled', () => {
    const wrapper = buildWrapper({
      contentAttributes: ref({
        data: {
          status: 'completed',
          transcript: 'Клиент: привет',
          transcriptItems: [{ speaker: 'caller', text: 'привет' }],
          tools: [{ name: 'faq_lookup', status: 'completed' }],
          aiVoice: {
            enabled: true,
            timelineMessagesEnabled: true,
          },
        },
      }),
    });

    expect(wrapper.text()).not.toContain('Клиент: привет');
    expect(wrapper.text()).not.toContain('faq_lookup');
  });
});
