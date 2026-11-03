import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, ref } from 'vue';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createMemoryHistory, createRouter } from 'vue-router';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmConversationLink from 'dashboard/components-next/CRM/CrmConversationLink.vue';
import { useCrmTaskConversation } from '../useCrmTaskConversation';

vi.mock('dashboard/api/crm/tasks', () => ({ default: { show: vi.fn() } }));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: (_key, { id } = {}) => `Conversation #${id}` }),
}));

const taskRow = { id: 7, accountId: 74, originatingConversationId: 98765 };
const reference = { id: 98765, display_id: 12, account_id: 74 };
const response = (origin = reference, task = taskRow) => ({
  data: { payload: { ...task, originating_conversation: origin } },
});
const deferred = () => {
  let resolve;
  const promise = new Promise(done => {
    resolve = done;
  });
  return { promise, resolve };
};
const wrappers = [];
const mountSource = async (selectedTask = taskRow) => {
  const accountId = ref(74);
  const task = ref(selectedTask);
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      {
        path: '/app/accounts/:accountId/tasks',
        component: { template: '<div />' },
      },
      {
        path: '/app/accounts/:accountId/conversations/:conversation_id',
        name: 'inbox_conversation',
        component: { template: '<div />' },
      },
    ],
  });
  await router.push('/app/accounts/74/tasks');
  let state;
  const Harness = defineComponent({
    components: { CrmConversationLink },
    setup() {
      state = useCrmTaskConversation({ accountId, task });
      return { ...state, accountId };
    },
    template:
      '<CrmConversationLink v-if="conversation" :account-id="accountId" :display-id="conversation.displayId" />',
  });
  const wrapper = mount(Harness, { global: { plugins: [router] } });
  wrappers.push(wrapper);
  await flushPromises();
  return { wrapper, accountId, task, state, router };
};

beforeEach(() => CrmTasksAPI.show.mockReset().mockResolvedValue(response()));
afterEach(() => wrappers.splice(0).forEach(wrapper => wrapper.unmount()));

describe('task source detail access', () => {
  it('opens the real display ID from one authorized detail read', async () => {
    const { wrapper, router } = await mountSource();
    expect(CrmTasksAPI.show).toHaveBeenCalledExactlyOnceWith(7);
    expect(wrapper.text()).toBe('Conversation #12');
    await wrapper.get('button').trigger('click');
    await flushPromises();
    expect(router.currentRoute.value.fullPath).toBe(
      '/app/accounts/74/conversations/12'
    );
  });

  it('does not query unopened cards or tasks without an origin', async () => {
    const { task, state } = await mountSource(null);
    task.value = { ...taskRow, originatingConversationId: null };
    await flushPromises();
    expect(CrmTasksAPI.show).not.toHaveBeenCalled();
    expect(state.conversation.value).toBeNull();
  });

  it('uses the authoritative detail when the list has an older origin', async () => {
    const currentTask = { ...taskRow, originatingConversationId: 34567 };
    CrmTasksAPI.show.mockResolvedValueOnce(
      response({ id: 34567, display_id: 13, account_id: 74 }, currentTask)
    );
    const { wrapper } = await mountSource();
    expect(wrapper.get('button').text()).toBe('Conversation #13');
  });

  it('uses an existing canonical detail without another request', async () => {
    const detail = {
      ...taskRow,
      originatingConversation: { id: 98765, displayId: 12, accountId: 74 },
    };
    const { wrapper } = await mountSource(detail);
    expect(CrmTasksAPI.show).not.toHaveBeenCalled();
    expect(wrapper.get('button').text()).toBe('Conversation #12');
  });

  it('keeps the reference through index snapshots, but accepts an explicit access denial from detail', async () => {
    const { task, state } = await mountSource();
    task.value = { ...taskRow, title: 'Updated by a list reload' };
    await flushPromises();
    expect(state.conversation.value?.displayId).toBe(12);
    expect(CrmTasksAPI.show).toHaveBeenCalledTimes(1);
    task.value = { ...taskRow, originatingConversation: null };
    await flushPromises();
    expect(state.conversation.value).toBeNull();
  });

  it.each([null, { ...reference, id: 123 }, { ...reference, account_id: 75 }])(
    'leaves missing, inaccessible or mismatched origin %s without an action',
    async origin => {
      CrmTasksAPI.show.mockResolvedValueOnce(response(origin));
      const { wrapper, state } = await mountSource();
      expect(state.conversation.value).toBeNull();
      expect(wrapper.find('button').exists()).toBe(false);
    }
  );

  it.each([403, 404])(
    'leaves a denied/deleted detail (%s) without an action',
    async status => {
      CrmTasksAPI.show.mockRejectedValueOnce({ response: { status } });
      const { wrapper } = await mountSource();
      expect(wrapper.find('button').exists()).toBe(false);
    }
  );

  it('ignores a late response after switching tasks', async () => {
    const old = deferred();
    CrmTasksAPI.show.mockReturnValueOnce(old.promise);
    const { task, state } = await mountSource();
    const nextTask = { id: 8, accountId: 74, originatingConversationId: 34567 };
    CrmTasksAPI.show.mockResolvedValueOnce(
      response({ id: 34567, display_id: 99, account_id: 74 }, nextTask)
    );
    task.value = nextTask;
    await flushPromises();
    old.resolve(response());
    await flushPromises();
    expect(state.conversation.value).toMatchObject({
      id: 34567,
      displayId: 99,
    });
  });

  it('clears access on account switch and ignores the prior account response', async () => {
    const old = deferred();
    CrmTasksAPI.show.mockReturnValueOnce(old.promise);
    const { task, accountId, state, router } = await mountSource();
    await router.push('/app/accounts/75/tasks');
    accountId.value = 75;
    const nextTask = { ...taskRow, accountId: 75 };
    CrmTasksAPI.show.mockResolvedValueOnce(response(null, nextTask));
    task.value = nextTask;
    await flushPromises();
    old.resolve(response());
    await flushPromises();
    expect(state.conversation.value).toBeNull();
  });

  it('ignores a pending response after the editor closes', async () => {
    const old = deferred();
    CrmTasksAPI.show.mockReturnValueOnce(old.promise);
    const { task, state } = await mountSource();
    task.value = null;
    old.resolve(response());
    await flushPromises();
    expect(state.conversation.value).toBeNull();
  });
});
