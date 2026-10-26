import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import CopilotEditorSection from './CopilotEditorSection.vue';

// Swap the content at once instead of waiting for a CSS transition
const PassThroughStub = { inheritAttrs: false, template: '<slot />' };

const AiOrbStub = {
  props: ['stage'],
  template: '<span data-test="ai-orb" :data-stage="stage" />',
};

const step = (tool, event, extra = {}) => ({
  id: `${tool}:${event}:1:call-${tool}`,
  type: 'captain_tool_event',
  tool_name: tool,
  event,
  status: event === 'complete' ? 'finish' : event,
  tool_call_id: `call-${tool}`,
  current_agent: 'Диана',
  ...extra,
});

// A progress event as the cable delivers it, with everything an agent adds
const progressOf = (phase, steps = [], extra = {}) => ({
  suggestion_request_id: 'sr-1',
  status: 'running',
  phase,
  active_agent: { id: 7, name: 'Диана', role: 'Администратор МО «Әлия»' },
  working_agents: [
    { id: 7, name: 'Диана' },
    { id: 8, name: 'Сезім' },
  ],
  council: {
    active: true,
    parts: [
      { id: 1, status: 'running', agent: { id: 8, name: 'Сезім' } },
      { id: 2, status: 'planned', agent: { id: 9, name: 'Мадина' } },
    ],
  },
  captain_trace: { version: 1, tool_steps: steps },
  elapsed_ms: 4000,
  budget_seconds: 60,
  ...extra,
});

