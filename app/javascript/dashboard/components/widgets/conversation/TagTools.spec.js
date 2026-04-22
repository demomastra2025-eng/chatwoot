import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import TagTools from './TagTools.vue';

const getMock = vi.fn();

vi.mock('dashboard/api/captain/tools', () => ({
  default: {
    get: (...args) => getMock(...args),
  },
}));

vi.mock('dashboard/composables/useKeyboardNavigableList', () => ({
  useKeyboardNavigableList: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
    te: () => false,
  }),
}));

const toolsDropdownStub = {
  name: 'ToolsDropdown',
  props: {
    items: {
      type: Array,
      default: () => [],
    },
    overlay: {
      type: Boolean,
      default: false,
    },
    selectedIndex: {
      type: Number,
      default: 0,
    },
    searchValue: {
      type: String,
      default: '',
    },
  },
  emits: ['close', 'select', 'update:searchValue'],
  template: '<div />',
};

describe('TagTools', () => {
  beforeEach(() => {
    getMock.mockReset();
    getMock.mockResolvedValue({
      data: [
        {
          id: 'handoff',
          title: 'Handoff to Human',
          description: 'Hand off the conversation',
        },
      ],
    });
  });

  it('renders the tool picker in centered overlay mode', async () => {
    const wrapper = shallowMount(TagTools, {
      props: {
        searchKey: '',
        assistantId: 23,
        toolScope: 'agent',
      },
      global: {
        stubs: {
          ToolsDropdown: toolsDropdownStub,
        },
      },
    });

    await flushPromises();

    const dropdown = wrapper.findComponent({ name: 'ToolsDropdown' });
    expect(dropdown.exists()).toBe(true);
    expect(dropdown.props('overlay')).toBe(true);
  });

  it('forwards close events from the overlay dropdown', async () => {
    const wrapper = shallowMount(TagTools, {
      props: {
        searchKey: '',
        assistantId: 23,
        toolScope: 'agent',
      },
      global: {
        stubs: {
          ToolsDropdown: toolsDropdownStub,
        },
      },
    });

    await flushPromises();

    wrapper.findComponent({ name: 'ToolsDropdown' }).vm.$emit('close');

    expect(wrapper.emitted('close')).toHaveLength(1);
  });
});
