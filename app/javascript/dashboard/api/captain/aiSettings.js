/* global axios */
import ApiClient from '../ApiClient';

// Workspace-level AI settings shared by every agent (package relsettings).
// GET and PATCH are admin only; PATCH accepts any subset of the sections and
// answers 422 with { errors: [{ field, code, message }] }.
class CaptainAiSettings extends ApiClient {
  constructor() {
    super('captain/settings', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  update(data) {
    return axios.patch(this.url, data);
  }
}

export default new CaptainAiSettings();
