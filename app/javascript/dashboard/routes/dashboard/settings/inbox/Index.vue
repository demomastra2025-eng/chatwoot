<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { picoSearch } from '@scmmishra/pico-search';
import Avatar from 'next/avatar/Avatar.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import ChannelName from './components/ChannelName.vue';
import ChannelIcon from 'next/icon/ChannelIcon.vue';
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';

const getters = useStoreGetters();
const { accountScopedRoute } = useAccount();
const { t } = useI18n();

const searchQuery = ref('');

const inboxes = useMapGetter('inboxes/getInboxes');

const normalizeValue = value => {
  return value ? String(value).trim() : '';
};

const pickFirstValue = values => {
  return values.map(normalizeValue).find(Boolean) || '';
};

const getChannelType = inbox =>
  normalizeValue(inbox.channel_type).toLowerCase();

const getConnectionState = inbox => {
  return pickFirstValue([
    inbox.connection_state,
    inbox.lifecycle_state,
    inbox.runtime_state,
  ]);
};

const capitalizeWords = value => {
  return normalizeValue(value)
    .replaceAll('_', ' ')
    .split(' ')
    .filter(Boolean)
    .map(word => `${word.charAt(0).toUpperCase()}${word.slice(1)}`)
    .join(' ');
};

const formatProvider = provider => {
  const normalizedProvider = normalizeValue(provider).toLowerCase();

  if (!normalizedProvider) return '';
  if (normalizedProvider === 'whatsapp_cloud') return 'WhatsApp Cloud';
  if (normalizedProvider === 'telegram_personal') return 'Telegram Personal';
  if (normalizedProvider === 'sipuni') return 'Sipuni';
  if (normalizedProvider === 'binotel') return 'Binotel';
  if (normalizedProvider === 'twilio') return 'Twilio';
  if (normalizedProvider === 'google') return 'Google';
  if (normalizedProvider === 'microsoft') return 'Microsoft';

  return capitalizeWords(provider);
};

