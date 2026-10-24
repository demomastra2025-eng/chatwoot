import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import CopilotEditor from './CopilotEditor.vue';

// A plain button that renders the label and keeps the icon visible to tests
const NextButtonStub = {
  props: ['label', 'icon'],
  template: '<button type="button" :data-icon="icon">{{ label }}</button>',
};

const mountEditor = (props = {}, locale = 'ru', messages = ru) =>
  mount(CopilotEditor, {
    props: {
      generatedContent: 'Здравствуйте! Завтра в 10:00 есть окно.',
      autofocus: false,
      ...props,
    },
    attachTo: document.body,
    global: {
      plugins: [
        createI18n({ legacy: false, locale, messages: { [locale]: messages } }),
      ],
      stubs: { NextButton: NextButtonStub },
      directives: {
        'dompurify-html': (el, binding) => {
          el.innerHTML = binding.value;
        },
      },
    },
  });

const submit = wrapper => wrapper.get('[data-test="copilot-refine-submit"]');

describe('CopilotEditor', () => {
  it('shows the draft preview', () => {
    const wrapper = mountEditor();

    expect(wrapper.text()).toContain('Здравствуйте! Завтра в 10:00 есть окно.');
    wrapper.unmount();
  });

  it('tells that the inserted text can be edited like a normal message', () => {
    const wrapper = mountEditor();

    expect(wrapper.get('[data-test="copilot-edit-hint"]').text()).toBe(
      'После вставки текст можно править как обычное сообщение'
    );
    wrapper.unmount();
  });

  it('replaces the round arrow with a labelled «Исправить с ИИ» button', () => {
    const wrapper = mountEditor();

    expect(submit(wrapper).text()).toBe('Исправить с ИИ');
    expect(submit(wrapper).attributes('data-icon')).not.toBe(
      'i-lucide-arrow-up'
    );
    expect(wrapper.findAll('button')).toHaveLength(1);
    wrapper.unmount();
  });

  it('keeps «Исправить с ИИ» disabled until something is typed', async () => {
    const wrapper = mountEditor({ modelValue: '' });
    expect(submit(wrapper).attributes('disabled')).toBeDefined();

    await wrapper.setProps({ modelValue: '   ' });
    expect(submit(wrapper).attributes('disabled')).toBeDefined();

    await wrapper.setProps({ modelValue: 'короче' });
    expect(submit(wrapper).attributes('disabled')).toBeUndefined();
    wrapper.unmount();
  });

  it('emits send when «Исправить с ИИ» is pressed', async () => {
    const wrapper = mountEditor({ modelValue: 'предложи время на завтра' });

    await submit(wrapper).trigger('click');

    expect(wrapper.emitted('send')).toHaveLength(1);
    wrapper.unmount();
  });

  it('uses the placeholder the parent passes, with no built-in English default', () => {
    const wrapper = mountEditor({
      placeholder: 'Что исправить? Например: короче, предложи время на завтра',
    });

    expect(wrapper.html()).toContain(
      'Что исправить? Например: короче, предложи время на завтра'
    );
    expect(wrapper.html()).not.toContain('Give copilot');
    wrapper.unmount();
  });

  describe.each([
    ['ru', ru],
    ['en', en],
    ['kk', kk],
  ])('texts in %s', (locale, messages) => {
    const labels = messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION;

    it('renders the translated hint and button', () => {
      const wrapper = mountEditor({}, locale, messages);

      expect(wrapper.get('[data-test="copilot-edit-hint"]').text()).toBe(
        labels.EDIT_HINT
      );
      expect(submit(wrapper).text()).toBe(labels.REFINE_BUTTON);
      wrapper.unmount();
    });
  });
});
