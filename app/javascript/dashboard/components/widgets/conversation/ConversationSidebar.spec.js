import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { shallowMount } from '@vue/test-utils';

import ConversationSidebar from './ConversationSidebar.vue';

const mocks = vi.hoisted(() => ({
  uiSettings: null,
  width: null,
  updateUISettings: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
    updateUISettings: mocks.updateUISettings,
  }),
}));

vi.mock('@vueuse/core', () => ({
  useWindowSize: () => ({ width: mocks.width }),
}));

const mountComponent = () =>
  shallowMount(ConversationSidebar, {
    props: {
      currentChat: {
        id: 1,
        inbox_id: 2,
      },
    },
    global: {
      stubs: {
        ContactPanel: true,
        TouchEditorDrawer: true,
      },
    },
  });

describe('ConversationSidebar', () => {
  beforeEach(() => {
    mocks.width = ref(390);
    mocks.updateUISettings.mockClear();
  });

  it('moves the mobile drawer off-canvas when no sidebar tab is open', () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: false,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toContain('ltr:translate-x-full');
    expect(wrapper.classes()).toContain('rtl:-translate-x-full');
    expect(wrapper.classes()).toContain('pointer-events-none');
  });

  it('keeps the mobile drawer visible when contact sidebar is open', () => {
    mocks.uiSettings = ref({
      is_contact_sidebar_open: true,
      is_touch_sidebar_open: false,
    });

    const wrapper = mountComponent();

    expect(wrapper.classes()).toContain('translate-x-0');
    expect(wrapper.classes()).not.toContain('pointer-events-none');
  });
});
