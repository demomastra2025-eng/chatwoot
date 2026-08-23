/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingProviderCommandsAPI extends ApiClient {
  constructor() {
    super('scheduling/provider_commands', { accountScoped: true });
  }

  get(id, { provider } = {}) {
    const url = `${this.url}/${id}`;
    return provider ? axios.get(url, { params: { provider } }) : axios.get(url);
  }

  list({ provider, appointmentId, activeOnly = false } = {}) {
    return axios.get(this.url, {
      params: {
        active_only: activeOnly,
        appointment_id: appointmentId,
        provider,
      },
    });
  }

  create(data) {
    return axios.post(this.url, data);
  }

  confirm(id, { automatic, provider } = {}) {
    const url = `${this.url}/${id}/confirm`;
    if (automatic === undefined && !provider) return axios.post(url);

    return axios.post(url, {
      ...(automatic === undefined ? {} : { automatic }),
      ...(provider ? { provider } : {}),
    });
  }

  patientCandidates(id, { provider } = {}) {
    const url = `${this.url}/${id}/patient_candidates`;
    return provider ? axios.get(url, { params: { provider } }) : axios.get(url);
  }

  selectPatient(id, { provider, token }) {
    return axios.post(`${this.url}/${id}/select_patient`, {
      patient_token: token,
      provider,
    });
  }

  confirmPatientCreation(id, { provider }) {
    return axios.post(`${this.url}/${id}/confirm_patient_creation`, {
      provider,
    });
  }

  retry(id, { provider }) {
    return axios.post(`${this.url}/${id}/retry`, { provider });
  }

  cancel(id, { provider }) {
    return axios.post(`${this.url}/${id}/cancel`, { provider });
  }
}

export default new SchedulingProviderCommandsAPI();
