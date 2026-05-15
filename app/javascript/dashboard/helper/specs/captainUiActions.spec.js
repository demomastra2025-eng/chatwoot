import { describe, expect, it, vi } from 'vitest';

import {
  executeCaptainUiAction,
  normalizeCaptainUiActions,
  routeForCaptainUiAction,
  supportedCaptainUiActionTypes,
} from '../captainUiActions';

describe('captainUiActions helper', () => {
  it('normalizes only supported UI actions with safe labels', () => {
    const actions = normalizeCaptainUiActions([
      { type: 'open_contact', label: 'Open Aruzhan', target_id: 42 },
      { type: 'click_dom', label: 'Unsafe', target_id: '#delete' },
      { type: 'open_tasks', label: '<b>Tasks</b>' },
    ]);

    expect(actions).toEqual([
      { type: 'open_contact', label: 'Open Aruzhan', targetId: '42' },
      { type: 'open_tasks', label: 'Tasks', targetId: '' },
    ]);
  });

  it('exposes the broader dashboard navigation whitelist', () => {
    expect(supportedCaptainUiActionTypes).toEqual(
      expect.arrayContaining([
        'open_inbox',
        'open_inbox_settings',
        'open_team_conversations',
        'open_label_conversations',
        'open_companies',
        'open_company',
        'open_deal',
        'open_outbound',
        'open_touch_plans',
        'open_automation_rules',
        'open_inboxes_settings',
        'open_agents_settings',
        'open_integrations',
        'open_reports',
        'open_help_center',
        'open_captain_documents',
        'open_captain_tools',
        'open_captain_observability',
        'open_assistant_settings',
        'open_scenario_editor',
        'open_documents_knowledge_panel',
        'open_custom_tool_editor',
        'open_tool_access_panel',
        'open_prompt_preview',
        'highlight_config_field',
        'show_confirmation',
        'create_contact',
        'create_company',
        'create_task',
        'create_deal',
      ])
    );
  });

  it('builds router targets for supported entity navigation actions', () => {
    expect(
      routeForCaptainUiAction({ type: 'open_conversation', targetId: '77' }, 1)
    ).toEqual({
      name: 'inbox_conversation',
      params: { accountId: 1, conversation_id: '77' },
    });

    expect(
      routeForCaptainUiAction({ type: 'open_contact', targetId: '42' }, 1)
    ).toEqual({
      name: 'contacts_edit',
      params: { accountId: 1, contactId: '42' },
    });

    expect(
      routeForCaptainUiAction({ type: 'open_company', targetId: '88' }, 1)
    ).toEqual({
      name: 'companies_dashboard_index',
      params: { accountId: 1 },
      query: { companyId: '88', source: 'captain_ui_action' },
    });

    expect(
      routeForCaptainUiAction({ type: 'open_deal', deal_id: 55 }, 1)
    ).toEqual({
      name: 'crm_deals_index',
      params: { accountId: 1 },
      query: { dealId: '55', source: 'captain_ui_action' },
    });

    expect(
      routeForCaptainUiAction({ type: 'open_task', targetId: '99' }, 1)
    ).toEqual({
      name: 'crm_tasks_index',
      params: { accountId: 1 },
      query: { taskId: '99', source: 'captain_ui_action' },
    });

    expect(
      routeForCaptainUiAction({ type: 'open_inbox_settings', targetId: '5' }, 1)
    ).toEqual({
      name: 'settings_inbox_show',
      params: { accountId: 1, inboxId: '5' },
    });

    expect(
      routeForCaptainUiAction(
        { type: 'open_label_conversations', targetId: 'vip' },
        1
      )
    ).toEqual({
      name: 'label_conversations',
      params: { accountId: 1, label: 'vip' },
    });
  });

  it('sanitizes target route params and query IDs before routing', () => {
    expect(
      routeForCaptainUiAction(
        { type: 'open_contact', targetId: '<b>42</b>\n' },
        1
      )
    ).toEqual({
      name: 'contacts_edit',
      params: { accountId: 1, contactId: '42' },
    });

    expect(
      routeForCaptainUiAction({ type: 'open_deal', targetId: '<i>55</i>' }, 1)
    ).toEqual({
      name: 'crm_deals_index',
      params: { accountId: 1 },
      query: { dealId: '55', source: 'captain_ui_action' },
    });

    expect(
      routeForCaptainUiAction(
        { type: 'open_task', targetId: '<span>99</span>' },
        1
      )
    ).toEqual({
      name: 'crm_tasks_index',
      params: { accountId: 1 },
      query: { taskId: '99', source: 'captain_ui_action' },
    });
  });

  it('normalizes and routes safe create-form UI actions with prefill data', () => {
    const [action] = normalizeCaptainUiActions([
      {
        type: 'create_task',
        label: '<b>Create task</b>',
        target_id:
          '{"title":"Follow up","description":"<i>Call client</i>","due_at":"2026-05-20T10:00","ignored":"#danger"}',
      },
    ]);

    expect(action).toEqual({
      type: 'create_task',
      label: 'Create task',
      targetId:
        '{"title":"Follow up","description":"Call client","due_at":"2026-05-20T10:00","ignored":"#danger"}',
      prefill: {
        title: 'Follow up',
        description: 'Call client',
        dueAt: '2026-05-20T10:00',
      },
    });

    expect(routeForCaptainUiAction(action, 7)).toEqual({
      name: 'crm_tasks_index',
      params: { accountId: 7 },
      query: {
        action: 'new',
        source: 'captain_ui_action',
        title: 'Follow up',
        description: 'Call client',
        dueAt: '2026-05-20T10:00',
      },
    });

    expect(
      routeForCaptainUiAction(
        {
          type: 'create_deal',
          prefill: { title: 'New deal', contactId: '42', amount: '25000' },
        },
        7
      )
    ).toEqual({
      name: 'crm_deals_index',
      params: { accountId: 7 },
      query: {
        action: 'new',
        source: 'captain_ui_action',
        title: 'New deal',
        contactId: '42',
        amount: '25000',
      },
    });

    expect(
      routeForCaptainUiAction(
        {
          type: 'create_contact',
          prefill: { name: 'Aruzhan', phoneNumber: '+7' },
        },
        7
      )
    ).toEqual({
      name: 'contacts_dashboard_index',
      params: { accountId: 7 },
      query: {
        action: 'new',
        source: 'captain_ui_action',
        name: 'Aruzhan',
        phoneNumber: '+7',
      },
    });
  });

  it('builds router targets for assistant and settings pages', () => {
    expect(
      routeForCaptainUiAction(
        { type: 'open_captain_documents', targetId: '12' },
        1
      )
    ).toEqual({
      name: 'captain_assistants_documents_index',
      params: { accountId: 1, assistantId: '12' },
      query: { source: 'captain_ui_action' },
    });

    expect(
      routeForCaptainUiAction(
        { type: 'open_automation_rules', targetId: '' },
        1
      )
    ).toEqual({
      name: 'automation_list',
      params: { accountId: 1 },
    });

    expect(
      routeForCaptainUiAction(
        { type: 'open_kaspi_pay_settings', targetId: '' },
        1
      )
    ).toEqual({
      name: 'settings_integrations_kaspi_pay',
      params: { accountId: 1 },
    });
  });

  it('builds typed Captain admin UI action routes without DOM selectors', () => {
    expect(
      routeForCaptainUiAction(
        { type: 'open_assistant_settings', targetId: '12' },
        1
      )
    ).toEqual({
      name: 'captain_assistants_settings_index',
      params: { accountId: 1, assistantId: '12' },
      query: { source: 'captain_ui_action' },
    });

    expect(
      routeForCaptainUiAction(
        {
          type: 'open_scenario_editor',
          targetId: '{"assistantId":"12","scenarioId":"34"}',
        },
        1
      )
    ).toEqual({
      name: 'captain_assistants_scenarios_index',
      params: { accountId: 1, assistantId: '12' },
      query: { source: 'captain_ui_action', scenarioId: '34' },
    });

    expect(
      routeForCaptainUiAction(
        {
          type: 'open_custom_tool_editor',
          targetId: '{"assistantId":"12","customToolId":"56"}',
        },
        1
      )
    ).toEqual({
      name: 'captain_tools_index',
      params: { accountId: 1, assistantId: '12' },
      query: {
        source: 'captain_ui_action',
        customToolId: '56',
        action: 'edit',
      },
    });

    expect(
      routeForCaptainUiAction(
        { type: 'open_prompt_preview', targetId: '12' },
        1
      )
    ).toEqual({
      name: 'captain_assistants_prompts_index',
      params: { accountId: 1, assistantId: '12' },
      query: { source: 'captain_ui_action', promptPreview: 'true' },
    });

    expect(
      routeForCaptainUiAction(
        {
          type: 'highlight_config_field',
          targetId:
            '{"assistantId":"12","field":"<b>temperature</b>","panel":"model"}',
        },
        1
      )
    ).toEqual({
      name: 'captain_assistants_settings_index',
      params: { accountId: 1, assistantId: '12' },
      query: {
        source: 'captain_ui_action',
        highlight: 'temperature',
        panel: 'model',
      },
    });
  });

  it('rejects entity actions without required target IDs', () => {
    expect(
      routeForCaptainUiAction({ type: 'open_contact', targetId: '' }, 1)
    ).toBe(null);
    expect(
      routeForCaptainUiAction({ type: 'open_company', targetId: '' }, 1)
    ).toBe(null);
    expect(
      routeForCaptainUiAction({ type: 'open_deal', targetId: '' }, 1)
    ).toBe(null);
    expect(
      routeForCaptainUiAction(
        { type: 'open_captain_documents', targetId: '' },
        1
      )
    ).toBe(null);
  });

  it('executes actions through router instead of direct DOM manipulation', async () => {
    const router = { push: vi.fn().mockResolvedValue() };

    await executeCaptainUiAction(
      { type: 'open_tasks', targetId: '' },
      { router, accountId: 7 }
    );

    expect(router.push).toHaveBeenCalledWith({
      name: 'crm_tasks_index',
      params: { accountId: 7 },
    });
  });

  it('handles confirmation display as a typed callback without router or DOM access', async () => {
    const router = { push: vi.fn().mockResolvedValue() };
    const showConfirmation = vi.fn();

    const executed = await executeCaptainUiAction(
      {
        type: 'show_confirmation',
        targetId: '<b>Confirm update_captain_assistant?</b>',
      },
      { router, accountId: 7, showConfirmation }
    );

    expect(executed).toBe(true);
    expect(showConfirmation).toHaveBeenCalledWith(
      'Confirm update_captain_assistant?'
    );
    expect(router.push).not.toHaveBeenCalled();
  });
});
