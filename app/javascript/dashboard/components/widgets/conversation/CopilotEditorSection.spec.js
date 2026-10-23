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
            template: '<div class="copilot-editor-stub" />',
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
});