const formatUrl = value => {
  const rawValue = normalizeValue(value);
  if (!rawValue) return '';

  try {
    const url = new URL(rawValue);
    return `${url.hostname}${url.pathname === '/' ? '' : url.pathname}`;
  } catch {
    return rawValue.replace(/^https?:\/\//, '').split(/[?#]/)[0];
  }
};

const formatDateTime = value => {
  if (!value) return '';

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
};

const getConnectionStateLabel = state => {
  const normalizedState = normalizeValue(state).toLowerCase();

  if (!normalizedState) return '';
  if (
    ['connected', 'ready', 'running', 'logged_in'].includes(normalizedState)
  ) {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.CONNECTED');
  }
  if (normalizedState === 'disconnected') {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.DISCONNECTED');
  }
  if (normalizedState === 'qr_required') {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.QR_REQUIRED');
  }
  if (['syncing', 'sync_in_progress'].includes(normalizedState)) {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.SYNCING');
  }
  if (['connecting', 'initializing', 'pending'].includes(normalizedState)) {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.CONNECTING');
  }
  if (['unauthorized', 'auth_failed'].includes(normalizedState)) {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.UNAUTHORIZED');
  }
  if (['failed', 'error'].includes(normalizedState)) {
    return t('INBOX_MGMT.LIST.CONNECTION_STATES.ERROR');
  }

  return capitalizeWords(state);
};

const getPrimaryPhone = inbox => {
  return pickFirstValue([
    inbox.phone_number,
    inbox.display_phone_number,
    inbox.telephony?.phone_number,
  ]);
};

const getPrimaryAccountName = inbox => {
  return pickFirstValue([
    inbox.display_name,
    inbox.bot_name,
    inbox.business_name,
    inbox.email,
  ]);
};

const getProvider = inbox => {
  return pickFirstValue([inbox.provider, inbox.telephony?.provider]);
};

const addDetail = (details, { icon, label, value, title }) => {
  const normalizedValue = normalizeValue(value);

  if (!normalizedValue) return;

  details.push({
    icon,
    label,
    value: normalizedValue,
    title: title || normalizedValue,
  });
};

const addConnectionDetails = (details, inbox) => {
  const connectionLabel = getConnectionStateLabel(getConnectionState(inbox));
  addDetail(details, {
    icon: 'i-lucide-wifi',
    label: t('INBOX_MGMT.LIST.DETAILS.CONNECTION'),
    value: connectionLabel,
  });

  const lastSync = formatDateTime(
    pickFirstValue([
      inbox.last_synced_at,
      inbox.message_templates_last_updated,
      inbox.telephony?.last_synced_at,
    ])
  );
  addDetail(details, {
    icon: 'i-lucide-clock-3',
    label: t('INBOX_MGMT.LIST.DETAILS.SYNCED_AT'),
    value: lastSync,
  });
};

const addProviderDetail = (details, inbox) => {
  addDetail(details, {
    icon: 'i-lucide-plug',
    label: t('INBOX_MGMT.LIST.DETAILS.PROVIDER'),
    value: formatProvider(getProvider(inbox)),
  });
};

const getVoiceRoutingLabel = inbox => {
  const routingPolicy = inbox.telephony?.routing_policy || {};
  const mode = normalizeValue(routingPolicy.mode).toLowerCase();

  if (routingPolicy.ai_enabled || mode === 'ai') {
    return t('INBOX_MGMT.LIST.DETAILS.ROUTING_AI');
  }

  if (mode === 'operator') {
    return t('INBOX_MGMT.LIST.DETAILS.ROUTING_OPERATOR');
  }

  return capitalizeWords(mode);
};

const addOperationalDetails = (details, inbox) => {
  const type = getChannelType(inbox);

  if (type.includes('voice')) {
    addDetail(details, {
      icon: 'i-lucide-phone',
      label: t('INBOX_MGMT.LIST.DETAILS.PHONE'),
      value: getPrimaryPhone(inbox),
    });
    addProviderDetail(details, inbox);
    addDetail(details, {
      icon: 'i-lucide-route',
      label: t('INBOX_MGMT.LIST.DETAILS.ROUTING'),
      value: getVoiceRoutingLabel(inbox),
    });
    addConnectionDetails(details, inbox);
    return;
  }

  if (type.includes('webwidget')) {
    addDetail(details, {
      icon: 'i-lucide-globe',
      label: t('INBOX_MGMT.LIST.DETAILS.SITE'),
      value: formatUrl(inbox.website_url),
      title: inbox.website_url,
    });
    addDetail(details, {
      icon: 'i-lucide-mail-check',
      label: t('INBOX_MGMT.LIST.DETAILS.EMAIL_CONTINUITY'),
      value: inbox.continuity_via_email
        ? t('INBOX_MGMT.LIST.DETAILS.ENABLED')
        : '',
    });
    return;
  }

  if (type.includes('email')) {
    addDetail(details, {
      icon: 'i-lucide-mail',
      label: t('INBOX_MGMT.LIST.DETAILS.EMAIL'),
      value: inbox.email,
    });
    addDetail(details, {
      icon: 'i-lucide-forward',
      label: t('INBOX_MGMT.LIST.DETAILS.FORWARD_TO'),
      value: inbox.forward_to_email,
    });
    return;
  }

  if (type.includes('api')) {
    addDetail(details, {
      icon: 'i-lucide-webhook',
      label: t('INBOX_MGMT.LIST.DETAILS.WEBHOOK'),
      value: formatUrl(inbox.webhook_url || inbox.callback_webhook_url),
      title: inbox.webhook_url || inbox.callback_webhook_url,
    });
    return;
  }

  if (
    type.includes('whatsapp') ||
    type.includes('twilio') ||
    type.includes('sms') ||
    type.includes('telegram_personal')
  ) {
    addDetail(details, {
      icon: 'i-lucide-phone',
      label: t('INBOX_MGMT.LIST.DETAILS.PHONE'),
      value: getPrimaryPhone(inbox),
    });
    addProviderDetail(details, inbox);
    addConnectionDetails(details, inbox);
    return;
  }

  if (type.includes('telegram')) {
    addDetail(details, {
      icon: 'i-lucide-bot',
      label: t('INBOX_MGMT.LIST.DETAILS.BOT'),
      value: inbox.bot_name,
    });
    return;
  }

  if (type.includes('linkedin') || type.includes('weixin')) {
    addDetail(details, {
      icon: 'i-lucide-user-round',
      label: t('INBOX_MGMT.LIST.DETAILS.PROFILE'),
      value: getPrimaryAccountName(inbox),
    });
    addConnectionDetails(details, inbox);
    return;
  }

  if (
    type.includes('facebook') ||
    type.includes('instagram') ||
    type.includes('tiktok') ||
    type.includes('twitter') ||
    type.includes('vk')
  ) {
    addDetail(details, {
      icon: 'i-lucide-at-sign',
      label: t('INBOX_MGMT.LIST.DETAILS.ACCOUNT'),
      value: getPrimaryAccountName(inbox),
    });
    addDetail(details, {
      icon: 'i-lucide-circle-check',
      label: t('INBOX_MGMT.LIST.DETAILS.CONNECTION'),
      value: inbox.reauthorization_required
        ? t('INBOX_MGMT.LIST.STATUS.NEEDS_AUTH')
        : t('INBOX_MGMT.LIST.DETAILS.CONNECTED_ACCOUNT'),
    });
  }
};

const getCardDetails = inbox => {
  const details = [];
  addOperationalDetails(details, inbox);

  if (!details.length) {
    addDetail(details, {
      icon: 'i-lucide-badge-check',
      label: t('INBOX_MGMT.LIST.DETAILS.IDENTITY'),
      value: pickFirstValue([
        getPrimaryPhone(inbox),
        getPrimaryAccountName(inbox),
        formatUrl(inbox.website_url),
      ]),
    });
  }

  return details.slice(0, 4);
};

const supportsCampaigns = campaignCapabilities => {
  if (!campaignCapabilities) return false;
  if (Array.isArray(campaignCapabilities))
    return campaignCapabilities.length > 0;
  if (typeof campaignCapabilities === 'object') {
    return Object.values(campaignCapabilities).some(Boolean);
  }
  return Boolean(campaignCapabilities);
};

const getCapabilityChips = inbox => {
  const chips = [];

  if (inbox.captain_assistant?.name) {
    chips.push(
      t('INBOX_MGMT.LIST.CHIPS.CAPTAIN', {
        name: inbox.captain_assistant.name,
      })
    );
  }

  if (inbox.enable_auto_assignment) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.AUTO_ASSIGNMENT'));
  }

  if (inbox.working_hours_enabled) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.WORKING_HOURS'));
  }

  if (inbox.greeting_enabled) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.GREETING'));
  }

  if (inbox.pre_chat_form_enabled) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.PRE_CHAT_FORM'));
  }

  if (inbox.imap_enabled) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.IMAP'));
  }

  if (inbox.smtp_enabled) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.SMTP'));
  }

  if (inbox.calling_enabled || inbox.telephony) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.CALLS'));
  }

  if (inbox.media_server_enabled) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.MEDIA_SERVER'));
  }

  if (supportsCampaigns(inbox.campaign_capabilities)) {
    chips.push(t('INBOX_MGMT.LIST.CHIPS.CAMPAIGNS'));
  }

  return chips.slice(0, 5);
};

