import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import * as types from '../mutation-types';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import InboxesAPI from '../../api/inboxes';
import WebChannel from '../../api/channel/webChannel';
import FBChannel from '../../api/channel/fbChannel';
import TwilioChannel from '../../api/channel/twilioChannel';
import WhatsappChannel from '../../api/channel/whatsappChannel';
import { throwErrorMessage } from '../utils/api';
import AnalyticsHelper from '../../helper/AnalyticsHelper';
import camelcaseKeys from 'camelcase-keys';
import { ACCOUNT_EVENTS } from '../../helper/AnalyticsHelper/events';
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';
import { channelActions, buildInboxData } from './inboxes/channelActions';
import {
  COMPONENT_TYPES,
  UNSUPPORTED_TEMPLATE_COMPONENT_TYPES,
  UNSUPPORTED_TEMPLATE_HEADER_FORMATS,
} from 'dashboard/helper/templateHelper';

export const state = {
  records: [],
  uiFlags: {
    isFetching: false,
    isFetchingItem: false,
    isCreating: false,
    isUpdating: false,
    isDeleting: false,
    isUpdatingIMAP: false,
    isUpdatingSMTP: false,
  },
};

const whatsappWebRefreshRequests = new Map();
const telegramPersonalDiagnosticsRequests = new Map();
const telegramPersonalDiagnosticsCache = new Map();
const TELEGRAM_PERSONAL_DIAGNOSTICS_COOLDOWN_MS = 3000;
const weixinDiagnosticsRequests = new Map();
const weixinDiagnosticsCache = new Map();
const WEIXIN_DIAGNOSTICS_COOLDOWN_MS = 3000;
const hasOwn = (object, key) =>
  Object.prototype.hasOwnProperty.call(object || {}, key);
const pickRuntimeValue = (runtimeState, diagnostics, channelState, key) => {
  if (hasOwn(channelState, key)) {
    return channelState[key];
  }
  if (hasOwn(diagnostics, key)) {
    return diagnostics[key];
  }
  return runtimeState[key];
};

const mergeTelegramPersonalDiagnostics = (inbox, diagnostics) => {
  if (!inbox || !diagnostics) {
    return inbox;
  }

  const channelState = diagnostics.channel || {};
  const runtimeState = {
    ...(inbox.runtime_state || {}),
    ...(channelState.runtime_state || {}),
  };

  [
    'auth_state',
    'connected',
    'authorized',
    'last_inbound_at',
    'last_outbound_at',
    'flood_wait_until',
    'flood_wait_seconds',
    'history_sync_state',
    'last_history_sync_at',
    'history_sync_count',
    'unread_reactions_count',
    'me',
  ].forEach(key => {
    if (diagnostics[key] !== undefined) {
      runtimeState[key] = diagnostics[key];
    }
  });

  if (diagnostics.connection_state !== undefined) {
    runtimeState.connection_state = diagnostics.connection_state;
  }

  if (diagnostics.lifecycle_state !== undefined) {
    runtimeState.lifecycle_state = diagnostics.lifecycle_state;
  }

  return {
    ...inbox,
    connection_state:
      channelState.connection_state ||
      diagnostics.connection_state ||
      inbox.connection_state,
    lifecycle_state:
      channelState.lifecycle_state ||
      diagnostics.lifecycle_state ||
      inbox.lifecycle_state,
    last_error: channelState.last_error ?? inbox.last_error,
    runtime_state: runtimeState,
  };
};

const normalizeTelegramPersonalDiagnosticsPayload = payload => {
  if (typeof payload === 'object' && payload !== null) {
    return {
      inboxId: payload.inboxId,
      force: payload.force === true,
    };
  }

  return {
    inboxId: payload,
    force: false,
  };
};

const clearTelegramPersonalDiagnosticsCache = inboxId => {
  telegramPersonalDiagnosticsCache.delete(String(inboxId));
};

