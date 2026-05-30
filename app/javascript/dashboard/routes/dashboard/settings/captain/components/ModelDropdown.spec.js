import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import ModelDropdown from './ModelDropdown.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
  }),
}));

const DialogStub = {
  template: '<div data-test="model-dialog"><slot /></div>',
  methods: {
    open() {},
    close() {},
  },
};

const mountComponent = () =>
  mount(ModelDropdown, {
    props: {
      featureKey: 'assistant',
      featureTitle: 'AI agent model',
    },
    global: {
      stubs: {
        Dialog: DialogStub,
        Icon: { template: '<span />' },
        LobeProviderIcon: { template: '<span data-test="provider-icon" />' },
      },
    },
  });

describe('Captain model dropdown diagnostics', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('shows backend diagnostic-only model matches during search without making them selectable', async () => {
    const store = useCaptainConfigStore();
    store.applyPayload({
      features: {
        assistant: {
          selected: 'openai/gpt-5.4',
          default: 'openai/gpt-5.4',
          models: [
            {
              id: 'openai/gpt-5.4',
              display_name: 'GPT 5.4',
              provider: 'openrouter',
              provider_configured: true,
              type: 'chat',
              capabilities: [
                'text_input',
                'text_output',
                'structured_output',
                'tool_calling',
              ],
            },
          ],
          diagnostic_models: [
            {
              id: 'openai/gpt-text-only',
              display_name: 'GPT Text Only',
              provider: 'openrouter',
              provider_configured: true,
              type: 'chat',
              capabilities: ['text_input', 'text_output', 'structured_output'],
              diagnostics: {
                allowed: false,
                reasons: [
                  {
                    code: 'tool_calling_unsupported',
                    message: 'Model does not support tool calling.',
                  },
                ],
              },
              diagnostic_only: true,
            },
          ],
        },
      },
    });

    const wrapper = mountComponent();

    expect(wrapper.find('[data-test="diagnostic-model-card"]').exists()).toBe(
      false
    );

    await wrapper.find('input[type="search"]').setValue('text only');

    const diagnosticCard = wrapper.find('[data-test="diagnostic-model-card"]');
    expect(diagnosticCard.exists()).toBe(true);
    expect(diagnosticCard.attributes('disabled')).toBeDefined();
    expect(diagnosticCard.text()).toContain('GPT Text Only');
    expect(diagnosticCard.text()).toContain(
      'CAPTAIN_SETTINGS.MODEL_CONFIG.NOT_AVAILABLE_FOR_FEATURE'
    );
    expect(
      wrapper.find('[data-test="diagnostic-model-reasons"]').text()
    ).toContain(
      'CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.REASONS.TOOL_CALLING_UNSUPPORTED'
    );

    await diagnosticCard.trigger('click');

    expect(wrapper.emitted('change')).toBeFalsy();
  });
});
