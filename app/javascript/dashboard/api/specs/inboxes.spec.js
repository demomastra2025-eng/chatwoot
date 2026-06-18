import inboxesAPI from '../inboxes';
import ApiClient from '../ApiClient';

describe('#InboxesAPI', () => {
  it('creates correct instance', () => {
    expect(inboxesAPI).toBeInstanceOf(ApiClient);
    expect(inboxesAPI).toHaveProperty('get');
    expect(inboxesAPI).toHaveProperty('show');
    expect(inboxesAPI).toHaveProperty('create');
    expect(inboxesAPI).toHaveProperty('update');
    expect(inboxesAPI).toHaveProperty('delete');
    expect(inboxesAPI).toHaveProperty('getCampaigns');
    expect(inboxesAPI).toHaveProperty('getAgentBot');
    expect(inboxesAPI).toHaveProperty('setAgentBot');
    expect(inboxesAPI).toHaveProperty('syncTemplates');
    expect(inboxesAPI).toHaveProperty('createWhatsAppTemplate');
    expect(inboxesAPI).toHaveProperty('deleteWhatsAppTemplate');
    expect(inboxesAPI).toHaveProperty('getWhatsAppFlows');
    expect(inboxesAPI).toHaveProperty('createWhatsAppFlow');
    expect(inboxesAPI).toHaveProperty('updateWhatsAppFlow');
    expect(inboxesAPI).toHaveProperty('deleteWhatsAppFlow');
    expect(inboxesAPI).toHaveProperty('createWhatsAppFlowSession');
  });

  describe('API calls', () => {
    const originalAxios = window.axios;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      get: vi.fn(() => Promise.resolve()),
      patch: vi.fn(() => Promise.resolve()),
      delete: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
    });

    afterEach(() => {
      window.axios = originalAxios;
    });

    it('#getCampaigns', () => {
      inboxesAPI.getCampaigns(2);
      expect(axiosMock.get).toHaveBeenCalledWith('/api/v1/inboxes/2/campaigns');
    });

    it('#deleteInboxAvatar', () => {
      inboxesAPI.deleteInboxAvatar(2);
      expect(axiosMock.delete).toHaveBeenCalledWith('/api/v1/inboxes/2/avatar');
    });

    it('#syncTemplates', () => {
      inboxesAPI.syncTemplates(2);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/sync_templates'
      );
    });

    it('#createWhatsAppTemplate', () => {
      const template = { name: 'order_update' };
      inboxesAPI.createWhatsAppTemplate(2, template);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_templates',
        { template }
      );
    });

    it('#deleteWhatsAppTemplate', () => {
      inboxesAPI.deleteWhatsAppTemplate(2, 'order_update');
      expect(axiosMock.delete).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_templates/order_update'
      );
    });

    it('#getWhatsAppFlows', () => {
      inboxesAPI.getWhatsAppFlows(2);
      expect(axiosMock.get).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_flows'
      );
    });

    it('#createWhatsAppFlow', () => {
      const flow = { provider_flow_id: 'flow-123', name: 'lead_flow' };
      inboxesAPI.createWhatsAppFlow(2, flow);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_flows',
        { flow }
      );
    });

    it('#updateWhatsAppFlow', () => {
      const flow = { title: 'Lead form' };
      inboxesAPI.updateWhatsAppFlow(2, 7, flow);
      expect(axiosMock.patch).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_flows/7',
        { flow }
      );
    });

    it('#deleteWhatsAppFlow', () => {
      inboxesAPI.deleteWhatsAppFlow(2, 7);
      expect(axiosMock.delete).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_flows/7'
      );
    });

    it('#createWhatsAppFlowSession', () => {
      const session = { conversation_id: 99 };
      inboxesAPI.createWhatsAppFlowSession(2, 7, session);
      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/2/whatsapp_flows/7/sessions',
        { session }
      );
    });
  });
});
