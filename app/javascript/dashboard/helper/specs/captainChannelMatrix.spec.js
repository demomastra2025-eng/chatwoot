import { describe, expect, it } from 'vitest';

import {
  agentChannelSummary,
  buildChannelMatrixPatch,
  channelsMissingMain,
  extractMatrixErrors,
  isDraftMember,
  isEmptyMatrixPatch,
  isTextChannel,
  matrixErrorsByInbox,
  setDraftAiEnabled,
  setDraftAutoReplyMode,
  setDraftDefaultMain,
  setDraftMain,
  setDraftMembership,
  setDraftScope,
  toMatrixDraft,
} from '../captainChannelMatrix';

const matrixPayload = () => ({
  default_main_assistant_id: 12,
  channels: [
    {
      inbox_id: 5,
      name: 'WhatsApp',
      channel_type: 'Channel::Whatsapp',
      ai_enabled: true,
      main_assistant_id: 12,
      assistant_ids: [12, 15],
      auto_reply_mode: 'always',
    },
    {
      inbox_id: 6,
      name: 'Telegram',
      channel_type: 'Channel::Telegram',
      ai_enabled: false,
      main_assistant_id: null,
      assistant_ids: [12],
      auto_reply_mode: 'working_hours',
    },
    {
      inbox_id: 9,
      name: 'Calls',
      channel_type: 'Channel::Voice',
      ai_enabled: true,
      main_assistant_id: 12,
      assistant_ids: [12],
      auto_reply_mode: 'always',
    },
  ],
  assistants: [
    {
      id: 12,
      name: 'Администратор',
      avatar_url: '',
      active: true,
      channel_scope: 'all',
      inbox_ids: [],
    },
    {
      id: 15,
      name: 'Продажи',
      avatar_url: '',
      active: true,
      channel_scope: 'selected',
      inbox_ids: [5],
    },
    {
      id: 20,
      name: 'Архив',
      avatar_url: '',
      active: false,
      channel_scope: 'selected',
      inbox_ids: [],
    },
  ],
});

const channelOf = (draft, inboxId) =>
  draft.channels.find(channel => channel.inbox_id === inboxId);

const assistantOf = (draft, id) =>
  draft.assistants.find(assistant => assistant.id === id);

