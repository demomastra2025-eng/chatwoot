import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';
import CrmContactTaskDrawer from './CrmContactTaskDrawer.vue';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';

const mocks = vi.hoisted(() => ({
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
    computed(() =>
      name === 'getCurrentUser' ? { id: 7 } : [{ id: 7, name: 'Agent' }]
    ),
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
    CrmDealsAPI.get.mockResolvedValue({ data: { payload: [] } });
    CrmTasksAPI.create.mockResolvedValue({ data: { payload: { id: 5 } } });
  });

  it('prefills contact, current conversation and all task fields before saving', async () => {
    const wrapper = shallowMount(CrmContactTaskDrawer, {
      props: {
        modelValue: true,
        contact: { id: 42, name: 'Айгерим' },
        currentChat: { id: 99, display_id: 18 },
      },
      global: { stubs },
    });
    await flushPromises();
    expect(useAlert).not.toHaveBeenCalled();
    const fields = wrapper.getComponent({ name: 'CrmTaskFormFields' });
    expect(fields.props('form')).toMatchObject({
      title: 'CRM.TASKS.PREFILL.CONVERSATION_WITH_CONTACT: Айгерим',
      originatingConversationId: 99,
      originatingConversationDisplayId: 18,
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
        originating_conversation_id: 99,
        assignee_id: 7,
        priority: 'medium',
        status_id: 2,
      })
    );
    expect(wrapper.emitted('update:modelValue')).toEqual([[false]]);
  });
});
