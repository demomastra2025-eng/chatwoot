import { effectScope, nextTick, ref } from 'vue';
import { flushPromises } from '@vue/test-utils';
import { usePhoneNativeCallTarget } from './usePhoneNativeCallTarget';

const mocks = vi.hoisted(() => ({
  search: vi.fn(),
  conversations: vi.fn(),
  initiate: vi.fn(),
  options: null,
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/api/contacts', () => ({
  default: { search: mocks.search, getConversations: mocks.conversations },
}));
vi.mock('./useWhatsappCallInitiation', async () => {
  const { ref: vueRef } = await import('vue');
  return {
    useWhatsappCallInitiation: options => {
      mocks.options = options;
      return {
        canInitiateWhatsappCall: vueRef(true),
        isInitiatingWhatsappCall: vueRef(false),
        initiateWhatsappCall: mocks.initiate,
      };
    },
  };
});
const conversation = (id, inboxId = 225, attrs = { chat_id: '123456' }) => ({
  id,
  inbox_id: inboxId,
  additional_attributes: attrs,
});
describe('phone native peer selection', () => {
  let scope;
  let inbox;
  let accountId;
  let busy;
  let target;
  beforeEach(() => {
    vi.clearAllMocks();
    inbox = ref({
      id: 225,
      channel_type: 'Channel::TelegramPersonal',
      calling_enabled: true,
      connection_state: 'connected',
    });
    accountId = ref(1);
    busy = ref(false);
    scope = effectScope();
    target = scope.run(() =>
      usePhoneNativeCallTarget({ inbox, accountId, busy })
    );
    mocks.search.mockResolvedValue({
      data: { payload: [{ id: 5, name: 'Fixture contact' }] },
    });
    mocks.conversations.mockResolvedValue({
      data: {
        payload: [
          {
            ...conversation(10, 225, {}),
            meta: { contact_inbox: { source_id: '123456' } },
          },
          conversation(11, 999),
          conversation(12, 225, { chat_id: '-123' }),
          conversation(13, 225, { chat_id: '123', is_group: true }),
          conversation(14, 225, {}),
        ],
      },
    });
  });
  afterEach(() => scope.stop());
  it('uses only an explicitly selected existing private peer in this inbox', async () => {
    await target.searchTargets('Fixture');
    expect(mocks.conversations).toHaveBeenCalledWith(5, 225);
    expect(target.targetOptions.value.map(option => option.value)).toEqual([
      10,
    ]);
    target.initiateCall();
    expect(mocks.initiate).not.toHaveBeenCalled();
    target.targetId.value = 10;
    expect(mocks.options.conversationId.value).toBe(10);
    expect(mocks.options.inboxId.value).toBe(225);
    expect(mocks.options.conversation.value.meta.contact_inbox.source_id).toBe(
      '123456'
    );
    target.initiateCall();
    expect(mocks.initiate).toHaveBeenCalledOnce();
  });
  it('blocks offline and busy lines with a reason', async () => {
    await target.searchTargets('Fixture');
    target.targetId.value = 10;
    inbox.value.connection_state = 'disconnected';
    expect(target.targetReason.value).toBe('PHONE_WIDGET.NATIVE_OFFLINE');
    target.initiateCall();
    inbox.value.connection_state = 'connected';
    busy.value = true;
    expect(target.targetReason.value).toBe('PHONE_WIDGET.NATIVE_BUSY');
    target.initiateCall();
    expect(mocks.initiate).not.toHaveBeenCalled();
  });
  it('discards late lookup after account switch even if the inbox id is reused', async () => {
    let resolve;
    mocks.conversations.mockReturnValue(
      new Promise(done => {
        resolve = done;
      })
    );
    const lookup = target.searchTargets('Fixture');
    await flushPromises();
    accountId.value = 2;
    await nextTick();
    resolve({ data: { payload: [conversation(10)] } });
    await lookup;
    expect(target.targetOptions.value).toEqual([]);
    expect(target.targetId.value).toBe('');
  });
  it('clears target immediately on a new search and handles errors without calling', async () => {
    await target.searchTargets('Fixture');
    target.targetId.value = 10;
    mocks.search.mockRejectedValue(new Error('fixture'));
    await target.searchTargets('Other');
    expect(target.targetReason.value).toBe('PHONE_WIDGET.NATIVE_LOOKUP_FAILED');
    target.initiateCall();
    expect(mocks.initiate).not.toHaveBeenCalled();
  });
});
