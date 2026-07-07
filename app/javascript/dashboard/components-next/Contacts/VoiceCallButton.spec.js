import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';

import { useCallsStore } from 'dashboard/stores/calls';
import VoiceCallButton from './VoiceCallButton.vue';

const {
  alertMock,
  initializeDeviceMock,
  prewarmMicrophoneMock,
  routeMock,
  routeParamsMock,
  routerPushMock,
  stopMicrophonePrewarmMock,
  storeMock,
} = vi.hoisted(() => ({
  alertMock: vi.fn(),
  initializeDeviceMock: vi.fn(),
  prewarmMicrophoneMock: vi.fn(),
  routeMock: { name: undefined, params: { accountId: 530 } },
  routeParamsMock: { accountId: 530 },
  routerPushMock: vi.fn(),
  stopMicrophonePrewarmMock: vi.fn(),
  storeMock: {
    getters: {},
    dispatch: vi.fn(),
  },
}));

vi.mock('vue-router', () => ({
  useRoute: () => routeMock,
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
  provider: 'sipuni',
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
    routeMock.name = undefined;
    routeMock.params = routeParamsMock;
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: true,
      registered: true,
    });
    prewarmMicrophoneMock.mockResolvedValue({
      provider: 'sipuni',
      prewarmed: true,
    });
    stopMicrophonePrewarmMock.mockReturnValue({
      provider: 'sipuni',
      stopped: true,
    });
  });

  it('prepares the Janus SIP webphone and microphone before initiating an outbound call', async () => {
    const order = [];
    prewarmMicrophoneMock.mockImplementation(async () => {
      order.push('microphone');
      return {
        provider: 'sipuni',
        prewarmed: true,
      };
    });
    initializeDeviceMock.mockImplementation(async () => {
      order.push('webphone');
      return {
        provider: 'sipuni',
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
    expect(prewarmMicrophoneMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni', inboxId: 4593 })
    );
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
        provider: 'sipuni',
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

  it('prewarms the microphone again after native SIP initialization when the scoped client was not ready yet', async () => {
    prewarmMicrophoneMock.mockResolvedValueOnce(null).mockResolvedValueOnce({
      provider: 'asterisk_analog',
      prewarmed: true,
    });
    initializeDeviceMock.mockResolvedValue({
      provider: 'asterisk_analog',
      sessionKey: 'sip_profile:41',
      sipProfileId: 41,
      callingSupported: true,
      registered: true,
    });
    const dispatch = vi.fn().mockResolvedValue({
      call_sid: 'call-ref-asterisk',
      conversation_id: 727,
    });
    const { wrapper } = mountComponent({
      inboxes: [voiceInbox({ provider: 'asterisk_analog' })],
      dispatch,
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(prewarmMicrophoneMock).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ provider: 'asterisk_analog', inboxId: 4593 })
    );
    expect(prewarmMicrophoneMock).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        provider: 'asterisk_analog',
        inboxId: 4593,
        sessionKey: 'sip_profile:41',
        sipProfileId: 41,
      })
    );
    expect(dispatch).toHaveBeenCalledWith('contacts/initiateCall', {
      contactId: 2179,
      inboxId: 4593,
    });
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

  it('does not initiate a Janus SIP outbound call when the webphone is unavailable', async () => {
    const { dispatchMock, wrapper } = mountComponent();
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: false,
      registered: false,
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalled();
    expect(stopMicrophonePrewarmMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni', inboxId: 4593 })
    );
    expect(alertMock).toHaveBeenCalledWith(
      'CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'
    );
  });

  it('does not initiate a Janus SIP outbound call when the microphone is unavailable', async () => {
    const { dispatchMock, wrapper } = mountComponent();
    prewarmMicrophoneMock.mockResolvedValue({
      provider: 'sipuni',
      prewarmed: false,
      reason: 'NotAllowedError',
    });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalled();
    expect(stopMicrophonePrewarmMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni', inboxId: 4593 })
    );
    expect(alertMock).toHaveBeenCalledWith(
      'CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'
    );
  });

  it('initiates a Janus SIP outbound call when the selected inbox uses an external SIP profile', async () => {
    initializeDeviceMock.mockResolvedValue({
      provider: 'sipuni',
      callingSupported: false,
      browserJoinSupported: false,
      registered: false,
    });
    prewarmMicrophoneMock.mockResolvedValue({
      provider: 'sipuni',
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
    expect(stopMicrophonePrewarmMock).toHaveBeenCalledWith(
      expect.objectContaining({ provider: 'sipuni', inboxId: 4593 })
    );
    expect(useCallsStore().calls).toEqual([
      expect.objectContaining({
        callSid: 'call-ref-external',
        browserJoinSupported: false,
      }),
    ]);
    expect(alertMock).toHaveBeenCalledWith('CONTACT_PANEL.CALL_INITIATED');
  });

  it('does not prewarm webphone for non-Janus SIP voice inboxes', async () => {
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

  it('does not downgrade from a communication thread to a concrete inbox conversation', async () => {
    routeMock.name = 'communication_thread_conversation';
    routeParamsMock.communication_thread_id = 25;
    const dispatch = vi.fn().mockResolvedValue({
      call_sid: 'call-ref-thread',
      conversation_id: 724,
    });
    const { wrapper } = mountComponent({ dispatch });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(routerPushMock).not.toHaveBeenCalled();
  });

  it('does not navigate when the initiated call returns the current communication thread', async () => {
    routeMock.name = 'communication_thread_conversation';
    routeParamsMock.communication_thread_id = 25;
    const dispatch = vi.fn().mockResolvedValue({
      call_sid: 'call-ref-thread',
      conversation_id: 724,
      communication_thread_id: 25,
    });
    const { wrapper } = mountComponent({ dispatch });

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(routerPushMock).not.toHaveBeenCalled();
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
