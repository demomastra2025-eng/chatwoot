/* global axios */
import ApiClient from './ApiClient';
import { buildDialogMessageData } from './inbox/communicationThread';

// The dialog of a person (a contact), opened from the person and not from a conversation. Reading it writes nothing: a person
// who has a dialog is answered with the id of its thread, a person who has none with a draft. The first message, call or
// note makes the dialog.
class PersonDialogApi extends ApiClient {
  constructor() {
    super('contacts', { accountScoped: true });
  }

  show(contactId, { includeReplyChannels = false } = {}) {
    const url = `${this.url}/${contactId}/dialog`;
    return includeReplyChannels
      ? axios.get(url, { params: { include_reply_channels: true } })
      : axios.get(url);
  }

  createMessage(contactId, message) {
    return axios({
      method: 'post',
      url: `${this.url}/${contactId}/dialog/messages`,
      data: buildDialogMessageData(message),
    });
  }
}

export default new PersonDialogApi();
