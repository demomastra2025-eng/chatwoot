import {
  ANALYTICS_IDENTITY,
  CHATWOOT_RESET,
  CHATWOOT_SET_USER,
} from '../constants/appEvents';
import { emitter } from 'shared/helpers/mitt';

let analyticsHelperPromise;
let audioNotificationHelperPromise;

const getAnalyticsHelper = () => {
  analyticsHelperPromise ||= import('./AnalyticsHelper').then(
    ({ default: AnalyticsHelper }) => AnalyticsHelper
  );
  return analyticsHelperPromise;
};

const getAudioNotificationHelper = () => {
  audioNotificationHelperPromise ||= import(
    './AudioAlerts/DashboardAudioNotificationHelper'
  ).then(
    ({ default: DashboardAudioNotificationHelper }) =>
      DashboardAudioNotificationHelper
  );
  return audioNotificationHelperPromise;
};

const runAnalytics = callback => {
  getAnalyticsHelper()
    .then(callback)
    .catch(() => {});
};

export const initializeAnalyticsEvents = () => {
  runAnalytics(AnalyticsHelper => AnalyticsHelper.init());
  emitter.on(ANALYTICS_IDENTITY, ({ user }) => {
    runAnalytics(AnalyticsHelper => AnalyticsHelper.identify(user));
  });
};

export const initializeAudioAlerts = user => {
  const { ui_settings: uiSettings } = user || {};
  const {
    always_play_audio_alert: alwaysPlayAudioAlert,
    enable_audio_alerts: audioAlertType,
    alert_if_unread_assigned_conversation_exist: alertIfUnreadConversationExist,
    notification_tone: audioAlertTone,
    // UI Settings can be undefined initially as we don't send the
    // entire payload for the user during the signup process.
  } = uiSettings || {};

  getAudioNotificationHelper()
    .then(DashboardAudioNotificationHelper => {
      DashboardAudioNotificationHelper.set({
        currentUser: user,
        audioAlertType: audioAlertType || 'none',
        audioAlertTone: audioAlertTone || 'ding',
        alwaysPlayAudioAlert: alwaysPlayAudioAlert || false,
        alertIfUnreadConversationExist: alertIfUnreadConversationExist || false,
      });
    })
    .catch(() => {});
};

export const initializeChatwootEvents = () => {
  emitter.on(CHATWOOT_RESET, () => {
    if (window.$chatwoot) {
      window.$chatwoot.reset();
    }
  });
  emitter.on(CHATWOOT_SET_USER, ({ user }) => {
    if (window.$chatwoot) {
      window.$chatwoot.setUser(user.email, {
        avatar_url: user.avatar_url,
        email: user.email,
        identifier_hash: user.hmac_identifier,
        name: user.name,
      });
      window.$chatwoot.setCustomAttributes({
        signedUpAt: user.created_at,
        cloudCustomer: 'true',
        account_id: user.account_id,
      });
    }

    initializeAudioAlerts(user);
  });
};
