import { expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { shallowMount } from '@vue/test-utils';
import SidepanelSwitch from './SidepanelSwitch.vue';

vi.mock('dashboard/composables/useConversationSidepanelAvailability', () => ({
  useConversationSidepanelAvailability: () => ({
    activePanel: ref('tasks'),
    closePanel: vi.fn(),
    dealsAvailable: ref(true),
    tasksAvailable: ref(true),
    appointmentsAvailable: ref(true),
    openPanel: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

it('orders the rail as contact, deals, tasks, appointments', () => {
  const wrapper = shallowMount(SidepanelSwitch, {
    global: {
      mocks: { $t: key => key },
      stubs: { ButtonGroup: { template: '<div><slot /></div>' } },
    },
  });
  expect(
    wrapper
      .findAllComponents({ name: 'Button' })
      .map(button => button.props('icon'))
  ).toEqual([
    'i-ph-user-bold',
    'i-lucide-briefcase-business',
    'i-lucide-list-checks',
    'i-lucide-calendar-clock',
  ]);
});
