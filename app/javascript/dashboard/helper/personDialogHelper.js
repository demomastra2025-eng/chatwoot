import { isCommunicationChannelReplyable } from './communicationThreadHelper';

// The dialog of a person is opened by the person: /communication_threads/contact/:contactId. A person who has a dialog is sent on to
// it, a person who has none sees the empty screen of a draft, see store/modules/conversations/actions/personDialogActions.js.

export const PERSON_DIALOG_ROUTE_NAME = 'communication_thread_contact';

// patientContactId: the patient the dialog is about when it is held with someone else (a child whose mother's number it is). The
// sidebar of the dialog shows that patient's card (patientContactId) next to the chat of the one written to (patientChatContactId).
export const personDialogRoute = ({
  accountId,
  contactId,
  patientContactId = null,
}) => {
  const hasPatient =
    patientContactId && Number(patientContactId) !== Number(contactId);

  return {
    name: PERSON_DIALOG_ROUTE_NAME,
    params: { accountId, contact_id: contactId },
    query: hasPatient
      ? {
          patientContactId: String(patientContactId),
          patientChatContactId: String(contactId),
        }
      : {},
  };
};

// The codes of a refused first message (422 { error, code }) that have a text of their own in the screen.
const PERSON_DIALOG_ERROR_CODES = [
  'foreign_chat_identity',
  'template_required',
  'channel_unavailable',
  'contact_blocked',
];

// The plain-words text of a refused send, or null for an error the screen has no words for (it shows the server's message).
export const personDialogErrorText = (error, t) => {
  const data = error?.response?.data;
  const code = data?.code;
  if (!PERSON_DIALOG_ERROR_CODES.includes(code)) return null;

  return t(`PERSON_DIALOG.ERRORS.${code}`, {
    name: data?.details?.contact_name || '',
  });
};

// What the empty screen of a person says, in the order of what stops the first message:
//   blocked        the contact is blocked
//   shared_phone   the person has no number of their own, it is someone else's (the mother's): offer to write to that one
//   needs_phone    nobody can be written to without a phone number (or an email) in the card
//   no_access      the person can be written to, but the user is in none of the channels for it
//   whatsapp_template   the channel in front is WhatsApp and the person has never written: only a template can open it
//   default        the first message can be written
export const personDialogEmptyStateKind = ({
  blocked = false,
  sharedPhoneHolder = null,
  channels = [],
  activeChannel = null,
  contact = {},
} = {}) => {
  if (blocked) return 'blocked';

  const list = Array.isArray(channels) ? channels : [];
  if (!list.some(isCommunicationChannelReplyable)) {
    if (sharedPhoneHolder?.id) return 'shared_phone';

    const lacksContactData = list.some(channel =>
      String(channel?.disabled_reason || '').startsWith('missing_contact_')
    );
    if (lacksContactData || (!contact?.phone_number && !contact?.email)) {
      return 'needs_phone';
    }
    return 'no_access';
  }

  return activeChannel?.requires_template ? 'whatsapp_template' : 'default';
};
