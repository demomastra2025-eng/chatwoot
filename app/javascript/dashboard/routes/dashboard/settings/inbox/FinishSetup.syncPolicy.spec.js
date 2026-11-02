import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { createMemoryHistory, createRouter } from 'vue-router';
import FinishSetup from './FinishSetup.vue';

afterEach(() => vi.useRealTimers());

describe('Telegram setup automatic history', () => {
  it.each([
    [
      'code_sent',
      'input[autocomplete="one-time-code"]',
      '12345',
      'inboxes/verifyTelegramPersonalCode',
      'code',
    ],
    [
      'password_required',
      'input[type="password"]',
      'Synthetic password',
      'inboxes/verifyTelegramPersonalPassword',
      'password',
    ],
  ])(
    'preserves %s login without invoking a support-only reset',
    async (lifecycle, selector, value, action, field) => {
      const calls = [];
      const store = createStore({
        state: {
          inbox: {
            id: 5,
            account_id: 1,
            channel_type: 'Channel::TelegramPersonal',
            lifecycle_state: lifecycle,
            connection_state: 'connected',
            runtime_state: {},
          },
        },
        getters: {
          'inboxes/getInbox': state => () => state.inbox,
          'inboxes/getInboxById': state => () => state.inbox,
          'inboxes/getFacebookInboxByInstagramId': () => () => undefined,
          getSelectedChat: () => ({}),
        },
        actions: {
          [action]: ({ state }, payload) => {
            calls.push({ action, payload });
            state.inbox = {
              ...state.inbox,
              lifecycle_state: 'connected',
              runtime_state: { history_sync_state: 'scheduled' },
            };
          },
          'inboxes/getTelegramPersonalDiagnostics': () => ({}),
        },
      });
      const dispatch = vi.spyOn(store, 'dispatch');
      const router = createRouter({
        history: createMemoryHistory(),
        routes: [
          {
            path: '/app/accounts/:accountId/inboxes/:inbox_id/finish',
            name: 'settings_inbox_finish',
            component: { render: () => null },
          },
          {
            path: '/app/accounts/:accountId/inboxes/:inboxId',
            name: 'settings_inbox_show',
            component: { render: () => null },
          },
          {
            path: '/app/accounts/:accountId/inbox/:inbox_id',
            name: 'inbox_dashboard',
            component: { render: () => null },
          },
        ],
      });
      await router.push(
        '/app/accounts/1/inboxes/5/finish?channel_type=telegram_personal'
      );
      vi.useFakeTimers({
        toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval'],
      });
      const wrapper = mount(FinishSetup, {
        global: { plugins: [store, router], stubs: { NextButton: false } },
      });
      await flushPromises();
      expect(wrapper.find('input[type="checkbox"]').exists()).toBe(false);
      await wrapper.find(selector).setValue(value);
      await wrapper
        .find(selector)
        .element.closest('form')
        .dispatchEvent(
          new Event('submit', { bubbles: true, cancelable: true })
        );
      await flushPromises();
      expect(calls).toEqual([
        { action, payload: { inboxId: 5, [field]: value } },
      ]);
      expect(dispatch.mock.calls.map(([name]) => name)).not.toContain(
        'inboxes/historySyncTelegramPersonal'
      );
      expect(dispatch.mock.calls.map(([name]) => name)).not.toContain(
        'inboxes/contactsSyncTelegramPersonal'
      );
      await vi.advanceTimersByTimeAsync(1500);
      expect(router.currentRoute.value.name).toBe('settings_inbox_show');
      wrapper.unmount();
    }
  );
});
