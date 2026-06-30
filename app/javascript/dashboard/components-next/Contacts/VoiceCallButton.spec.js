import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';

import { useCallsStore } from 'dashboard/stores/calls';
import VoiceCallButton from './VoiceCallButton.vue';

const {
  alertMock,
  initializeDeviceMock,
  prewarmMicrophoneMock,
  routeParamsMock,
  routerPushMock,
  stopMicrophonePrewarmMock,
  storeMock,
} = vi.hoisted(() => ({
  alertMock: vi.fn(),
  initializeDeviceMock: vi.fn(),
  prewarmMicrophoneMock: vi.fn(),
  routeParamsMock: { accountId: 530 },
  routerPushMock: vi.fn(),
  stopMicrophonePrewarmMock: vi.fn(),
  storeMock: {
    getters: {},
    dispatch: vi.fn(),
  },
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: routeParamsMock }),
  useRouter: () => ({ push: routerPushMock }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/store', async () => {
  const { computed } = await vi.importActual('vue');
  return {
    useStore: () => storeMock,
    useMapGetter: key => computed(() => storeMock.getters[key]),
  };
});

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    initializeDevice: initializeDeviceMock,
    prewarmMicrophone: prewarmMicrophoneMock,
    stopMicrophonePrewarm: stopMicrophonePrewarmMock,
  },
}));

const voiceInbox = (overrides = {}) => ({
  id: 4593,
  channel_type: 'Channel::Voice',
  name: '+77172705175',
  provider: 'fonoster',
  phone_number: '+77172705175',
  ...overrides,
});

const mountComponent = ({
  inboxes = [voiceInbox()],
  dispatch,
  props = {},
  selectedChat = null,
} = {}) => {
  const dispatchMock =
    dispatch ||
    vi.fn().mockResolvedValue({
      call_sid: 'call-ref-1',
      conversation_id: 627,
    });

  storeMock.getters = {
    'inboxes/getInboxes': inboxes,
    'contacts/getUIFlags': { isInitiatingCall: false },
    getSelectedChat: selectedChat,
  };
  storeMock.dispatch = dispatchMock;

  const wrapper = shallowMount(VoiceCallButton, {
    props: {
      contactId: 2179,
      phone: '+770****8623',
      icon: 'i-ph-phone',
      ...props,
    },
    global: {
      stubs: {
        Button: {
          props: ['disabled', 'isLoading', 'label', 'icon', 'size'],
          emits: ['click'],
          template: `<button type="button" :disabled="disabled" @click="$emit('click')">{{ label }}</button>`,
        },
        Dialog: true,
      },
      directives: {
        tooltip: {},
      },
    },
  });

  return { wrapper, dispatchMock };
};

