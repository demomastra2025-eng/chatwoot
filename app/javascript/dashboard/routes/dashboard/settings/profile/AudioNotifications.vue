<script setup>
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';
import AudioAlertTone from './AudioAlertTone.vue';
import AudioAlertEvent from './AudioAlertEvent.vue';
import AudioAlertCondition from './AudioAlertCondition.vue';
import { computed, onMounted, ref, watch } from 'vue';
import { useStore } from 'dashboard/composables/store';
const store = useStore();
import { useI18n } from 'vue-i18n';
import camelcaseKeys from 'camelcase-keys';
import { initializeAudioAlerts } from 'dashboard/helper/scriptHelpers';
import { useStoreGetters } from 'dashboard/composables/store';
import {
  DEFAULT_INCOMING_CALL_RINGTONE,
  INCOMING_CALL_RINGTONES,
  resolveIncomingCallRingtone,
} from 'dashboard/helper/AudioAlerts/ringtone';
import {
  DEFAULT_AUDIO_ALERT_TYPE,
  DEFAULT_NOTIFICATION_TONE,
  NOTIFICATION_TONES,
  resolveAudioAlertType,
  resolveNotificationTone,
} from 'dashboard/helper/AudioAlerts/notificationSound';

const getters = useStoreGetters();
const currentUser = computed(() => getters.getCurrentUser.value);

const { uiSettings, updateUISettings } = useUISettings();

const { t } = useI18n();
const audioAlert = ref(DEFAULT_AUDIO_ALERT_TYPE);
const playAudioWhenTabIsInactive = ref(false);
const alertIfUnreadConversationExist = ref(false);
const incomingCallRingtone = ref(DEFAULT_INCOMING_CALL_RINGTONE);
const alertTone = ref(DEFAULT_NOTIFICATION_TONE);
const audioAlertConditions = ref([]);
const i18nKeyPrefix = 'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION';
const alertToneOptions = computed(() => [
  {
    value: NOTIFICATION_TONES[0],
    label: t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES.DING'),
  },
  {
    value: NOTIFICATION_TONES[1],
    label: t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES.PING'),
  },
  {
    value: NOTIFICATION_TONES[2],
    label: t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES.DUET'),
  },
  {
    value: NOTIFICATION_TONES[3],
    label: t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES.BIPBOP'),
  },
  {
    value: NOTIFICATION_TONES[4],
    label: t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES.SIGNAL'),
  },
  {
    value: NOTIFICATION_TONES[5],
    label: t(
      'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES.SOFTBELL'
    ),
  },
]);
const incomingCallRingtoneOptions = computed(() => [
  {
    value: INCOMING_CALL_RINGTONES[0],
    label: t(
      'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.RINGTONE.OPTIONS.MYSTERIOUS_02'
    ),
  },
  {
    value: INCOMING_CALL_RINGTONES[1],
    label: t(
      'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.RINGTONE.OPTIONS.RINGTONE_028'
    ),
  },
  {
    value: INCOMING_CALL_RINGTONES[2],
    label: t(
      'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.RINGTONE.OPTIONS.RINGTONE_066'
    ),
  },
  {
    value: INCOMING_CALL_RINGTONES[3],
    label: t(
      'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.RINGTONE.OPTIONS.RINGTONE_091'
    ),
  },
]);

const initializeNotificationUISettings = newUISettings => {
  const updatedUISettings = camelcaseKeys(newUISettings);

  audioAlert.value = resolveAudioAlertType(updatedUISettings.enableAudioAlerts);
  playAudioWhenTabIsInactive.value = !updatedUISettings.alwaysPlayAudioAlert;
  alertIfUnreadConversationExist.value =
    updatedUISettings.alertIfUnreadAssignedConversationExist;
  audioAlertConditions.value = [
    {
      id: 'audio1',
      label: t(`${i18nKeyPrefix}.CONDITIONS.CONDITION_ONE`),
      model: playAudioWhenTabIsInactive.value,
      value: 'tab_is_inactive',
    },
    {
      id: 'audio2',
      label: t(`${i18nKeyPrefix}.CONDITIONS.CONDITION_TWO`),
      model: alertIfUnreadConversationExist.value,
      value: 'conversations_are_read',
    },
  ];
  incomingCallRingtone.value = resolveIncomingCallRingtone(
    updatedUISettings.incomingCallRingtone
  );
  alertTone.value = resolveNotificationTone(updatedUISettings.notificationTone);
};

watch(
  uiSettings,
  value => {
    initializeNotificationUISettings(value);
  },
  { immediate: true }
);

const handleAudioConfigChange = value => {
  updateUISettings(value);
  initializeAudioAlerts(currentUser.value);
  useAlert(t('PROFILE_SETTINGS.FORM.API.UPDATE_SUCCESS'));
};

onMounted(() => {
  store.dispatch('userNotificationSettings/get');
});

const handAudioAlertChange = value => {
  audioAlert.value = value;
  handleAudioConfigChange({
    enable_audio_alerts: value,
  });
};
const handleAudioAlertConditions = (id, value) => {
  if (id === 'tab_is_inactive') {
    handleAudioConfigChange({
      always_play_audio_alert: !value,
    });
  } else if (id === 'conversations_are_read') {
    handleAudioConfigChange({
      alert_if_unread_assigned_conversation_exist: value,
    });
  }
};
const handleAudioToneChange = value => {
  handleAudioConfigChange({
    notification_tone: resolveNotificationTone(value),
  });
};
const handleIncomingCallRingtoneChange = value => {
  handleAudioConfigChange({
    incoming_call_ringtone: resolveIncomingCallRingtone(value),
  });
};
</script>

<template>
  <div id="profile-settings-notifications" class="flex flex-col gap-6">
    <AudioAlertTone
      :value="incomingCallRingtone"
      name="incomingCallRingtone"
      audio-path="/audio/ringtone"
      :tones="incomingCallRingtoneOptions"
      :label="
        $t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.RINGTONE.TITLE')
      "
      @change="handleIncomingCallRingtoneChange"
    />

    <AudioAlertTone
      :value="alertTone"
      name="alertTone"
      audio-path="/audio/dashboard"
      :tones="alertToneOptions"
      :label="$t(`${i18nKeyPrefix}.DEFAULT_TONE.TITLE`)"
      @change="handleAudioToneChange"
    />

    <AudioAlertEvent
      :label="$t(`${i18nKeyPrefix}.ALERT_TYPE.TITLE`)"
      :value="audioAlert"
      @update="handAudioAlertChange"
    />

    <AudioAlertCondition
      :items="audioAlertConditions"
      :label="$t(`${i18nKeyPrefix}.CONDITIONS.TITLE`)"
      @change="handleAudioAlertConditions"
    />
  </div>
</template>
