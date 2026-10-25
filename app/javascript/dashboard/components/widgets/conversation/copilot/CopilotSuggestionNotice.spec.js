import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import CopilotSuggestionNotice from './CopilotSuggestionNotice.vue';

const NextButtonStub = {
  props: ['label'],
  template: '<button type="button">{{ label }}</button>',
};

const mountNotice = (props, locale = 'ru', messages = ru) =>
  mount(CopilotSuggestionNotice, {
    props,
    global: {
      plugins: [
        createI18n({ legacy: false, locale, messages: { [locale]: messages } }),
      ],
      stubs: { NextButton: NextButtonStub, Icon: true },
    },
  });

const notice = (overrides = {}) => ({
  kind: 'no_reply',
  reason: 'Пациент только поблагодарил, вопросов нет.',
  reasonCode: null,
  reasonSource: 'agent',
  agent: null,
  canRetry: false,
  stale: false,
  ...overrides,
});

const text = wrapper => wrapper.get('[data-test="copilot-notice-text"]').text();

describe('CopilotSuggestionNotice', () => {
  it('says why no reply is needed, with the reason after the title', () => {
    const wrapper = mountNotice({ notice: notice() });

    expect(text(wrapper)).toBe(
      'ИИ считает, что ответ не нужен: Пациент только поблагодарил, вопросов нет.'
    );
    expect(wrapper.attributes('data-kind')).toBe('no_reply');
  });

  it('says why a staff member is needed', () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'human_needed',
        reason: 'В базе нет данных, кто оперирует ЛОР.',
      }),
    });

    expect(text(wrapper)).toBe(
      'Нужен сотрудник: В базе нет данных, кто оперирует ЛОР.'
    );
    expect(wrapper.attributes('data-kind')).toBe('human_needed');
  });

  it('shows only a short status for a failed run, with «Повторить»', async () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'failed',
        reason: null,
        reasonCode: 'timeout',
        canRetry: true,
      }),
    });

    expect(text(wrapper)).toBe('ИИ не смог подготовить ответ');
    expect(wrapper.find('[data-test="copilot-notice-reason"]').exists()).toBe(
      false
    );
    const retry = wrapper.get('[data-test="copilot-notice-retry"]');
    expect(retry.text()).toBe('Повторить');

    await retry.trigger('click');
    expect(wrapper.emitted('retry')).toHaveLength(1);
    expect(wrapper.emitted('dismiss')).toBeUndefined();
  });

  it('does not offer a retry when the run cannot be retried', () => {
    const wrapper = mountNotice({ notice: notice({ canRetry: false }) });

    expect(wrapper.find('[data-test="copilot-notice-retry"]').exists()).toBe(
      false
    );
  });

  it('emits dismiss from the close button', async () => {
    const wrapper = mountNotice({ notice: notice() });

    await wrapper.get('[data-test="copilot-notice-dismiss"]').trigger('click');

    expect(wrapper.emitted('dismiss')).toHaveLength(1);
    expect(wrapper.emitted('retry')).toBeUndefined();
  });

  it('shows the refusal text of an unavailable suggestion', () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'unavailable',
        reason: 'Лимит ИИ-ответов исчерпан.',
        reasonCode: 'quota_exceeded',
      }),
    });

    expect(text(wrapper)).toBe(
      'Подсказка ИИ недоступна Лимит ИИ-ответов исчерпан.'
    );
  });

  it('explains the voice limitation from the locale when the server sent no text', () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'unavailable',
        reason: null,
        reasonCode: 'voice_channel_unsupported',
      }),
    });

    expect(text(wrapper)).toContain(
      'В звонке нельзя отправить текст. Откройте чат клиента в мессенджере'
    );
  });

  it('names the agent that made the decision', () => {
    const wrapper = mountNotice({
      notice: notice({ agent: { id: 84, name: 'Сезім', avatarUrl: '' } }),
    });

    expect(wrapper.get('[data-test="copilot-notice-agent"]').text()).toBe(
      'Решение агента Сезім'
    );
  });

  it('says that the router decided a staff request, and names no agent', () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'human_needed',
        reason: 'Пациент просит живого сотрудника — ответьте ему сами.',
        reasonSource: 'router',
        agent: null,
      }),
    });

    expect(wrapper.get('[data-test="copilot-notice-agent"]').text()).toBe(
      'Решение маршрутизации ИИ'
    );
  });

  it.each([
    ['router_unavailable', 'ИИ не смог сейчас выбрать агента'],
    ['council_unavailable', 'ИИ не смог сейчас собрать агентов'],
  ])('explains the failure %s in a short sentence', (reasonCode, sentence) => {
    const wrapper = mountNotice({
      notice: notice({ kind: 'failed', reason: null, reasonCode }),
    });

    expect(text(wrapper)).toContain('ИИ не смог подготовить ответ');
    expect(wrapper.get('[data-test="copilot-notice-reason"]').text()).toContain(
      sentence
    );
  });

  it('warns when new customer messages arrived after the request', () => {
    const stale = mountNotice({ notice: notice(), stale: true });
    const fresh = mountNotice({ notice: notice(), stale: false });

    expect(stale.get('[data-test="copilot-notice-stale"]').text()).toContain(
      'пришли новые сообщения клиента'
    );
    expect(fresh.find('[data-test="copilot-notice-stale"]').exists()).toBe(
      false
    );
  });

  it('renders the reason as plain text and never interprets HTML', () => {
    const reason = '<img src=x onerror="alert(1)"><b>важно</b>';
    const wrapper = mountNotice({ notice: notice({ reason }) });

    expect(wrapper.find('img').exists()).toBe(false);
    expect(wrapper.find('b').exists()).toBe(false);
    expect(wrapper.get('[data-test="copilot-notice-reason"]').text()).toBe(
      reason
    );
  });

  it('falls back to a neutral reason when the agent gave none', () => {
    const wrapper = mountNotice({ notice: notice({ reason: '  ' }) });

    expect(text(wrapper)).toBe(
      'ИИ считает, что ответ не нужен: причина не указана'
    );
  });

  it('has no control that inserts, copies or sends the text', () => {
    const wrapper = mountNotice({
      notice: notice({ kind: 'failed', canRetry: true }),
    });

    const controls = wrapper
      .findAll('button')
      .map(button => button.attributes('data-test'));
    expect(controls).toEqual([
      'copilot-notice-retry',
      'copilot-notice-dismiss',
    ]);
    expect(wrapper.find('textarea').exists()).toBe(false);
    expect(wrapper.find('input').exists()).toBe(false);
    expect(wrapper.find('[contenteditable]').exists()).toBe(false);
  });

  describe.each([
    ['ru', ru],
    ['en', en],
    ['kk', kk],
  ])('titles in %s', (locale, messages) => {
    const { NOTICE } = messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION;

    it('has the texts of the router failures and of the router decision', () => {
      expect(NOTICE.ROUTER_LABEL).toBeTruthy();
      expect(NOTICE.FAILED_REASONS.ROUTER_UNAVAILABLE).toBeTruthy();
      expect(NOTICE.FAILED_REASONS.COUNCIL_UNAVAILABLE).toBeTruthy();
      expect(
        messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.ROUTING
      ).toBeTruthy();
    });

    it.each([
      ['no_reply', NOTICE.NO_REPLY_TITLE],
      ['human_needed', NOTICE.HUMAN_NEEDED_TITLE],
      ['failed', NOTICE.FAILED_TITLE],
      ['unavailable', NOTICE.UNAVAILABLE_TITLE],
    ])('uses the %s title', (kind, title) => {
      const wrapper = mountNotice(
        { notice: notice({ kind, reason: null, canRetry: true }) },
        locale,
        messages
      );

      expect(text(wrapper)).toContain(title);
      expect(wrapper.text()).not.toContain('COPILOT_SUGGESTION');
    });
  });
});