const getCachedTelegramPersonalDiagnostics = inboxId => {
  const cachedDiagnostics = telegramPersonalDiagnosticsCache.get(
    String(inboxId)
  );

  if (!cachedDiagnostics) {
    return null;
  }

  if (
    Date.now() - cachedDiagnostics.fetchedAt >
    TELEGRAM_PERSONAL_DIAGNOSTICS_COOLDOWN_MS
  ) {
    clearTelegramPersonalDiagnosticsCache(inboxId);
    return null;
  }

  return cachedDiagnostics.data;
};

const cacheTelegramPersonalDiagnostics = (inboxId, diagnostics) => {
  telegramPersonalDiagnosticsCache.set(String(inboxId), {
    data: diagnostics,
    fetchedAt: Date.now(),
  });
};

const mergeWeixinDiagnostics = (inbox, diagnostics) => {
  if (!inbox || !diagnostics) {
    return diagnostics || inbox;
  }

  if (diagnostics.id) {
    return {
      ...inbox,
      ...diagnostics,
      runtime_state: {
        ...(inbox.runtime_state || {}),
        ...(diagnostics.runtime_state || {}),
      },
    };
  }

  const channelState = diagnostics.channel || {};
  const runtimeState = {
    ...(inbox.runtime_state || {}),
    ...(channelState.runtime_state || {}),
  };

  [
    'qr_login_state',
    'qr_login_url',
    'qr_login_expires_at',
    'status',
    'connected',
    'authorized',
    'last_inbound_at',
    'last_outbound_at',
    'last_error_at',
    'runtime_status',
  ].forEach(key => {
    const value = pickRuntimeValue(
      runtimeState,
      diagnostics,
      channelState,
      key
    );
    if (value !== undefined) {
      runtimeState[key] = value;
    }
  });

  if (diagnostics.connection_state !== undefined) {
    runtimeState.connection_state = diagnostics.connection_state;
  }

  if (diagnostics.lifecycle_state !== undefined) {
    runtimeState.lifecycle_state = diagnostics.lifecycle_state;
  }

  return {
    ...inbox,
    provider_account_id:
      channelState.provider_account_id ||
      diagnostics.provider_account_id ||
      inbox.provider_account_id,
    display_name:
      channelState.display_name ||
      diagnostics.display_name ||
      inbox.display_name,
    connection_state:
      channelState.connection_state ||
      diagnostics.connection_state ||
      inbox.connection_state,
    lifecycle_state:
      channelState.lifecycle_state ||
      diagnostics.lifecycle_state ||
      inbox.lifecycle_state,
    last_error:
      channelState.last_error ?? diagnostics.last_error ?? inbox.last_error,
    last_synced_at:
      channelState.last_synced_at ||
      diagnostics.last_synced_at ||
      inbox.last_synced_at,
    runtime_state: runtimeState,
  };
};

const normalizeWeixinDiagnosticsPayload = payload => {
  if (typeof payload === 'object' && payload !== null) {
    return {
      inboxId: payload.inboxId,
      force: payload.force === true,
    };
  }

  return {
    inboxId: payload,
    force: false,
  };
};

const clearWeixinDiagnosticsCache = inboxId => {
  weixinDiagnosticsCache.delete(String(inboxId));
};

const getCachedWeixinDiagnostics = inboxId => {
  const cachedDiagnostics = weixinDiagnosticsCache.get(String(inboxId));

  if (!cachedDiagnostics) {
    return null;
  }

  if (
    Date.now() - cachedDiagnostics.fetchedAt >
    WEIXIN_DIAGNOSTICS_COOLDOWN_MS
  ) {
    clearWeixinDiagnosticsCache(inboxId);
    return null;
  }

  return cachedDiagnostics.data;
};

const cacheWeixinDiagnostics = (inboxId, diagnostics) => {
  weixinDiagnosticsCache.set(String(inboxId), {
    data: diagnostics,
    fetchedAt: Date.now(),
  });
};

const commitWeixinDiagnostics = (
  commit,
  inboxGetters,
  inboxId,
  diagnostics
) => {
  const currentInbox = inboxGetters?.getInbox
    ? inboxGetters.getInbox(inboxId)
    : null;
  const mergedInbox = mergeWeixinDiagnostics(currentInbox, diagnostics);

  if (mergedInbox) {
    commit(types.default.EDIT_INBOXES, mergedInbox);
  }
};