describe('VoiceCallButton', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    Object.keys(routeParamsMock).forEach(key => {
      delete routeParamsMock[key];
    });
    routeParamsMock.accountId = 530;
    initializeDeviceMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: true,
      registered: true,
    });
    prewarmMicrophoneMock.mockResolvedValue({
      provider: 'fonoster',
      prewarmed: true,
    });
    stopMicrophonePrewarmMock.mockReturnValue({
      provider: 'fonoster',
      stopped: true,
    });
  });

  it('prepares the Fonoster webphone and microphone before initiating an outbound call', async () => {
    const order = [];
    prewarmMicrophoneMock.mockImplementation(async () => {
      order.push('microphone');
      return {
        provider: 'fonoster',
        prewarmed: true,
      };
    });
    initializeDeviceMock.mockImplementation(async () => {
      order.push('webphone');
      return {
        provider: 'fonoster',
        callingSupported: true,
        registered: true,
      };
    });
    const dispatch = vi.fn().mockImplementation(async () => {
      order.push('initiate');
      return {
        call_sid: 'call-ref-1',
        conversation_id: 627,
        call_session: {
          from_number: '+77070001001',
          to_number: '+77070001002',
          metadata: {
            metadata: {
              operator_internal_extension: '502',
              operator_candidates: [
                {
                  user_id: 177,
                  name: 'Ayan',
                  internal_extension: '502',
                },
              ],
            },
          },
        },
      };
    });
    const { wrapper } = mountComponent({ dispatch });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(initializeDeviceMock).toHaveBeenCalledWith(4593, { native: true });
    expect(prewarmMicrophoneMock).toHaveBeenCalledWith('fonoster');
    expect(dispatch).toHaveBeenCalledWith('contacts/initiateCall', {
      contactId: 2179,
      inboxId: 4593,
    });
    expect(order).toEqual(['microphone', 'webphone', 'initiate']);
    expect(useCallsStore().calls).toEqual([
      expect.objectContaining({
        callSid: 'call-ref-1',
        conversationId: 627,
        inboxId: 4593,
        provider: 'fonoster',
        callDirection: 'outbound',
        fromNumber: '+77070001001',
        toNumber: '+77070001002',
        operatorCandidates: [
          {
            user_id: 177,
            name: 'Ayan',
            internal_extension: '502',
          },
        ],
        operatorInternalExtension: '502',
      }),
    ]);
  });

  it('does not navigate when the current chat already belongs to the contact', async () => {
    const { wrapper } = mountComponent({
      selectedChat: {
        id: 25,
        contact_id: 2179,
      },
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(routerPushMock).not.toHaveBeenCalled();
  });

  it('does not initiate a Fonoster outbound call when the webphone is unavailable', async () => {
    const { dispatchMock, wrapper } = mountComponent();
    initializeDeviceMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: false,
      registered: false,
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalled();
    expect(stopMicrophonePrewarmMock).toHaveBeenCalledWith('fonoster');
    expect(alertMock).toHaveBeenCalledWith(
      'CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'
    );
  });

  it('does not initiate a Fonoster outbound call when the microphone is unavailable', async () => {
    const { dispatchMock, wrapper } = mountComponent();
    prewarmMicrophoneMock.mockResolvedValue({
      provider: 'fonoster',
      prewarmed: false,
      reason: 'NotAllowedError',
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalled();
    expect(stopMicrophonePrewarmMock).toHaveBeenCalledWith('fonoster');
    expect(alertMock).toHaveBeenCalledWith(
      'CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'
    );
  });

  it('initiates a Fonoster outbound call when the selected inbox uses an external SIP profile', async () => {
    initializeDeviceMock.mockResolvedValue({
      provider: 'fonoster',
      callingSupported: false,
      browserJoinSupported: false,
      registered: false,
    });
    prewarmMicrophoneMock.mockResolvedValue({
      provider: 'fonoster',
      prewarmed: false,
      reason: 'NotAllowedError',
    });
    const dispatch = vi.fn().mockResolvedValue({
      call_sid: 'call-ref-external',
      conversation_id: 628,
      browser_join_supported: false,
    });
    const { wrapper } = mountComponent({ dispatch });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('contacts/initiateCall', {
      contactId: 2179,
      inboxId: 4593,
    });
    expect(stopMicrophonePrewarmMock).toHaveBeenCalledWith('fonoster');
    expect(useCallsStore().calls).toEqual([
      expect.objectContaining({
        callSid: 'call-ref-external',
        browserJoinSupported: false,
      }),
    ]);
    expect(alertMock).toHaveBeenCalledWith('CONTACT_PANEL.CALL_INITIATED');
  });

  it('does not prewarm webphone for non-Fonoster voice inboxes', async () => {
    const { dispatchMock, wrapper } = mountComponent({
      inboxes: [voiceInbox({ id: 4674, provider: 'twilio' })],
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(initializeDeviceMock).not.toHaveBeenCalled();
    expect(prewarmMicrophoneMock).not.toHaveBeenCalled();
    expect(dispatchMock).toHaveBeenCalledWith('contacts/initiateCall', {
      contactId: 2179,
      inboxId: 4674,
    });
  });

  it('uses the requested voice inbox when inboxId is provided', async () => {
    const { dispatchMock, wrapper } = mountComponent({
      inboxes: [voiceInbox({ id: 4593 }), voiceInbox({ id: 4674 })],
      props: { inboxId: 4674 },
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('contacts/initiateCall', {
      contactId: 2179,
      inboxId: 4674,
    });
  });

  it('uses explicit inboxId even when the voice inbox list is not hydrated', async () => {
    const { dispatchMock, wrapper } = mountComponent({
      inboxes: [],
      props: { inboxId: 4593 },
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('contacts/initiateCall', {
      contactId: 2179,
      inboxId: 4593,
    });
  });

  it('does not navigate when the initiated call belongs to the currently open conversation', async () => {
    routeParamsMock.conversation_id = 627;
    const { wrapper } = mountComponent();

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(routerPushMock).not.toHaveBeenCalled();
  });

  it('navigates outbound calls to the communication thread when the API returns it', async () => {
    const dispatch = vi.fn().mockResolvedValue({
      call_sid: 'call-ref-thread',
      conversation_id: 627,
      communication_thread_id: 72,
    });
    const { wrapper } = mountComponent({ dispatch });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(routerPushMock).toHaveBeenCalledWith({
      path: '/app/accounts/530/communication_threads/72?assignee_type=all',
    });
  });

  it('does not start a call when disabled', async () => {
    const { dispatchMock, wrapper } = mountComponent({
      props: { disabled: true },
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalled();
  });
});
