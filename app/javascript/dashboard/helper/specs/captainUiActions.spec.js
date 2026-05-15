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

  it('builds router targets for assistant and settings pages', () => {
    expect(
      routeForCaptainUiAction(
        { type: 'open_captain_documents', targetId: '12' },
        1
      )
    ).toEqual({
      name: 'captain_assistants_documents_index',
      params: { accountId: 1, assistantId: '12' },
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

  it('rejects entity actions without required target IDs', () => {
    expect(
      routeForCaptainUiAction({ type: 'open_contact', targetId: '' }, 1)
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
});
