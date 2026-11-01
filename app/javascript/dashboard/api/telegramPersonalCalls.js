/* global axios */
import ApiClient from './ApiClient';
import WhatsappCallsAPI from './whatsappCalls';

class TelegramPersonalCallsAPI extends ApiClient {
  constructor() {
    super('telegram_personal_calls', { accountScoped: true });
  }

  show(callId) {
    return axios.get(`${this.url}/${callId}`);
  }

  accept(callId) {
    return axios.post(`${this.url}/${callId}/accept`, {});
  }

  reject(callId) {
    return axios.post(`${this.url}/${callId}/reject`);
  }

  terminate(callId) {
    return axios.post(`${this.url}/${callId}/terminate`);
  }

  prepareOutbound(conversationId) {
    return axios.post(`${this.url}/prepare_outbound`, {
      conversation_id: conversationId,
    });
  }

  dial(callId) {
    return axios.post(`${this.url}/${callId}/dial`);
  }

  agentAnswer(callId, sdpAnswer, clientTiming = null, peerId = null) {
    const body = { sdp_answer: sdpAnswer };
    if (peerId) body.peer_id = peerId;
    if (clientTiming) body.client_timing = clientTiming;
    return axios.post(`${this.url}/${callId}/agent_answer`, body);
  }

  active() {
    return axios.get(`${this.url}/active`);
  }

  reconnect(callId) {
    return axios.post(`${this.url}/${callId}/reconnect`);
  }
}

const telegramPersonalCallsApi = new TelegramPersonalCallsAPI();

export const isTelegramPersonalProvider = value => {
  const provider =
    typeof value === 'string'
      ? value
      : value?.provider ||
        value?.callSource ||
        value?.call_source ||
        value?.channel;
  return (
    provider === 'telegram_personal' || provider === 'Channel::TelegramPersonal'
  );
};

export const callsApiFor = value =>
  isTelegramPersonalProvider(value)
    ? telegramPersonalCallsApi
    : WhatsappCallsAPI;

export default telegramPersonalCallsApi;
