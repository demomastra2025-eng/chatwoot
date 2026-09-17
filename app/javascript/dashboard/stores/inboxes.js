import { defineStore } from 'pinia';
import { computed, unref } from 'vue';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import InboxesAPI from 'dashboard/api/inboxes';
import WebChannel from 'dashboard/api/channel/webChannel';
import FBChannel from 'dashboard/api/channel/fbChannel';
import TwilioChannel from 'dashboard/api/channel/twilioChannel';
import WhatsappChannel from 'dashboard/api/channel/whatsappChannel';
import { throwErrorMessage } from 'dashboard/store/utils/api';
import AnalyticsHelper from 'dashboard/helper/AnalyticsHelper';
import camelcaseKeys from 'camelcase-keys';
import { ACCOUNT_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';
import { storeOneTimeWebhookVerifyToken } from 'shared/helpers/whatsappCloudCredentials';
import {
  COMPONENT_TYPES,
  UNSUPPORTED_TEMPLATE_COMPONENT_TYPES,
  UNSUPPORTED_TEMPLATE_HEADER_FORMATS,
} from 'dashboard/helper/templateHelper';

const mutationTypes = {
  SET_INBOXES_UI_FLAG: 'SET_INBOXES_UI_FLAG',
  SET_INBOXES: 'SET_INBOXES',
  SET_INBOXES_ITEM: 'SET_INBOXES_ITEM',
  ADD_INBOXES: 'ADD_INBOXES',
  EDIT_INBOXES: 'EDIT_INBOXES',
  DELETE_INBOXES: 'DELETE_INBOXES',
};

const types = { default: mutationTypes };

const buildInboxData = inboxParams => {
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

const initialState = () => ({
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
});

const whatsappWebLifecycleRequests = new WeakMap();
const getWhatsappWebLifecycleRequests = store => {
  let requests = whatsappWebLifecycleRequests.get(store);
  if (!requests) {
    requests = new Map();
    whatsappWebLifecycleRequests.set(store, requests);
  }
  return requests;
};
const WHATSAPP_WEB_OPERATION_IN_PROGRESS =
  'Another WhatsApp Web operation is already in progress';
const runWhatsappWebLifecycleRequest = (
  store,
  inboxId,
  operation,
  { reuseExisting = false } = {}
) => {
  const requests = getWhatsappWebLifecycleRequests(store);
  const requestKey = String(inboxId);
  const existingRequest = requests.get(requestKey);

  if (existingRequest) {
    return reuseExisting
      ? existingRequest
      : Promise.reject(new Error(WHATSAPP_WEB_OPERATION_IN_PROGRESS));
  }

  const request = operation().finally(() => requests.delete(requestKey));
  requests.set(requestKey, request);
  return request;
};
const telegramPersonalRuntimeScopes = new WeakMap();
const getTelegramPersonalRuntimeScope = store => {
  let scope = telegramPersonalRuntimeScopes.get(store);
  if (!scope) {
    scope = { requests: new Map(), cache: new Map() };
    telegramPersonalRuntimeScopes.set(store, scope);
  }
  return scope;
};
const TELEGRAM_PERSONAL_DIAGNOSTICS_COOLDOWN_MS = 3000;
const weixinRuntimeScopes = new WeakMap();
const getWeixinRuntimeScope = store => {
  let scope = weixinRuntimeScopes.get(store);
  if (!scope) {
    scope = { requests: new Map(), cache: new Map() };
    weixinRuntimeScopes.set(store, scope);
  }
  return scope;
};
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

const clearTelegramPersonalDiagnosticsCache = (store, inboxId) => {
  getTelegramPersonalRuntimeScope(store).cache.delete(String(inboxId));
};

const getCachedTelegramPersonalDiagnostics = (store, inboxId) => {
  const cachedDiagnostics = getTelegramPersonalRuntimeScope(store).cache.get(
    String(inboxId)
  );

  if (!cachedDiagnostics) {
    return null;
  }

  if (
    Date.now() - cachedDiagnostics.fetchedAt >
    TELEGRAM_PERSONAL_DIAGNOSTICS_COOLDOWN_MS
  ) {
    clearTelegramPersonalDiagnosticsCache(store, inboxId);
    return null;
  }

  return cachedDiagnostics.data;
};

const cacheTelegramPersonalDiagnostics = (store, inboxId, diagnostics) => {
  getTelegramPersonalRuntimeScope(store).cache.set(String(inboxId), {
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

const clearWeixinDiagnosticsCache = (store, inboxId) => {
  getWeixinRuntimeScope(store).cache.delete(String(inboxId));
};

const getCachedWeixinDiagnostics = (store, inboxId) => {
  const cachedDiagnostics = getWeixinRuntimeScope(store).cache.get(
    String(inboxId)
  );

  if (!cachedDiagnostics) {
    return null;
  }

  if (
    Date.now() - cachedDiagnostics.fetchedAt >
    WEIXIN_DIAGNOSTICS_COOLDOWN_MS
  ) {
    clearWeixinDiagnosticsCache(store, inboxId);
    return null;
  }

  return cachedDiagnostics.data;
};

const cacheWeixinDiagnostics = (store, inboxId, diagnostics) => {
  getWeixinRuntimeScope(store).cache.set(String(inboxId), {
    data: diagnostics,
    fetchedAt: Date.now(),
  });
};

const commitWeixinDiagnostics = (store, inboxId, diagnostics) => {
  const currentInbox = store.getInbox(inboxId);
  const mergedInbox = mergeWeixinDiagnostics(currentInbox, diagnostics);

  if (mergedInbox) {
    store.applyMutation(types.default.EDIT_INBOXES, mergedInbox);
  }
};

const removeInboxFromClientState = (store, inboxId) => {
  const requestKey = String(inboxId);
  clearTelegramPersonalDiagnosticsCache(store, inboxId);
  clearWeixinDiagnosticsCache(store, inboxId);
  getTelegramPersonalRuntimeScope(store).requests.delete(requestKey);
  getWeixinRuntimeScope(store).requests.delete(requestKey);
  store.applyMutation(types.default.DELETE_INBOXES, inboxId);
};

const commitTelegramPersonalDiagnostics = (store, inboxId, diagnostics) => {
  const currentInbox = store.getInbox(inboxId);
  const mergedInbox = mergeTelegramPersonalDiagnostics(
    currentInbox,
    diagnostics
  );

  if (mergedInbox) {
    store.applyMutation(types.default.EDIT_INBOXES, mergedInbox);
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

const getters = {
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
  getConversationWhatsAppTemplates() {
    return inboxId =>
      this.getFilteredWhatsAppTemplates(inboxId).filter(
        template => template.visible_in_conversation_picker !== false
      );
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

const currentRouteAccountId = () => {
  const accountId = Number(InboxesAPI.accountIdFromRoute);
  return Number.isFinite(accountId) && accountId > 0 ? accountId : null;
};

const isCurrentRouteAccountId = accountId =>
  !accountId || currentRouteAccountId() === accountId;

const withCurrentRouteAccountId = (
  inbox,
  accountId = currentRouteAccountId()
) => {
  if (!accountId || !inbox) return inbox;

  return {
    ...inbox,
    account_id: inbox.account_id ?? accountId,
  };
};

const withCurrentRouteAccountIdList = (
  inboxes,
  accountId = currentRouteAccountId()
) =>
  Array.isArray(inboxes)
    ? inboxes.map(inbox => withCurrentRouteAccountId(inbox, accountId))
    : inboxes;

const actions = {
  async revalidate({ newKey }) {
    const accountId = currentRouteAccountId();
    try {
      const isExistingKeyValid = await InboxesAPI.validateCacheKey(
        newKey,
        accountId
      );
      if (!isExistingKeyValid) {
        const response = await InboxesAPI.refetchAndCommit(newKey, accountId);
        if (!isCurrentRouteAccountId(accountId)) return;

        this.applyMutation(
          types.default.SET_INBOXES,
          withCurrentRouteAccountIdList(response.data.payload, accountId)
        );
      }
    } catch (error) {
      // Ignore error
    }
  },
  async get() {
    const accountId = currentRouteAccountId();
    this.applyMutation(types.default.SET_INBOXES_UI_FLAG, { isFetching: true });
    try {
      const response = await InboxesAPI.get(true);
      if (!isCurrentRouteAccountId(accountId)) return;

      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isFetching: false,
      });
      this.applyMutation(
        types.default.SET_INBOXES,
        withCurrentRouteAccountIdList(response.data.payload, accountId)
      );
    } catch (error) {
      if (!isCurrentRouteAccountId(accountId)) return;

      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isFetching: false,
      });
    }
  },
  async createChannel(params) {
    try {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: true,
      });
      const response = await WebChannel.create(params);
      storeOneTimeWebhookVerifyToken(
        response.data.id,
        params.channel?.provider_config?.webhook_verify_token
      );
      this.applyMutation(types.default.ADD_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      const { channel = {} } = params;
      sendAnalyticsEvent(channel.type);
      return response.data;
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      return throwErrorMessage(error);
    }
  },
  async createWebsiteChannel(params) {
    try {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: true,
      });
      const response = await WebChannel.create(buildInboxData(params));
      this.applyMutation(types.default.ADD_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      sendAnalyticsEvent('website');
      return response.data;
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      return throwErrorMessage(error);
    }
  },
  async createTwilioChannel(params) {
    try {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: true,
      });
      const response = await TwilioChannel.create(params);
      this.applyMutation(types.default.ADD_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      sendAnalyticsEvent('twilio');
      return response.data;
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      throw error;
    }
  },
  async createFBChannel(params) {
    try {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: true,
      });
      const response = await FBChannel.create(params);
      this.applyMutation(types.default.ADD_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      sendAnalyticsEvent('facebook');
      return response.data;
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      throw new Error(error);
    }
  },
  async createWhatsAppEmbeddedSignup(params) {
    try {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: true,
      });
      const response = await WhatsappChannel.createEmbeddedSignup(params);
      this.applyMutation(types.default.ADD_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      sendAnalyticsEvent('whatsapp');
      return response.data;
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      throw error;
    }
  },
  async reauthorizeWhatsApp(params) {
    const response = await WhatsappChannel.reauthorizeWhatsApp(params);
    const currentInbox = this?.getInbox ? this.getInbox(params.inboxId) : null;
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
      provider_config: providerConfig || currentProviderConfig,
    };

    this.applyMutation(types.default.EDIT_INBOXES, updatedInbox);
    return updatedInbox;
  },
  async registerWhatsAppPhoneNumber(params) {
    const response = await WhatsappChannel.registerPhoneNumber(params);
    const currentInbox = this?.getInbox ? this.getInbox(params.inboxId) : null;
    const updatedInbox = {
      ...currentInbox,
      reauthorization_required: response.data.reauthorization_required,
      provider_config: {
        ...(currentInbox?.provider_config || {}),
        ...(response.data.provider_config || {}),
      },
    };
    this.applyMutation(types.default.EDIT_INBOXES, updatedInbox);
    return updatedInbox;
  },
  async createVoiceChannel(params) {
    try {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: true,
      });
      const response = await InboxesAPI.create({
        name: params.name,
        channel: { ...params.voice, type: 'voice' },
      });
      this.applyMutation(types.default.ADD_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      sendAnalyticsEvent('voice');
      return response.data;
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isCreating: false,
      });
      throw error;
    }
  },
  // TODO: Extract other create channel methods to separate files to reduce file size
  // - createChannel
  // - createWebsiteChannel
  // - createTwilioChannel
  // - createFBChannel
  async updateInbox({ id, formData = true, ...inboxParams }) {
    this.applyMutation(types.default.SET_INBOXES_UI_FLAG, { isUpdating: true });
    try {
      const response = await InboxesAPI.update(
        id,
        formData ? buildInboxData(inboxParams) : inboxParams
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isUpdating: false,
      });
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isUpdating: false,
      });
      throwErrorMessage(error);
    }
  },
  async updateInboxIMAP({ id, ...inboxParams }) {
    this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
      isUpdatingIMAP: true,
    });
    try {
      const response = await InboxesAPI.update(id, inboxParams);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isUpdatingIMAP: false,
      });
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isUpdatingIMAP: false,
      });
      throwErrorMessage(error);
    }
  },
  async updateInboxSMTP({ id, ...inboxParams }) {
    this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
      isUpdatingSMTP: true,
    });
    try {
      const response = await InboxesAPI.update(id, inboxParams);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isUpdatingSMTP: false,
      });
    } catch (error) {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isUpdatingSMTP: false,
      });
      throwErrorMessage(error);
    }
  },
  async delete(inboxId) {
    this.applyMutation(types.default.SET_INBOXES_UI_FLAG, { isDeleting: true });
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      await InboxesAPI.delete(inboxId);
      removeInboxFromClientState(this, inboxId);
      return null;
    } catch (error) {
      if ([404, 410].includes(error?.response?.status)) {
        removeInboxFromClientState(this, inboxId);
        return null;
      }

      throw new Error(error);
    } finally {
      this.applyMutation(types.default.SET_INBOXES_UI_FLAG, {
        isDeleting: false,
      });
    }
  },
  async reauthorizeFacebookPage(params) {
    try {
      const response = await FBChannel.reauthorizeFacebookPage(params);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
    } catch (error) {
      throw new Error(error.message);
    }
  },
  async deleteInboxAvatar(inboxId) {
    try {
      await InboxesAPI.deleteInboxAvatar(inboxId);
    } catch (error) {
      throw new Error(error);
    }
  },
  async syncTemplates(inboxId) {
    try {
      const response = await InboxesAPI.syncTemplates(inboxId);
      if (response.data?.id) {
        this.applyMutation(types.default.EDIT_INBOXES, response.data);
      }
      return response.data;
    } catch (error) {
      throw new Error(error);
    }
  },
  async refreshWhatsappWebQr(payload) {
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
    const currentInbox = this?.getInbox ? this.getInbox(inboxId) : null;

    if (isInboxPendingDeletion(currentInbox)) {
      return currentInbox;
    }

    return runWhatsappWebLifecycleRequest(
      this,
      inboxId,
      () =>
        InboxesAPI.refreshWhatsappWebQr(inboxId, requestPayload)
          .then(response => {
            const existingInbox = this.records.find(
              record => record.id === response.data.id
            );
            const inboxPayload = isStatusOnly
              ? mergeWhatsappWebInboxPayload(
                  existingInbox,
                  response.data,
                  includeQrCode
                )
              : response.data;

            this.applyMutation(types.default.EDIT_INBOXES, inboxPayload);
            return inboxPayload;
          })
          .catch(error => {
            if ([404, 410].includes(error?.response?.status)) {
              this.applyMutation(types.default.DELETE_INBOXES, inboxId);
              return null;
            }

            throw new Error(error?.response?.data?.error || error.message);
          }),
      { reuseExisting: isStatusOnly }
    );
  },
  async reconnectWhatsappWeb(inboxId) {
    return runWhatsappWebLifecycleRequest(this, inboxId, async () => {
      try {
        const response = await InboxesAPI.reconnectWhatsappWeb(inboxId);
        const reconnectedInbox = response.data;

        this.applyMutation(types.default.EDIT_INBOXES, reconnectedInbox);
        return reconnectedInbox;
      } catch (error) {
        throw new Error(error?.response?.data?.error || error.message);
      }
    });
  },
  async reauthorizeWhatsappWeb(inboxId) {
    return runWhatsappWebLifecycleRequest(this, inboxId, async () => {
      try {
        const response = await InboxesAPI.reauthorizeWhatsappWeb(inboxId);
        const reauthorizedInbox = response.data;

        this.applyMutation(types.default.EDIT_INBOXES, reauthorizedInbox);
        return reauthorizedInbox;
      } catch (error) {
        throw new Error(error?.response?.data?.error || error.message);
      }
    });
  },
  async disconnectWhatsappWeb(inboxId) {
    return runWhatsappWebLifecycleRequest(this, inboxId, async () => {
      try {
        const response = await InboxesAPI.disconnectWhatsappWeb(inboxId);
        this.applyMutation(types.default.EDIT_INBOXES, response.data);
        return response.data;
      } catch (error) {
        throw new Error(error?.response?.data?.error || error.message);
      }
    });
  },
  async repairWhatsappWeb(inboxId) {
    return runWhatsappWebLifecycleRequest(this, inboxId, async () => {
      try {
        const response = await InboxesAPI.repairWhatsappWeb(inboxId);
        const repairedInbox = response.data;

        this.applyMutation(types.default.EDIT_INBOXES, repairedInbox);
        return repairedInbox;
      } catch (error) {
        throw new Error(error?.response?.data?.error || error.message);
      }
    });
  },
  async getWhatsappWebDiagnostics(inboxId) {
    try {
      const response = await InboxesAPI.getWhatsappWebDiagnostics(inboxId);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async requestTelegramPersonalCode(inboxId) {
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.requestTelegramPersonalCode(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async requestTelegramPersonalQr(inboxId) {
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.requestTelegramPersonalQr(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async verifyTelegramPersonalCode({ inboxId, code }) {
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.verifyTelegramPersonalCode(
        inboxId,
        code
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async verifyTelegramPersonalPassword({ inboxId, password }) {
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.verifyTelegramPersonalPassword(
        inboxId,
        password
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async reconnectTelegramPersonal(inboxId) {
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.reconnectTelegramPersonal(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async historySyncTelegramPersonal(payload) {
    try {
      const inboxId = typeof payload === 'object' ? payload.inboxId : payload;
      const requestPayload =
        typeof payload === 'object' ? payload.payload || {} : {};
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.historySyncTelegramPersonal(
        inboxId,
        requestPayload
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async contactsSyncTelegramPersonal(payload) {
    try {
      const inboxId = typeof payload === 'object' ? payload.inboxId : payload;
      const requestPayload =
        typeof payload === 'object' ? payload.payload || {} : {};
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.contactsSyncTelegramPersonal(
        inboxId,
        requestPayload
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async disconnectTelegramPersonal(inboxId) {
    try {
      clearTelegramPersonalDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.disconnectTelegramPersonal(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async getTelegramPersonalDiagnostics(payload) {
    const { inboxId, force } =
      normalizeTelegramPersonalDiagnosticsPayload(payload);

    if (!inboxId) {
      return null;
    }

    const requestKey = String(inboxId);

    if (!force) {
      const cachedDiagnostics = getCachedTelegramPersonalDiagnostics(
        this,
        inboxId
      );

      if (cachedDiagnostics) {
        commitTelegramPersonalDiagnostics(this, inboxId, cachedDiagnostics);
        return cachedDiagnostics;
      }

      if (getTelegramPersonalRuntimeScope(this).requests.has(requestKey)) {
        return getTelegramPersonalRuntimeScope(this).requests.get(requestKey);
      }
    }

    const request = InboxesAPI.getTelegramPersonalDiagnostics(inboxId)
      .then(response => {
        cacheTelegramPersonalDiagnostics(this, inboxId, response.data);
        commitTelegramPersonalDiagnostics(this, inboxId, response.data);
        return response.data;
      })
      .catch(error => {
        if ([404, 410].includes(error?.response?.status)) {
          removeInboxFromClientState(this, inboxId);
          return null;
        }

        throw new Error(error?.response?.data?.error || error.message);
      })
      .finally(() => {
        getTelegramPersonalRuntimeScope(this).requests.delete(requestKey);
      });

    getTelegramPersonalRuntimeScope(this).requests.set(requestKey, request);
    return request;
  },
  async requestWeixinQr(inboxId) {
    try {
      clearWeixinDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.requestWeixinQr(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async reconnectWeixin(inboxId) {
    try {
      clearWeixinDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.reconnectWeixin(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async disconnectWeixin(inboxId) {
    try {
      clearWeixinDiagnosticsCache(this, inboxId);
      const response = await InboxesAPI.disconnectWeixin(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async getWeixinDiagnostics(payload) {
    const { inboxId, force } = normalizeWeixinDiagnosticsPayload(payload);

    if (!inboxId) {
      return null;
    }

    const requestKey = String(inboxId);

    if (!force) {
      const cachedDiagnostics = getCachedWeixinDiagnostics(this, inboxId);

      if (cachedDiagnostics) {
        commitWeixinDiagnostics(this, inboxId, cachedDiagnostics);
        return cachedDiagnostics;
      }

      if (getWeixinRuntimeScope(this).requests.has(requestKey)) {
        return getWeixinRuntimeScope(this).requests.get(requestKey);
      }
    }

    const request = InboxesAPI.getWeixinDiagnostics(inboxId)
      .then(response => {
        cacheWeixinDiagnostics(this, inboxId, response.data);
        commitWeixinDiagnostics(this, inboxId, response.data);
        return response.data;
      })
      .catch(error => {
        if ([404, 410].includes(error?.response?.status)) {
          removeInboxFromClientState(this, inboxId);
          return null;
        }

        throw new Error(error?.response?.data?.error || error.message);
      })
      .finally(() => {
        getWeixinRuntimeScope(this).requests.delete(requestKey);
      });

    getWeixinRuntimeScope(this).requests.set(requestKey, request);
    return request;
  },
  async createCSATTemplate({ inboxId, template }) {
    const response = await InboxesAPI.createCSATTemplate(inboxId, template);
    return response.data;
  },
  async createWhatsAppTemplate({ inboxId, template }) {
    try {
      const response = await InboxesAPI.createWhatsAppTemplate(
        inboxId,
        template
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async deleteWhatsAppTemplate({ inboxId, templateName }) {
    try {
      const response = await InboxesAPI.deleteWhatsAppTemplate(
        inboxId,
        templateName
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async updateWhatsAppTemplateVisibility({ inboxId, templateName, visible }) {
    try {
      const response = await InboxesAPI.updateWhatsAppTemplateVisibility(
        inboxId,
        templateName,
        visible
      );
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throw new Error(error?.response?.data?.error || error.message);
    }
  },
  async getCSATTemplateStatus({ inboxId }) {
    const response = await InboxesAPI.getCSATTemplateStatus(inboxId);
    return response.data;
  },
  async analyzeCSATTemplateUtility({ inboxId, template }) {
    const response = await InboxesAPI.analyzeCSATTemplateUtility(
      inboxId,
      template
    );
    return response.data;
  },
  async resetSecret(inboxId) {
    try {
      const response = await InboxesAPI.resetSecret(inboxId);
      this.applyMutation(types.default.EDIT_INBOXES, response.data);
      return response.data;
    } catch (error) {
      throwErrorMessage(error);
      return null;
    }
  },
};

export const useInboxStore = defineStore('inboxes', {
  state: initialState,
  getters,
  actions: {
    applyMutation(type, payload) {
      if (type === mutationTypes.SET_INBOXES_UI_FLAG) {
        this.uiFlags = { ...this.uiFlags, ...payload };
      } else if (type === mutationTypes.SET_INBOXES) {
        this.records = payload;
      } else if (type === mutationTypes.SET_INBOXES_ITEM) {
        const index = this.records.findIndex(
          record => record.id === payload.id
        );
        if (index === -1) this.records.push(payload);
        else this.records[index] = payload;
      } else if (type === mutationTypes.ADD_INBOXES) {
        this.records.push(payload);
      } else if (type === mutationTypes.EDIT_INBOXES) {
        const index = this.records.findIndex(
          record => record.id === payload.id
        );
        if (index !== -1) this.records[index] = payload;
      } else if (type === mutationTypes.DELETE_INBOXES) {
        this.records = this.records.filter(record => record.id !== payload);
      }
    },
    ...actions,
  },
});

export const useInboxStoreGetter = (getter, ...args) =>
  computed(() => {
    const value = useInboxStore()[getter];
    return args.length ? value(...args.map(unref)) : value;
  });