describe('CopilotEditorSection.vue', () => {
  const sampleAction = {
    action_id: 'act-101',
    tool_name: 'create_appointment',
    status: 'pending',
    title: 'Записать на приём',
    digest: 'digest-xyz',
    agent: { id: 7, name: 'Координатор' },
    details: [
      { label: 'Специалист', value: 'Д-р Смит' },
      { label: 'Услуга', value: 'Консультация терапевта' },
      { label: 'Дата и время', value: '25.10.2026, 10:00–10:30' },
    ],
  };

  let wrapper;

  const mountComponent = (props = {}, locale = 'ru', messages = ru) => {
    wrapper = mount(CopilotEditorSection, {
      props: {
        showCopilotEditor: true,
        isGeneratingContent: false,
        generatedContent: 'Можем записать вас к Д-ру Смиту на 10:00.',
        pendingActions: [sampleAction],
        actionLoadingById: {},
        ...props,
      },
      attachTo: document.body,
      global: {
        plugins: [
          createI18n({
            legacy: false,
            locale,
            messages: { [locale]: messages },
          }),
        ],
        stubs: {
          Icon: true,
          AiOrb: AiOrbStub,
          transition: PassThroughStub,
          Transition: PassThroughStub,
        },
        directives: {
          'dompurify-html': (el, binding) => {
            el.innerHTML = binding.value;
          },
        },
      },
    });
    return wrapper;
  };

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
  });

  describe('the approval card of an action', () => {
    it('says «AI предлагает: …», shows the details and offers Разрешить / Запретить', () => {
      mountComponent();

      expect(
        wrapper.find('[data-test="copilot-pending-actions"]').exists()
      ).toBe(true);
      expect(wrapper.find('[data-test="copilot-action-title"]').text()).toBe(
        'AI предлагает: Записать на приём'
      );
      const detailsText = wrapper
        .find('[data-test="copilot-action-details"]')
        .text();
      expect(detailsText).toContain('Специалист:');
      expect(detailsText).toContain('Д-р Смит');
      expect(detailsText).toContain('Консультация терапевта');

      const approveBtn = wrapper.find('[data-test="copilot-action-approve"]');
      const rejectBtn = wrapper.find('[data-test="copilot-action-reject"]');
      expect(approveBtn.text()).toContain('Разрешить');
      expect(rejectBtn.text()).toContain('Запретить');
    });

    it('names no agent and no tool, even when the action carries them', () => {
      mountComponent();

      const card = wrapper.get('[data-test="copilot-action-card"]').text();
      expect(card).not.toContain('Координатор');
      expect(card).not.toContain('create_appointment');
      expect(card).not.toMatch(/агент/i);
      expect(
        wrapper.find('[data-test="copilot-action-card"] img').exists()
      ).toBe(false);
    });

    it('does not fall back to the tool name when the action has no title', () => {
      mountComponent({
        pendingActions: [{ ...sampleAction, title: '', details: [] }],
      });

      const title = wrapper.get('[data-test="copilot-action-title"]').text();
      expect(title).toBe('AI предлагает выполнить действие');
      expect(wrapper.text()).not.toContain('create_appointment');
    });

    it('emits approveAction and rejectAction with the raw action payload', async () => {
      mountComponent();

      await wrapper
        .find('[data-test="copilot-action-approve"]')
        .trigger('click');
      expect(wrapper.emitted('approveAction')).toEqual([[sampleAction]]);

      await wrapper
        .find('[data-test="copilot-action-reject"]')
        .trigger('click');
      expect(wrapper.emitted('rejectAction')).toEqual([[sampleAction]]);
    });

    it('blocks both buttons while the action is being approved', () => {
      mountComponent({ actionLoadingById: { 'act-101': 'approving' } });

      expect(
        wrapper
          .find('[data-test="copilot-action-approve"]')
          .attributes('disabled')
      ).toBeDefined();
      expect(
        wrapper
          .find('[data-test="copilot-action-reject"]')
          .attributes('disabled')
      ).toBeDefined();
      expect(wrapper.find('[data-test="copilot-action-approve"]').text()).toBe(
        'Выполняется…'
      );
    });

    it('renders the approved badge with the result, the rejected badge and the failed state', () => {
      mountComponent({
        pendingActions: [
          {
            ...sampleAction,
            status: 'approved',
            result_summary: 'Д-р Смит — 2026-10-25, 10:00',
          },
        ],
      });
      expect(
        wrapper.find('[data-test="copilot-action-approved-badge"]').text()
      ).toContain('Разрешено и выполнено');
      expect(
        wrapper.find('[data-test="copilot-action-result-summary"]').text()
      ).toContain('Д-р Смит — 2026-10-25, 10:00');
      wrapper.unmount();

      mountComponent({
        pendingActions: [{ ...sampleAction, status: 'rejected' }],
      });
      expect(
        wrapper.find('[data-test="copilot-action-rejected-badge"]').text()
      ).toContain('Отклонено');
      wrapper.unmount();

      mountComponent({
        pendingActions: [{ ...sampleAction, status: 'failed' }],
      });
      expect(wrapper.find('[data-test="copilot-action-error"]').text()).toBe(
        'Не удалось выполнить действие. Попробуйте ещё раз или сделайте это вручную'
      );
      // the manager can try again
      expect(
        wrapper.find('[data-test="copilot-action-approve"]').exists()
      ).toBe(true);
    });

    // The server's error text is written for the logs and the model: it can
    // name a tool argument or an integration. The staff never see it.
    const RAW_ERRORS = [
      "This service is not linked to the clinic's MedElement. Retry the call without service_id and let the clinic choose the service.",
      'PG::UniqueViolation: duplicate key value violates unique constraint',
      'Время уже занято',
    ];

    it.each(RAW_ERRORS)(
      'shows one plain line for a failed card and never the server text: %s',
      raw => {
        mountComponent({
          pendingActions: [
            {
              ...sampleAction,
              status: 'failed',
              error_message: raw,
              errorMessage: raw,
            },
          ],
        });

        const card = wrapper.get('[data-test="copilot-action-card"]');
        expect(card.get('[data-test="copilot-action-error"]').text()).toBe(
          ru.CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_FAILED
        );
        expect(card.text()).not.toContain(raw);
        expect(card.text()).not.toMatch(/service_id|MedElement|PG::/);
        expect(card.html()).not.toContain(raw);
        expect(card.html()).not.toMatch(/service_id|MedElement|PG::/);
        // no Latin word at all (the card is Russian: «AI» is the only one)
        expect(card.text()).not.toMatch(/[A-Za-z]{3,}/);
      }
    );

    it.each([
      ['ru', ru],
      ['en', en],
      ['kk', kk],
    ])('has a plain failed line in %s', (locale, messages) => {
      mountComponent(
        {
          pendingActions: [
            {
              ...sampleAction,
              status: 'failed',
              error_message: 'service_id is not linked to MedElement',
            },
          ],
        },
        locale,
        messages
      );

      const line = wrapper.get('[data-test="copilot-action-error"]').text();
      expect(line).toBe(
        messages.CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_FAILED
      );
      expect(line.length).toBeGreaterThan(20);
      expect(line).not.toMatch(/service_id|MedElement|tool|agent|API/i);
    });

    it('shows no error line for a card that is not failed', () => {
      mountComponent({
        pendingActions: [
          { ...sampleAction, status: 'pending', error_message: 'old text' },
        ],
      });

      expect(wrapper.find('[data-test="copilot-action-error"]').exists()).toBe(
        false
      );
      expect(wrapper.text()).not.toContain('old text');
    });

    it('keeps the cards visible after the text was inserted', () => {
      mountComponent({
        showCopilotEditor: false,
        pendingActions: [sampleAction],
      });

      expect(
        wrapper.find('[data-test="copilot-pending-actions"]').exists()
      ).toBe(true);
      expect(wrapper.find('[data-test="copilot-draft"]').exists()).toBe(false);
      expect(
        wrapper.find('[data-test="copilot-action-approve"]').exists()
      ).toBe(true);
    });

    it('never shows a card that the run withdrew for a corrected one', async () => {
      const corrected = {
        ...sampleAction,
        action_id: 'act-102',
        tool_name: 'update_appointment',
        title: 'Перенести запись',
      };
      const replaced = { ...corrected, action_id: 'act-101' };

      const live = mountComponent({
        pendingActions: [],
        liveProgress: {
          pending_actions: [replaced, corrected],
          superseded_action_ids: ['act-101'],
        },
      });
      const liveTitles = live.findAll('[data-test="copilot-action-title"]');
      expect(liveTitles).toHaveLength(1);
      expect(liveTitles[0].text()).toBe('AI предлагает: Перенести запись');
      live.unmount();

      const draft = mountComponent({
        pendingActions: [],
        suggestionMeta: {
          pending_actions: [replaced, corrected],
          superseded_action_ids: ['act-101'],
        },
      });
      expect(draft.findAll('[data-test="copilot-action-title"]')).toHaveLength(
        1
      );
      draft.unmount();

      const kept = mountComponent({
        pendingActions: [replaced, corrected],
        suggestionMeta: { superseded_action_ids: ['act-101'] },
      });
      await kept.find('[data-test="copilot-action-approve"]').trigger('click');
      expect(kept.emitted('approveAction')).toEqual([[corrected]]);
    });
  });

  describe('the ready draft', () => {
    const DRAFT = 'Здравствуйте! Завтра в 10:00 есть окно.';

    it('shows only the text of the draft', () => {
      mountComponent({ pendingActions: [], generatedContent: DRAFT });

      expect(wrapper.get('[data-test="copilot-draft"]').text()).toBe(DRAFT);
      expect(wrapper.text()).toBe(DRAFT);
    });

    it('has no label, no author line, no hint, no refine box and no buttons', () => {
      mountComponent({
        pendingActions: [],
        generatedContent: DRAFT,
        suggestionMeta: {
          agent: { id: 7, name: 'Диана', role: 'Администратор МО «Әлия»' },
          working_agents: [{ id: 7, name: 'Диана' }],
          council_contributors: [
            { id: 8, name: 'Сезім' },
            { id: 9, name: 'Мадина' },
          ],
          council: { parts: [{ id: 1, status: 'answered' }] },
          routing: { decision_key: 'council', decided_by: 'router' },
        },
      });

      const text = wrapper.text();
      ['Диана', 'Сезім', 'Мадина', 'Әлия'].forEach(name =>
        expect(text).not.toContain(name)
      );
      [
        'Черновик AI',
        'Ответ подготовил',
        'Что исправить',
        'Исправить с ИИ',
        'После вставки',
        'Обновить',
        'Консилиум',
      ].forEach(phrase => expect(text).not.toContain(phrase));
      expect(
        wrapper.find('[data-test="copilot-suggestion-attribution"]').exists()
      ).toBe(false);
      expect(wrapper.find('[data-test="copilot-refine-submit"]').exists()).toBe(
        false
      );
      expect(wrapper.find('[data-test="copilot-edit-hint"]').exists()).toBe(
        false
      );
      expect(wrapper.find('button').exists()).toBe(false);
      expect(wrapper.find('input').exists()).toBe(false);
      expect(wrapper.find('textarea').exists()).toBe(false);
      expect(wrapper.find('[contenteditable]').exists()).toBe(false);
      expect(wrapper.find('.ProseMirror').exists()).toBe(false);
    });

    it('uses no violet or iris colour', () => {
      mountComponent({ generatedContent: DRAFT });

      expect(wrapper.html()).not.toMatch(/iris|violet|purple/);
    });

    it('warns above the draft when new customer messages arrived', () => {
      mountComponent({ pendingActions: [], stale: true });
      const stale = wrapper.get('[data-test="copilot-stale-warning"]').text();
      wrapper.unmount();
      mountComponent({ pendingActions: [], stale: false });

      expect(stale).toBe(
        ru.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.STALE_WARNING
      );
      expect(wrapper.find('[data-test="copilot-stale-warning"]').exists()).toBe(
        false
      );
    });

    it('says when the draft was prepared without the schedule, and does not say «агент»', () => {
      mountComponent({ pendingActions: [], engine: 'legacy_prompt' });
      const legacy = wrapper.get('[data-test="copilot-legacy-engine"]').text();
      wrapper.unmount();
      mountComponent({ pendingActions: [], engine: 'agent' });

      expect(legacy).toBe('Подготовлено без расписания и базы знаний');
      expect(legacy).not.toMatch(/агент/i);
      expect(wrapper.find('[data-test="copilot-legacy-engine"]').exists()).toBe(
        false
      );
    });

    it('shows above the draft what a council left to the manager', () => {
      const note =
        'ИИ не решил часть обращения — ответьте на неё сами: справка.';
      mountComponent({
        pendingActions: [],
        suggestionMeta: { operator_note: note },
      });
      const shown = wrapper.get('[data-test="copilot-operator-note"]').text();
      wrapper.unmount();
      mountComponent({ pendingActions: [] });

      expect(shown).toBe(note);
      expect(wrapper.find('[data-test="copilot-operator-note"]').exists()).toBe(
        false
      );
    });

    it('takes the focus when it appears, so that Ctrl+Enter and Esc work at once', () => {
      mountComponent({ pendingActions: [], generatedContent: DRAFT });
      const panel = wrapper.get('[data-test="copilot-editor-panel"]').element;

      wrapper.vm.onAfterEnter(panel);

      expect(document.activeElement).toBe(panel);
      expect(wrapper.emitted('contentReady')).toHaveLength(1);
    });

    it('reports focus and blur of the panel to the reply box', async () => {
      mountComponent({ pendingActions: [], generatedContent: DRAFT });

      const panel = wrapper.get('[data-test="copilot-editor-panel"]');
      await panel.trigger('focus');
      await panel.trigger('blur');

      expect(wrapper.emitted('focus')).toHaveLength(1);
      expect(wrapper.emitted('blur')).toHaveLength(1);
    });

    it('does not take the focus from a field the manager is typing in', () => {
      const input = document.createElement('input');
      document.body.appendChild(input);
      input.focus();
      mountComponent({ pendingActions: [], generatedContent: DRAFT });

      wrapper.vm.onAfterEnter(
        wrapper.get('[data-test="copilot-editor-panel"]').element
      );

      expect(document.activeElement).toBe(input);
      expect(wrapper.emitted('contentReady')).toHaveLength(1);
      input.remove();
    });
  });

  describe('while the suggestion works', () => {
    const working = (props = {}, locale = 'ru', messages = ru) =>
      mountComponent(
        {
          showCopilotEditor: false,
          pendingActions: [],
          isGeneratingContent: true,
          ...props,
        },
        locale,
        messages
      );
    const stageText = () => wrapper.get('[data-test="copilot-stage"]').text();

    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it('shows the glow and one plain sentence', () => {
      working({ liveProgress: progressOf('thinking') });

      expect(wrapper.find('[data-test="ai-orb"]').exists()).toBe(true);
      expect(stageText()).toBe('AI анализирует…');
      const status = wrapper.get('[data-test="copilot-stage"]');
      expect(status.attributes('role')).toBe('status');
      expect(status.attributes('aria-live')).toBe('polite');
    });

    it('starts with «AI анализирует…» before the first event', () => {
      working({ liveProgress: null });

      expect(stageText()).toBe('AI анализирует…');
      expect(wrapper.get('[data-test="ai-orb"]').attributes('data-stage')).toBe(
        'analyzing'
      );
    });

    it('says the request waits in the queue', () => {
      working({ isQueued: true });

      expect(stageText()).toBe('AI скоро начнёт…');
    });

    it('shows no agent, council, tool, status or timer, whatever the event carries', () => {
      working({
        liveProgress: progressOf('tool_running', [
          step('search_available_slots', 'start'),
          step('faq_lookup', 'complete'),
        ]),
      });

      const text = wrapper.text();
      ['Диана', 'Сезім', 'Мадина', 'Әлия'].forEach(name =>
        expect(text).not.toContain(name)
      );
      expect(text).not.toMatch(/search_available_slots|faq_lookup/);
      expect(text).not.toMatch(/агент|консилиум|инструмент|маршрутиз/i);
      // no counter of seconds: nothing numeric at all
      expect(text).not.toMatch(/\d/);
      expect(text).not.toContain('Ход работы');
      ['live-agents', 'live-council', 'live-trace'].forEach(id =>
        expect(wrapper.find(`[data-test="copilot-${id}"]`).exists()).toBe(false)
      );
      expect(wrapper.html()).not.toMatch(/iris|violet|purple/);
      expect(wrapper.find('img').exists()).toBe(false);
    });

    it('recognises a running tool by the statuses the run really sends', () => {
      working({
        liveProgress: progressOf('tool_running', [
          step('search_available_slots', 'start'),
        ]),
      });

      expect(stageText()).toBe('AI ищет свободное время…');
    });

    it('follows the events, each stage staying for at least 800 ms', async () => {
      working({ liveProgress: progressOf('thinking') });
      expect(stageText()).toBe('AI анализирует…');

      vi.advanceTimersByTime(800);
      await wrapper.setProps({
        liveProgress: progressOf('tool_running', [step('faq_lookup', 'start')]),
      });
      expect(stageText()).toBe('AI проверяет базу знаний…');

      await wrapper.setProps({
        liveProgress: progressOf('tool_running', [
          step('faq_lookup', 'start'),
          step('faq_lookup', 'complete'),
          step('search_scheduling_services', 'start'),
        ]),
      });
      expect(stageText()).toBe('AI проверяет базу знаний…');

      vi.advanceTimersByTime(800);
      await nextTick();
      expect(stageText()).toBe('AI уточняет услуги и цены…');
    });

    it('turns to «AI готовит ответ…» when the tools are done and the run goes quiet', async () => {
      working({
        liveProgress: progressOf('thinking', [
          step('search_available_slots', 'start'),
          step('search_available_slots', 'complete'),
        ]),
      });
      expect(stageText()).toBe('AI анализирует…');

      vi.advanceTimersByTime(2500);
      await nextTick();

      expect(stageText()).toBe('AI готовит ответ…');
    });

    it('adds a calm second line after about 30 seconds', async () => {
      working({
        liveProgress: progressOf('thinking', [], { elapsed_ms: 1000 }),
      });
      expect(wrapper.find('[data-test="copilot-slow-hint"]').exists()).toBe(
        false
      );

      vi.advanceTimersByTime(29000);
      await nextTick();

      expect(wrapper.get('[data-test="copilot-slow-hint"]').text()).toBe(
        'Это занимает чуть дольше обычного…'
      );
      expect(stageText()).toContain('AI анализирует…');
    });

    it('takes the focus when it is shown, so that Esc cancels the run at once', () => {
      working({ liveProgress: progressOf('thinking') });

      // the editor that had the focus is gone: the focus would be on the page
      expect(document.activeElement).toBe(
        wrapper.get('[data-test="copilot-live-progress"]').element
      );
    });

    it('does not take the focus from a field the manager is typing in', () => {
      const input = document.createElement('input');
      document.body.appendChild(input);
      input.focus();

      working({ liveProgress: progressOf('thinking') });

      expect(document.activeElement).toBe(input);
      input.remove();
    });

    it('is replaced by the draft at once when the result arrives', async () => {
      working({ liveProgress: progressOf('thinking') });
      expect(wrapper.find('[data-test="copilot-live-progress"]').exists()).toBe(
        true
      );

      await wrapper.setProps({
        isGeneratingContent: false,
        showCopilotEditor: true,
        generatedContent: 'Готовый ответ.',
      });

      expect(wrapper.find('[data-test="copilot-live-progress"]').exists()).toBe(
        false
      );
      expect(wrapper.get('[data-test="copilot-draft"]').text()).toBe(
        'Готовый ответ.'
      );
      expect(vi.getTimerCount()).toBe(0);
    });

    it.each([
      ['en', en, 'AI is analyzing…'],
      ['kk', kk, 'AI талдап жатыр…'],
    ])('speaks %s', (locale, messages, expected) => {
      working({ liveProgress: progressOf('thinking') }, locale, messages);

      expect(stageText()).toBe(expected);
    });
  });
});
