import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ref } from 'vue';
import TelegramPersonalCallsAPI, {
  callsApiFor,
  isTelegramPersonalProvider,
} from '../telegramPersonalCalls';
import WhatsappCallsAPI from '../whatsappCalls';
import {
  COMMUNICATION_CHANNEL_ACTIONS,
  getCommunicationReplyChannels,
  isCommunicationCallChannel,
  isCommunicationChannelReplyable,
  isCommunicationMessengerCallChannel,
  isCommunicationTelegramPersonalCallChannel,
  isCommunicationWhatsappCallChannel,
} from 'dashboard/helper/communicationThreadHelper';
import { useWhatsappCallInitiation } from 'dashboard/composables/useWhatsappCallInitiation';

const mockHandleAgentOffer = vi.fn();
const mockHandleCallAgentOffer = vi.fn();
const mockShowAlert = vi.fn();
const mockStore = {
  getters: {
    getConversationById: vi.fn(),
    'inboxes/getInbox': vi.fn(),
  },
};

const mockCallsStoreState = {
  hasWhatsappCall: false,
  hasActiveCall: false,
  activeCall: null,
  setActiveCall: vi.fn(call => {
    mockCallsStoreState.activeCall = call;
    mockCallsStoreState.hasActiveCall = Boolean(call);
    mockCallsStoreState.hasWhatsappCall = Boolean(call);
  }),
  updateActiveCall: vi.fn(patch => {
    if (mockCallsStoreState.activeCall) {
      mockCallsStoreState.activeCall = {
        ...mockCallsStoreState.activeCall,
        ...patch,
      };
    }
  }),
  clearActiveCall: vi.fn(() => {
    mockCallsStoreState.activeCall = null;
    mockCallsStoreState.hasActiveCall = false;
    mockCallsStoreState.hasWhatsappCall = false;
  }),
  consumePendingAgentOffer: vi.fn(() => null),
  clearPendingAgentOffer: vi.fn(),
  markActiveCallConnected: vi.fn(),
};

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vuex', () => ({
  useStore: () => mockStore,
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockShowAlert(...args),
}));

vi.mock('dashboard/stores/whatsappCalls', () => ({
  useWhatsappCallsStore: () => mockCallsStoreState,
  setOutboundCallState: vi.fn(),
  cleanupOutboundCall: vi.fn(),
}));

vi.mock('dashboard/stores/calls', () => ({
  useCallsStore: () => ({
    hasActiveCall: false,
  }),
}));

vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  handleAgentOffer: (...args) => mockHandleAgentOffer(...args),
  handleCallAgentOffer: (...args) => mockHandleCallAgentOffer(...args),
  hasAgentMediaOffer: offer =>
    offer?.transport === 'janus_audiobridge' || Boolean(offer?.sdp_offer),
  WHATSAPP_CALL_MEDIA_LEG_CLOSED_MESSAGE: 'Media leg closed',
  isMediaLegClosedError: () => false,
}));

describe('TelegramPersonalCallsAPI & callsApiFor', () => {
  it('identifies telegram_personal providers and routes callsApiFor accurately', () => {
    expect(isTelegramPersonalProvider('telegram_personal')).toBe(true);
    expect(isTelegramPersonalProvider('Channel::TelegramPersonal')).toBe(true);
    expect(isTelegramPersonalProvider({ provider: 'telegram_personal' })).toBe(
      true
    );
    expect(
      isTelegramPersonalProvider({ channel: 'Channel::TelegramPersonal' })
    ).toBe(true);
    expect(isTelegramPersonalProvider('whatsapp')).toBe(false);
    expect(isTelegramPersonalProvider(null)).toBe(false);

    expect(callsApiFor('telegram_personal')).toBe(TelegramPersonalCallsAPI);
    expect(callsApiFor({ provider: 'telegram_personal' })).toBe(
      TelegramPersonalCallsAPI
    );
    expect(callsApiFor('whatsapp')).toBe(WhatsappCallsAPI);
    expect(callsApiFor({ provider: 'whatsapp' })).toBe(WhatsappCallsAPI);
  });
});

