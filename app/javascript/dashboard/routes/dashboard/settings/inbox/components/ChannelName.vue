<script setup>
import { useI18n } from 'vue-i18n';
import { useStoreGetters } from 'dashboard/composables/store';
import { computed } from 'vue';

const props = defineProps({
  channelType: {
    type: String,
    required: true,
  },
  medium: {
    type: String,
    default: '',
  },
});
const getters = useStoreGetters();
const { t } = useI18n();
const globalConfig = computed(() => getters['globalConfig/get'].value);

const i18nMap = {
  'Channel::FacebookPage': 'MESSENGER',
  'Channel::WebWidget': 'WEB_WIDGET',
  'Channel::TwitterProfile': 'TWITTER_PROFILE',
  'Channel::TwilioSms': 'TWILIO_SMS',
  'Channel::Whatsapp': 'WHATSAPP',
  'Channel::Sms': 'SMS',
  'Channel::Email': 'EMAIL',
  'Channel::Telegram': 'TELEGRAM_BOT',
  'Channel::TelegramPersonal': 'TELEGRAM_PERSONAL',
  'Channel::VkCommunity': 'VK',
  'Channel::Line': 'LINE',
  'Channel::Api': 'API',
  'Channel::WhatsappWeb': 'WHATSAPP_WEB',
  'Channel::Instagram': 'INSTAGRAM',
  'Channel::Tiktok': 'TIKTOK',
  'Channel::Voice': 'VOICE',
  'Channel::Weixin': 'WEIXIN',
};

const twilioChannelName = () => {
  if (props.medium === 'whatsapp') {
    return t(`INBOX_MGMT.CHANNELS.WHATSAPP`);
  }
  return t(`INBOX_MGMT.CHANNELS.TWILIO_SMS`);
};

const readableChannelName = computed(() => {
  if (props.channelType === 'Channel::Api') {
    return globalConfig.value.apiChannelName || t('INBOX_MGMT.CHANNELS.API');
  }
  if (props.channelType === 'Channel::TwilioSms') {
    return twilioChannelName();
  }
  const i18nKey = i18nMap[props.channelType];
  return i18nKey
    ? t(`INBOX_MGMT.CHANNELS.${i18nKey}`)
    : t('INBOX_MGMT.CHANNELS.UNKNOWN');
});
</script>

<template>
  <span>
    {{ readableChannelName }}
  </span>
</template>
