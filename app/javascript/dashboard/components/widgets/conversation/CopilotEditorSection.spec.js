import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import CopilotEditorSection from './CopilotEditorSection.vue';
import workingStateSource from './copilot/CopilotWorkingState.vue?raw';
import sectionSource from './CopilotEditorSection.vue?raw';

// Swap the content at once instead of waiting for a CSS transition
const PassThroughStub = { inheritAttrs: false, template: '<slot />' };

const AiOrbStub = {
  template: '<span data-test="ai-orb" />',
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
    it('says «AI: …», shows the details and offers Разрешить / Запретить', () => {
      mountComponent();

      expect(
        wrapper.find('[data-test="copilot-pending-actions"]').exists()
      ).toBe(true);
      expect(wrapper.find('[data-test="copilot-action-title"]').text()).toBe(
        'AI: Записать на приём'
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

    it.each([
      [
        'ru',
        ru,
        'Добавить личную заметку',
        'Перезвонить после консультации и уточнить удобное время следующего визита',
      ],
      [
        'kk',
        kk,
        'Жеке ескерту қосу',
        'Кеңес беруден кейін қоңырау шалып, келесі қабылдауға ыңғайлы уақытты нақтылау',
      ],
      [
        'en',
        en,
        'Add a private note',
        'Call after the consultation and confirm a convenient time for the next appointment',
      ],
    ])(
      'shows the full note and every parameter in %s before approval',
      (locale, messages, title, note) => {
        mountComponent(
          {
            pendingActions: [
              {
                ...sampleAction,
                title,
                description: note,
                details: [
                  ...sampleAction.details,
                  { label: '2026', value: '03.11.2026, 10:00–10:30' },
                ],
              },
            ],
          },
          locale,
          messages
        );
        const card = wrapper.get('[data-test="copilot-action-card"]');
        expect(card.get('[data-test="copilot-action-title"]').text()).toContain(
          title
        );
        expect(card.text()).toContain(note);
        expect(card.text()).toContain('03.11.2026, 10:00–10:30');
        expect(card.findAll('button')).toHaveLength(2);
      }
    );

    it.each(['executing', 'approving', 'rejecting'])(
      'prevents approval and rejection while %s',
      async loading => {
        mountComponent({
          pendingActions: [
            {
              ...sampleAction,
              status: loading === 'executing' ? 'executing' : 'pending',
            },
          ],
          actionLoadingById:
            loading === 'executing' ? {} : { 'act-101': loading },
        });
        await wrapper
          .get('[data-test="copilot-action-approve"]')
          .trigger('click');
        await wrapper
          .get('[data-test="copilot-action-reject"]')
          .trigger('click');
        expect(wrapper.emitted('approveAction')).toBeUndefined();
        expect(wrapper.emitted('rejectAction')).toBeUndefined();
      }
    );

    it('does not repeat a description already shown as a detail value', () => {
      const note = 'Перезвонить после консультации';
      mountComponent({
        pendingActions: [
          {
            ...sampleAction,
            description: note,
            details: [{ label: 'Заметка', value: note }],
          },
        ],
      });
      expect(
        wrapper.get('[data-test="copilot-action-card"]').text().split(note)
      ).toHaveLength(2);
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
      expect(liveTitles[0].text()).toBe('AI: Перенести запись');
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

  describe('a card that was decided or closed', () => {
    const EN = en.CONVERSATION.REPLYBOX.COPILOT_TRACE;
    const KK = kk.CONVERSATION.REPLYBOX.COPILOT_TRACE;
    const RU = ru.CONVERSATION.REPLYBOX.COPILOT_TRACE;
    const approved = { ...sampleAction, status: 'approved' };

    it('shows the result line of an approved card, and «Готово» when there is none', () => {
      mountComponent({
        pendingActions: [{ ...approved, result_summary: 'Д-р Смит — 10:00' }],
      });
      const withResult = wrapper.get('[data-test="copilot-action-card"]');
      expect(
        withResult.get('[data-test="copilot-action-result-summary"]').text()
      ).toBe('Д-р Смит — 10:00');
      expect(withResult.text()).not.toContain('Готово');
      wrapper.unmount();

      mountComponent({ pendingActions: [approved] });
      const card = wrapper.get('[data-test="copilot-action-card"]');
      expect(
        card.get('[data-test="copilot-action-approved-badge"]').text()
      ).toBe('Готово');
      expect(
        card.find('[data-test="copilot-action-result-summary"]').exists()
      ).toBe(false);
      // nothing to press any more
      expect(card.find('[data-test="copilot-action-approve"]').exists()).toBe(
        false
      );
      expect(card.find('[data-test="copilot-action-reject"]').exists()).toBe(
        false
      );
    });

    it.each([
      ['ru', ru, RU],
      ['en', en, EN],
      ['kk', kk, KK],
    ])('says «Готово» in %s', (locale, messages, trace) => {
      mountComponent({ pendingActions: [approved] }, locale, messages);

      expect(
        wrapper.get('[data-test="copilot-action-approved-badge"]').text()
      ).toBe(trace.ACTION_DONE);
      expect(trace.ACTION_DONE.length).toBeGreaterThan(1);
    });

    it('shows nothing of a card that has left, and no empty panel', () => {
      mountComponent({
        showCopilotEditor: false,
        pendingActions: [
          { ...approved, dismissed: true },
          {
            ...sampleAction,
            action_id: 'act-102',
            status: 'rejected',
            dismissed: true,
          },
        ],
      });

      expect(wrapper.find('[data-test="copilot-action-card"]').exists()).toBe(
        false
      );
      expect(
        wrapper.find('[data-test="copilot-pending-actions"]').exists()
      ).toBe(false);
      expect(wrapper.find('[data-test="copilot-editor-panel"]').exists()).toBe(
        false
      );
    });

    it('keeps the draft when its last card has left', () => {
      mountComponent({
        pendingActions: [{ ...approved, dismissed: true }],
      });

      expect(wrapper.find('[data-test="copilot-draft"]').exists()).toBe(true);
      expect(wrapper.find('[data-test="copilot-action-card"]').exists()).toBe(
        false
      );
    });

    it('never brings a card back from the draft meta or the live progress', () => {
      mountComponent({
        pendingActions: [
          { ...sampleAction, status: 'rejected', dismissed: true },
        ],
        suggestionMeta: { pending_actions: [sampleAction] },
        liveProgress: { pending_actions: [sampleAction] },
      });

      expect(wrapper.find('[data-test="copilot-action-card"]').exists()).toBe(
        false
      );
    });

    describe('the close button of a failed card', () => {
      const closeOf = card => card.find('[data-test="copilot-action-close"]');

      it('closes a failed card and nothing else', async () => {
        const failed = { ...sampleAction, status: 'failed' };
        mountComponent({ pendingActions: [failed] });

        const close = closeOf(wrapper);
        expect(close.exists()).toBe(true);
        expect(close.attributes('aria-label')).toBe('Закрыть');
        expect(close.text()).toBe('');

        await close.trigger('click');

        expect(wrapper.emitted('closeAction')).toEqual([[failed]]);
        expect(wrapper.emitted('approveAction')).toBeUndefined();
        expect(wrapper.emitted('rejectAction')).toBeUndefined();
      });

      it.each(['pending', 'executing', 'approved', 'rejected'])(
        'is not on a %s card',
        status => {
          mountComponent({ pendingActions: [{ ...sampleAction, status }] });

          expect(closeOf(wrapper).exists()).toBe(false);
        }
      );

      it('waits while the card is busy', () => {
        mountComponent({
          pendingActions: [{ ...sampleAction, status: 'failed' }],
          actionLoadingById: { 'act-101': 'approving' },
        });

        expect(closeOf(wrapper).attributes('disabled')).toBeDefined();
      });

      it.each([
        ['en', en, EN],
        ['kk', kk, KK],
      ])('is labelled in %s', (locale, messages, trace) => {
        mountComponent(
          { pendingActions: [{ ...sampleAction, status: 'failed' }] },
          locale,
          messages
        );

        expect(closeOf(wrapper).attributes('aria-label')).toBe(
          trace.ACTION_CLOSE
        );
      });
    });

    it('fades a card out when it leaves, and shortens the fade under reduced motion', () => {
      const group = sectionSource.match(/<TransitionGroup[\s\S]*?>/)[0];

      expect(group).toContain('v-if=');
      expect(group).toMatch(/leave-active-class="[^"]*duration-200/);
      expect(group).toMatch(
        /leave-active-class="[^"]*motion-reduce:duration-100/
      );
      expect(group).toContain('motion-reduce:translate-y-0');
      expect(group).toContain('motion-reduce:scale-100');
    });
  });

  describe('the line of a suggestion with only actions', () => {
    const note = () => wrapper.find('[data-test="copilot-actions-only-note"]');

    it('is shown above the cards when there is no draft', () => {
      mountComponent({
        showCopilotEditor: false,
        actionsOnly: true,
        pendingActions: [sampleAction],
      });

      expect(note().text()).toBe(
        'AI предлагает только действия — ответ пациенту не нужен.'
      );
      expect(note().attributes('role')).toBe('status');
      const html = wrapper.html();
      expect(html.indexOf('copilot-actions-only-note')).toBeLessThan(
        html.indexOf('copilot-pending-actions')
      );
      expect(wrapper.find('[data-test="copilot-draft"]').exists()).toBe(false);
    });

    it('is not shown with a draft', () => {
      mountComponent({
        showCopilotEditor: true,
        actionsOnly: true,
        pendingActions: [sampleAction],
      });

      expect(note().exists()).toBe(false);
    });

    it('is not shown when the run did not say that only actions are needed', () => {
      mountComponent({
        showCopilotEditor: false,
        actionsOnly: false,
        pendingActions: [sampleAction],
      });

      expect(note().exists()).toBe(false);
    });

    it('goes together with the cards: no cards, no line', () => {
      mountComponent({
        showCopilotEditor: false,
        actionsOnly: true,
        pendingActions: [{ ...sampleAction, dismissed: true }],
      });

      expect(note().exists()).toBe(false);
    });

    it('stays while the decided cards are still shown', () => {
      mountComponent({
        showCopilotEditor: false,
        actionsOnly: true,
        pendingActions: [{ ...sampleAction, status: 'rejected' }],
      });

      expect(note().exists()).toBe(true);
    });

    it.each([
      ['ru', ru, 'AI предлагает только действия — ответ пациенту не нужен.'],
      ['kk', kk, 'AI тек әрекеттерді ұсынады — пациентке жауап қажет емес.'],
      [
        'en',
        en,
        'AI suggests actions only — no reply to the patient is needed.',
      ],
    ])('is written in %s', (locale, messages, text) => {
      mountComponent(
        {
          showCopilotEditor: false,
          actionsOnly: true,
          pendingActions: [sampleAction],
        },
        locale,
        messages
      );

      expect(note().text()).toBe(text);
      expect(text).toBe(
        messages.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.ACTIONS_ONLY
      );
      expect(note().text()).not.toMatch(/agent|агент|council|консилиум/i);
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

    it('shows the orb and one plain sentence', () => {
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
      expect(
        wrapper
          .get('[data-test="copilot-live-progress"]')
          .attributes('data-stage')
      ).toBe('analyzing');
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

      const hint = wrapper.get('[data-test="copilot-slow-hint"]');
      expect(hint.text()).toBe('Это занимает чуть дольше обычного…');
      // the calm second line has no effects
      expect(hint.classes().join(' ')).not.toMatch(/ai-text/);
      expect(stageText()).toContain('AI анализирует…');
    });

    describe('the sentence', () => {
      const sentence = () => wrapper.get('[data-test="copilot-stage-text"]');

      it('shimmers and is revealed when it appears, and stays the plain sentence', () => {
        working({ liveProgress: progressOf('thinking') });

        expect(sentence().classes()).toEqual(
          expect.arrayContaining(['ai-text', 'ai-text--enter'])
        );
        // one text node: the effect is CSS only, nothing is split or wrapped
        expect(sentence().element.children).toHaveLength(0);
        expect(sentence().text()).toBe('AI анализирует…');
        const status = wrapper.get('[data-test="copilot-stage"]');
        expect(status.attributes('role')).toBe('status');
        expect(status.attributes('aria-live')).toBe('polite');
        expect(status.text()).toBe('AI анализирует…');
      });

      it('takes the reveal class off and puts it back on every stage change', async () => {
        working({ liveProgress: progressOf('thinking') });
        const el = sentence().element;
        const remove = vi.spyOn(el.classList, 'remove');
        const add = vi.spyOn(el.classList, 'add');

        vi.advanceTimersByTime(800);
        await wrapper.setProps({
          liveProgress: progressOf('tool_running', [
            step('faq_lookup', 'start'),
          ]),
        });
        await nextTick();

        expect(stageText()).toBe('AI проверяет базу знаний…');
        expect(remove).toHaveBeenCalledTimes(1);
        expect(remove).toHaveBeenCalledWith('ai-text--enter');
        expect(add).toHaveBeenCalledTimes(1);
        expect(add).toHaveBeenCalledWith('ai-text--enter');
        expect(remove.mock.invocationCallOrder[0]).toBeLessThan(
          add.mock.invocationCallOrder[0]
        );
        expect(el.classList.contains('ai-text--enter')).toBe(true);
        // the same element, changed in place: no swap, no fade between two
        expect(sentence().element).toBe(el);
        expect(wrapper.get('[data-test="copilot-stage"]').text()).toBe(
          'AI проверяет базу знаний…'
        );

        vi.advanceTimersByTime(800);
        await wrapper.setProps({
          liveProgress: progressOf('tool_running', [
            step('faq_lookup', 'start'),
            step('faq_lookup', 'complete'),
            step('search_scheduling_services', 'start'),
          ]),
        });
        await nextTick();

        expect(stageText()).toBe('AI уточняет услуги и цены…');
        expect(remove).toHaveBeenCalledTimes(2);
        expect(add).toHaveBeenCalledTimes(2);
      });

      it('does not reveal again for a new event of the same step', async () => {
        working({ liveProgress: progressOf('thinking') });
        const remove = vi.spyOn(sentence().element.classList, 'remove');

        await wrapper.setProps({ liveProgress: progressOf('thinking') });
        await nextTick();

        expect(stageText()).toBe('AI анализирует…');
        expect(remove).not.toHaveBeenCalled();
      });

      it('reveals the sentence of a run that waits in the queue as well', async () => {
        working({ liveProgress: null });
        const remove = vi.spyOn(sentence().element.classList, 'remove');

        vi.advanceTimersByTime(800);
        await wrapper.setProps({ isQueued: true });
        await nextTick();

        expect(stageText()).toBe('AI скоро начнёт…');
        expect(remove).toHaveBeenCalledWith('ai-text--enter');
      });

      it('never freezes under reduced motion: slower, still moving', () => {
        const style = workingStateSource.slice(
          workingStateSource.indexOf('<style scoped>')
        );
        const reduced = style.slice(
          style.indexOf('@media (prefers-reduced-motion: reduce)'),
          style.indexOf('/* High contrast')
        );

        expect(reduced).toContain('animation-duration: 4.8s;');
        expect(reduced).toContain('animation-duration: 4.8s, 1.2s;');
        expect(reduced).not.toMatch(/animation(-name)?:\s*none/);
        // the motion is written once at full speed; reduced motion only
        // lengthens it
        expect(style).toContain('ai-shimmer 2.4s linear infinite');
        expect(style).toContain('ai-reveal 0.75s');
      });

      it('takes its colours from the theme tokens, never from violet', () => {
        const style = workingStateSource.slice(
          workingStateSource.indexOf('<style scoped>')
        );

        expect(style).toContain('var(--slate-11)');
        expect(style).toContain('var(--blue-11)');
        expect(style).not.toMatch(/violet|purple|iris/i);
      });
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
      // jsdom queues its own selectionchange timer when the run takes the
      // focus: let it run, so that only the timers of the stages are counted
      vi.advanceTimersByTime(1);

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

  describe('while the AI writes the draft', () => {
    const writing = (props = {}, locale = 'ru', messages = ru) =>
      mountComponent(
        {
          showCopilotEditor: false,
          generatedContent: '',
          pendingActions: [],
          isGeneratingContent: true,
          liveProgress: progressOf('thinking'),
          streamingText: 'Здравствуйте, Анна! Приём стоит 8000 тенге.',
          ...props,
        },
        locale,
        messages
      );
    const draft = () => wrapper.get('[data-test="copilot-draft"]');

    it('shows the text so far in the panel of the draft, in place of the sentence about the step', () => {
      writing();

      expect(draft().text()).toContain(
        'Здравствуйте, Анна! Приём стоит 8000 тенге.'
      );
      expect(draft().attributes('data-streaming')).toBe('true');
      expect(draft().attributes('aria-busy')).toBe('true');
      expect(wrapper.find('[data-test="copilot-live-progress"]').exists()).toBe(
        false
      );
      expect(wrapper.find('[data-test="copilot-stage-text"]').exists()).toBe(
        false
      );
    });

    it('looks like the final draft: the same typography, plus the dot of a text that is still written', () => {
      writing();
      const text = draft().get('.prose-sm');

      expect(text.classes()).toEqual(
        expect.arrayContaining([
          'text-sm',
          'font-normal',
          'leading-relaxed',
          'text-n-slate-12',
          'ai-writing',
        ])
      );
    });

    it('tells a screen reader once that the AI is writing, in the language of the interface', () => {
      writing();
      const status = wrapper.get('[data-test="copilot-draft-writing"]');

      expect(status.attributes('role')).toBe('status');
      expect(status.classes()).toContain('sr-only');
      expect(status.text()).toBe('AI пишет ответ…');

      wrapper.unmount();
      writing({}, 'en', en);
      expect(wrapper.get('[data-test="copilot-draft-writing"]').text()).toBe(
        'AI is writing the reply…'
      );

      wrapper.unmount();
      writing({}, 'kk', kk);
      expect(wrapper.get('[data-test="copilot-draft-writing"]').text()).toBe(
        'AI жауап жазып жатыр…'
      );
    });

    it('grows with the text', async () => {
      writing({ streamingText: 'Здравствуйте, Анна!' });

      await wrapper.setProps({
        streamingText: 'Здравствуйте, Анна! Приём стоит 8000 тенге.',
      });

      expect(draft().text()).toContain('Приём стоит 8000 тенге.');
    });

    it('keeps the cards back until the draft is final', async () => {
      writing({ pendingActions: [sampleAction] });

      expect(
        wrapper.find('[data-test="copilot-pending-actions"]').exists()
      ).toBe(false);
      expect(
        wrapper.find('[data-test="copilot-action-approve"]').exists()
      ).toBe(false);

      await wrapper.setProps({
        isGeneratingContent: false,
        showCopilotEditor: true,
        generatedContent: 'Приём стоит 8000 тенге.',
        streamingText: '',
      });

      expect(
        wrapper.find('[data-test="copilot-action-approve"]').exists()
      ).toBe(true);
    });

    it('changes nothing on screen but the text when the final draft arrives: the same panel, no dot, no fade', async () => {
      writing();
      const panel = wrapper.get('[data-test="copilot-editor-panel"]').element;
      const box = draft().element;

      await wrapper.setProps({
        isGeneratingContent: false,
        showCopilotEditor: true,
        generatedContent: 'Здравствуйте, Анна! Приём стоит 8000 тенге.',
        streamingText: '',
      });

      expect(wrapper.get('[data-test="copilot-editor-panel"]').element).toBe(
        panel
      );
      expect(draft().element).toBe(box);
      expect(draft().text()).toBe(
        'Здравствуйте, Анна! Приём стоит 8000 тенге.'
      );
      expect(draft().attributes('data-streaming')).toBeUndefined();
      expect(draft().attributes('aria-busy')).toBe('false');
      expect(draft().get('.prose-sm').classes()).not.toContain('ai-writing');
      expect(wrapper.find('[data-test="copilot-draft-writing"]').exists()).toBe(
        false
      );
    });

    it('goes back to the sentence about the step when what was written is taken back', async () => {
      writing();

      await wrapper.setProps({ streamingText: '' });

      expect(wrapper.find('[data-test="copilot-draft"]').exists()).toBe(false);
      expect(wrapper.get('[data-test="copilot-stage-text"]').text()).toBe(
        'AI анализирует…'
      );
    });

    it('does not open the panel for a text of blanks', () => {
      writing({ streamingText: '  \n ' });

      expect(wrapper.find('[data-test="copilot-draft"]').exists()).toBe(false);
      expect(wrapper.find('[data-test="copilot-live-progress"]').exists()).toBe(
        true
      );
    });

    it('does not show a text for a draft that is ready, whatever the stream says', () => {
      mountComponent({ streamingText: 'Старый текст' });

      expect(draft().text()).toBe('Можем записать вас к Д-ру Смиту на 10:00.');
      expect(draft().attributes('data-streaming')).toBeUndefined();
    });

    describe('a long text', () => {
      const scrollBox = ({ scrollHeight = 600, clientHeight = 224 } = {}) => {
        const el = draft().element;
        Object.defineProperty(el, 'scrollHeight', {
          configurable: true,
          value: scrollHeight,
        });
        Object.defineProperty(el, 'clientHeight', {
          configurable: true,
          value: clientHeight,
        });
        return el;
      };

      it('stays at its end while it grows', async () => {
        writing();
        const el = scrollBox();

        await wrapper.setProps({
          streamingText: 'Здравствуйте, Анна! Ещё текст',
        });
        await nextTick();

        expect(el.scrollTop).toBe(600);
      });

      it('stays where the manager scrolled to read', async () => {
        writing();
        const el = scrollBox();
        el.scrollTop = 0;
        await draft().trigger('scroll');

        await wrapper.setProps({
          streamingText: 'Здравствуйте, Анна! Ещё текст',
        });
        await nextTick();

        expect(el.scrollTop).toBe(0);
      });

      it('shows the final draft from its start', async () => {
        writing();
        const el = scrollBox();
        el.scrollTop = 376;

        await wrapper.setProps({
          isGeneratingContent: false,
          showCopilotEditor: true,
          generatedContent: 'Здравствуйте, Анна! Приём стоит 8000 тенге.',
          streamingText: '',
        });
        await nextTick();

        expect(el.scrollTop).toBe(0);
      });
    });

    describe('the dot at the end of the text', () => {
      const style = sectionSource.slice(
        sectionSource.indexOf('<style scoped>')
      );

      it('pulses in the blue of the interface, slower under reduced motion, and never stops', () => {
        expect(style).toContain('rgb(var(--blue-9))');
        expect(style).toContain('animation: ai-writing-pulse 1.2s');
        const reduced = style.slice(
          style.indexOf('@media (prefers-reduced-motion: reduce)'),
          style.indexOf('/* High contrast')
        );

        expect(reduced).toContain('animation-duration: 2.4s;');
        expect(reduced).not.toMatch(/animation(-name)?:\s*none/);
        expect(style).not.toMatch(/violet|purple|iris/i);
      });
    });
  });
});