describe('communicationThreadHelper Telegram Personal call support', () => {
  const telegramPrivateCallable = {
    conversation_id: 77,
    inbox_id: 12,
    inbox_name: 'Telegram Личный',
    channel: 'Channel::TelegramPersonal',
    can_reply: true,
    can_send_text: true,
    can_send_attachments: true,
    can_call: true,
    media_server_enabled: true,
    disabled: false,
  };

  it('splits a callable Telegram Personal channel into MESSAGE and CALL actions without affecting WhatsApp predicate', () => {
    expect(isCommunicationChannelReplyable(telegramPrivateCallable)).toBe(true);

    const actions = getCommunicationReplyChannels([telegramPrivateCallable]);
    expect(actions).toHaveLength(2);

    const [msgAction, callAction] = actions;
    expect(msgAction.communication_action).toBe(
      COMMUNICATION_CHANNEL_ACTIONS.MESSAGE
    );
    expect(callAction.communication_action).toBe(
      COMMUNICATION_CHANNEL_ACTIONS.CALL
    );

    expect(isCommunicationTelegramPersonalCallChannel(callAction)).toBe(true);
    expect(isCommunicationMessengerCallChannel(callAction)).toBe(true);
    expect(isCommunicationCallChannel(callAction)).toBe(true);
    expect(isCommunicationWhatsappCallChannel(callAction)).toBe(false);
  });

  it('keeps non-callable Telegram Personal channels (e.g. group chats) as a single message channel', () => {
    const groupChannel = {
      ...telegramPrivateCallable,
      can_call: false,
    };

    const actions = getCommunicationReplyChannels([groupChannel]);
    expect(actions).toHaveLength(1);
    expect(isCommunicationCallChannel(actions[0])).toBe(false);
  });
});

describe('useWhatsappCallInitiation for Channel::TelegramPersonal', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCallsStoreState.activeCall = null;
    mockCallsStoreState.hasActiveCall = false;
    mockCallsStoreState.hasWhatsappCall = false;
  });

  it('dials Telegram only after its Janus media leg is ready', async () => {
    mockStore.getters.getConversationById.mockReturnValue({
      id: 501,
      display_id: 501,
      inbox_id: 12,
      additional_attributes: { chat_type: 'private' },
      meta: {
        sender: {
          name: 'Arman',
          phone_number: '+77015550101',
          thumbnail: '',
        },
      },
    });
    mockStore.getters['inboxes/getInbox'].mockReturnValue({
      id: 12,
      channel_type: 'Channel::TelegramPersonal',
      calling_enabled: true,
      media_server_enabled: true,
    });

    const prepareSpy = vi
      .spyOn(TelegramPersonalCallsAPI, 'prepareOutbound')
      .mockResolvedValue({
        data: {
          id: 91,
          call_id: 'pending_tg-sess-91',
          provider: 'telegram_personal',
          agent_offer: {
            transport: 'janus_audiobridge',
            room_id: 123,
            server: 'wss://example.test/janus-sipuni',
            token: 'ephemeral-token',
            pin: 'ephemeral-pin',
            ice_servers: [],
            peer_id: 'peer-91',
          },
        },
      });
    const dialSpy = vi
      .spyOn(TelegramPersonalCallsAPI, 'dial')
      .mockResolvedValue({
        data: {
          id: 91,
          call_id: 'tg-real-91',
        },
      });
    let resolveMedia;
    mockHandleCallAgentOffer.mockReturnValue(
      new Promise(resolve => {
        resolveMedia = resolve;
      })
    );

    const { canInitiateWhatsappCall, initiateWhatsappCall } =
      useWhatsappCallInitiation({
        conversationId: ref(501),
        inboxId: ref(12),
      });

    expect(canInitiateWhatsappCall.value).toBe(true);

    const initiation = initiateWhatsappCall();
    await vi.waitFor(() =>
      expect(mockHandleCallAgentOffer).toHaveBeenCalledOnce()
    );
    expect(dialSpy).not.toHaveBeenCalled();
    resolveMedia({ success: true });
    await initiation;

    expect(prepareSpy).toHaveBeenCalledWith(501);
    expect(mockHandleAgentOffer).not.toHaveBeenCalled();
    expect(mockHandleCallAgentOffer).toHaveBeenCalledWith(
      91,
      expect.objectContaining({ transport: 'janus_audiobridge', room_id: 123 }),
      expect.objectContaining({
        direction: 'outbound',
        peerId: 'peer-91',
        provider: 'telegram_personal',
      })
    );
    expect(dialSpy).toHaveBeenCalledWith(91);
    expect(mockCallsStoreState.activeCall).toMatchObject({
      id: 91,
      callId: 'tg-real-91',
      provider: 'telegram_personal',
      direction: 'outbound',
      serverRelay: true,
    });
  });

  it('disables call initiation for Telegram group conversations', () => {
    mockStore.getters.getConversationById.mockReturnValue({
      id: 502,
      display_id: 502,
      inbox_id: 12,
      additional_attributes: { chat_type: 'supergroup' },
      meta: { sender: { name: 'Team Group' } },
    });
    mockStore.getters['inboxes/getInbox'].mockReturnValue({
      id: 12,
      channel_type: 'Channel::TelegramPersonal',
      calling_enabled: true,
      media_server_enabled: true,
    });

    const { canInitiateWhatsappCall } = useWhatsappCallInitiation({
      conversationId: ref(502),
      inboxId: ref(12),
    });

    expect(canInitiateWhatsappCall.value).toBe(false);
  });
});
