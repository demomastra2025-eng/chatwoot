import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { ref } from 'vue';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getOperatorActivity: vi.fn(),
  emitterHandlers: {},
  getters: {},
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => `${key}|${params.name || ''}`,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: name => mocks.getters[name],
}));

vi.mock('dashboard/composables/emitter', () => ({
  useEmitter: (event, handler) => {
    mocks.emitterHandlers[event] = handler;
  },
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: { getOperatorActivity: mocks.getOperatorActivity },
}));

import { useCallOperatorActivityStore } from 'dashboard/stores/callOperatorActivity';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CallOperatorIndicator from './CallOperatorIndicator.vue';

const voiceInbox = { id: 4, channel_type: 'Channel::Voice' };
const voiceChat = { id: 627, inbox_id: 4 };

const activity = (overrides = {}) => ({
  call_id: 'sipuni:local:one',
  conversation_id: 627,
  operator_user_id: 9,
  operator_name: 'Ayan',
  state: 'calling',
  ...overrides,
});

const mountIndicator = (chat = voiceChat) =>
  mount(CallOperatorIndicator, { props: { chat } });

describe('CallOperatorIndicator', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    mocks.getters = {
      getCurrentUserID: ref(7),
      'inboxes/getInbox': ref(id => (id === 4 ? voiceInbox : { id })),
    };
    mocks.emitterHandlers = {};
    mocks.getOperatorActivity.mockReset().mockResolvedValue([]);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('shows nothing while nobody is calling', async () => {
    const wrapper = mountIndicator();
    await flushPromises();

    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('says that an operator is calling the client while the call rings', async () => {
    const wrapper = mountIndicator();
    await flushPromises();

    useCallOperatorActivityStore().applyActivity(activity(), 7);
    await flushPromises();

    const line = wrapper.get('[data-testid="call-operator-activity"] p');
    expect(line.text()).toBe(
      'CONVERSATION.OPERATOR_CALL_ACTIVITY.CALLING|Ayan'
    );
    expect(line.attributes('data-state')).toBe('calling');
    wrapper.unmount();
  });

  it('says that the operator is talking once the call is answered, and clears the line when it ends', async () => {
    const wrapper = mountIndicator();
    await flushPromises();
    const store = useCallOperatorActivityStore();

    store.applyActivity(activity({ state: 'talking' }), 7);
    await flushPromises();
    expect(wrapper.get('[data-testid="call-operator-activity"] p').text()).toBe(
      'CONVERSATION.OPERATOR_CALL_ACTIVITY.TALKING|Ayan'
    );

    store.applyActivity(activity({ state: 'ended' }), 7);
    await flushPromises();
    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('shows no line about a call in another chat', async () => {
    const wrapper = mountIndicator();
    await flushPromises();

    useCallOperatorActivityStore().applyActivity(
      activity({ conversation_id: 700 }),
      7
    );
    await flushPromises();

    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('shows no line for the employee own call', async () => {
    const wrapper = mountIndicator();
    await flushPromises();
    // The store drops the own call; even a stale entry is filtered here.
    const store = useCallOperatorActivityStore();
    store.entries = {
      mine: {
        callId: 'mine',
        conversationId: 627,
        operatorUserId: 7,
        operatorName: 'Me',
        state: 'calling',
        receivedAt: Date.now(),
      },
    };
    await flushPromises();

    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('asks the server which operators are calling when a voice chat is opened', async () => {
    mocks.getOperatorActivity.mockResolvedValue([activity()]);

    const wrapper = mountIndicator();
    await flushPromises();

    expect(mocks.getOperatorActivity).toHaveBeenCalledWith({
      conversationId: 627,
    });
    expect(wrapper.get('[data-testid="call-operator-activity"] p').text()).toBe(
      'CONVERSATION.OPERATOR_CALL_ACTIVITY.CALLING|Ayan'
    );
    wrapper.unmount();
  });

  it('asks again for another chat and for a communication thread', async () => {
    const wrapper = mountIndicator();
    await flushPromises();
    mocks.getOperatorActivity.mockClear();

    await wrapper.setProps({
      chat: {
        id: 72,
        is_communication_thread: true,
        channels: [{ channel: 'Channel::Voice', conversation_id: 627 }],
      },
    });
    await flushPromises();

    expect(mocks.getOperatorActivity).toHaveBeenCalledWith({
      communicationThreadId: 72,
    });
    wrapper.unmount();
  });

  it('asks once the inbox list arrives after the chat is mounted', async () => {
    const inboxes = ref(() => undefined);
    mocks.getters['inboxes/getInbox'] = inboxes;
    mocks.getOperatorActivity.mockResolvedValue([activity()]);

    const wrapper = mountIndicator();
    await flushPromises();
    expect(mocks.getOperatorActivity).not.toHaveBeenCalled();

    inboxes.value = id => (id === 4 ? voiceInbox : { id });
    await flushPromises();

    expect(mocks.getOperatorActivity).toHaveBeenCalledTimes(1);
    expect(mocks.getOperatorActivity).toHaveBeenCalledWith({
      conversationId: 627,
    });
    expect(wrapper.get('[data-testid="call-operator-activity"] p').text()).toBe(
      'CONVERSATION.OPERATOR_CALL_ACTIVITY.CALLING|Ayan'
    );
    wrapper.unmount();
  });

  it('does not ask for chats without a voice channel', async () => {
    const wrapper = mountIndicator({ id: 12, inbox_id: 9 });
    await flushPromises();

    expect(mocks.getOperatorActivity).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('asks again when the connection comes back, after the lines were cleared', async () => {
    const wrapper = mountIndicator();
    await flushPromises();
    mocks.getOperatorActivity.mockClear();
    mocks.getOperatorActivity.mockResolvedValue([
      activity({ state: 'talking' }),
    ]);

    mocks.emitterHandlers[BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED]();
    await flushPromises();

    expect(mocks.getOperatorActivity).toHaveBeenCalledTimes(1);
    expect(wrapper.get('[data-testid="call-operator-activity"] p').text()).toBe(
      'CONVERSATION.OPERATOR_CALL_ACTIVITY.TALKING|Ayan'
    );
    wrapper.unmount();
  });

  it('keeps working when the server cannot be reached', async () => {
    mocks.getOperatorActivity.mockRejectedValue(new Error('offline'));

    const wrapper = mountIndicator();
    await flushPromises();

    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('drops a ringing line that nobody ended after a few minutes', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-05T06:00:00Z'));
    const wrapper = mountIndicator();
    await flushPromises();
    useCallOperatorActivityStore().applyActivity(activity(), 7);
    await flushPromises();
    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(true);

    await vi.advanceTimersByTimeAsync(4 * 60 * 1000);

    expect(
      wrapper.find('[data-testid="call-operator-activity"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });
});
