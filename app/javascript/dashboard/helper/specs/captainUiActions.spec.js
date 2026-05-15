import { describe, expect, it, vi } from 'vitest';

import {
  executeCaptainUiAction,
  normalizeCaptainUiActions,
  routeForCaptainUiAction,
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
