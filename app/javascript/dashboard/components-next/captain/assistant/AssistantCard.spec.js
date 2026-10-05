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
    expect(wrapper.text()).not.toContain('CAPTAIN.ASSISTANTS.INTERNAL_LABEL');
    expect(wrapper.text()).not.toContain('USAGE_MODE');
  });

  it('marks one of the few internal assistants with a quiet label', () => {
    const wrapper = mountCard({ usageMode: 'internal_assistant' });

    expect(wrapper.text()).toContain('Мөлдір');
    expect(wrapper.text()).toContain('CAPTAIN.ASSISTANTS.INTERNAL_LABEL');
    expect(wrapper.text()).not.toContain('USAGE_MODE');
  });
});