const getStatus = inbox => {
  const state = getConnectionState(inbox).toLowerCase();

  if (isInboxPendingDeletion(inbox)) {
    return {
      label: t('INBOX_MGMT.LIST.STATUS.DELETING'),
      class: 'bg-n-amber-3 text-n-amber-11 border-n-amber-5',
    };
  }

  if (inbox.reauthorization_required || inbox.requires_reauthorization) {
    return {
      label: t('INBOX_MGMT.LIST.STATUS.NEEDS_AUTH'),
      class: 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-5',
    };
  }

  if (
    [
      'disconnected',
      'unauthorized',
      'auth_failed',
      'qr_required',
      'failed',
      'error',
    ].includes(state)
  ) {
    return {
      label: t('INBOX_MGMT.LIST.STATUS.CHECK'),
      class: 'bg-n-amber-3 text-n-amber-11 border-n-amber-5',
    };
  }

  if (inbox.enabled === false || inbox.status === 'disabled') {
    return {
      label: t('INBOX_MGMT.LIST.STATUS.INACTIVE'),
      class: 'bg-n-slate-3 text-n-slate-11 border-n-slate-5',
    };
  }

  const tokenExpiring =
    inbox.provider_config?.token_health?.status === 'expiring';

  return tokenExpiring
    ? {
        label: t('INBOX_MGMT.HEALTH_STATUS.TOKEN_EXPIRING'),
        class: 'bg-n-amber-3 text-n-amber-11 border-n-amber-5',
      }
    : {
        label: t('INBOX_MGMT.LIST.STATUS.ACTIVE'),
        class: 'bg-n-teal-3 text-n-teal-11 border-n-teal-5',
      };
};

