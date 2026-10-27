import { isCommunicationChannelReplyable } from '../communicationThreadHelper';
import {
  PERSON_DIALOG_ROUTE_NAME,
  personDialogEmptyStateKind,
  personDialogErrorText,
  personDialogRoute,
} from '../personDialogHelper';

const whatsappTemplateOnly = {
  inbox_id: 12,
  channel: 'Channel::Whatsapp',
  requires_template: true,
  can_reply: false,
  can_send_text: false,
};
// The official WhatsApp of a card without a number, exactly as the server answers it (GET contacts/:id/dialog): a template cannot
// reach a person the channel has no number for, so the channel asks for none and only says why it is disabled.
const disabledNoPhone = {
  conversation_id: null,
  inbox_id: 12,
  channel: 'Channel::Whatsapp',
  channel_key: 'inbox:12',
  can_reply: false,
  can_send_text: false,
  can_send_attachments: false,
  can_call: false,
  requires_template: false,
  reply_window_open: false,
  disabled: true,
  disabled_reason: 'missing_contact_phone_number',
};

describe('#personDialogRoute', () => {
  it('opens the dialog of the person', () => {
    expect(
      personDialogRoute({ accountId: 3, contactId: 5, patientContactId: 5 })
    ).toEqual({
      name: PERSON_DIALOG_ROUTE_NAME,
      params: { accountId: 3, contact_id: 5 },
      query: {},
    });
  });

  it('names the channel the reply box starts on when the dialog is opened from one of the channels of the person', () => {
    expect(
      personDialogRoute({ accountId: 3, contactId: 5, replyInboxId: 12 }).query
    ).toEqual({ replyInbox: '12' });
  });

  it('names the patient when the dialog is held with someone else', () => {
    expect(
      personDialogRoute({ accountId: 3, contactId: 9, patientContactId: 5 })
        .query
    ).toEqual({ patientContactId: '5', patientChatContactId: '9' });
  });
});

describe('#personDialogEmptyStateKind', () => {
  const contact = { phone_number: '+77011234567' };

  it('says the first message can be written', () => {
    expect(
      personDialogEmptyStateKind({
        channels: [{ can_reply: true, can_send_text: true }],
        activeChannel: { can_send_text: true },
        contact,
      })
    ).toBe('default');
  });

  it('explains that WhatsApp opens only with a template', () => {
    expect(
      personDialogEmptyStateKind({
        channels: [whatsappTemplateOnly],
        activeChannel: whatsappTemplateOnly,
        contact,
      })
    ).toBe('whatsapp_template');
  });

  it('asks for a phone number when nobody can be written to without one', () => {
    expect(
      personDialogEmptyStateKind({
        channels: [disabledNoPhone],
        contact: {},
      })
    ).toBe('needs_phone');
    expect(personDialogEmptyStateKind({ channels: [], contact: {} })).toBe(
      'needs_phone'
    );
  });

  it('does not take a channel that cannot reach the person for one a template opens', () => {
    expect(isCommunicationChannelReplyable(disabledNoPhone)).toBe(false);
    expect(isCommunicationChannelReplyable(whatsappTemplateOnly)).toBe(true);
  });

  it('offers to write to the holder of a shared number', () => {
    expect(
      personDialogEmptyStateKind({
        channels: [disabledNoPhone],
        sharedPhoneHolder: { id: 9, name: 'Mother' },
        contact: {},
      })
    ).toBe('shared_phone');
  });

  it('says the user has no messenger for the person when the person has a number but no channel is open to the user', () => {
    expect(personDialogEmptyStateKind({ channels: [], contact })).toBe(
      'no_access'
    );
  });

  it('puts a blocked contact first', () => {
    expect(
      personDialogEmptyStateKind({
        blocked: true,
        channels: [whatsappTemplateOnly],
        activeChannel: whatsappTemplateOnly,
        contact,
      })
    ).toBe('blocked');
  });
});

describe('#personDialogErrorText', () => {
  const t = (key, params) => `${key}|${params.name}`;

  it('gives plain words for the codes the server uses', () => {
    const error = {
      response: {
        data: {
          code: 'foreign_chat_identity',
          details: { contact_name: 'Aigul' },
        },
      },
    };

    expect(personDialogErrorText(error, t)).toBe(
      'PERSON_DIALOG.ERRORS.foreign_chat_identity|Aigul'
    );
  });

  it('has words for a person nobody can be written to or noted on', () => {
    expect(
      personDialogErrorText(
        { response: { data: { code: 'no_reachable_channel' } } },
        t
      )
    ).toBe('PERSON_DIALOG.ERRORS.no_reachable_channel|');
  });

  it('leaves an error without a text of its own to the caller', () => {
    expect(
      personDialogErrorText({ response: { data: { error: 'x' } } }, t)
    ).toBeNull();
    expect(personDialogErrorText(undefined, t)).toBeNull();
  });
});
