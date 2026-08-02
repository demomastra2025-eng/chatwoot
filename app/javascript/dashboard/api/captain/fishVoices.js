/* global axios */
import ApiClient from '../ApiClient';

class CaptainFishVoices extends ApiClient {
  constructor() {
    super('captain/fish_voices', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  createVoice({ title, voice, transcript, consentConfirmed }) {
    const formData = new FormData();
    formData.append('title', title);
    formData.append('voice', voice);
    formData.append('consent_confirmed', String(consentConfirmed));
    if (transcript) formData.append('transcript', transcript);

    return axios.post(this.url, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  refresh(id) {
    return axios.get(`${this.url}/${id}`);
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }
}

export default new CaptainFishVoices();
