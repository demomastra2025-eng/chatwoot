import * as types from '../../mutation-types';
import InboxesAPI from '../../../api/inboxes';
import AnalyticsHelper from '../../../helper/AnalyticsHelper';
import { ACCOUNT_EVENTS } from '../../../helper/AnalyticsHelper/events';

export const buildInboxData = inboxParams => {
  const formData = new FormData();
  const { channel = {}, ...inboxProperties } = inboxParams;
  Object.keys(inboxProperties).forEach(key => {
    formData.append(key, inboxProperties[key]);
  });
  const {
    selectedFeatureFlags,
    ignore_jids: ignoreJidsSnakeCase,
    ignoreJids,
    ...channelParams
  } = channel;
  const arrayFields = [
    ['selected_feature_flags', selectedFeatureFlags],
    ['ignore_jids', ignoreJidsSnakeCase || ignoreJids],
  ];

  arrayFields.forEach(([fieldName, value]) => {
    if (!Array.isArray(value)) return;

    if (value.length) {
      value.forEach(entry => {
        formData.append(`channel[${fieldName}][]`, entry);
      });
    } else {
      formData.append(`channel[${fieldName}][]`, '');
    }
  });
  Object.keys(channelParams).forEach(key => {
    formData.append(`channel[${key}]`, channel[key]);
  });
  return formData;
};

const sendAnalyticsEvent = channelType => {
  AnalyticsHelper.track(ACCOUNT_EVENTS.ADDED_AN_INBOX, {
    channelType,
  });
};

export const channelActions = {
  createVoiceChannel: async ({ commit }, params) => {
    try {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: true });
      const response = await InboxesAPI.create({
        name: params.name,
        channel: { ...params.voice, type: 'voice' },
      });
      commit(types.default.ADD_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      sendAnalyticsEvent('voice');
      return response.data;
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      throw error;
    }
  },
};
