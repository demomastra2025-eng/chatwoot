import { FEATURE_FLAGS } from '../../../featureFlags';
import ConversationApi from '../../../api/inbox/conversation';
import store from '../../../store';
import { redirectToCommunicationThread } from './redirectToCommunicationThread';

vi.mock('../../../store', () => ({
  default: {
    getters: { 'accounts/isFeatureEnabledonAccount': vi.fn() },
  },
}));
vi.mock('../../../api/inbox/conversation', () => ({
  default: { show: vi.fn() },
}));

describe('redirectToCommunicationThread', () => {
  const enter = async to => {
    const next = vi.fn();
    await redirectToCommunicationThread(
      {
        params: { accountId: '7', conversation_id: '42' },
        query: {},
        hash: '',
        ...to,
      },
      {},
      next
    );
    return next;
  };

  beforeEach(() => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockReset();
    ConversationApi.show.mockReset();
  });

  it('opens the dialog of the person when the conversation belongs to a thread', async () => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockImplementation(
      (_accountId, flag) => flag === FEATURE_FLAGS.COMMUNICATION_THREADS
    );
    ConversationApi.show.mockResolvedValue({
      data: { id: 42, meta: { communication_thread_id: 9 } },
    });

    const next = await enter({ query: { status: 'open' }, hash: '#msg' });

    expect(ConversationApi.show).toHaveBeenCalledWith('42');
    expect(next).toHaveBeenCalledWith({
      name: 'communication_thread_conversation',
      params: { accountId: '7', communication_thread_id: 9 },
      query: { status: 'open' },
      hash: '#msg',
      replace: true,
    });
  });

  it('keeps the plain conversation when it has no thread', async () => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockReturnValue(true);
    ConversationApi.show.mockResolvedValue({
      data: { id: 42, meta: { communication_thread_id: null } },
    });

    const next = await enter();

    expect(next).toHaveBeenCalledWith();
  });

  it('does not call the API when the account has no communication threads', async () => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockReturnValue(false);

    const next = await enter();

    expect(ConversationApi.show).not.toHaveBeenCalled();
    expect(next).toHaveBeenCalledWith();
  });

  it('falls back to the plain conversation when the conversation cannot be loaded', async () => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockReturnValue(true);
    ConversationApi.show.mockRejectedValue(new Error('403'));

    const next = await enter();

    expect(next).toHaveBeenCalledWith();
  });

  it('falls back when the account feature state cannot be read', async () => {
    store.getters['accounts/isFeatureEnabledonAccount'].mockImplementation(
      () => {
        throw new Error('account is not loaded');
      }
    );

    const next = await enter();

    expect(ConversationApi.show).not.toHaveBeenCalled();
    expect(next).toHaveBeenCalledWith();
  });
});
