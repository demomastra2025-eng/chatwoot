import axios from 'axios';
import { actions } from '../../inboxes';
import * as types from '../../../mutation-types';
import inboxList from './fixtures';

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      const mockedGet = vi.fn(url => {
        if (url === '/api/v1/inboxes') {
          return Promise.resolve({ data: { payload: inboxList } });
        }
        if (url === '/api/v1/accounts//cache_keys') {
          return Promise.resolve({ data: { cache_keys: { inboxes: 0 } } });
        }
        // Return default value or throw an error for unexpected requests
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      axios.get = mockedGet;

      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isFetching: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isFetching: false }],
        [types.default.SET_INBOXES, inboxList],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isFetching: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#createWebsiteChannel', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });
      await actions.createWebsiteChannel({ commit }, inboxList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: true }],
        [types.default.ADD_INBOXES, inboxList[0]],
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.createWebsiteChannel({ commit })).rejects.toThrow(
        Error
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: false }],
      ]);
    });
  });

  describe('#createVoiceChannel', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });
      await actions.createVoiceChannel({ commit }, inboxList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: true }],
        [types.default.ADD_INBOXES, inboxList[0]],
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.createVoiceChannel({ commit })).rejects.toThrow(
        Error
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: false }],
      ]);
    });
  });

  describe('#createFBChannel', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });
      await actions.createFBChannel({ commit }, inboxList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: true }],
        [types.default.ADD_INBOXES, inboxList[0]],
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.createFBChannel({ commit })).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isCreating: false }],
      ]);
    });
  });

  describe('#updateInbox', () => {
    it('sends correct actions if API is success', async () => {
      const updatedInbox = inboxList[0];
      updatedInbox.enable_auto_assignment = false;

      axios.patch.mockResolvedValue({ data: updatedInbox });
      await actions.updateInbox(
        { commit },
        { id: updatedInbox.id, inbox: { enable_auto_assignment: false } }
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isUpdating: true }],
        [types.default.EDIT_INBOXES, updatedInbox],
        [types.default.SET_INBOXES_UI_FLAG, { isUpdating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.updateInbox(
          { commit },
          { id: inboxList[0].id, inbox: { enable_auto_assignment: false } }
        )
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isUpdating: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isUpdating: false }],
      ]);
    });
  });

  describe('#updateInboxIMAP', () => {
    it('sends correct actions if API is success', async () => {
      const updatedInbox = inboxList[0];

      axios.patch.mockResolvedValue({ data: updatedInbox });
      await actions.updateInboxIMAP(
        { commit },
        { id: updatedInbox.id, inbox: { channel: { imap_enabled: true } } }
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: true }],
        [types.default.EDIT_INBOXES, updatedInbox],
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.updateInboxIMAP(
          { commit },
          { id: inboxList[0].id, inbox: { channel: { imap_enabled: true } } }
        )
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: false }],
      ]);
    });
  });

  describe('#updateInboxSMTP', () => {
    it('sends correct actions if API is success', async () => {
      const updatedInbox = inboxList[0];

      axios.patch.mockResolvedValue({ data: updatedInbox });
      await actions.updateInboxSMTP(
        { commit },
        { id: updatedInbox.id, inbox: { channel: { smtp_enabled: true } } }
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: true }],
        [types.default.EDIT_INBOXES, updatedInbox],
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.updateInboxSMTP(
          { commit },
          { id: inboxList[0].id, inbox: { channel: { smtp_enabled: true } } }
        )
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: false }],
      ]);
    });
  });

  describe('#delete', () => {
    it('sends correct actions if API is success', async () => {
      axios.delete.mockResolvedValue({ data: inboxList[0] });
      await actions.delete({ commit }, inboxList[0].id);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isDeleting: true }],
        [types.default.DELETE_INBOXES, inboxList[0].id],
        [types.default.SET_INBOXES_UI_FLAG, { isDeleting: false }],
      ]);
    });
    it('treats a missing inbox as already deleted', async () => {
      commit.mockClear();
      axios.delete.mockRejectedValue({ response: { status: 404 } });

      await expect(
        actions.delete({ commit }, inboxList[0].id)
      ).resolves.toBeNull();

      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isDeleting: true }],
        [types.default.DELETE_INBOXES, inboxList[0].id],
        [types.default.SET_INBOXES_UI_FLAG, { isDeleting: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.delete({ commit }, inboxList[0].id)).rejects.toThrow(
        Error
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_INBOXES_UI_FLAG, { isDeleting: true }],
        [types.default.SET_INBOXES_UI_FLAG, { isDeleting: false }],
      ]);
    });
  });

  describe('#deleteInboxAvatar', () => {
    it('sends correct actions if API is success', async () => {
      axios.delete.mockResolvedValue();
      await expect(
        actions.deleteInboxAvatar({}, inboxList[0].id)
      ).resolves.toBe();
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.deleteInboxAvatar({}, inboxList[0].id)
      ).rejects.toThrow(Error);
    });
  });

  describe('#syncTemplates', () => {
    it('sends correct API call when sync is successful', async () => {
      axios.post.mockResolvedValue({
        data: { message: 'Template sync initiated successfully' },
      });

      await actions.syncTemplates({ commit }, 123);

      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/sync_templates'
      );
    });

    it('throws error when API call fails', async () => {
      const errorMessage =
        'Template sync is only available for WhatsApp channels';
      axios.post.mockRejectedValue(new Error(errorMessage));

      await expect(actions.syncTemplates({ commit }, 123)).rejects.toThrow(
        errorMessage
      );
    });
  });

  describe('#createWhatsAppTemplate', () => {
    it('updates the inbox when create succeeds', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.createWhatsAppTemplate(
        { commit },
        { inboxId: 123, template: { name: 'order_update' } }
      );

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/whatsapp_templates',
        { template: { name: 'order_update' } }
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#deleteWhatsAppTemplate', () => {
    it('updates the inbox when delete succeeds', async () => {
      axios.delete.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.deleteWhatsAppTemplate(
        { commit },
        { inboxId: 123, templateName: 'order_update' }
      );

      expect(response).toEqual(inboxList[0]);
      expect(axios.delete).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/whatsapp_templates/order_update'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#refreshWhatsappWebQr', () => {
    it('updates the inbox when the qr refresh succeeds', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.refreshWhatsappWebQr(
        { commit, state: { records: [] } },
        123
      );

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/refresh_whatsapp_web_qr',
        {}
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });

    it('supports silent status sync without forcing a new qr code', async () => {
      const existingInbox = {
        id: 123,
        additional_attributes: {
          evolution: {
            qrcode: { base64: 'existing-qr' },
            status: 'waiting_for_qr',
          },
        },
      };
      const compactStatusPayload = {
        id: 123,
        additional_attributes: {
          evolution: {
            status: 'connected',
            connection_state: 'open',
          },
        },
      };
      axios.post.mockResolvedValue({ data: compactStatusPayload });

      const response = await actions.refreshWhatsappWebQr(
        { commit, state: { records: [existingInbox] } },
        { inboxId: 123, statusOnly: true }
      );

      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/refresh_whatsapp_web_qr',
        { status_only: true, include_qr_code: false }
      );
      expect(response.additional_attributes.evolution.qrcode).toEqual({
        base64: 'existing-qr',
      });
      expect(commit).toHaveBeenCalledWith(types.default.EDIT_INBOXES, response);
    });

    it('throws a readable error when the qr refresh fails', async () => {
      axios.post.mockRejectedValue({
        response: { data: { error: 'Unable to refresh QR code' } },
      });

      await expect(
        actions.refreshWhatsappWebQr({ commit, state: { records: [] } }, 123)
      ).rejects.toThrow('Unable to refresh QR code');
    });

    it('short-circuits qr refresh when the inbox is already deleting', async () => {
      const deletingInbox = {
        ...inboxList[0],
        id: 123,
        channel_type: 'Channel::WhatsappWeb',
        deleting: true,
        additional_attributes: {
          evolution: {
            status: 'deleting',
            connection_state: 'close',
          },
        },
      };

      const response = await actions.refreshWhatsappWebQr(
        { commit, getters: { getInbox: () => deletingInbox } },
        { inboxId: 123, statusOnly: true }
      );

      expect(response).toEqual(deletingInbox);
      expect(axios.post).not.toHaveBeenCalled();
    });

    it('deduplicates in-flight status sync requests for the same inbox', async () => {
      let resolveRequest;
      axios.post.mockReturnValue(
        new Promise(resolve => {
          resolveRequest = resolve;
        })
      );

      const firstRequest = actions.refreshWhatsappWebQr(
        { commit, state: { records: [] } },
        { inboxId: 123, statusOnly: true }
      );
      const secondRequest = actions.refreshWhatsappWebQr(
        { commit, state: { records: [] } },
        { inboxId: 123, statusOnly: true }
      );

      expect(axios.post).toHaveBeenCalledTimes(1);

      resolveRequest({ data: inboxList[0] });
      await expect(Promise.all([firstRequest, secondRequest])).resolves.toEqual(
        [inboxList[0], inboxList[0]]
      );
      expect(commit).toHaveBeenCalledTimes(1);
    });
  });

  describe('#reconnectWhatsappWeb', () => {
    it('updates the inbox when reconnect succeeds', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.reconnectWhatsappWeb({ commit }, 123);

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/reconnect_whatsapp_web'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#requestTelegramPersonalQr', () => {
    it('updates the inbox when qr login request succeeds', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.requestTelegramPersonalQr({ commit }, 123);

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/telegram_personal_request_qr'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#disconnectWhatsappWeb', () => {
    it('updates the inbox when disconnect succeeds', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.disconnectWhatsappWeb({ commit }, 123);

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/disconnect_whatsapp_web'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#repairWhatsappWeb', () => {
    it('updates the inbox when repair succeeds', async () => {
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.repairWhatsappWeb({ commit }, 123);

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/repair_whatsapp_web'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#getWhatsappWebDiagnostics', () => {
    it('returns diagnostics payload', async () => {
      const diagnostics = { counts: { total_messages: 2 } };
      axios.get.mockResolvedValue({ data: diagnostics });

      const response = await actions.getWhatsappWebDiagnostics({}, 123);

      expect(response).toEqual(diagnostics);
      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/whatsapp_web_diagnostics'
      );
    });
  });

  describe('#requestTelegramPersonalCode', () => {
    it('updates the inbox when request code succeeds', async () => {
      commit.mockClear();
      axios.post.mockResolvedValue({ data: inboxList[0] });

      const response = await actions.requestTelegramPersonalCode(
        { commit },
        123
      );

      expect(response).toEqual(inboxList[0]);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/telegram_personal_request_code'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        inboxList[0]
      );
    });
  });

  describe('#getTelegramPersonalDiagnostics', () => {
    it('merges diagnostics back into the inbox store when an inbox exists', async () => {
      commit.mockClear();
      const currentInbox = {
        id: 123,
        channel_type: 'Channel::TelegramPersonal',
        connection_state: 'disconnected',
        lifecycle_state: 'pending_auth',
        runtime_state: {},
      };
      const diagnostics = {
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          runtime_state: { auth_state: 'authorized' },
          last_error: null,
        },
      };

      const getters = {
        getInbox: id => (id === 123 ? currentInbox : null),
      };

      axios.get.mockResolvedValue({ data: diagnostics });

      const response = await actions.getTelegramPersonalDiagnostics(
        { commit, getters },
        123
      );

      expect(response).toEqual(diagnostics);
      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/inboxes/123/telegram_personal_diagnostics'
      );
      expect(commit).toHaveBeenCalledWith(
        types.default.EDIT_INBOXES,
        expect.objectContaining({
          id: 123,
          connection_state: 'connected',
          lifecycle_state: 'connected',
          runtime_state: { auth_state: 'authorized' },
        })
      );
    });

    it('coalesces concurrent requests for the same inbox', async () => {
      commit.mockClear();
      const currentInbox = {
        id: 456,
        channel_type: 'Channel::TelegramPersonal',
        runtime_state: {},
      };
      const diagnostics = {
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          runtime_state: { auth_state: 'authorized' },
        },
      };

      const getters = {
        getInbox: id => (id === 456 ? currentInbox : null),
      };

      let resolveRequest;
      const pendingRequest = new Promise(resolve => {
        resolveRequest = resolve;
      });
      axios.get.mockReturnValue(pendingRequest);

      const firstRequest = actions.getTelegramPersonalDiagnostics(
        { commit, getters },
        456
      );
      const secondRequest = actions.getTelegramPersonalDiagnostics(
        { commit, getters },
        456
      );

      resolveRequest({ data: diagnostics });

      const [firstResponse, secondResponse] = await Promise.all([
        firstRequest,
        secondRequest,
      ]);

      expect(firstResponse).toEqual(diagnostics);
      expect(secondResponse).toEqual(diagnostics);
      expect(axios.get).toHaveBeenCalledTimes(1);
      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/inboxes/456/telegram_personal_diagnostics'
      );
    });

    it('reuses a recent diagnostics response during the cooldown window', async () => {
      commit.mockClear();
      const currentInbox = {
        id: 789,
        channel_type: 'Channel::TelegramPersonal',
        runtime_state: {},
      };
      const diagnostics = {
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          runtime_state: { auth_state: 'authorized' },
        },
      };
      const getters = {
        getInbox: id => (id === 789 ? currentInbox : null),
      };
      const nowSpy = vi.spyOn(Date, 'now');

      axios.get.mockResolvedValue({ data: diagnostics });
      nowSpy.mockReturnValue(1_000);
      const firstResponse = await actions.getTelegramPersonalDiagnostics(
        { commit, getters },
        789
      );

      nowSpy.mockReturnValue(2_000);
      const secondResponse = await actions.getTelegramPersonalDiagnostics(
        { commit, getters },
        789
      );

      expect(firstResponse).toEqual(diagnostics);
      expect(secondResponse).toEqual(diagnostics);
      expect(axios.get).toHaveBeenCalledTimes(1);

      nowSpy.mockRestore();
    });

    it('removes a missing inbox from the store on 404', async () => {
      commit.mockClear();
      axios.get.mockRejectedValue({ response: { status: 404 } });

      const response = await actions.getTelegramPersonalDiagnostics(
        { commit, getters: {} },
        123
      );

      expect(response).toBeNull();
      expect(commit).toHaveBeenCalledWith(types.default.DELETE_INBOXES, 123);
    });
  });
});
