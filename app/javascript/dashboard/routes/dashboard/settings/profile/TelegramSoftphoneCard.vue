<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import TelegramSoftphoneAPI from 'dashboard/api/telephony/telegramSoftphone';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import Button from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();
const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);
const isTelegramCallsBotEnabled = computed(
  () =>
    isFeatureEnabledonAccount.value?.(accountId.value, 'telegram_calls_bot') ===
    true
);
const mountedAccountId = accountId.value;
let active = true;
const isCurrentAccount = () =>
  active &&
  isTelegramCallsBotEnabled.value &&
  accountId.value === mountedAccountId;

const isLoading = ref(false);
const isActionPending = ref(false);
const pendingDeepLink = ref('');
const state = ref({
  configured: false,
  connected: false,
  on_line: false,
  username: '',
  first_name: '',
  last_name: '',
  bot_username: 'onelink_calls_bot',
  sip_lines: [],
});

const identityLabel = computed(() => {
  if (state.value.username) return `@${state.value.username}`;
  const fullName = [state.value.first_name, state.value.last_name]
    .filter(Boolean)
    .join(' ')
    .trim();
  return (
    fullName || t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.CONNECTED_FALLBACK')
  );
});

const activeSipLinesCount = computed(
  () => (state.value.sip_lines || []).filter(line => line?.registered).length
);

const loadStatus = async () => {
  if (!isCurrentAccount()) return;
  isLoading.value = true;
  try {
    const payload = await TelegramSoftphoneAPI.getStatus();
    if (isCurrentAccount() && payload && typeof payload === 'object') {
      state.value = { ...state.value, ...payload };
      if (state.value.connected) pendingDeepLink.value = '';
    }
  } catch {
    // Non-blocking on initial profile load
  } finally {
    isLoading.value = false;
  }
};

const connectTelegram = async () => {
  if (!isCurrentAccount() || isActionPending.value) return;
  isActionPending.value = true;
  try {
    const payload = await TelegramSoftphoneAPI.issueLinkToken();
    if (!isCurrentAccount()) return;
    state.value = { ...state.value, ...payload };
    pendingDeepLink.value = payload?.deep_link || '';
    if (pendingDeepLink.value && typeof window !== 'undefined') {
      window.open(pendingDeepLink.value, '_blank', 'noopener,noreferrer');
    }
  } catch (error) {
    if (!isCurrentAccount()) return;
    useAlert(
      error?.response?.data?.error ||
        t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.ERROR_GENERIC')
    );
  } finally {
    isActionPending.value = false;
  }
};

const toggleOnLine = async () => {
  if (!isCurrentAccount() || isActionPending.value) return;
  isActionPending.value = true;
  const targetOnLine = !state.value.on_line;
  try {
    const payload = await TelegramSoftphoneAPI.setOnLine(targetOnLine);
    if (!isCurrentAccount()) return;
    state.value = { ...state.value, ...payload };
    if (!targetOnLine) {
      WebphoneClient.bootstrapIncomingSupport?.().catch?.(() => null);
    }
  } catch (error) {
    if (!isCurrentAccount()) return;
    useAlert(
      error?.response?.data?.error ||
        t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.ERROR_GENERIC')
    );
  } finally {
    isActionPending.value = false;
  }
};

const disconnectTelegram = async () => {
  if (!isCurrentAccount() || isActionPending.value) return;
  isActionPending.value = true;
  try {
    const payload = await TelegramSoftphoneAPI.disconnect();
    if (!isCurrentAccount()) return;
    state.value = { ...state.value, ...payload };
    pendingDeepLink.value = '';
    WebphoneClient.bootstrapIncomingSupport?.().catch?.(() => null);
  } catch (error) {
    if (!isCurrentAccount()) return;
    useAlert(
      error?.response?.data?.error ||
        t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.ERROR_GENERIC')
    );
  } finally {
    isActionPending.value = false;
  }
};

onMounted(() => {
  loadStatus();
});
onUnmounted(() => {
  active = false;
});
</script>

<template>
  <div
    v-if="isTelegramCallsBotEnabled"
    class="flex flex-col gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
    data-testid="telegram-softphone-card"
  >
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-2.5">
        <span
          class="inline-flex size-9 shrink-0 items-center justify-center rounded-lg bg-n-alpha-2 text-n-blue-11"
        >
          <i class="i-ri-telegram-fill text-lg" aria-hidden="true" />
        </span>
        <div class="flex flex-col">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-n-slate-12">
              {{
                state.connected
                  ? identityLabel
                  : `@${state.bot_username || 'onelink_calls_bot'}`
              }}
            </span>
            <span
              v-if="state.connected"
              class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium"
              :class="
                state.on_line
                  ? 'bg-n-teal-3 text-n-teal-11'
                  : 'bg-n-alpha-2 text-n-slate-11'
              "
              data-testid="telegram-softphone-badge"
            >
              <span
                class="size-1.5 rounded-full"
                :class="state.on_line ? 'bg-n-teal-9' : 'bg-n-slate-8'"
              />
              {{
                state.on_line
                  ? t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.STATUS_ONLINE')
                  : t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.STATUS_OFFLINE')
              }}
            </span>
          </div>
          <span class="text-xs text-n-slate-11">
            {{
              state.connected && activeSipLinesCount > 0
                ? t(
                    'PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.SIP_LINES_ACTIVE',
                    { count: activeSipLinesCount }
                  )
                : t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.SUBTITLE')
            }}
          </span>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <template v-if="!state.connected">
          <Button
            type="button"
            variant="solid"
            color="blue"
            size="sm"
            icon="i-ri-telegram-fill"
            :disabled="!state.configured || isActionPending || isLoading"
            :label="t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.CONNECT_BTN')"
            data-testid="telegram-softphone-connect"
            @click="connectTelegram"
          />
          <Button
            v-if="pendingDeepLink"
            type="button"
            variant="faded"
            color="slate"
            size="sm"
            icon="i-lucide-refresh-cw"
            :disabled="isLoading"
            :label="
              t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.CHECK_STATUS_BTN')
            "
            data-testid="telegram-softphone-refresh"
            @click="loadStatus"
          />
        </template>
        <template v-else>
          <Button
            type="button"
            :variant="state.on_line ? 'faded' : 'solid'"
            :color="state.on_line ? 'ruby' : 'teal'"
            size="sm"
            :disabled="isActionPending"
            :label="
              state.on_line
                ? t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.GO_OFFLINE_BTN')
                : t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.GO_ONLINE_BTN')
            "
            data-testid="telegram-softphone-toggle"
            @click="toggleOnLine"
          />
          <Button
            type="button"
            variant="ghost"
            color="slate"
            size="sm"
            :disabled="isActionPending"
            :label="
              t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.DISCONNECT_BTN')
            "
            data-testid="telegram-softphone-disconnect"
            @click="disconnectTelegram"
          />
        </template>
      </div>
    </div>

    <div
      v-if="pendingDeepLink && !state.connected"
      class="flex items-center justify-between gap-2 rounded-lg bg-n-alpha-1 px-3 py-2 text-xs text-n-slate-11"
      data-testid="telegram-softphone-deeplink-box"
    >
      <span class="truncate">
        {{ t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.OPEN_BOT_HINT') }}
      </span>
      <a
        :href="pendingDeepLink"
        target="_blank"
        rel="noopener noreferrer"
        class="shrink-0 font-medium text-n-blue-11 underline"
      >
        {{ t('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.OPEN_LINK') }}
      </a>
    </div>
  </div>
</template>
