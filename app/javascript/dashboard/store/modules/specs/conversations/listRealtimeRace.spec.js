import actions from '../../conversations/actions';
import { mutations } from '../../conversations';
import CommunicationThreadApi from 'dashboard/api/inbox/communicationThread';
import { buildCommunicationThreadConversation } from 'dashboard/helper/communicationThreadHelper';

const thread = (updatedAt = 1) => ({
  id: 7,
  updated_at: updatedAt,
  status: 'open',
  unread_count: 0,
  labels: ['snapshot'],
  contact: { id: 12, name: 'Contact' },
  channels: [],
  messages: [],
});

const contextFor = (page = 1) => {
  const state = {
    allConversations: [buildCommunicationThreadConversation(thread())],
    selectedChatId: null,
    conversationFilters: {
      page,
      assigneeType: 'all',
      communicationThreadMode: true,
    },
  };
  return {
    state,
    commit: vi.fn((type, payload) => mutations[type]?.(state, payload)),
    dispatch: vi.fn(),
  };
};

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

const response = payload => ({ data: { data: { payload, meta: {} } } });
const update = (updatedAt = 2) => ({
  id: 7,
  updated_at: updatedAt,
  unread_count: 3,
  labels: ['realtime'],
  message: {
    id: 91,
    communication_thread_id: 7,
    conversation_id: 11,
    created_at: 2,
    message_type: 0,
    content: 'Fresh message',
    status: 'sent',
  },
});
const fetchList = (context, filter) =>
  filter
    ? actions.fetchFilteredConversations(context, {
        ...context.state.conversationFilters,
        queryData: [],
      })
    : actions.fetchCommunicationThreads(context);

const cases = [
  { filter: false, page: 1 },
  { filter: false, page: 2 },
  { filter: true, page: 1 },
  { filter: true, page: 2 },
];

beforeEach(() => {
  actions.invalidateConversationListRequests(contextFor());
});
afterEach(() => vi.restoreAllMocks());

it.each(cases)(
  'preserves realtime over a stale list (filter=$filter, page=$page) without refetching',
  async ({ filter, page }) => {
    const context = contextFor(page);
    const request = deferred();
    const api = vi
      .spyOn(CommunicationThreadApi, filter ? 'filter' : 'get')
      .mockReturnValue(request.promise);
    const pending = fetchList(context, filter);
    actions.updateCommunicationThreadRealtime(context, update());
    actions.updateCommunicationThreadRealtime(context, {
      id: 7,
      updated_at: 3,
      labels: ['latest'],
    });
    request.resolve(response([thread()]));
    await pending;
    const chat = context.state.allConversations[0];
    expect(chat.labels).toEqual(['latest']);
    expect(chat.unread_count).toBe(3);
    expect(chat.messages.some(message => message.id === 91)).toBe(true);
    expect(context.state.listLoadingStatus).toBe(false);
    expect(context.state.listLoadingError).toBe(false);
    expect(api).toHaveBeenCalledTimes(1);
    expect(context.dispatch).toHaveBeenCalledWith(
      'conversationPage/setCurrentPage',
      { filter: filter ? 'appliedFilters' : 'all', page },
      { root: true }
    );
  }
);

it('applies an event received before the initial list contains its thread', async () => {
  const context = contextFor();
  context.state.allConversations = [];
  const request = deferred();
  vi.spyOn(CommunicationThreadApi, 'get').mockReturnValue(request.promise);
  const pending = fetchList(context, false);
  actions.updateCommunicationThreadRealtime(context, update());
  request.resolve(response([thread()]));
  await pending;
  expect(context.state.allConversations[0].labels).toEqual(['realtime']);
});

it('does not replay an older event over a newer HTTP snapshot', async () => {
  const context = contextFor();
  const request = deferred();
  vi.spyOn(CommunicationThreadApi, 'get').mockReturnValue(request.promise);
  const pending = fetchList(context, false);
  actions.updateCommunicationThreadRealtime(context, update());
  request.resolve(response([thread(5)]));
  await pending;
  expect(context.state.allConversations[0].labels).toEqual(['snapshot']);
  expect(context.state.allConversations[0].messages).toEqual([]);
});

it('discards events on filter/account invalidation and ignores the old response', async () => {
  const oldContext = contextFor();
  const old = deferred();
  const next = deferred();
  vi.spyOn(CommunicationThreadApi, 'get')
    .mockReturnValueOnce(old.promise)
    .mockReturnValueOnce(next.promise);
  const pendingOld = fetchList(oldContext, false);
  actions.updateCommunicationThreadRealtime(oldContext, update());
  actions.invalidateConversationListRequests(oldContext);
  actions.emptyAllConversations(oldContext);
  const newContext = contextFor();
  const pendingNew = fetchList(newContext, false);
  old.resolve(response([thread()]));
  await pendingOld;
  expect(newContext.state.listLoadingStatus).toBe(true);
  next.resolve(response([thread()]));
  await pendingNew;
  expect(newContext.state.allConversations[0].labels).toEqual(['snapshot']);
  expect(oldContext.state.allConversations).toEqual([]);
});

it('does not carry buffered events into a retry after rejection', async () => {
  const context = contextFor();
  const request = deferred();
  vi.spyOn(CommunicationThreadApi, 'get')
    .mockReturnValueOnce(request.promise)
    .mockResolvedValueOnce(response([thread()]));
  const pending = fetchList(context, false);
  actions.updateCommunicationThreadRealtime(context, update());
  request.reject(new Error('failed'));
  await pending;
  expect(context.state.listLoadingError).toBe(true);
  await fetchList(context, false);
  expect(context.state.allConversations[0].labels).toEqual(['snapshot']);
  expect(context.state.listLoadingStatus).toBe(false);
});
