import { describe, it, expect, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import KaspiPayComposerButton from './KaspiPayComposerButton.vue';

const buildStore = ({ enabled }) =>
  createStore({
    modules: {
      integrations: {
        namespaced: true,
        getters: {
          getAppIntegrations: () => [{ id: 'kaspi_pay', enabled }],
          getIntegration: () => id =>
            id === 'kaspi_pay' ? { id: 'kaspi_pay', enabled, hooks: [] } : {},
          getUIFlags: () => ({ isFetching: false }),
        },
        actions: {
          get: vi.fn(),
        },
      },
    },
  });

describe('KaspiPayComposerButton', () => {
  it('renders the quick Kaspi Pay composer button only when Kaspi Pay is enabled on the account', () => {
    const disabledWrapper = mount(KaspiPayComposerButton, {
      props: { conversationId: 42, contactPhone: '+77011112233' },
      global: {
        plugins: [buildStore({ enabled: false })],
        mocks: { $t: k => k },
        directives: { tooltip: () => {} },
        stubs: { KaspiPayModal: true, NextButton: { template: '<button />' } },
      },
    });
    expect(
      disabledWrapper.find('[data-test="kaspi-composer-btn"]').exists()
    ).toBe(false);

    const enabledWrapper = mount(KaspiPayComposerButton, {
      props: { conversationId: 42, contactPhone: '+77011112233' },
      global: {
        plugins: [buildStore({ enabled: true })],
        mocks: { $t: k => k },
        directives: { tooltip: () => {} },
        stubs: { KaspiPayModal: true, NextButton: { template: '<button />' } },
      },
    });
    expect(
      enabledWrapper.find('[data-test="kaspi-composer-btn"]').exists()
    ).toBe(true);
  });
});