const removeInboxFromClientState = (commit, inboxId) => {
  clearTelegramPersonalDiagnosticsCache(inboxId);
  clearWeixinDiagnosticsCache(inboxId);
  telegramPersonalDiagnosticsRequests.delete(String(inboxId));
  weixinDiagnosticsRequests.delete(String(inboxId));
  commit(types.default.DELETE_INBOXES, inboxId);
};

const commitTelegramPersonalDiagnostics = (
  commit,
  inboxGetters,
  inboxId,
  diagnostics
) => {
  const currentInbox = inboxGetters?.getInbox
    ? inboxGetters.getInbox(inboxId)
    : null;
  const mergedInbox = mergeTelegramPersonalDiagnostics(
    currentInbox,
    diagnostics
  );

  if (mergedInbox) {
    commit(types.default.EDIT_INBOXES, mergedInbox);
  }
};

const mergeWhatsappWebInboxPayload = (
  existingInbox,
  nextInbox,
  includeQrCode = false
) => {
  if (!existingInbox) {
    return nextInbox;
  }

  const existingAdditionalAttributes =
    existingInbox.additional_attributes || {};
  const nextAdditionalAttributes = nextInbox.additional_attributes || {};
  const existingEvolution = existingAdditionalAttributes.evolution || {};
  const nextEvolution = nextAdditionalAttributes.evolution || {};
  const hasNextEvolutionQrCode = Object.prototype.hasOwnProperty.call(
    nextEvolution,
    'qrcode'
  );
  const mergedEvolution = {
    ...existingEvolution,
    ...nextEvolution,
  };

  // If explicit qr artifact request is on, remove stale QR when provider does not
  // return it in the status-only response.
  if (includeQrCode && !hasNextEvolutionQrCode) {
    mergedEvolution.qrcode = {};
  }

  return {
    ...existingInbox,
    ...nextInbox,
    additional_attributes: {
      ...existingAdditionalAttributes,
      ...nextAdditionalAttributes,
      evolution: {
        ...mergedEvolution,
      },
    },
  };
};

const visibleInboxRecords = records =>
  records.filter(inbox => !isInboxPendingDeletion(inbox));

