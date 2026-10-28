import { beforeEach, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia } from 'pinia';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmContactTasksSidebar from './CrmContactTasksSidebar.vue';

const mocks = vi.hoisted(() => ({
  push: vi.fn(),
  references: {
    taskStatuses: [{ id: 1, name: 'Open' }],
    taskTypes: [],
    loadTaskStatuses: vi.fn().mockResolvedValue(),
    loadTaskTypes: vi.fn().mockResolvedValue(),
  },
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({
  useRouter: () => ({ push: mocks.push }),
  useRoute: () => ({ params: { accountId: '1' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    __v_isRef: true,
    value: [{ id: 5, name: 'Operator' }],
  }),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mocks.references,
}));
vi.mock('dashboard/api/crm/tasks', () => ({
  default: { get: vi.fn(), complete: vi.fn() },
}));

const currentChat = { id: 30, meta: { sender: { id: 7 } } };
const contact = { id: 7, name: 'Client' };
const mountPanel = () =>
  shallowMount(CrmContactTasksSidebar, {
    props: { contact, currentChat },
    global: { plugins: [createPinia()] },
  });

beforeEach(() => {
  vi.clearAllMocks();
  CrmTasksAPI.get.mockResolvedValue({
    data: {
      payload: [
        {
          id: 2,
          title: 'Completed',
          completedAt: '2026-10-28',
          dueOn: '2026-10-29',
        },
        {
          id: 1,
          title: 'Call client',
          dueOn: '2026-10-28',
          assigneeId: 5,
          statusId: 1,
          lockVersion: 0,
        },
      ],
    },
  });
});

it('loads only this contact and lists open tasks before completed tasks', async () => {
  const wrapper = mountPanel();
  await flushPromises();
  expect(CrmTasksAPI.get).toHaveBeenCalledWith({
    contact_id: 7,
    page: 1,
    per_page: 100,
  });
  const titles = wrapper
    .findAll('[data-test="contact-tasks-panel"] button')
    .map(button => button.text());
  expect(titles.findIndex(text => text.includes('Call client'))).toBeLessThan(
    titles.findIndex(text => text.includes('Completed'))
  );
  expect(wrapper.text()).toContain('Operator');
});

it('opens the full task drawer with the contact and dialog', async () => {
  const wrapper = mountPanel();
  await flushPromises();
  await wrapper
    .find('[data-test="contact-tasks-panel"] button')
    .trigger('click');
  const drawer = wrapper.findComponent({ name: 'CrmContactTaskDrawer' });
  expect(drawer.props('contact')).toEqual(contact);
  expect(drawer.props('currentChat')).toEqual(currentChat);
  expect(drawer.props('modelValue')).toBe(true);
});

it('completes a task through the existing completion dialog', async () => {
  CrmTasksAPI.complete.mockResolvedValue({});
  const wrapper = mountPanel();
  await flushPromises();
  wrapper
    .findComponent({ name: 'CrmTaskCompletionDialog' })
    .vm.$emit('confirm', {
      task: { id: 1, lockVersion: 0 },
      taskOutcomeId: 10,
      note: 'Called',
    });
  await flushPromises();

  expect(CrmTasksAPI.complete).toHaveBeenCalledWith(1, {
    task_outcome_id: 10,
    outcome_note: 'Called',
    lock_version: 0,
  });
});
