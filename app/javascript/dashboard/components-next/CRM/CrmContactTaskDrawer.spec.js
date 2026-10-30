import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';
import CrmContactTaskDrawer from './CrmContactTaskDrawer.vue';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';

const mocks = vi.hoisted(() => ({
  crmDealsEnabled: true,
  references: {
    taskStatuses: [{ id: 2, code: 'todo', default: true, active: true }],
    taskTypes: [{ id: 3, code: 'task', default: true, active: true }],
    taskFieldDefinitions: [],
    loadTaskStatuses: vi.fn().mockResolvedValue([]),
    loadTaskTypes: vi.fn().mockResolvedValue([]),
    loadFieldDefinitions: vi.fn().mockResolvedValue([]),
  },
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) =>
      params?.contactName ? `${key}: ${params.contactName}` : key,
  }),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: name =>
    computed(() => {
      if (name === 'getCurrentUser') return { id: 7 };
      if (name === 'getCurrentAccountId') return 48;
      if (name === 'accounts/isFeatureEnabledonAccount') {
        return (_accountId, feature) =>
          feature === 'crm_deals' ? mocks.crmDealsEnabled : true;
      }
      return [{ id: 7, name: 'Agent' }];
    }),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mocks.references,
}));
vi.mock('dashboard/api/crm/deals', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/crm/tasks', () => ({
  default: {
    create: vi.fn().mockResolvedValue({ data: { payload: { id: 5 } } }),
  },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const stubs = {
  SchedulingDrawer: {
    name: 'SchedulingDrawer',
    props: ['modelValue'],
    emits: ['confirm', 'update:modelValue'],
    template: '<div><slot /></div>',
  },
  CrmTaskFormFields: {
    name: 'CrmTaskFormFields',
    props: [
      'form',
      'assigneeOptions',
      'taskPriorityOptions',
      'taskStatusOptions',
    ],
    template: '<div />',
  },
};

describe('contact task drawer', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.crmDealsEnabled = true;
    CrmDealsAPI.get.mockResolvedValue({ data: { payload: [] } });
    CrmTasksAPI.create.mockResolvedValue({ data: { payload: { id: 5 } } });
  });

  it('prefills contact, conversation display_id and all task fields before saving', async () => {
    const wrapper = shallowMount(CrmContactTaskDrawer, {
      props: {
        modelValue: true,
        contact: { id: 42, name: 'Айгерим' },
        currentChat: { id: 1074 },
      },
      global: { stubs },
    });
    await flushPromises();
    expect(useAlert).not.toHaveBeenCalled();
    const fields = wrapper.getComponent({ name: 'CrmTaskFormFields' });
    expect(fields.props('form')).toMatchObject({
      title: 'CRM.TASKS.PREFILL.CONVERSATION_WITH_CONTACT: Айгерим',
      originatingConversationId: 1074,
      originatingConversationDisplayId: 1074,
      originatingCommunicationThreadId: '',
      assigneeId: 7,
      priority: 'medium',
      statusId: 2,
    });
    expect(fields.props('assigneeOptions')).toHaveLength(1);
    expect(fields.props('taskPriorityOptions')).toHaveLength(4);
    expect(fields.props('taskStatusOptions')).toHaveLength(1);
    wrapper.getComponent({ name: 'SchedulingDrawer' }).vm.$emit('confirm');
    await flushPromises();
    expect(CrmTasksAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        title: 'CRM.TASKS.PREFILL.CONVERSATION_WITH_CONTACT: Айгерим',
        originating_conversation_display_id: 1074,
        originating_conversation_id: 1074,
        originating_communication_thread_id: undefined,
        assignee_id: 7,
        priority: 'medium',
        status_id: 2,
      })
    );
    expect(wrapper.emitted('update:modelValue')).toEqual([[false]]);
  });

  it('resolves reply channel conversation_id and thread id separately on a communication thread', async () => {
    const wrapper = shallowMount(CrmContactTaskDrawer, {
      props: {
        modelValue: true,
        contact: { id: 42, name: 'Айгерим' },
        currentChat: {
          id: 619,
          display_id: 619,
          is_communication_thread: true,
          active_reply_channel: { conversation_id: 1074 },
        },
      },
      global: { stubs },
    });
    await flushPromises();
    const fields = wrapper.getComponent({ name: 'CrmTaskFormFields' });
    expect(fields.props('form')).toMatchObject({
      originatingConversationId: 1074,
      originatingConversationDisplayId: 1074,
      originatingCommunicationThreadId: 619,
    });
    wrapper.getComponent({ name: 'SchedulingDrawer' }).vm.$emit('confirm');
    await flushPromises();
    expect(CrmTasksAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        originating_conversation_display_id: 1074,
        originating_conversation_id: 1074,
        originating_communication_thread_id: 619,
      })
    );
  });

  it('does not send thread display_id as originating_conversation_id when a thread has no conversation', async () => {
    const wrapper = shallowMount(CrmContactTaskDrawer, {
      props: {
        modelValue: true,
        contact: { id: 42, name: 'Айгерим' },
        currentChat: {
          id: 620,
          display_id: 620,
          is_communication_thread: true,
        },
      },
      global: { stubs },
    });
    await flushPromises();
    wrapper.getComponent({ name: 'SchedulingDrawer' }).vm.$emit('confirm');
    await flushPromises();
    expect(CrmTasksAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        originating_conversation_display_id: undefined,
        originating_conversation_id: undefined,
        originating_communication_thread_id: 620,
      })
    );
  });

  it('opens and saves cleanly when crm_deals is disabled or returns 403', async () => {
    mocks.crmDealsEnabled = false;
    const wrapper = shallowMount(CrmContactTaskDrawer, {
      props: {
        modelValue: true,
        contact: { id: 42, name: 'Айгерим' },
        currentChat: { id: 1074 },
      },
      global: { stubs },
    });
    await flushPromises();
    expect(CrmDealsAPI.get).not.toHaveBeenCalled();
    expect(useAlert).not.toHaveBeenCalled();

    mocks.crmDealsEnabled = true;
    CrmDealsAPI.get.mockRejectedValueOnce({ response: { status: 403 } });
    await wrapper.setProps({ modelValue: false });
    await wrapper.setProps({ modelValue: true });
    await flushPromises();
    expect(useAlert).not.toHaveBeenCalled();
    wrapper.getComponent({ name: 'SchedulingDrawer' }).vm.$emit('confirm');
    await flushPromises();
    expect(CrmTasksAPI.create).toHaveBeenCalledTimes(1);
  });
});