export const getters = {
  getInboxes($state) {
    return visibleInboxRecords($state.records);
  },
  getAllInboxes($state) {
    return camelcaseKeys(visibleInboxRecords($state.records), { deep: true });
  },
  getWhatsAppTemplates: $state => inboxId => {
    const [inbox] = $state.records.filter(
      record => record.id === Number(inboxId)
    );

    const {
      message_templates: whatsAppMessageTemplates,
      additional_attributes: additionalAttributes,
    } = inbox || {};

    const { message_templates: apiInboxMessageTemplates } =
      additionalAttributes || {};
    const messagesTemplates =
      whatsAppMessageTemplates || apiInboxMessageTemplates;

    return messagesTemplates;
  },
  getFilteredWhatsAppTemplates: $state => inboxId => {
    const [inbox] = $state.records.filter(
      record => record.id === Number(inboxId)
    );

    const {
      message_templates: whatsAppMessageTemplates,
      additional_attributes: additionalAttributes,
    } = inbox || {};

    const { message_templates: apiInboxMessageTemplates } =
      additionalAttributes || {};
    const templates = whatsAppMessageTemplates || apiInboxMessageTemplates;

    if (!templates || !Array.isArray(templates)) {
      return [];
    }

    return templates.filter(template => {
      // Ensure template has required properties
      if (
        !template ||
        !template.name ||
        !template.status ||
        !Array.isArray(template.components)
      ) {
        return false;
      }

      // Only show approved templates
      if (template.status.toLowerCase() !== 'approved') {
        return false;
      }

      // Filter out authentication templates
      if (String(template.category).toUpperCase() === 'AUTHENTICATION') {
        return false;
      }

      // Only show templates we can preview and populate reliably
      const hasBodyComponent = template.components.some(
        component =>
          String(component.type).toUpperCase() === COMPONENT_TYPES.BODY
      );
      if (!hasBodyComponent) {
        return false;
      }

      // Filter out CSAT templates (customer_satisfaction_survey and its versions)
      if (
        template.name &&
        template.name.startsWith('customer_satisfaction_survey')
      ) {
        return false;
      }

      // Filter out templates with interactive/header formats we do not support end-to-end yet.
      const hasUnsupportedComponents = template.components.some(
        component =>
          UNSUPPORTED_TEMPLATE_COMPONENT_TYPES.includes(
            String(component.type).toUpperCase()
          ) ||
          (String(component.type).toUpperCase() === COMPONENT_TYPES.HEADER &&
            UNSUPPORTED_TEMPLATE_HEADER_FORMATS.includes(
              String(component.format).toUpperCase()
            ))
      );

      if (hasUnsupportedComponents) {
        return false;
      }

      return true;
    });
  },
  getNewConversationInboxes($state) {
    return visibleInboxRecords($state.records).filter(inbox => {
      const { channel_type: channelType, phone_number: phoneNumber = '' } =
        inbox;

      const isEmailChannel = channelType === INBOX_TYPES.EMAIL;
      const isSmsChannel =
        channelType === INBOX_TYPES.TWILIO &&
        phoneNumber.startsWith('whatsapp');
      return isEmailChannel || isSmsChannel;
    });
  },
  getInbox: $state => inboxId => {
    const [inbox] = $state.records.filter(
      record => record.id === Number(inboxId)
    );
    return inbox || {};
  },
  getInboxById: $state => inboxId => {
    const [inbox] = $state.records.filter(
      record => record.id === Number(inboxId)
    );
    return camelcaseKeys(inbox || {}, { deep: true });
  },
  getUIFlags($state) {
    return $state.uiFlags;
  },
  getWebsiteInboxes($state) {
    return visibleInboxRecords($state.records).filter(
      item => item.channel_type === INBOX_TYPES.WEB
    );
  },
  getTwilioInboxes($state) {
    return visibleInboxRecords($state.records).filter(
      item => item.channel_type === INBOX_TYPES.TWILIO
    );
  },
  getSMSInboxes($state) {
    return visibleInboxRecords($state.records).filter(
      item =>
        item.channel_type === INBOX_TYPES.SMS ||
        (item.channel_type === INBOX_TYPES.TWILIO && item.medium === 'sms')
    );
  },
  getWhatsAppInboxes($state) {
    return visibleInboxRecords($state.records).filter(
      item => item.channel_type === INBOX_TYPES.WHATSAPP
    );
  },
  getOutboundCampaignInboxes($state) {
    const legacyOutboundTypes = [
      INBOX_TYPES.SMS,
      INBOX_TYPES.TWILIO,
      INBOX_TYPES.WHATSAPP,
      INBOX_TYPES.EMAIL,
      INBOX_TYPES.WHATSAPP_WEB,
      INBOX_TYPES.TELEGRAM,
      INBOX_TYPES.TELEGRAM_PERSONAL,
      INBOX_TYPES.VK,
      INBOX_TYPES.LINE,
      INBOX_TYPES.FB,
      INBOX_TYPES.INSTAGRAM,
      INBOX_TYPES.TIKTOK,
      INBOX_TYPES.TWITTER,
    ];

    return visibleInboxRecords($state.records).filter(item => {
      const capabilities = item.campaign_capabilities;

      if (!capabilities) {
        return legacyOutboundTypes.includes(item.channel_type);
      }

      return (
        capabilities.supports_outbound_campaigns &&
        capabilities.implemented_in_current_campaigns &&
        capabilities.delivery_readiness === 'ready'
      );
    });
  },
  dialogFlowEnabledInboxes($state) {
    return visibleInboxRecords($state.records).filter(
      item => item.channel_type !== INBOX_TYPES.EMAIL
    );
  },
  getFacebookInboxByInstagramId: $state => instagramId => {
    return $state.records.find(
      item =>
        item.instagram_id === instagramId &&
        item.channel_type === INBOX_TYPES.FB
    );
  },
  getInstagramInboxByInstagramId: $state => instagramId => {
    return $state.records.find(
      item =>
        item.instagram_id === instagramId &&
        item.channel_type === INBOX_TYPES.INSTAGRAM
    );
  },
  getTiktokInboxByBusinessId: $state => businessId => {
    return $state.records.find(
      item =>
        item.business_id === businessId &&
        item.channel_type === INBOX_TYPES.TIKTOK
    );
  },
};

