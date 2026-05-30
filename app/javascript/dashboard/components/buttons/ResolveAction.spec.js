import { ref } from 'vue';
import { mount } from '@vue/test-utils';
import { useI18n } from 'vue-i18n';
import { useStore, useStoreGetters } from 'dashboard/composables/store';

import ResolveAction from './ResolveAction.vue';

const toggleState = vi.hoisted(() => ({ initial: false }));

vi.mock('vue-i18n');
vi.mock('@vueuse/core', async () => {
  const { ref: vueRef } = await vi.importActual('vue');

  return {
    useToggle: vi.fn(() => {
      const value = vueRef(toggleState.initial);
      const toggle = nextValue => {
        value.value = typeof nextValue === 'boolean' ? nextValue : !value.value;
      };

      return [value, toggle];
    }),
  };
});
vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));
vi.mock('dashboard/composables/emitter', () => ({
  useEmitter: vi.fn(),
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));
vi.mock('dashboard/composables/useConversationRequiredAttributes', () => ({
  useConversationRequiredAttributes: () => ({
    checkMissingAttributes: vi.fn(() => ({ hasMissing: false, missing: [] })),
  }),
}));

const translations = {
  'CONVERSATION.HEADER.RESOLVE_ACTION': 'Закрыть',
  'CONVERSATION.HEADER.REOPEN_ACTION': 'Открыть',
  'CONVERSATION.HEADER.OPEN_ACTION': 'Открыть',
  'CONVERSATION.RESOLVE_DROPDOWN.SNOOZE_UNTIL': 'Отложить',
  'CONVERSATION.RESOLVE_DROPDOWN.MARK_PENDING': 'Передать AI-агенту',
};

const ButtonStub = {
  props: ['label', 'icon', 'isLoading'],
  emits: ['click'],
  template: `
    <button type="button" :aria-label="label || icon" @click="$emit('click')">
      <span v-if="label">{{ label }}</span>
      <slot />
    </button>
  `,
};

const mountComponent = (status, { dropdownOpen = false } = {}) => {
  toggleState.initial = dropdownOpen;
  useI18n.mockReturnValue({ t: key => translations[key] || key });
  useStore.mockReturnValue({ dispatch: vi.fn(() => Promise.resolve()) });
  useStoreGetters.mockReturnValue({
    getSelectedChat: ref({ id: 1, status, custom_attributes: {} }),
  });

  return mount(ResolveAction, {
    global: {
      directives: {
        'on-clickaway': vi.fn(),
      },
      stubs: {
        Button: ButtonStub,
        ButtonGroup: { template: '<div><slot /></div>' },
        WootDropdownItem: { template: '<li><slot /></li>' },
        WootDropdownMenu: { template: '<ul><slot /></ul>' },
        ConversationResolveAttributesModal: { template: '<div />' },
      },
    },
  });
};

const buttonLabels = wrapper =>
  wrapper
    .findAll('button')
    .map(button => button.text())
    .filter(Boolean);

describe('ResolveAction', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it.each([
    ['open', 'Закрыть'],
    ['resolved', 'Открыть'],
    ['pending', 'Открыть'],
    ['snoozed', 'Открыть'],
  ])(
    'renders the primary status action for %s conversations',
    (status, label) => {
      const wrapper = mountComponent(status);

      expect(buttonLabels(wrapper)).toContain(label);
    }
  );

  it('exposes direct snooze action from pending conversations', async () => {
    const wrapper = mountComponent('pending', { dropdownOpen: true });

    expect(buttonLabels(wrapper)).toContain('Отложить');
    expect(buttonLabels(wrapper)).not.toContain('Передать AI-агенту');
  });

  it('keeps snoozed conversations as open-only without extra actions', () => {
    const wrapper = mountComponent('snoozed');

    expect(
      wrapper.find('button[aria-label="i-lucide-chevron-down"]').exists()
    ).toBe(false);
    expect(buttonLabels(wrapper)).toEqual(['Открыть']);
  });
});
