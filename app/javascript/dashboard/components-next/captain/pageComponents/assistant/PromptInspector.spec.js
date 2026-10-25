import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';

const promptPreviewMock = vi.fn();
const currentUser = ref({ type: 'User', role: 'administrator' });
const isImpersonating = ref(false);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { promptPreview: (...args) => promptPreviewMock(...args) },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => (key === 'getCurrentUser' ? currentUser : ref({})),
}));

vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => ({ isImpersonating }),
}));

const { default: PromptInspector } = await import('./PromptInspector.vue');

const COMPILED_PROMPT = '# Clinic\nSecret clinic instructions';

const mountInspector = () =>
  shallowMount(PromptInspector, {
    props: {
      assistantId: 58,
      assistant: { id: 58, updated_at: '2026-10-25T10:00:00Z' },
      showScenariosSection: false,
    },
  });

describe('PromptInspector', () => {
  beforeEach(() => {
    promptPreviewMock.mockReset();
    promptPreviewMock.mockResolvedValue({
      data: {
        assistant: {
          compiled_prompt: COMPILED_PROMPT,
          used_tool_ids: [],
          used_field_ids: [],
        },
        scenarios: [],
      },
    });
    currentUser.value = { type: 'User', role: 'administrator' };
    isImpersonating.value = false;
  });

  it.each([
    ['administrator', { type: 'User', role: 'administrator' }],
    ['agent', { type: 'User', role: 'agent' }],
  ])(
    'neither requests nor draws the compiled prompt for a clinic %s',
    async (_label, user) => {
      currentUser.value = user;
      const wrapper = mountInspector();
      await flushPromises();

      expect(promptPreviewMock).not.toHaveBeenCalled();
      expect(wrapper.html()).not.toContain('Secret clinic instructions');
      expect(wrapper.find('pre').exists()).toBe(false);
      expect(wrapper.text()).toBe('');
    }
  );

  it('loads and draws the compiled prompt for a super admin', async () => {
    currentUser.value = { type: 'SuperAdmin', role: 'administrator' };
    const wrapper = mountInspector();
    await flushPromises();

    expect(promptPreviewMock).toHaveBeenCalledWith(58);
    expect(wrapper.find('pre').text()).toContain('Secret clinic instructions');
  });

  it('loads the compiled prompt for a super admin inside the clinic', async () => {
    isImpersonating.value = true;
    mountInspector();
    await flushPromises();

    expect(promptPreviewMock).toHaveBeenCalledWith(58);
  });
});