const sendAnalyticsEvent = channelType => {
  AnalyticsHelper.track(ACCOUNT_EVENTS.ADDED_AN_INBOX, {
    channelType,
  });
};

export const actions = {
  revalidate: async ({ commit }, { newKey }) => {
    try {
      const isExistingKeyValid = await InboxesAPI.validateCacheKey(newKey);
      if (!isExistingKeyValid) {
        const response = await InboxesAPI.refetchAndCommit(newKey);
        commit(types.default.SET_INBOXES, response.data.payload);
      }
    } catch (error) {
      // Ignore error
    }
  },
  get: async ({ commit }) => {
    commit(types.default.SET_INBOXES_UI_FLAG, { isFetching: true });
    try {
      const response = await InboxesAPI.get(true);
      commit(types.default.SET_INBOXES_UI_FLAG, { isFetching: false });
      commit(types.default.SET_INBOXES, response.data.payload);
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isFetching: false });
    }
  },
  createChannel: async ({ commit }, params) => {
    try {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: true });
      const response = await WebChannel.create(params);
      commit(types.default.ADD_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      const { channel = {} } = params;
      sendAnalyticsEvent(channel.type);
      return response.data;
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      return throwErrorMessage(error);
    }
  },
  createWebsiteChannel: async ({ commit }, params) => {
    try {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: true });
      const response = await WebChannel.create(buildInboxData(params));
      commit(types.default.ADD_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      sendAnalyticsEvent('website');
      return response.data;
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      return throwErrorMessage(error);
    }
  },
  createTwilioChannel: async ({ commit }, params) => {
    try {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: true });
      const response = await TwilioChannel.create(params);
      commit(types.default.ADD_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      sendAnalyticsEvent('twilio');
      return response.data;
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      throw error;
    }
  },
  createFBChannel: async ({ commit }, params) => {
    try {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: true });
      const response = await FBChannel.create(params);
      commit(types.default.ADD_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      sendAnalyticsEvent('facebook');
      return response.data;
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      throw new Error(error);
    }
  },
  createWhatsAppEmbeddedSignup: async ({ commit }, params) => {
    try {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: true });
      const response = await WhatsappChannel.createEmbeddedSignup(params);
      commit(types.default.ADD_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      sendAnalyticsEvent('whatsapp');
      return response.data;
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isCreating: false });
      throw error;
    }
  },
  reauthorizeWhatsApp: async ({ commit, getters: inboxGetters }, params) => {
    const response = await WhatsappChannel.reauthorizeWhatsApp(params);
    const currentInbox = inboxGetters?.getInbox
      ? inboxGetters.getInbox(params.inboxId)
      : null;
    const responseProviderConfig = response.data?.provider_config;
    const currentProviderConfig = currentInbox?.provider_config;
    const providerConfig =
      responseProviderConfig || currentProviderConfig
        ? {
            ...(currentProviderConfig || {}),
            ...(responseProviderConfig || {}),
          }
        : currentProviderConfig;
    if (providerConfig) {
      delete providerConfig.authorization_status;
      delete providerConfig.authorization_error;
    }
    const updatedInbox = {
      ...currentInbox,
      ...response.data,
      reauthorization_required: false,
      provider_config: currentProviderConfig
        ? providerConfig
        : currentProviderConfig,
    };

    commit(types.default.EDIT_INBOXES, updatedInbox);
    return updatedInbox;
  },
  ...channelActions,
  // TODO: Extract other create channel methods to separate files to reduce file size
  // - createChannel
  // - createWebsiteChannel
  // - createTwilioChannel
  // - createFBChannel
  updateInbox: async ({ commit }, { id, formData = true, ...inboxParams }) => {
    commit(types.default.SET_INBOXES_UI_FLAG, { isUpdating: true });
    try {
      const response = await InboxesAPI.update(
        id,
        formData ? buildInboxData(inboxParams) : inboxParams
      );
      commit(types.default.EDIT_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isUpdating: false });
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isUpdating: false });
      throwErrorMessage(error);
    }
  },
  updateInboxIMAP: async ({ commit }, { id, ...inboxParams }) => {
    commit(types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: true });
    try {
      const response = await InboxesAPI.update(id, inboxParams);
      commit(types.default.EDIT_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: false });
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isUpdatingIMAP: false });
      throwErrorMessage(error);
    }
  },
  updateInboxSMTP: async ({ commit }, { id, ...inboxParams }) => {
    commit(types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: true });
    try {
      const response = await InboxesAPI.update(id, inboxParams);
      commit(types.default.EDIT_INBOXES, response.data);
      commit(types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: false });
    } catch (error) {
      commit(types.default.SET_INBOXES_UI_FLAG, { isUpdatingSMTP: false });
      throwErrorMessage(error);
    }
  },
  delete: async ({ commit }, inboxId) => {
    commit(types.default.SET_INBOXES_UI_FLAG, { isDeleting: true });
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      await InboxesAPI.delete(inboxId);
      removeInboxFromClientState(commit, inboxId);
      return null;
    } catch (error) {
      if ([404, 410].includes(error?.response?.status)) {
        removeInboxFromClientState(commit, inboxId);
        return null;
      }

      throw new Error(error);
    } finally {
      commit(types.default.SET_INBOXES_UI_FLAG, { isDeleting: false });
    }
  },
  reauthorizeFacebookPage: async ({ commit }, params) => {
    try {
      const response = await FBChannel.reauthorizeFacebookPage(params);
      commit(types.default.EDIT_INBOXES, response.data);
    } catch (error) {
      throw new Error(error.message);
    }
  },
  deleteInboxAvatar: async (_, inboxId) => {
    try {
      await InboxesAPI.deleteInboxAvatar(inboxId);
    } catch (error) {
      throw new Error(error);
    }
  },
  syncTemplates: async ({ commit }, inboxId) => {
    try {
      const response = await InboxesAPI.syncTemplates(inboxId);
      if (response.data?.id) {
        commit(types.default.EDIT_INBOXES, response.data);
      }
      return response.data;
    } catch (error) {
      throw new Error(error);
    }
  },
  refreshWhatsappWebQr: async ({ commit, getters: inboxGetters }, payload) => {
    const inboxId = typeof payload === 'object' ? payload.inboxId : payload;
    const isStatusOnly =
      typeof payload === 'object' && payload?.statusOnly === true;
    const includeQrCode =
      typeof payload === 'object' && payload?.includeQrCode === true;
    const artifactType =
      typeof payload === 'object' && payload?.artifactType
        ? payload.artifactType
        : null;
    const requestPayload =
      typeof payload === 'object' && payload !== null
        ? {
            status_only: isStatusOnly,
            include_qr_code: includeQrCode,
            ...(artifactType && !isStatusOnly
              ? { artifact_type: artifactType }
              : {}),
          }
        : {};
    const requestKey = isStatusOnly
      ? `${inboxId}:status:${includeQrCode ? 'with_qr' : 'state_only'}`
      : `${inboxId}:refresh:${artifactType || 'qr'}`;
    const currentInbox = inboxGetters?.getInbox
      ? inboxGetters.getInbox(inboxId)
      : null;

    if (isInboxPendingDeletion(currentInbox)) {
      return currentInbox;
    }

    if (whatsappWebRefreshRequests.has(requestKey)) {
      return whatsappWebRefreshRequests.get(requestKey);
    }

    const request = InboxesAPI.refreshWhatsappWebQr(inboxId, requestPayload)
      .then(response => {
        const existingInbox = state.records.find(
          record => record.id === response.data.id
        );
        const inboxPayload = isStatusOnly
          ? mergeWhatsappWebInboxPayload(
              existingInbox,
              response.data,
              includeQrCode
            )
          : response.data;

        commit(types.default.EDIT_INBOXES, inboxPayload);
        return inboxPayload;
      })
      .catch(error => {
        if ([404, 410].includes(error?.response?.status)) {
          commit(types.default.DELETE_INBOXES, inboxId);
          return null;
        }

        throw new Error(error?.response?.data?.error || error.message);
      })
      .finally(() => {
        whatsappWebRefreshRequests.delete(requestKey);
      });

    whatsappWebRefreshRequests.set(requestKey, request);
    return request;
  },
  reconnectWhatsappWeb: async ({ commit }, inboxId) => {
    try {
      const response = await InboxesAPI.reconnectWhatsappWeb(inboxId);
      const reconnectedInbox = response.data;

      commit(types.default.EDIT_INBOXES, reconnectedInbox);
      return reconnectedInbox;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  disconnectWhatsappWeb: async ({ commit }, inboxId) => {
    try {
      const response = await InboxesAPI.disconnectWhatsappWeb(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  repairWhatsappWeb: async ({ commit }, inboxId) => {
    try {
      const response = await InboxesAPI.repairWhatsappWeb(inboxId);
      const repairedInbox = response.data;

      commit(types.default.EDIT_INBOXES, repairedInbox);
      return repairedInbox;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  getWhatsappWebDiagnostics: async (_, inboxId) => {
    try {
      const response = await InboxesAPI.getWhatsappWebDiagnostics(inboxId);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  requestTelegramPersonalCode: async ({ commit }, inboxId) => {
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.requestTelegramPersonalCode(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  requestTelegramPersonalQr: async ({ commit }, inboxId) => {
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.requestTelegramPersonalQr(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  verifyTelegramPersonalCode: async ({ commit }, { inboxId, code }) => {
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.verifyTelegramPersonalCode(
        inboxId,
        code
      );
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  verifyTelegramPersonalPassword: async ({ commit }, { inboxId, password }) => {
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.verifyTelegramPersonalPassword(
        inboxId,
        password
      );
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  reconnectTelegramPersonal: async ({ commit }, inboxId) => {
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.reconnectTelegramPersonal(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  historySyncTelegramPersonal: async ({ commit }, payload) => {
    try {
      const inboxId = typeof payload === 'object' ? payload.inboxId : payload;
      const requestPayload =
        typeof payload === 'object' ? payload.payload || {} : {};
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.historySyncTelegramPersonal(
        inboxId,
        requestPayload
      );
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  contactsSyncTelegramPersonal: async ({ commit }, payload) => {
    try {
      const inboxId = typeof payload === 'object' ? payload.inboxId : payload;
      const requestPayload =
        typeof payload === 'object' ? payload.payload || {} : {};
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.contactsSyncTelegramPersonal(
        inboxId,
        requestPayload
      );
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  disconnectTelegramPersonal: async ({ commit }, inboxId) => {
    try {
      clearTelegramPersonalDiagnosticsCache(inboxId);
      const response = await InboxesAPI.disconnectTelegramPersonal(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  getTelegramPersonalDiagnostics: async (
    { commit, getters: inboxGetters },
    payload
  ) => {
    const { inboxId, force } =
      normalizeTelegramPersonalDiagnosticsPayload(payload);

    if (!inboxId) {
      return null;
    }

    const requestKey = String(inboxId);

    if (!force) {
      const cachedDiagnostics = getCachedTelegramPersonalDiagnostics(inboxId);

      if (cachedDiagnostics) {
        commitTelegramPersonalDiagnostics(
          commit,
          inboxGetters,
          inboxId,
          cachedDiagnostics
        );
        return cachedDiagnostics;
      }

      if (telegramPersonalDiagnosticsRequests.has(requestKey)) {
        return telegramPersonalDiagnosticsRequests.get(requestKey);
      }
    }

    const request = InboxesAPI.getTelegramPersonalDiagnostics(inboxId)
      .then(response => {
        cacheTelegramPersonalDiagnostics(inboxId, response.data);
        commitTelegramPersonalDiagnostics(
          commit,
          inboxGetters,
          inboxId,
          response.data
        );
        return response.data;
      })
      .catch(error => {
        if ([404, 410].includes(error?.response?.status)) {
          removeInboxFromClientState(commit, inboxId);
          return null;
        }

        throw new Error(error?.response?.data?.error || error.message);
      })
      .finally(() => {
        telegramPersonalDiagnosticsRequests.delete(requestKey);
      });

    telegramPersonalDiagnosticsRequests.set(requestKey, request);
    return request;
  },
  requestWeixinQr: async ({ commit }, inboxId) => {
    try {
      clearWeixinDiagnosticsCache(inboxId);
      const response = await InboxesAPI.requestWeixinQr(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  reconnectWeixin: async ({ commit }, inboxId) => {
    try {
      clearWeixinDiagnosticsCache(inboxId);
      const response = await InboxesAPI.reconnectWeixin(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  disconnectWeixin: async ({ commit }, inboxId) => {
    try {
      clearWeixinDiagnosticsCache(inboxId);
      const response = await InboxesAPI.disconnectWeixin(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  getWeixinDiagnostics: async ({ commit, getters: inboxGetters }, payload) => {
    const { inboxId, force } = normalizeWeixinDiagnosticsPayload(payload);

    if (!inboxId) {
      return null;
    }

    const requestKey = String(inboxId);

    if (!force) {
      const cachedDiagnostics = getCachedWeixinDiagnostics(inboxId);

      if (cachedDiagnostics) {
        commitWeixinDiagnostics(
          commit,
          inboxGetters,
          inboxId,
          cachedDiagnostics
        );
        return cachedDiagnostics;
      }

      if (weixinDiagnosticsRequests.has(requestKey)) {
        return weixinDiagnosticsRequests.get(requestKey);
      }
    }

    const request = InboxesAPI.getWeixinDiagnostics(inboxId)
      .then(response => {
        cacheWeixinDiagnostics(inboxId, response.data);
        commitWeixinDiagnostics(commit, inboxGetters, inboxId, response.data);
        return response.data;
      })
      .catch(error => {
        if ([404, 410].includes(error?.response?.status)) {
          removeInboxFromClientState(commit, inboxId);
          return null;
        }

        throw new Error(error?.response?.data?.error || error.message);
      })
      .finally(() => {
        weixinDiagnosticsRequests.delete(requestKey);
      });

    weixinDiagnosticsRequests.set(requestKey, request);
    return request;
  },
  createCSATTemplate: async (_, { inboxId, template }) => {
    const response = await InboxesAPI.createCSATTemplate(inboxId, template);
    return response.data;
  },
  createWhatsAppTemplate: async ({ commit }, { inboxId, template }) => {
    try {
      const response = await InboxesAPI.createWhatsAppTemplate(
        inboxId,
        template
      );
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  deleteWhatsAppTemplate: async ({ commit }, { inboxId, templateName }) => {
    try {
      const response = await InboxesAPI.deleteWhatsAppTemplate(
        inboxId,
        templateName
      );
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  getCSATTemplateStatus: async (_, { inboxId }) => {
    const response = await InboxesAPI.getCSATTemplateStatus(inboxId);
    return response.data;
  },
  analyzeCSATTemplateUtility: async (_, { inboxId, template }) => {
    const response = await InboxesAPI.analyzeCSATTemplateUtility(
      inboxId,
      template
    );
    return response.data;
  },
  resetSecret: async ({ commit }, inboxId) => {
    try {
      const response = await InboxesAPI.resetSecret(inboxId);
      commit(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throwErrorMessage(error);
      return null;
    }
  },
};

export const mutations = {
  [types.default.SET_INBOXES_UI_FLAG]($state, uiFlag) {
    $state.uiFlags = { ...$state.uiFlags, ...uiFlag };
  },
  [types.default.SET_INBOXES]: MutationHelpers.set,
  [types.default.SET_INBOXES_ITEM]: MutationHelpers.setSingleRecord,
  [types.default.ADD_INBOXES]: MutationHelpers.create,
  [types.default.EDIT_INBOXES]: MutationHelpers.update,
  [types.default.DELETE_INBOXES]: MutationHelpers.destroy,
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
