import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h, nextTick, ref } from 'vue';
import { mount } from '@vue/test-utils';

const mocks = vi.hoisted(() => ({
  useVoiceAgentPreview: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/useVoiceAgentPreview', () => ({
  useVoiceAgentPreview: (...args) => mocks.useVoiceAgentPreview(...args),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    props: {
      label: { type: String, default: '' },
      isLoading: { type: Boolean, default: false },
    },
    emits: ['click'],
    setup(props, { attrs, emit }) {
      return () =>
        h(
          'button',
          {
            ...attrs,
            'data-loading': String(props.isLoading),
            onClick: () => emit('click'),
          },
          props.label
        );
    },
  }),
}));

const { default: VoiceAgentPreview } = await import('./VoiceAgentPreview.vue');

describe('VoiceAgentPreview', () => {
  let state;

  beforeEach(() => {
    const status = ref('idle');
    state = {
      elapsedSeconds: ref(65),
      errorCode: ref(''),
      inputLevel: ref(0.2),
      isActive: computed(() =>
        ['connecting', 'listening', 'speaking'].includes(status.value)
      ),
      isConnected: computed(() =>
        ['listening', 'speaking'].includes(status.value)
      ),
      isMuted: ref(false),
      outputLevel: ref(0.5),
      provider: ref(''),
      start: vi.fn(),
      status,
      stop: vi.fn(),
      toggleMute: vi.fn(),
    };
    mocks.useVoiceAgentPreview.mockReset();
    mocks.useVoiceAgentPreview.mockReturnValue(state);
  });

  it('uses readable provider and accessible lifecycle controls', async () => {
    const wrapper = mount(VoiceAgentPreview, {
      props: { assistantId: 57, configuredProvider: 'gemini-live' },
    });

    expect(wrapper.text()).toContain('Gemini Live');
    expect(wrapper.text()).not.toContain('gemini-live');
    expect(wrapper.get('[role="status"]').attributes('aria-live')).toBe(
      'polite'
    );

    await wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.START')
      )
      .trigger('click');
    expect(state.start).toHaveBeenCalledOnce();

    state.status.value = 'connecting';
    await nextTick();
    const connectingButtons = wrapper.findAll('button');
    expect(
      connectingButtons.some(button =>
        button.text().includes('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.CANCEL')
      )
    ).toBe(true);
    expect(
      connectingButtons
        .find(button => button.attributes('aria-pressed'))
        ?.attributes('disabled')
    ).toBeDefined();

    state.status.value = 'listening';
    await nextTick();
    const muteButton = wrapper.get('button[aria-pressed="false"]');
    expect(muteButton.attributes('disabled')).toBeUndefined();
    expect(wrapper.text()).toContain('01:05');
  });

  it('shows a muted microphone as a filled red pressed button with its own label', async () => {
    state.status.value = 'listening';
    const wrapper = mount(VoiceAgentPreview, {
      props: { assistantId: 57, configuredProvider: 'gemini-live' },
    });

    const microphone = () => wrapper.get('button[aria-pressed]');
    expect(microphone().attributes('aria-pressed')).toBe('false');
    expect(microphone().classes()).not.toContain('bg-n-ruby-9');
    expect(microphone().attributes('aria-label')).toBe(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.MUTE'
    );

    state.isMuted.value = true;
    await nextTick();

    expect(microphone().attributes('aria-pressed')).toBe('true');
    expect(microphone().classes()).toEqual(
      expect.arrayContaining(['bg-n-ruby-9', 'text-white'])
    );
    expect(microphone().attributes('aria-label')).toBe(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.MICROPHONE_MUTED'
    );
    expect(microphone().attributes('title')).toBe(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.MICROPHONE_MUTED'
    );
    expect(microphone().find('.i-lucide-mic-off').exists()).toBe(true);

    await microphone().trigger('click');
    expect(state.toggleMute).toHaveBeenCalledOnce();
  });

  it('shows the GPT Live provider label', () => {
    const wrapper = mount(VoiceAgentPreview, {
      props: { assistantId: 57, configuredProvider: 'openai-live' },
    });

    expect(wrapper.text()).toContain('OpenAI GPT Live');
    expect(wrapper.text()).not.toContain('openai-live');
  });
});
