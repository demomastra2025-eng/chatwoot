import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import AssistantCard from './AssistantCard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));

vi.mock('shared/helpers/timeHelper', () => ({
  dynamicTime: () => 'today',
}));

const mountCard = (props = {}) =>
  mount(AssistantCard, {
    props: {
      id: 7,
      name: 'Мөлдір',
      description: 'Отвечает клиентам',
      updatedAt: 1700000000,
      ...props,
    },
    global: {
      directives: { 'on-clickaway': {} },
      stubs: {
        CardLayout: { template: '<div><slot /></div>' },
        DropdownMenu: true,
        Button: true,
      },
    },
  });

describe('AssistantCard', () => {
  it('shows an AI agent by its name only, without a kind badge', () => {
    const wrapper = mountCard();

    expect(wrapper.text()).toContain('Мөлдір');
    expect(wrapper.text()).not.toContain('USAGE_MODE');
  });

  it('offers the connected inboxes, edit and delete actions to an administrator', () => {
    const wrapper = mountCard();

    expect(wrapper.vm.menuItems.map(item => item.action)).toEqual([
      'viewConnectedInboxes',
      'edit',
      'delete',
    ]);
  });
});
