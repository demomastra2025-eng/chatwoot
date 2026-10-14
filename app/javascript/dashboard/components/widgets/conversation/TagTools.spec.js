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

  it('offers ordinary tools while hiding capabilities and skill scripts in an agent prompt', async () => {
    getMock.mockResolvedValue({
      data: [
        { id: 'faq_lookup', title: 'FAQ' },
        { id: 'handoff', title: 'Handoff' },
        { id: 'resolve_conversation', title: 'Resolve' },
        { id: 'cancel_response', title: 'Cancel response' },
        { id: 'add_private_note', title: 'Private note' },
        { id: 'add_contact_note', title: 'Contact note' },
        { id: 'send_notification', title: 'Notification' },
        {
          id: 'future_capability',
          title: 'Future capability',
          capability_tool: true,
        },
        { id: 'hidden_tool', title: 'Hidden', mentionable: false },
        {
          id: 'legacy_script',
          title: 'Legacy script',
          provider: 'skill_script',
        },
        { id: 'create_deal', title: 'Create deal' },
        { id: 'custom_orders', title: 'Orders', provider: 'custom' },
        {
          id: 'mcp__calendar__slots',
          title: 'Calendar slots',
          provider: 'mcp',
        },
      ],
    });
    const wrapper = shallowMount(TagTools, {
      props: { assistantId: 23, toolScope: 'agent' },
      global: { stubs: { ToolsDropdown: toolsDropdownStub } },
    });
    await flushPromises();
    const ids = wrapper
      .findComponent({ name: 'ToolsDropdown' })
      .props('items')
      .map(item => item.id);
    expect(ids).toHaveLength(6);
    expect(ids).toEqual(
      expect.arrayContaining([
        'create_deal',
        'custom_orders',
        'mcp__calendar__slots',
        'add_private_note',
        'add_contact_note',
        'send_notification',
      ])
    );
    expect(ids).not.toContain('cancel_response');
    wrapper
      .findComponent({ name: 'ToolsDropdown' })
      .vm.$emit('select', ids.indexOf('custom_orders'));
    expect(wrapper.emitted('selectTool')[0][0].id).toBe('custom_orders');
  });

  it('keeps the separate Copilot tool picker contract', async () => {
    getMock.mockResolvedValue({
      data: [
        { id: 'search_documentation', title: 'Search', capability_tool: true },
      ],
    });
    const wrapper = shallowMount(TagTools, {
      props: { toolScope: 'assistant' },
      global: { stubs: { ToolsDropdown: toolsDropdownStub } },
    });
    await flushPromises();
    expect(
      wrapper.findComponent({ name: 'ToolsDropdown' }).props('items')
    ).toHaveLength(1);
  });
});
