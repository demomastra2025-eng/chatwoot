import * as types from '../../../mutation-types';
import { mutations } from '../../inboxes';
import inboxList from './fixtures';

describe('#mutations', () => {
  describe('#SET_INBOXES', () => {
    it('set inbox records', () => {
      const state = { records: [] };
      mutations[types.default.SET_INBOXES](state, inboxList);
      expect(state.records).toEqual(inboxList);
    });
  });

  describe('#SET_INBOXES_ITEM', () => {
    it('push inbox if inbox doesnot exist to the store', () => {
      const state = {
        records: [],
      };
      mutations[types.default.SET_INBOXES_ITEM](state, inboxList[0]);
      expect(state.records).toEqual([inboxList[0]]);
    });

    it('update inbox if it exists to the store', () => {
      const state = {
        records: [
          {
            id: 1,
            channel_id: 1,
            name: 'Test FacebookPage',
            channel_type: 'Channel::FacebookPage',
            avatar_url: 'random_image1.png',
            page_id: '1235',
            widget_color: null,
            website_token: null,
          },
        ],
      };
      mutations[types.default.SET_INBOXES_ITEM](state, inboxList[0]);
      expect(state.records).toEqual([inboxList[0]]);
    });
  });

  describe('#ADD_INBOXES', () => {
    it('push new record in the inbox store', () => {
      const state = {
        records: [],
      };
      mutations[types.default.ADD_INBOXES](state, inboxList[0]);
      expect(state.records).toEqual([inboxList[0]]);
    });
  });
  describe('#EDIT_INBOXES', () => {
    it('update inbox in the store', () => {
      const state = {
        records: [
          {
            id: 1,
            channel_id: 1,
            name: 'Test FacebookPage',
            channel_type: 'Channel::FacebookPage',
            avatar_url: 'random_image1.png',
            page_id: '1235',
            widget_color: null,
            website_token: null,
          },
        ],
      };
      mutations[types.default.EDIT_INBOXES](state, inboxList[0]);
      expect(state.records).toEqual([inboxList[0]]);
    });
  });

  describe('#DELETE_INBOXES', () => {
    it('delete inbox from store', () => {
      const state = {
        records: [inboxList[0]],
      };
      mutations[types.default.DELETE_INBOXES](state, 1);
      expect(state.records).toEqual([]);
    });
  });

  describe('#SET_INBOX_WHATSAPP_FLOWS', () => {
    it('updates only the target inbox with fetched flows', () => {
      const flows = [{ id: 7, provider_flow_id: 'flow-123' }];
      const state = {
        records: [
          { ...inboxList[0], id: 1, name: 'Existing inbox' },
          { ...inboxList[1], id: 2, whatsapp_flows: [] },
        ],
      };

      mutations[types.default.SET_INBOX_WHATSAPP_FLOWS](state, {
        inboxId: 2,
        flows,
      });

      expect(state.records[0].whatsapp_flows).toBeUndefined();
      expect(state.records[1]).toMatchObject({
        id: 2,
        whatsapp_flows: flows,
      });
      expect(state.records[1].name).toBe(inboxList[1].name);
    });
  });

  describe('#DELETE_INBOXES', () => {
    it('delete inbox from store', () => {
      const state = {
        uiFlags: { isFetchingItem: false },
      };
      mutations[types.default.SET_INBOXES_UI_FLAG](state, {
        isFetchingItem: true,
      });
      expect(state.uiFlags).toEqual({ isFetchingItem: true });
    });
  });
});
