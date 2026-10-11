import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CaptainPageRouteView from './CaptainPageRouteView.vue';

const mocks = vi.hoisted(() => ({
  useUISettings: vi.fn(() => ({
    uiSettings: { value: {} },
    updateUISettings: vi.fn(),
  })),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: mocks.useUISettings,
}));

const mountComponent = () =>
  shallowMount(CaptainPageRouteView, {
    global: {
      stubs: {
        RouterView: { template: '<div data-test="router-view" />' },
      },
    },
  });

describe('CaptainPageRouteView', () => {
  it('renders the AI section page inside the full-height section', () => {
    const wrapper = mountComponent();
    const section = wrapper.find('section');

    expect(section.exists()).toBe(true);
    expect(section.classes()).toContain('bg-n-surface-1');
    expect(section.find('[data-test="router-view"]').exists()).toBe(true);
  });

  it('no longer remembers the last opened agent in the UI settings', () => {
    mountComponent();

    expect(mocks.useUISettings).not.toHaveBeenCalled();
  });
});
