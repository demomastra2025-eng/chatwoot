import { describe, expect, it } from 'vitest';
import {
  CONVERSATION_LIST_GLOBAL_STATUS_KEY,
  CONVERSATION_LIST_CONTEXT_SETTINGS_KEY,
  conversationListContextKey,
  conversationListContextState,
  updatedConversationListContextSettings,
} from '../conversationListContext';

describe('conversationListContext', () => {
  it('derives mutually exclusive assignment, CRM stage, and appointment keys', () => {
    expect(conversationListContextKey({})).toBe('assignee:all');
    expect(conversationListContextKey({ assignee_type: 'me' })).toBe(
      'assignee:me'
    );
    expect(conversationListContextKey({ assigneeType: 'unassigned' })).toBe(
      'assignee:unassigned'
    );
    expect(
      conversationListContextKey({
        crm_stage_id: 42,
        appointment_status: 'confirmed',
      })
    ).toBe('crm-stage:42');
    expect(
      conversationListContextKey({ appointment_status: 'confirmed' })
    ).toBe('appointment:confirmed');
  });

  it('keeps sort isolated for each saved folder', () => {
    expect(conversationListContextKey({}, { folderId: 9 })).toBe('folder:9');
    expect(conversationListContextKey({}, { folderId: 10 })).toBe('folder:10');
    expect(conversationListContextKey({}, { folderId: 0 })).toBe(
      'assignee:all'
    );
    expect(
      conversationListContextKey(
        { crm_stage_id: 42, assignee_type: 'me' },
        { folderId: 9 }
      )
    ).toBe('folder:9');
  });

  it('uses the same open status default for every left context', () => {
    expect(conversationListContextState({}, 'assignee:all')).toEqual({
      status: 'open',
      order_by: 'last_activity_at_desc',
    });
    expect(conversationListContextState(undefined, 'crm-stage:42')).toEqual({
      status: 'open',
      order_by: 'last_activity_at_desc',
    });
  });

  it('stores status globally while keeping sort independent per context', () => {
    const firstSettings = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]:
        updatedConversationListContextSettings({}, 'assignee:all', {
          status: 'resolved',
          order_by: 'created_at_asc',
        }),
    };
    const secondSettings = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]:
        updatedConversationListContextSettings(firstSettings, 'assignee:me', {
          status: 'snoozed',
        }),
    };

    expect(
      conversationListContextState(secondSettings, 'assignee:all')
    ).toEqual({
      status: 'snoozed',
      order_by: 'created_at_asc',
    });
    expect(conversationListContextState(secondSettings, 'assignee:me')).toEqual(
      {
        status: 'snoozed',
        order_by: 'last_activity_at_desc',
      }
    );
    expect(
      secondSettings[CONVERSATION_LIST_CONTEXT_SETTINGS_KEY][
        CONVERSATION_LIST_GLOBAL_STATUS_KEY
      ]
    ).toEqual({ status: 'snoozed' });
  });

  it('does not remember the all-statuses selection', () => {
    const rememberedResolved = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]:
        updatedConversationListContextSettings({}, 'assignee:all', {
          status: 'resolved',
        }),
    };
    const settings = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]:
        updatedConversationListContextSettings(
          rememberedResolved,
          'assignee:all',
          { status: 'all', order_by: 'created_at_asc' }
        ),
    };

    // the previously remembered status stays the default of every list
    expect(conversationListContextState(settings, 'folder:3').status).toBe(
      'resolved'
    );
    expect(conversationListContextState(settings, 'assignee:all')).toEqual({
      status: 'resolved',
      order_by: 'created_at_asc',
    });
  });

  it('reopens open instead of a stored all-statuses selection', () => {
    const settings = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
        [CONVERSATION_LIST_GLOBAL_STATUS_KEY]: { status: 'all' },
      },
    };

    expect(conversationListContextState(settings, 'assignee:all').status).toBe(
      'open'
    );
  });

  it('does not overwrite the saved status with an invalid value', () => {
    const settings = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
        [CONVERSATION_LIST_GLOBAL_STATUS_KEY]: { status: 'pending' },
      },
    };

    const nextSettings = updatedConversationListContextSettings(
      settings,
      'assignee:all',
      { status: 'deleted', order_by: 'priority_desc' }
    );

    expect(nextSettings[CONVERSATION_LIST_GLOBAL_STATUS_KEY]).toEqual({
      status: 'pending',
    });
    expect(nextSettings['assignee:all']).toEqual({ order_by: 'priority_desc' });
  });

  it('falls back from stale stored status and sort values', () => {
    const settings = {
      [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]: {
        [CONVERSATION_LIST_GLOBAL_STATUS_KEY]: { status: 'deleted' },
        'assignee:all': { order_by: 'unknown' },
      },
    };

    expect(conversationListContextState(settings, 'assignee:all')).toEqual({
      status: 'open',
      order_by: 'last_activity_at_desc',
    });
  });
});
