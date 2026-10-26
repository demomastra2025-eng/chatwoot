import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import CopilotReplyBottomPanel from './CopilotReplyBottomPanel.vue';

// A plain button that renders the label and keeps what the tests look at: the
// global NextButton stub drops the label
const NextButtonStub = {
  props: ['label', 'variant', 'color', 'size'],
  template:
    '<button type="button" :data-variant="variant" :data-color="color">{{ label }}</button>',
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

const insert = wrapper => wrapper.find('[data-test="copilot-panel-accept"]');
const cancel = wrapper => wrapper.find('[data-test="copilot-panel-cancel"]');
const labels = wrapper =>
  wrapper.findAll('button').map(button => button.text());

describe('CopilotReplyBottomPanel', () => {
  describe('after the draft is ready', () => {
    it('offers only «Вставить» and «Отменить»', () => {
      const wrapper = mountPanel();

      expect(labels(wrapper)).toEqual(['Вставить', 'Отменить']);
      ['Обновить', 'Отклонить', 'Принять', 'Редактировать', 'Закрыть'].forEach(
        word => expect(wrapper.text()).not.toContain(word)
      );
    });

    it('makes «Вставить» the blue main button', () => {
      const wrapper = mountPanel();

      expect(insert(wrapper).attributes('data-variant')).toBe('solid');
      expect(insert(wrapper).attributes('data-color')).toBe('blue');
      expect(wrapper.html()).not.toMatch(/iris|violet|purple/);
    });

    it('keeps the shortcut out of the label and in the tooltip', () => {
      const wrapper = mountPanel();

      expect(insert(wrapper).text()).toBe('Вставить');
      expect(insert(wrapper).attributes('title')).toMatch(
        /^Вставить в поле ответа \(.+\)$/
      );
    });

    it('emits submit from «Вставить» and reject from «Отменить»', async () => {
      const wrapper = mountPanel();

      await insert(wrapper).trigger('click');
      await cancel(wrapper).trigger('click');

      expect(wrapper.emitted('submit')).toHaveLength(1);
      expect(wrapper.emitted('reject')).toHaveLength(1);
      expect(wrapper.emitted('cancel')).toBeUndefined();
    });

    it('disables «Вставить» while the draft is still animating in', () => {
      const wrapper = mountPanel({ isGeneratingContent: true });

      expect(insert(wrapper).attributes('disabled')).toBeDefined();
      expect(cancel(wrapper).attributes('disabled')).toBeUndefined();
    });

    it('shows no counter, no timer and no queue text', () => {
      const wrapper = mountPanel({ elapsedSeconds: 12, budgetSeconds: 60 });

      expect(wrapper.text()).not.toMatch(/\d/);
      expect(
        wrapper.find('[data-test="copilot-panel-progress"]').exists()
      ).toBe(false);
    });
  });

  describe('while the suggestion is being prepared', () => {
    const generating = (props = {}) =>
      mountPanel({
        isGenerating: true,
        isGeneratingContent: true,
        canCancel: true,
        ...props,
      });

    it('offers only «Отменить», with no disabled «Вставить»', () => {
      const wrapper = generating();

      expect(labels(wrapper)).toEqual(['Отменить']);
      expect(insert(wrapper).exists()).toBe(false);
    });

    it('emits cancel, not reject', async () => {
      const wrapper = generating();

      await cancel(wrapper).trigger('click');

      expect(wrapper.emitted('cancel')).toHaveLength(1);
      expect(wrapper.emitted('reject')).toBeUndefined();
      expect(wrapper.emitted('submit')).toBeUndefined();
    });

    it('disables «Отменить» when the request cannot be cancelled', () => {
      const wrapper = generating({ canCancel: false });

      expect(cancel(wrapper).attributes('disabled')).toBeDefined();
    });

    it('shows no counter and no queue text, only the glow above says what happens', () => {
      const wrapper = generating({ isQueued: true, elapsedSeconds: 12 });

      expect(wrapper.text()).toBe('Отменить');
    });
  });

  describe('when the run left only actions and no draft', () => {
    const actionsOnly = (props = {}) =>
      mountPanel({ actionsOnly: true, canCancel: true, ...props });

    it('offers only «Отменить», with no «Вставить»', () => {
      const wrapper = actionsOnly();

      expect(labels(wrapper)).toEqual(['Отменить']);
      expect(insert(wrapper).exists()).toBe(false);
      expect(cancel(wrapper).attributes('disabled')).toBeUndefined();
    });

    it('emits reject, which declines the actions, not cancel', async () => {
      const wrapper = actionsOnly();

      await cancel(wrapper).trigger('click');

      expect(wrapper.emitted('reject')).toHaveLength(1);
      expect(wrapper.emitted('cancel')).toBeUndefined();
      expect(wrapper.emitted('submit')).toBeUndefined();
    });

    it('disables «Отменить» when no action is left to decline', () => {
      const wrapper = actionsOnly({ canCancel: false });

      expect(cancel(wrapper).attributes('disabled')).toBeDefined();
    });

    it('is the same button as that of a draft', () => {
      const draftWrapper = mountPanel();
      const actionsWrapper = actionsOnly();

      expect(cancel(actionsWrapper).text()).toBe(cancel(draftWrapper).text());
      expect(cancel(actionsWrapper).attributes('data-variant')).toBe(
        cancel(draftWrapper).attributes('data-variant')
      );
    });
  });

  describe.each([
    ['ru', ru],
    ['en', en],
    ['kk', kk],
  ])('labels in %s', (locale, messages) => {
    const texts = messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION;

    it('uses the translated insert and cancel labels', () => {
      const readyWrapper = mountPanel({}, locale, messages);
      const generatingWrapper = mountPanel(
        { isGenerating: true },
        locale,
        messages
      );

      expect(labels(readyWrapper)).toEqual([texts.INSERT, texts.CANCEL]);
      expect(labels(generatingWrapper)).toEqual([texts.CANCEL]);
      expect(insert(readyWrapper).attributes('title')).toContain('(');
      expect(readyWrapper.text()).not.toContain('COPILOT_SUGGESTION');
    });
  });
});
