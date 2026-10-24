import { describe, it, expect, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import CopilotEditorSection from './CopilotEditorSection.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => {
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_AGENT_WANTS') {
        return `Агент ${params.agent} хочет: ${params.action}`;
      }
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_DEFAULT_WANTS') {
        return `Агент хочет: ${params.action}`;
      }
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_ALLOW') {
        return 'Разрешить';
      }
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_DENY') {
        return 'Запретить';
      }
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_APPROVED') {
        return 'Выполнено';
      }
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_REJECTED') {
        return 'Запрещено';
      }
      if (key === 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_EXECUTING') {
        return 'Выполняется...';
      }
      return key;
    },
  }),
}));

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

  const mountComponent = (props = {}) =>
    mount(CopilotEditorSection, {
      props: {
        showCopilotEditor: true,
        isGeneratingContent: false,
        generatedContent: 'Можем записать вас к Д-ру Смиту на 10:00.',
        pendingActions: [sampleAction],
        actionLoadingById: {},
        ...props,
      },
      global: {
        stubs: {
          Transition: false,
          CopilotEditor: {
            props: ['placeholder'],
            template:
              '<div class="copilot-editor-stub" :data-placeholder="placeholder" />',
          },
          CaptainLoader: true,
          Avatar: true,
          Icon: true,
          CaptainSenderAvatars: true,
        },
      },
    });

  it('renders pending action approval card with agent name, action title, details, and Allow / Deny buttons', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-test="copilot-pending-actions"]').exists()).toBe(
      true
    );
    expect(wrapper.find('[data-test="copilot-action-title"]').text()).toBe(
      'Агент Координатор хочет: Записать на приём'
    );
    const detailsText = wrapper
      .find('[data-test="copilot-action-details"]')
      .text();
    expect(detailsText).toContain('Специалист:');
    expect(detailsText).toContain('Д-р Смит');
    expect(detailsText).toContain('Консультация терапевта');

    const approveBtn = wrapper.find('[data-test="copilot-action-approve"]');
    const rejectBtn = wrapper.find('[data-test="copilot-action-reject"]');
    expect(approveBtn.exists()).toBe(true);
    expect(approveBtn.text()).toContain('Разрешить');
    expect(rejectBtn.exists()).toBe(true);
    expect(rejectBtn.text()).toContain('Запретить');
  });

  it('emits approveAction and rejectAction with raw action payload when clicked', async () => {
    const wrapper = mountComponent();

    await wrapper.find('[data-test="copilot-action-approve"]').trigger('click');
    expect(wrapper.emitted('approveAction')).toEqual([[sampleAction]]);

    await wrapper.find('[data-test="copilot-action-reject"]').trigger('click');
    expect(wrapper.emitted('rejectAction')).toEqual([[sampleAction]]);
  });

  it('renders approved badge with resultSummary, rejected badge, and failed error state', () => {
    const approvedWrapper = mountComponent({
      pendingActions: [
        {
          ...sampleAction,
          status: 'approved',
          result_summary: 'Д-р Смит — 2026-10-25, 10:00',
        },
      ],
    });
    expect(
      approvedWrapper.find('[data-test="copilot-action-approved-badge"]').text()
    ).toContain('Выполнено');
    expect(
      approvedWrapper.find('[data-test="copilot-action-result-summary"]').text()
    ).toContain('Д-р Смит — 2026-10-25, 10:00');

    const rejectedWrapper = mountComponent({
      pendingActions: [{ ...sampleAction, status: 'rejected' }],
    });
    expect(
      rejectedWrapper.find('[data-test="copilot-action-rejected-badge"]').text()
    ).toContain('Запрещено');

    const failedWrapper = mountComponent({
      pendingActions: [
        {
          ...sampleAction,
          status: 'failed',
          error_message: 'Время уже занято',
        },
      ],
    });
    expect(
      failedWrapper.find('[data-test="copilot-action-error"]').text()
    ).toContain('Время уже занято');
    expect(
      failedWrapper.find('[data-test="copilot-action-approve"]').exists()
    ).toBe(true);
  });

  it('keeps pending action cards visible when showCopilotEditor is false after accepting reply text', () => {
    const wrapper = mountComponent({
      showCopilotEditor: false,
      pendingActions: [sampleAction],
    });

    expect(wrapper.find('[data-test="copilot-pending-actions"]').exists()).toBe(
      true
    );
    expect(wrapper.find('.copilot-editor-stub').exists()).toBe(false);
    expect(wrapper.find('[data-test="copilot-action-approve"]').exists()).toBe(
      true
    );
  });

  describe('refine and status lines', () => {
    const REFINE_KEY =
      'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.REFINE_PLACEHOLDER';

    it('uses the refine placeholder when the parent passes none', () => {
      const wrapper = mountComponent({ pendingActions: [] });

      expect(
        wrapper.get('.copilot-editor-stub').attributes('data-placeholder')
      ).toBe(REFINE_KEY);
    });

    it('passes the placeholder of the parent through', () => {
      const wrapper = mountComponent({
        pendingActions: [],
        placeholder: 'Что исправить?',
      });

      expect(
        wrapper.get('.copilot-editor-stub').attributes('data-placeholder')
      ).toBe('Что исправить?');
    });

    it('warns above the preview when new customer messages arrived', () => {
      const stale = mountComponent({ pendingActions: [], stale: true });
      const fresh = mountComponent({ pendingActions: [], stale: false });

      expect(stale.get('[data-test="copilot-stale-warning"]').text()).toBe(
        'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.STALE_WARNING'
      );
      expect(fresh.find('[data-test="copilot-stale-warning"]').exists()).toBe(
        false
      );
    });

    it('says when the draft was prepared without an AI agent', () => {
      const legacy = mountComponent({
        pendingActions: [],
        engine: 'legacy_prompt',
      });
      const agent = mountComponent({ pendingActions: [], engine: 'agent' });

      expect(legacy.get('[data-test="copilot-legacy-engine"]').text()).toBe(
        'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.LEGACY_ENGINE'
      );
      expect(agent.find('[data-test="copilot-legacy-engine"]').exists()).toBe(
        false
      );
    });

    it('shows no draft lines while the suggestion is still generating', () => {
      const wrapper = mountComponent({
        pendingActions: [],
        isGeneratingContent: true,
        stale: true,
        engine: 'legacy_prompt',
      });

      expect(wrapper.find('.copilot-editor-stub').exists()).toBe(false);
      expect(wrapper.find('[data-test="copilot-stale-warning"]').exists()).toBe(
        false
      );
      expect(wrapper.find('[data-test="copilot-live-progress"]').exists()).toBe(
        true
      );
    });

    it('says the request is queued instead of "thinking"', () => {
      const queued = mountComponent({
        showCopilotEditor: false,
        pendingActions: [],
        isGeneratingContent: true,
        isQueued: true,
      });
      const running = mountComponent({
        showCopilotEditor: false,
        pendingActions: [],
        isGeneratingContent: true,
      });

      expect(
        queued.get('[data-test="copilot-live-progress"]').text()
      ).toContain('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.QUEUED');
      expect(
        running.get('[data-test="copilot-live-progress"]').text()
      ).toContain('CONVERSATION.REPLYBOX.COPILOT_THINKING');
    });

    it('shows no live steps before the first trace arrives', () => {
      const withoutTrace = mountComponent({
        showCopilotEditor: false,
        pendingActions: [],
        isGeneratingContent: true,
        liveProgress: { phase: 'thinking' },
      });

      expect(
        withoutTrace.find('[data-test="copilot-live-trace"]').exists()
      ).toBe(false);
    });
  });
});