describe('captainChannelMatrix helpers', () => {
  describe('isTextChannel', () => {
    it('treats every channel except voice as a text channel', () => {
      expect(isTextChannel('Channel::Whatsapp')).toBe(true);
      expect(isTextChannel('Channel::Api')).toBe(true);
      expect(isTextChannel('Channel::Voice')).toBe(false);
    });
  });

  describe('toMatrixDraft', () => {
    it('normalizes the payload and drops voice channels', () => {
      const draft = toMatrixDraft(matrixPayload());

      expect(draft.default_main_assistant_id).toBe(12);
      expect(draft.channels.map(channel => channel.inbox_id)).toEqual([5, 6]);
      expect(assistantOf(draft, 12)).toMatchObject({
        channel_scope: 'all',
        inbox_ids: [],
        active: true,
      });
      expect(assistantOf(draft, 20).active).toBe(false);
    });

    it('returns an empty draft for a missing payload', () => {
      expect(toMatrixDraft(null)).toEqual({
        default_main_assistant_id: null,
        channels: [],
        assistants: [],
      });
    });

    it('defaults unknown reply modes and scopes', () => {
      const draft = toMatrixDraft({
        channels: [{ inbox_id: '7', channel_type: 'Channel::Api' }],
        assistants: [{ id: '3', channel_scope: null, inbox_ids: [7] }],
      });

      expect(channelOf(draft, 7)).toMatchObject({
        ai_enabled: false,
        main_assistant_id: null,
        auto_reply_mode: 'always',
      });
      expect(assistantOf(draft, 3)).toMatchObject({
        channel_scope: 'all',
        inbox_ids: [],
      });
    });
  });

  describe('draft rules', () => {
    it('knows configured membership for all and selected scopes', () => {
      const draft = toMatrixDraft(matrixPayload());

      expect(isDraftMember(draft, 12, 6)).toBe(true);
      expect(isDraftMember(draft, 15, 5)).toBe(true);
      expect(isDraftMember(draft, 15, 6)).toBe(false);
      expect(isDraftMember(draft, 99, 5)).toBe(false);
    });

    it('turns an «all channels» agent into a selection when one cell is unchecked', () => {
      const base = toMatrixDraft(matrixPayload());
      const next = setDraftMembership(base, 12, 6, false);

      expect(assistantOf(next, 12)).toMatchObject({
        channel_scope: 'selected',
        inbox_ids: [5],
      });
      expect(isDraftMember(next, 12, 6)).toBe(false);
      // The original draft is not mutated.
      expect(assistantOf(base, 12).channel_scope).toBe('all');
    });

    it('clears the main agent when its cell is unchecked', () => {
      const next = setDraftMembership(
        toMatrixDraft(matrixPayload()),
        12,
        5,
        false
      );

      expect(channelOf(next, 5).main_assistant_id).toBeNull();
      expect(channelsMissingMain(next)).toEqual([5]);
    });

    it('adds a channel to a selected agent when a cell is checked', () => {
      const draft = toMatrixDraft(matrixPayload());
      const next = setDraftMembership(draft, 15, 6, true);

      expect(assistantOf(next, 15).inbox_ids).toEqual([5, 6]);
    });

    it('switches the column scope', () => {
      const draft = toMatrixDraft(matrixPayload());

      const selected = setDraftScope(draft, 12, 'selected');
      expect(assistantOf(selected, 12)).toMatchObject({
        channel_scope: 'selected',
        inbox_ids: [5, 6],
      });

      const all = setDraftScope(draft, 15, 'all');
      expect(assistantOf(all, 15)).toMatchObject({
        channel_scope: 'all',
        inbox_ids: [],
      });
      expect(isDraftMember(all, 15, 6)).toBe(true);
    });

    it('sets the main agent only among members', () => {
      const draft = toMatrixDraft(matrixPayload());
      const member = setDraftMain(draft, 5, 15);
      const notMember = setDraftMain(draft, 6, 15);
      const cleared = setDraftMain(draft, 5, null);

      expect(channelOf(member, 5).main_assistant_id).toBe(15);
      expect(channelOf(notMember, 6).main_assistant_id).toBeNull();
      expect(channelOf(cleared, 5).main_assistant_id).toBeNull();
    });

    it('pre-selects the default main agent when AI is turned on', () => {
      const next = setDraftAiEnabled(toMatrixDraft(matrixPayload()), 6, true);

      expect(channelOf(next, 6)).toMatchObject({
        ai_enabled: true,
        main_assistant_id: 12,
      });
    });

    it('does not pre-select a default main agent that is not a member', () => {
      const draft = setDraftDefaultMain(toMatrixDraft(matrixPayload()), 15);
      const next = setDraftAiEnabled(draft, 6, true);

      expect(channelOf(next, 6).main_assistant_id).toBeNull();
      expect(channelsMissingMain(next)).toEqual([6]);
    });

    it('updates the reply mode', () => {
      const next = setDraftAutoReplyMode(
        toMatrixDraft(matrixPayload()),
        5,
        'outside_working_hours'
      );

      expect(channelOf(next, 5).auto_reply_mode).toBe('outside_working_hours');
    });
  });

  describe('buildChannelMatrixPatch', () => {
    it('is empty when nothing changed', () => {
      const patch = buildChannelMatrixPatch(
        matrixPayload(),
        toMatrixDraft(matrixPayload())
      );

      expect(patch).toEqual({});
      expect(isEmptyMatrixPatch(patch)).toBe(true);
    });

    it('sends only the changed channel rows, agents and default', () => {
      const base = toMatrixDraft(matrixPayload());
      let draft = setDraftMembership(base, 12, 5, false);
      draft = setDraftMain(draft, 5, 15);
      draft = setDraftDefaultMain(draft, 15);

      expect(buildChannelMatrixPatch(base, draft)).toEqual({
        default_main_assistant_id: 15,
        channels: [
          {
            inbox_id: 5,
            ai_enabled: true,
            main_assistant_id: 15,
            auto_reply_mode: 'always',
          },
        ],
        assistants: [{ id: 12, channel_scope: 'selected', inbox_ids: [6] }],
      });
    });

    it('ignores the order of inbox ids', () => {
      const base = toMatrixDraft(matrixPayload());
      const draft = toMatrixDraft(matrixPayload());
      assistantOf(base, 15).inbox_ids = [5, 6];
      assistantOf(draft, 15).inbox_ids = [6, 5];

      expect(buildChannelMatrixPatch(base, draft)).toEqual({});
    });
  });

  describe('errors', () => {
    it('reads the 422 error list', () => {
      const errors = extractMatrixErrors({
        response: {
          status: 422,
          data: {
            errors: [
              {
                inbox_id: 5,
                assistant_id: null,
                code: 'MAIN_AGENT_REQUIRED',
                message: 'Choose a main agent',
              },
            ],
          },
        },
      });

      expect(errors).toEqual([
        {
          inbox_id: 5,
          assistant_id: null,
          code: 'MAIN_AGENT_REQUIRED',
          message: 'Choose a main agent',
        },
      ]);
    });

    it('turns any other failure into one general error', () => {
      const serverError = { response: { status: 500, data: {} } };

      expect(extractMatrixErrors(serverError)).toEqual([
        { inbox_id: null, assistant_id: null, code: 'HTTP_500', message: '' },
      ]);
      expect(extractMatrixErrors(new Error('offline'))[0]).toMatchObject({
        inbox_id: null,
        code: 'NETWORK_ERROR',
      });
    });

    it('groups errors by channel row and general errors', () => {
      const { byInbox, general } = matrixErrorsByInbox([
        { inbox_id: 5, code: 'MAIN_AGENT_REQUIRED', message: 'Row five' },
        { inbox_id: '5', code: 'MAIN_AGENT_INACTIVE', message: 'Again' },
        { inbox_id: null, code: 'INVALID_DEFAULT', message: 'General' },
      ]);

      expect(byInbox[5].map(error => error.message)).toEqual([
        'Row five',
        'Again',
      ]);
      expect(general.map(error => error.code)).toEqual(['INVALID_DEFAULT']);
    });
  });

  describe('agentChannelSummary', () => {
    it('uses the matrix when it is loaded', () => {
      const summary = agentChannelSummary({
        assistant: { id: 12 },
        matrix: matrixPayload(),
      });

      expect(summary).toEqual({
        scope: 'all',
        memberInboxIds: [5, 6],
        mainInboxIds: [5],
        channels: [
          {
            inboxId: 5,
            name: 'WhatsApp',
            channelType: 'Channel::Whatsapp',
            isMain: true,
          },
          {
            inboxId: 6,
            name: 'Telegram',
            channelType: 'Channel::Telegram',
            isMain: false,
          },
        ],
      });
    });

    it('counts main channels only where AI is on', () => {
      const matrix = matrixPayload();
      matrix.channels[0].ai_enabled = false;
      const summary = agentChannelSummary({ assistant: { id: 12 }, matrix });

      expect(summary.mainInboxIds).toEqual([]);
    });

    it('lists only the selected channels of a selected agent', () => {
      const summary = agentChannelSummary({
        assistant: { id: 15 },
        matrix: matrixPayload(),
      });

      expect(summary.scope).toBe('selected');
      expect(summary.memberInboxIds).toEqual([5]);
      expect(summary.mainInboxIds).toEqual([]);
    });

    it('falls back to the assistant JSON and Vuex inboxes without a matrix', () => {
      const inboxes = [
        { id: 5, name: 'WhatsApp', channel_type: 'Channel::Whatsapp' },
        { id: 6, name: 'Telegram', channel_type: 'Channel::Telegram' },
        { id: 9, name: 'Calls', channel_type: 'Channel::Voice' },
      ];

      const selected = agentChannelSummary({
        assistant: {
          id: 15,
          channel_scope: 'selected',
          inbox_ids: [6, 9],
          main_in_inbox_ids: [6],
        },
        inboxes,
      });
      expect(selected).toEqual({
        scope: 'selected',
        memberInboxIds: [6],
        mainInboxIds: [6],
        channels: [
          {
            inboxId: 6,
            name: 'Telegram',
            channelType: 'Channel::Telegram',
            isMain: true,
          },
        ],
      });

      const all = agentChannelSummary({
        assistant: { id: 12, channel_scope: 'all', main_in_inbox_ids: [] },
        inboxes,
      });
      expect(all.scope).toBe('all');
      expect(all.memberInboxIds).toEqual([5, 6]);
      expect(all.channels.map(channel => channel.name)).toEqual([
        'WhatsApp',
        'Telegram',
      ]);
    });
  });
});
