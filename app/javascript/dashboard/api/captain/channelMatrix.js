/* global axios */
import ApiClient from '../ApiClient';

// Text channels × AI agents (package relchannels). One GET returns the whole
// matrix; one PATCH saves every change atomically (422 lists per-row errors).
class CaptainChannelMatrix extends ApiClient {
  constructor() {
    super('captain/channel_matrix', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  update(data) {
    return axios.patch(this.url, data);
  }
}

export default new CaptainChannelMatrix();
