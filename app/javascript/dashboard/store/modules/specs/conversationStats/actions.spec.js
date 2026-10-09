import axios from 'axios';
import { actions, resetMetaRefresh } from '../../conversationStats';
import * as types from '../../../mutation-types';

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

const setTabVisibility = visibilityState => {
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    value: visibilityState,
  });
  document.dispatchEvent(new Event('visibilitychange'));
};

describe('#actions', () => {
  beforeEach(() => {
    vi.useFakeTimers(); // Set up fake timers
    commit.mockClear();
    axios.get.mockReset();
    resetMetaRefresh();
  });

  afterEach(() => {
    resetMetaRefresh();
    setTabVisibility('visible');
    vi.useRealTimers(); // Reset to real timers after each test
  });

  describe('#get', () => {
    it('sends correct mutations if API is success', async () => {
      axios.get.mockResolvedValue({ data: { meta: { mine_count: 1 } } });
      actions.get(
        { commit, state: { allCount: 0 } },
        { inboxId: 1, assigneeTpe: 'me', status: 'open' }
      );

      await vi.runAllTimersAsync();
      await vi.waitFor(() => expect(commit).toHaveBeenCalled());

      expect(commit.mock.calls).toEqual([
        [types.default.SET_CONV_TAB_META, { mine_count: 1 }],
      ]);
    });

    it('commits filtered unread counts from meta when present', async () => {
      const unreadCounts = {
        all: 3,
        statuses: { open: 2 },
        inboxes: { 1: 1 },
      };
      axios.get.mockResolvedValue({
        data: { meta: { mine_count: 1, unread_counts: unreadCounts } },
      });

      actions.get(
        { commit, state: { allCount: 0 } },
        { inboxId: 1, assigneeType: 'me', status: 'open' }
      );

      await vi.runAllTimersAsync();
      await vi.waitFor(() => expect(commit).toHaveBeenCalled());

      expect(commit.mock.calls).toEqual([
        [
          types.default.SET_CONV_TAB_META,
          { mine_count: 1, unread_counts: unreadCounts },
        ],
        [
          types.default.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
          unreadCounts,
          { root: true },
        ],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      actions.get(
        { commit, state: { allCount: 0 } },
        { inboxId: 1, assigneeTpe: 'me', status: 'open' }
      );
      expect(commit.mock.calls).toEqual([]);
    });

    it('does not overwrite explicit stats with an older in-flight response', async () => {
      let resolveRequest;
      axios.get.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveRequest = resolve;
          })
      );

      actions.get(
        { commit, state: { allCount: 0 } },
        { communicationThreadMode: true, status: 'open' }
      );
      await vi.advanceTimersByTimeAsync(1500);
      expect(axios.get).toHaveBeenCalledOnce();

      const exactMeta = { mine_count: 1, all_count: 2 };
      actions.set({ commit }, exactMeta);
      resolveRequest({ data: { meta: { mine_count: 9, all_count: 10 } } });
      await Promise.resolve();
      await Promise.resolve();

      expect(commit.mock.calls).toEqual([
        [types.default.SET_CONV_TAB_META, exactMeta],
      ]);
    });

    describe('trailing debounce', () => {
      const context = { commit, state: { allCount: 0 } };

      beforeEach(() => {
        axios.get.mockResolvedValue({ data: { meta: { mine_count: 1 } } });
      });

      it('turns a burst of calls into one request with the latest filters', async () => {
        actions.get(context, { status: 'open', inboxId: 1 });
        await vi.advanceTimersByTimeAsync(500);
        actions.get(context, { status: 'open', inboxId: 2 });
        await vi.advanceTimersByTimeAsync(500);
        actions.get(context, { status: 'open', inboxId: 3 });

        await vi.advanceTimersByTimeAsync(1499);
        expect(axios.get).not.toHaveBeenCalled();
        await vi.advanceTimersByTimeAsync(1);

        expect(axios.get).toHaveBeenCalledOnce();
        expect(axios.get.mock.calls[0][1].params).toMatchObject({
          inbox_id: 3,
        });
      });

      it('still fires within the maximum wait while calls keep arriving', async () => {
        actions.get(context, { status: 'open', inboxId: 4 });
        for (let interval = 1; interval <= 4; interval += 1) {
          // eslint-disable-next-line no-await-in-loop
          await vi.advanceTimersByTimeAsync(1000);
          actions.get(context, { status: 'open', inboxId: 4 });
        }
        expect(axios.get).not.toHaveBeenCalled();

        await vi.advanceTimersByTimeAsync(1000);

        expect(axios.get).toHaveBeenCalledOnce();
      });

      it('waits longer on bigger accounts', async () => {
        actions.get(
          { commit, state: { allCount: 150 } },
          { status: 'open', inboxId: 5 }
        );
        await vi.advanceTimersByTimeAsync(4999);
        expect(axios.get).not.toHaveBeenCalled();
        await vi.advanceTimersByTimeAsync(1);
        expect(axios.get).toHaveBeenCalledOnce();
        await vi.advanceTimersByTimeAsync(0);

        axios.get.mockClear();
        actions.get(
          { commit, state: { allCount: 2500 } },
          { status: 'open', inboxId: 6 }
        );
        await vi.advanceTimersByTimeAsync(9999);
        expect(axios.get).not.toHaveBeenCalled();
        await vi.advanceTimersByTimeAsync(1);
        expect(axios.get).toHaveBeenCalledOnce();
      });

      it('coalesces rapid status changes and uses the latest filters within 500ms', async () => {
        for (let change = 0; change <= 9; change += 1) {
          if (change > 0) {
            // eslint-disable-next-line no-await-in-loop
            await vi.advanceTimersByTimeAsync(50);
          }
          actions.get(context, {
            status: change === 9 ? 'resolved' : 'open',
            inboxId: change,
            refreshPriority: 'realtime',
          });
        }

        await vi.advanceTimersByTimeAsync(49);
        expect(axios.get).not.toHaveBeenCalled();
        await vi.advanceTimersByTimeAsync(1);

        expect(axios.get).toHaveBeenCalledOnce();
        expect(axios.get.mock.calls[0][1].params).toMatchObject({
          status: 'resolved',
          inbox_id: 9,
        });
        expect(axios.get.mock.calls[0][1].params).not.toHaveProperty(
          'refresh_priority'
        );
      });

      it('does not run a second request while one is in flight and refreshes once afterwards', async () => {
        let resolveFirst;
        axios.get.mockImplementationOnce(
          () =>
            new Promise(resolve => {
              resolveFirst = resolve;
            })
        );
        const params = { status: 'open', inboxId: 7 };

        actions.get(context, params);
        await vi.advanceTimersByTimeAsync(1500);
        expect(axios.get).toHaveBeenCalledOnce();

        actions.get(context, params);
        actions.get(context, params);
        await vi.advanceTimersByTimeAsync(1500);
        expect(axios.get).toHaveBeenCalledOnce();

        resolveFirst({ data: { meta: { mine_count: 2 } } });
        await vi.advanceTimersByTimeAsync(2000);

        expect(axios.get).toHaveBeenCalledTimes(2);
      });

      it('does not let a list refresh cancel a pending debounced fetch', async () => {
        actions.get(context, { status: 'open', inboxId: 8 });
        await vi.advanceTimersByTimeAsync(700);

        const listMeta = { mine_count: 5, all_count: 5 };
        actions.set({ commit }, listMeta);
        await vi.advanceTimersByTimeAsync(800);
        await vi.waitFor(() => expect(commit).toHaveBeenCalledTimes(2));

        expect(axios.get).toHaveBeenCalledOnce();
        expect(commit.mock.calls).toEqual([
          [types.default.SET_CONV_TAB_META, listMeta],
          [types.default.SET_CONV_TAB_META, { mine_count: 1 }],
        ]);
      });
    });

    describe('hidden tab', () => {
      const context = { commit, state: { allCount: 0 } };

      beforeEach(() => {
        axios.get.mockResolvedValue({ data: { meta: { mine_count: 1 } } });
      });

      it('does not call the server on events while the tab is hidden', async () => {
        setTabVisibility('hidden');

        actions.get(context, { status: 'open', inboxId: 9 });
        actions.get(context, { status: 'open', inboxId: 9 });
        await vi.advanceTimersByTimeAsync(60000);

        expect(axios.get).not.toHaveBeenCalled();
      });

      it('refreshes once when the tab becomes visible again', async () => {
        setTabVisibility('hidden');
        actions.get(context, { status: 'open', inboxId: 10 });
        actions.get(context, { status: 'open', inboxId: 10 });
        actions.get(context, { status: 'open', inboxId: 10 });
        await vi.advanceTimersByTimeAsync(20000);
        expect(axios.get).not.toHaveBeenCalled();

        setTabVisibility('visible');
        await vi.advanceTimersByTimeAsync(0);
        expect(axios.get).toHaveBeenCalledOnce();
        expect(axios.get.mock.calls[0][1].params).toMatchObject({
          inbox_id: 10,
        });

        await vi.advanceTimersByTimeAsync(20000);
        expect(axios.get).toHaveBeenCalledOnce();
      });

      it('does not refresh on visibility changes when nothing happened while hidden', async () => {
        setTabVisibility('hidden');
        setTabVisibility('visible');
        await vi.advanceTimersByTimeAsync(5000);

        expect(axios.get).not.toHaveBeenCalled();
      });

      it('skips the request when the tab is hidden by the time the wait ends', async () => {
        actions.get(context, { status: 'open', inboxId: 11 });
        await vi.advanceTimersByTimeAsync(1000);
        setTabVisibility('hidden');
        await vi.advanceTimersByTimeAsync(2000);

        expect(axios.get).not.toHaveBeenCalled();

        setTabVisibility('visible');
        await vi.advanceTimersByTimeAsync(0);
        expect(axios.get).toHaveBeenCalledOnce();
      });
    });
  });

  describe('#set', () => {
    it('sends correct mutations', async () => {
      actions.set(
        { commit },
        { mine_count: 1, unassigned_count: 1, all_count: 2 }
      );
      expect(commit.mock.calls).toEqual([
        [
          types.default.SET_CONV_TAB_META,
          { mine_count: 1, unassigned_count: 1, all_count: 2 },
        ],
      ]);
    });
  });
});