const inboxesList = computed(() => {
  return (inboxes.value || [])
    .slice()
    .sort((a, b) => a.name.localeCompare(b.name));
});

const searchableInboxes = computed(() => {
  return inboxesList.value.map(inbox => ({
    ...inbox,
    search_text: [
      getCardDetails(inbox)
        .map(detail => `${detail.label} ${detail.value}`)
        .join(' '),
      getCapabilityChips(inbox).join(' '),
      getStatus(inbox).label,
    ].join(' '),
  }));
});

const filteredInboxesList = computed(() => {
  const visibleInboxes = searchableInboxes.value.filter(
    inbox => !isInboxPendingDeletion(inbox)
  );
  const query = searchQuery.value.trim();
  if (!query) return visibleInboxes;
  return picoSearch(visibleInboxes, query, [
    'name',
    'channel_type',
    'search_text',
  ]);
});

const showAddCard = computed(() => !searchQuery.value.trim());

const uiFlags = computed(() => getters['inboxes/getUIFlags'].value);
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching">
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('INBOX_MGMT.HEADER')"
        :description="$t('INBOX_MGMT.DESCRIPTION')"
        :link-text="$t('INBOX_MGMT.LEARN_MORE')"
        :search-placeholder="$t('INBOX_MGMT.SEARCH_PLACEHOLDER')"
        feature-name="inboxes"
      >
        <template v-if="inboxesList.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('INBOX_MGMT.COUNT', { n: filteredInboxesList.length }) }}
          </span>
        </template>
        <template #actions>
          <router-link :to="accountScopedRoute('settings_inbox_new')">
            <Button
              :label="$t('INBOX_MGMT.LIST.CREATE_CHANNEL')"
              icon="i-lucide-plus"
              size="sm"
            />
          </router-link>
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <span
        v-if="!filteredInboxesList.length && searchQuery"
        class="flex-1 flex items-center justify-center py-20 text-center text-body-main !text-base text-n-slate-11"
      >
        {{ $t('INBOX_MGMT.NO_RESULTS') }}
      </span>
      <div
        v-else
        class="grid grid-cols-1 gap-4 pt-2 sm:grid-cols-2 xl:grid-cols-3"
      >
        <router-link
          v-for="inbox in filteredInboxesList"
          :key="inbox.id"
          :to="accountScopedRoute('settings_inbox_show', { inboxId: inbox.id })"
          class="group flex min-h-48 flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-1 p-4 shadow-sm outline outline-1 outline-transparent transition hover:-translate-y-0.5 hover:border-n-brand/50 hover:bg-n-alpha-2 hover:shadow-md focus-visible:outline-n-brand"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="flex min-w-0 items-center gap-3">
              <div
                v-if="inbox.avatar_url"
                class="grid size-11 place-items-center rounded-xl border border-n-strong bg-n-alpha-3 shadow-sm ring ring-n-solid-1"
              >
                <Avatar
                  :src="inbox.avatar_url"
                  :name="inbox.name"
                  :size="28"
                  rounded-full
                />
              </div>
              <div
                v-else
                class="grid size-11 place-items-center rounded-xl border border-n-strong bg-n-alpha-3 shadow-sm ring ring-n-solid-1"
              >
                <ChannelIcon class="size-6 text-n-slate-10" :inbox="inbox" />
              </div>
              <div class="min-w-0">
                <span
                  class="block truncate text-heading-3 text-n-slate-12 capitalize"
                >
                  {{ inbox.name }}
                </span>
                <ChannelName
                  :channel-type="inbox.channel_type"
                  :medium="inbox.medium"
                  class="text-body-main text-n-slate-11"
                />
              </div>
            </div>
            <span
              class="shrink-0 rounded-full border px-2 py-0.5 text-xs font-medium"
              :class="getStatus(inbox).class"
            >
              {{ getStatus(inbox).label }}
            </span>
          </div>

          <div class="mt-4 flex flex-col gap-2 text-sm text-n-slate-11">
            <div
              v-for="detail in getCardDetails(inbox)"
              :key="`${detail.label}-${detail.value}`"
              class="flex min-w-0 items-start gap-2"
            >
              <Icon
                :icon="detail.icon"
                class="mt-0.5 size-4 shrink-0 text-n-slate-9"
              />
              <span class="shrink-0 text-n-slate-10">{{ detail.label }}</span>
              <span
                class="min-w-0 truncate text-n-slate-12"
                :title="detail.title"
              >
                {{ detail.value }}
              </span>
            </div>

            <div
              v-if="getCapabilityChips(inbox).length"
              class="flex flex-wrap gap-1.5 pt-1"
            >
              <span
                v-for="chip in getCapabilityChips(inbox)"
                :key="chip"
                class="rounded-md border border-n-weak bg-n-alpha-2 px-2 py-1 text-xs text-n-slate-11"
              >
                {{ chip }}
              </span>
            </div>

            <p
              v-if="inbox.last_error"
              class="line-clamp-2 rounded-lg bg-n-ruby-3 px-3 py-2 text-xs text-n-ruby-11"
              :title="inbox.last_error"
            >
              {{ inbox.last_error }}
            </p>
          </div>

          <div
            class="mt-4 flex items-center justify-between border-t border-n-weak pt-3 text-sm font-medium text-n-brand"
          >
            <span>{{ $t('INBOX_MGMT.LIST.OPEN_SETTINGS') }}</span>
            <Icon
              icon="i-lucide-arrow-right"
              class="size-4 transition group-hover:translate-x-0.5"
            />
          </div>
        </router-link>

        <router-link
          v-if="showAddCard"
          :to="accountScopedRoute('settings_inbox_new')"
          class="flex min-h-48 flex-col items-center justify-center gap-3 rounded-2xl border border-dashed border-n-strong bg-n-alpha-2 p-6 text-center outline outline-1 outline-transparent transition hover:border-n-brand hover:bg-n-brand/5 focus-visible:outline-n-brand"
        >
          <span
            class="grid size-12 place-items-center rounded-2xl bg-n-brand/10 text-n-brand"
          >
            <Icon icon="i-lucide-plus" class="size-6" />
          </span>
          <span class="text-heading-3 text-n-slate-12">
            {{ $t('INBOX_MGMT.LIST.CREATE_CHANNEL') }}
          </span>
          <span class="max-w-56 text-body-main text-n-slate-11">
            {{ $t('INBOX_MGMT.LIST.CREATE_CHANNEL_HELP') }}
          </span>
        </router-link>
      </div>
    </template>
  </SettingsLayout>
</template>
