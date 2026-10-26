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

const title = wrapper =>
  wrapper.get('[data-test="copilot-notice-title"]').text();
const reason = wrapper =>
  wrapper.get('[data-test="copilot-notice-reason"]').text();

describe('CopilotSuggestionNotice', () => {
  it('says that no reply is needed, with the reason on the second line', () => {
    const wrapper = mountNotice({ notice: notice() });

    expect(title(wrapper)).toBe('Ответ не нужен');
    expect(reason(wrapper)).toBe('Пациент только поблагодарил, вопросов нет.');
    expect(wrapper.attributes('data-kind')).toBe('no_reply');
  });

  it('says «Нужен сотрудник» without a colon and gives the reason below', () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'human_needed',
        reason: 'В базе нет данных, кто оперирует ЛОР.',
      }),
    });

    expect(title(wrapper)).toBe('Нужен сотрудник');
    expect(reason(wrapper)).toBe('В базе нет данных, кто оперирует ЛОР.');
    expect(wrapper.attributes('data-kind')).toBe('human_needed');
  });

  it('says «Не удалось подготовить ответ» with one calm line and «Повторить»', async () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'failed',
        reason: null,
        reasonCode: 'timeout',
        canRetry: true,
      }),
    });

    expect(title(wrapper)).toBe('Не удалось подготовить ответ');
    expect(reason(wrapper)).toBe('Попробуйте ещё раз или ответьте сами.');
    const retry = wrapper.get('[data-test="copilot-notice-retry"]');
    expect(retry.text()).toBe('Повторить');

    await retry.trigger('click');
    expect(wrapper.emitted('retry')).toHaveLength(1);
    expect(wrapper.emitted('dismiss')).toBeUndefined();
  });

  it.each(['router_unavailable', 'council_unavailable'])(
    'does not mention agents or routing when the failure is %s',
    reasonCode => {
      const wrapper = mountNotice({
        notice: notice({ kind: 'failed', reason: null, reasonCode }),
      });

      expect(title(wrapper)).toBe('Не удалось подготовить ответ');
      expect(reason(wrapper)).toBe('Попробуйте ещё раз или ответьте сами.');
      expect(wrapper.text()).not.toMatch(/агент|маршрутиз|консилиум|router/i);
    }
  );

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

    expect(title(wrapper)).toBe('Подсказка недоступна');
    expect(reason(wrapper)).toBe('Лимит ИИ-ответов исчерпан.');
  });

  it('explains the voice limitation from the locale when the server sent no text', () => {
    const wrapper = mountNotice({
      notice: notice({
        kind: 'unavailable',
        reason: null,
        reasonCode: 'voice_channel_unsupported',
      }),
    });

    expect(reason(wrapper)).toContain(
      'В звонке нельзя отправить текст. Откройте чат клиента в мессенджере'
    );
  });

  it('shows no line for an unavailable suggestion that has no reason at all', () => {
    const wrapper = mountNotice({
      notice: notice({ kind: 'unavailable', reason: null, reasonCode: null }),
    });

    expect(title(wrapper)).toBe('Подсказка недоступна');
    expect(wrapper.find('[data-test="copilot-notice-reason"]').exists()).toBe(
      false
    );
  });

  it('names no agent and no router, whoever made the decision', () => {
    const byAgent = mountNotice({
      notice: notice({ agent: { id: 84, name: 'Сезім', avatarUrl: '' } }),
    });
    const byRouter = mountNotice({
      notice: notice({
        kind: 'human_needed',
        reason: 'Пациент просит живого сотрудника — ответьте ему сами.',
        reasonSource: 'router',
        agent: null,
      }),
    });

    expect(byAgent.text()).not.toContain('Сезім');
    expect(byAgent.text()).not.toContain('Решение агента');
    expect(byAgent.find('[data-test="copilot-notice-agent"]').exists()).toBe(
      false
    );
    expect(byRouter.text()).not.toContain('маршрутизации');
    expect(byRouter.find('[data-test="copilot-notice-agent"]').exists()).toBe(
      false
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
    const reasonText = '<img src=x onerror="alert(1)"><b>важно</b>';
    const wrapper = mountNotice({ notice: notice({ reason: reasonText }) });

    expect(wrapper.find('img').exists()).toBe(false);
    expect(wrapper.find('b').exists()).toBe(false);
    expect(reason(wrapper)).toBe(reasonText);
  });

  it('falls back to a neutral reason when the agent gave none', () => {
    const wrapper = mountNotice({ notice: notice({ reason: '  ' }) });

    expect(title(wrapper)).toBe('Ответ не нужен');
    expect(reason(wrapper)).toBe('Причина не указана.');
  });

  it('is a neutral card: only the icon in its circle carries a colour', () => {
    const staff = mountNotice({ notice: notice({ kind: 'human_needed' }) });
    const failed = mountNotice({ notice: notice({ kind: 'failed' }) });

    [staff, failed].forEach(wrapper => {
      expect(wrapper.classes().join(' ')).not.toMatch(/amber|ruby|iris/);
      expect(wrapper.classes()).toContain('bg-n-solid-1');
    });
    expect(staff.get('span').classes().join(' ')).toContain('amber');
    expect(failed.get('span').classes().join(' ')).toContain('ruby');
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

    it('has no texts of the router, of an agent decision or of a council failure', () => {
      expect(NOTICE.ROUTER_LABEL).toBeUndefined();
      expect(NOTICE.AGENT_LABEL).toBeUndefined();
      expect(NOTICE.FAILED_REASONS).toBeUndefined();
      expect(
        messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.ROUTING
      ).toBeUndefined();
    });

    it.each([
      ['no_reply', NOTICE.NO_REPLY_TITLE],
      ['human_needed', NOTICE.HUMAN_NEEDED_TITLE],
      ['failed', NOTICE.FAILED_TITLE],
      ['unavailable', NOTICE.UNAVAILABLE_TITLE],
    ])('uses the %s title', (kind, expected) => {
      const wrapper = mountNotice(
        { notice: notice({ kind, reason: null, canRetry: true }) },
        locale,
        messages
      );

      expect(title(wrapper)).toBe(expected);
      expect(expected).not.toMatch(/:$/);
      expect(wrapper.text()).not.toContain('COPILOT_SUGGESTION');
    });

    it('has the one calm line for a failure and the retry label', () => {
      const wrapper = mountNotice(
        { notice: notice({ kind: 'failed', reason: null, canRetry: true }) },
        locale,
        messages
      );

      expect(reason(wrapper)).toBe(NOTICE.FAILED_BODY);
      expect(wrapper.get('[data-test="copilot-notice-retry"]').text()).toBe(
        NOTICE.RETRY
      );
    });
  });
});
