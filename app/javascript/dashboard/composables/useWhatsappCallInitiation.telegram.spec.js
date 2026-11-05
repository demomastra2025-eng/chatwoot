import { effectScope, ref } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { useWhatsappCallInitiation } from './useWhatsappCallInitiation';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';

const mocks = await vi.hoisted(async () => {
  const { reactive: makeReactive } = await import('vue');
  return {
    getters: makeReactive({ getCurrentAccountId: 1, getSelectedChat: {} }),
    prepare: vi.fn(),
    dial: vi.fn(),
    terminate: vi.fn(),
    media: vi.fn(),
    whatsapp: vi.fn(),
  };
});
vi.mock('vuex', () => ({ useStore: () => ({ getters: mocks.getters }) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/api/whatsappCalls', () => ({
  default: { prepareOutbound: mocks.whatsapp, initiate: mocks.whatsapp },
}));
vi.mock('dashboard/api/telegramPersonalCalls', () => ({
  callsApiFor: () => ({
    prepareOutbound: mocks.prepare,
    dial: mocks.dial,
    terminate: mocks.terminate,
  }),
  isTelegramPersonalProvider: value => value === 'telegram_personal',
}));
vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  handleAgentOffer: vi.fn(),
  handleCallAgentOffer: mocks.media,
  hasAgentMediaOffer: () => true,
  handleMediaLegClosed: vi.fn(),
  isMediaLegClosedError: () => false,
}));

describe('Telegram native initiation target', () => {
  let scope;
  let target;
  let conversationId;
  beforeEach(() => {
    vi.clearAllMocks();
    setActivePinia(createPinia());
    mocks.getters.getCurrentAccountId = 1;
    mocks.getters['inboxes/getInbox'] = () => ({
      id: 225,
      channel_type: 'Channel::TelegramPersonal',
      calling_enabled: true,
    });
    mocks.getters.getSelectedChat = {
      id: 999,
      additional_attributes: { is_group: true },
    };
    mocks.prepare.mockResolvedValue({
      data: {
        id: 20,
        call_id: 'fixture',
        provider: 'telegram_personal',
        agent_offer: { sdp_offer: 'fixture' },
      },
    });
    mocks.dial.mockResolvedValue({ data: { id: 20, status: 'ringing' } });
    mocks.terminate.mockResolvedValue({});
    mocks.media.mockResolvedValue(true);
    conversationId = ref(10);
    scope = effectScope();
    target = scope.run(() =>
      useWhatsappCallInitiation({
        inboxId: ref(225),
        conversationId,
        conversation: ref({
          id: 10,
          inbox_id: 225,
          additional_attributes: { chat_id: '123456' },
        }),
        contact: ref({ id: 5, name: 'Fixture' }),
      })
    );
  });
  afterEach(() => scope.stop());
  it('prepares the chosen private conversation, negotiates Telegram media, then dials', async () => {
    expect(target.canInitiateWhatsappCall.value).toBe(true);
    await target.initiateWhatsappCall();
    expect(mocks.prepare).toHaveBeenCalledWith(10);
    expect(mocks.media).toHaveBeenCalledWith(
      20,
      expect.anything(),
      expect.objectContaining({ provider: 'telegram_personal' })
    );
    expect(mocks.dial).toHaveBeenCalledWith(20);
    expect(mocks.whatsapp).not.toHaveBeenCalled();
    expect(useWhatsappCallsStore().activeCall.provider).toBe(
      'telegram_personal'
    );
  });
  it('does not dial or terminate a late prepare in another account', async () => {
    let resolve;
    mocks.prepare.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    const pending = target.initiateWhatsappCall();
    mocks.getters.getCurrentAccountId = 2;
    resolve({ data: { id: 20, provider: 'telegram_personal' } });
    await pending;
    expect(mocks.dial).not.toHaveBeenCalled();
    expect(mocks.terminate).not.toHaveBeenCalled();
    expect(useWhatsappCallsStore().activeCall).toBeNull();
  });
  it('cancels late prepare when the conversation changes within the same account', async () => {
    let resolve;
    mocks.prepare.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    const pending = target.initiateWhatsappCall();
    conversationId.value = 11;
    resolve({ data: { id: 20, provider: 'telegram_personal' } });
    await pending;
    expect(mocks.dial).not.toHaveBeenCalled();
    expect(mocks.terminate).toHaveBeenCalledWith(20);
  });
  it.each([false, true])(
    'cleans only the owned prepared media after target/account switch (account=%s)',
    async switchAccount => {
      let resolveMedia;
      mocks.media.mockReturnValue(
        new Promise(done => {
          resolveMedia = done;
        })
      );
      const store = useWhatsappCallsStore();
      const cleanup = vi.fn();
      store.registerCleanupCallback(cleanup);
      const pending = target.initiateWhatsappCall();
      await Promise.resolve();
      if (switchAccount) mocks.getters.getCurrentAccountId = 2;
      else conversationId.value = 11;
      resolveMedia(true);
      await pending;
      expect(mocks.dial).not.toHaveBeenCalled();
      expect(cleanup).toHaveBeenCalledOnce();
      expect(store.activeCall).toBeNull();
      if (switchAccount) expect(mocks.terminate).not.toHaveBeenCalled();
      else expect(mocks.terminate).toHaveBeenCalledWith(20);
    }
  );
  it('does not clean newer call media after a deferred old media offer', async () => {
    let resolveMedia;
    mocks.media.mockReturnValue(
      new Promise(done => {
        resolveMedia = done;
      })
    );
    const store = useWhatsappCallsStore();
    const cleanup = vi.fn();
    store.registerCleanupCallback(cleanup);
    const pending = target.initiateWhatsappCall();
    await Promise.resolve();
    conversationId.value = 11;
    store.setActiveCall({
      id: 21,
      callId: 'new',
      provider: 'telegram_personal',
    });
    resolveMedia(true);
    await pending;
    expect(mocks.dial).not.toHaveBeenCalled();
    expect(cleanup).not.toHaveBeenCalled();
    expect(store.activeCall.id).toBe(21);
  });
});
