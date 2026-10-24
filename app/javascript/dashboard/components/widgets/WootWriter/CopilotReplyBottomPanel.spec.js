import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import CopilotReplyBottomPanel from './CopilotReplyBottomPanel.vue';

// A plain button that renders the label: the global NextButton stub drops it
const NextButtonStub = {
  props: ['label'],
  template: '<button type="button">{{ label }}</button>',
};

const mountPanel = (props = {}, locale = 'ru', messages = ru) =>
  mount(CopilotReplyBottomPanel, {
    props,
    global: {
      plugins: [
        createI18n({ legacy: false, locale, messages: { [locale]: messages } }),
      ],
      stubs: { NextButton: NextButtonStub },
    },
  });

const left = wrapper => wrapper.get('[data-test="copilot-panel-left"]');
const accept = wrapper => wrapper.get('[data-test="copilot-panel-accept"]');
const progress = wrapper =>
  wrapper.find('[data-test="copilot-panel-progress"]');

describe('CopilotReplyBottomPanel', () => {
  describe('after the draft is ready', () => {
    it('offers «Вставить и редактировать» and «Отклонить», not the old «Принять»', () => {
      const wrapper = mountPanel();

      expect(accept(wrapper).text()).toMatch(
        /^Вставить и редактировать\s+\(.+\)$/
      );
      expect(left(wrapper).text()).toBe('Отклонить');
      expect(wrapper.text()).not.toContain('Принять');
      expect(wrapper.text()).not.toContain('Отменить');
    });

    it('emits submit from the insert button and reject from the left button', async () => {
      const wrapper = mountPanel();

      await accept(wrapper).trigger('click');
      await left(wrapper).trigger('click');

      expect(wrapper.emitted('submit')).toHaveLength(1);
      expect(wrapper.emitted('reject')).toHaveLength(1);
      expect(wrapper.emitted('cancel')).toBeUndefined();
    });

    it('disables the insert button while the draft is not ready', () => {
      const wrapper = mountPanel({ isGeneratingContent: true });

      expect(accept(wrapper).attributes('disabled')).toBeDefined();
    });

    it('does not show a counter once the draft is ready', () => {
      const wrapper = mountPanel({ elapsedSeconds: 12 });

      expect(progress(wrapper).exists()).toBe(false);
    });
  });

  describe('while the suggestion is being generated', () => {
    const generating = (props = {}) =>
      mountPanel({
        isGenerating: true,
        isGeneratingContent: true,
        canCancel: true,
        ...props,
      });

    it('shows an enabled «Отменить» that emits cancel', async () => {
      const wrapper = generating();

      expect(left(wrapper).text()).toBe('Отменить');
      expect(left(wrapper).attributes('disabled')).toBeUndefined();
      expect(wrapper.text()).not.toContain('Отклонить');

      await left(wrapper).trigger('click');

      expect(wrapper.emitted('cancel')).toHaveLength(1);
      expect(wrapper.emitted('reject')).toBeUndefined();
    });

    it('keeps the insert button disabled and labelled', () => {
      const wrapper = generating();

      expect(accept(wrapper).attributes('disabled')).toBeDefined();
      expect(accept(wrapper).text()).toContain('Вставить и редактировать');
    });

    it('disables the cancel button when the request cannot be cancelled', () => {
      const wrapper = generating({ canCancel: false });

      expect(left(wrapper).attributes('disabled')).toBeDefined();
    });

    it('shows the elapsed time against the budget', () => {
      const wrapper = generating({ elapsedSeconds: 12, budgetSeconds: 60 });

      expect(progress(wrapper).text()).toBe('12 с из ~60 с');
    });

    it('shows that the request is queued', () => {
      const wrapper = generating({ isQueued: true, elapsedSeconds: null });

      expect(progress(wrapper).text()).toBe('В очереди…');
    });

    it('shows no progress text before the first timing is known', () => {
      const wrapper = generating({ elapsedSeconds: null });

      expect(progress(wrapper).exists()).toBe(false);
    });
  });

  describe.each([
    ['ru', ru],
    ['en', en],
    ['kk', kk],
  ])('labels in %s', (locale, messages) => {
    const labels = messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION;

    it('uses the translated insert, cancel and reject labels', () => {
      const generatingWrapper = mountPanel(
        { isGenerating: true },
        locale,
        messages
      );
      const readyWrapper = mountPanel({}, locale, messages);

      expect(left(generatingWrapper).text()).toBe(labels.CANCEL);
      expect(left(readyWrapper).text()).toBe(labels.REJECT);
      expect(accept(readyWrapper).text()).toContain(labels.INSERT_AND_EDIT);
      expect(readyWrapper.text()).not.toContain('COPILOT_SUGGESTION');
    });
  });
});
