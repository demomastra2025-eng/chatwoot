<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import TableHeaderCell from 'dashboard/components/widgets/TableHeaderCell.vue';
import CheckBox from 'v3/components/Form/CheckBox.vue';
import {
  hasPushPermissions,
  requestPushPermissions,
  verifyServiceWorkerExistence,
} from 'dashboard/helper/pushHelper.js';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import { NOTIFICATION_CHANNELS, NOTIFICATION_TYPES } from './constants';

export default {
  components: {
    TableHeaderCell,
    ToggleSwitch,
    CheckBox,
  },
  data() {
    return {
      selectedEmailFlags: [],
      selectedInboxFlags: [],
      selectedPushFlags: [],
      selectedTelegramFlags: [],
      telegramPendingFlag: '',
      enableAudioAlerts: false,
      hasEnabledPushPermissions: false,
      notificationTypes: NOTIFICATION_TYPES,
      notificationChannels: NOTIFICATION_CHANNELS,
    };
  },
  computed: {
    ...mapGetters({
      accountId: 'getCurrentAccountId',
      emailFlags: 'userNotificationSettings/getSelectedEmailFlags',
      inboxFlags: 'userNotificationSettings/getSelectedInboxFlags',
      pushFlags: 'userNotificationSettings/getSelectedPushFlags',
      telegramFlags: 'userNotificationSettings/getSelectedTelegramFlags',
      telegramConnection: 'userNotificationSettings/getTelegramConnection',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
    }),
    hasPushAPISupport() {
      return !!('Notification' in window);
    },
    isSLAEnabled() {
      return this.isFeatureEnabledonAccount(this.accountId, FEATURE_FLAGS.SLA);
    },
    isTelegramConnected() {
      return !!this.telegramConnection?.connected;
    },
    isTelegramPending() {
      return !!this.telegramPendingFlag;
    },
    telegramBotLink() {
      const username = this.telegramConnection?.bot_username;
      if (!username) return '';

      return `https://t.me/${username}`;
    },
    telegramDisplayName() {
      if (this.telegramConnection?.username) {
        return `@${this.telegramConnection.username}`;
      }

      return [
        this.telegramConnection?.first_name,
        this.telegramConnection?.last_name,
      ]
        .filter(Boolean)
        .join(' ');
    },
    filteredNotificationTypes() {
      return this.notificationTypes.filter(notification =>
        this.isSLAEnabled
          ? true
          : ![
              'sla_missed_first_response',
              'sla_missed_next_response',
              'sla_missed_resolution',
            ].includes(notification.value)
      );
    },
  },
  watch: {
    emailFlags(value) {
      this.selectedEmailFlags = value || [];
    },
    inboxFlags(value) {
      this.selectedInboxFlags = value || [];
    },
    pushFlags(value) {
      this.selectedPushFlags = value || [];
    },
    telegramFlags(value) {
      this.selectedTelegramFlags = value || [];
    },
    isTelegramConnected(value) {
      if (value && this.telegramPendingFlag) {
        this.selectedTelegramFlags = this.toggleInput(
          this.selectedTelegramFlags,
          this.telegramPendingFlag
        );
        this.telegramPendingFlag = '';
        this.updateNotificationSettings();
      }
    },
  },
  mounted() {
    if (hasPushPermissions()) {
      this.getPushSubscription();
    }
    this.$store.dispatch('userNotificationSettings/get');
  },
  methods: {
    checkFlagStatus(type, flagType) {
      const selectedFlagsByType = {
        email: this.selectedEmailFlags,
        inbox: this.selectedInboxFlags,
        push: this.selectedPushFlags,
        telegram: this.selectedTelegramFlags,
      };
      const selectedFlags = selectedFlagsByType[type] || [];
      return selectedFlags.includes(`${type}_${flagType}`);
    },
    onRegistrationSuccess() {
      this.hasEnabledPushPermissions = true;
    },
    onRequestPermissions(value) {
      if (value) {
        // Enable / re-enable push notifications
        requestPushPermissions({
          onSuccess: this.onRegistrationSuccess,
        });
      } else {
        // Disable push notifications
        this.disablePushPermissions();
      }
    },
    disablePushPermissions() {
      verifyServiceWorkerExistence(registration =>
        registration.pushManager
          .getSubscription()
          .then(subscription => {
            if (subscription) {
              return subscription.unsubscribe();
            }
            return null;
          })
          .finally(() => {
            this.hasEnabledPushPermissions = false;
          })
          .catch(() => {
            // error
          })
      );
    },
    getPushSubscription() {
      verifyServiceWorkerExistence(registration =>
        registration.pushManager
          .getSubscription()
          .then(subscription => {
            if (!subscription) {
              this.hasEnabledPushPermissions = false;
            } else {
              this.hasEnabledPushPermissions = true;
            }
          })
          // eslint-disable-next-line no-console
          .catch(error => console.log(error))
      );
    },
    async updateNotificationSettings() {
      try {
        await this.$store.dispatch('userNotificationSettings/update', {
          selectedEmailFlags: this.selectedEmailFlags,
          selectedInboxFlags: this.selectedInboxFlags,
          selectedPushFlags: this.selectedPushFlags,
          selectedTelegramFlags: this.selectedTelegramFlags,
        });
        useAlert(this.$t('PROFILE_SETTINGS.FORM.API.UPDATE_SUCCESS'));
      } catch (error) {
        useAlert(this.$t('PROFILE_SETTINGS.FORM.API.UPDATE_ERROR'));
      }
    },
    handleInput(type, id) {
      if (type === 'email') {
        this.handleEmailInput(id);
      } else if (type === 'inbox') {
        this.handleInboxInput(id);
      } else if (type === 'telegram') {
        this.handleTelegramInput(id);
      } else {
        this.handlePushInput(id);
      }
    },
    handleInboxInput(id) {
      this.selectedInboxFlags = this.toggleInput(this.selectedInboxFlags, id);
      this.updateNotificationSettings();
    },
    handleEmailInput(id) {
      this.selectedEmailFlags = this.toggleInput(this.selectedEmailFlags, id);
      this.updateNotificationSettings();
    },
    handlePushInput(id) {
      this.selectedPushFlags = this.toggleInput(this.selectedPushFlags, id);
      this.updateNotificationSettings();
    },
    async handleTelegramInput(id) {
      if (!this.isTelegramConnected) {
        this.telegramPendingFlag = id;
        useAlert(
          this.$t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_TOKEN_HELP')
        );
        return;
      }

      this.selectedTelegramFlags = this.toggleInput(
        this.selectedTelegramFlags,
        id
      );
      this.updateNotificationSettings();
    },
    async refreshTelegramConnection() {
      await this.$store.dispatch('userNotificationSettings/get');
      if (this.isTelegramConnected) {
        useAlert(
          this.$t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_CONNECTED')
        );
      }
    },
    async disconnectTelegram() {
      try {
        await this.$store.dispatch(
          'userNotificationSettings/disconnectTelegram'
        );
        this.selectedTelegramFlags = [];
        this.telegramPendingFlag = '';
        useAlert(
          this.$t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_DISCONNECTED')
        );
      } catch (error) {
        useAlert(this.$t('PROFILE_SETTINGS.FORM.API.UPDATE_ERROR'));
      }
    },
    toggleInput(selected, current) {
      if (selected.includes(current)) {
        const newSelectedFlags = selected.filter(flag => flag !== current);
        return newSelectedFlags;
      }
      return [...selected, current];
    },
  },
};
</script>

<template>
  <div id="profile-settings-notifications" class="flex flex-col gap-6">
    <!-- Layout for desktop devices -->
    <div class="hidden sm:block">
      <div
        class="grid content-center h-12 grid-cols-12 gap-4 py-0 rounded-t-xl"
      >
        <TableHeaderCell
          :span="4"
          :label="$t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TYPE_TITLE')"
        >
          <span class="text-heading-3 normal-case text-n-slate-12">
            {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TYPE_TITLE') }}
          </span>
        </TableHeaderCell>
        <TableHeaderCell
          v-for="channel in notificationChannels"
          :key="channel.key"
          :span="2"
          :label="$t(channel.label)"
        >
          <div class="flex items-center justify-center gap-1">
            <span
              class="text-heading-3 normal-case text-n-slate-12 whitespace-nowrap"
            >
              {{ $t(channel.label) }}
            </span>
          </div>
        </TableHeaderCell>
      </div>
      <div
        v-for="(notification, index) in filteredNotificationTypes"
        :key="index"
      >
        <div
          class="grid items-center content-center h-12 grid-cols-12 gap-4 py-0 rounded-t-xl"
        >
          <div
            class="flex flex-row items-start gap-2 col-span-4 px-0 py-2 text-sm tracking-[0.5] rtl:text-right"
          >
            <span class="text-body-main text-n-slate-12">
              {{ $t(notification.label) }}
            </span>
          </div>
          <div
            v-for="channel in notificationChannels"
            :key="channel.key"
            class="col-span-2 flex justify-center items-start gap-2 px-0 text-sm tracking-[0.5] text-left rtl:text-right"
          >
            <CheckBox
              :value="`${channel.key}_${notification.value}`"
              :is-checked="checkFlagStatus(channel.key, notification.value)"
              @update="id => handleInput(channel.key, id)"
            />
          </div>
        </div>
      </div>
    </div>
    <!--  Layout for mobile devices -->
    <div class="flex flex-col gap-6 sm:hidden">
      <span class="text-heading-3 text-n-slate-12">
        {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.INBOX') }}
      </span>
      <div class="flex flex-col gap-4">
        <div
          v-for="(notification, index) in filteredNotificationTypes"
          :key="`inbox-${index}`"
          class="flex flex-row items-start gap-2"
        >
          <CheckBox
            :id="`inbox_${notification.value}`"
            :value="`inbox_${notification.value}`"
            :is-checked="checkFlagStatus('inbox', notification.value)"
            @update="handleInboxInput"
          />
          <span class="text-body-main text-n-slate-12">{{
            $t(notification.label)
          }}</span>
        </div>
      </div>

      <span class="text-heading-3 text-n-slate-12">
        {{ $t('PROFILE_SETTINGS.FORM.EMAIL_NOTIFICATIONS_SECTION.TITLE') }}
      </span>
      <div class="flex flex-col gap-4">
        <div
          v-for="(notification, index) in filteredNotificationTypes"
          :key="index"
          class="flex flex-row items-start gap-2"
        >
          <CheckBox
            :id="`email_${notification.value}`"
            :value="`email_${notification.value}`"
            :is-checked="checkFlagStatus('email', notification.value)"
            @update="handleEmailInput"
          />
          <span class="text-body-main text-n-slate-12">{{
            $t(notification.label)
          }}</span>
        </div>
      </div>

      <div class="flex items-center justify-start gap-2">
        <span class="text-heading-3 text-n-slate-12">
          {{ $t('PROFILE_SETTINGS.FORM.PUSH_NOTIFICATIONS_SECTION.TITLE') }}
        </span>
      </div>

      <div class="flex flex-col gap-4">
        <div
          v-for="(notification, index) in filteredNotificationTypes"
          :key="index"
          class="flex flex-row items-start gap-2"
        >
          <CheckBox
            :id="`push_${notification.value}`"
            :value="`push_${notification.value}`"
            :is-checked="checkFlagStatus('push', notification.value)"
            @update="handlePushInput"
          />
          <span class="text-body-main text-n-slate-12">{{
            $t(notification.label)
          }}</span>
        </div>
      </div>

      <span class="text-heading-3 text-n-slate-12">
        {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM') }}
      </span>
      <div class="flex flex-col gap-4">
        <div
          v-for="(notification, index) in filteredNotificationTypes"
          :key="`telegram-${index}`"
          class="flex flex-row items-start gap-2"
        >
          <CheckBox
            :id="`telegram_${notification.value}`"
            :value="`telegram_${notification.value}`"
            :is-checked="checkFlagStatus('telegram', notification.value)"
            @update="handleTelegramInput"
          />
          <span class="text-body-main text-n-slate-12">{{
            $t(notification.label)
          }}</span>
        </div>
      </div>
    </div>

    <div
      class="flex flex-col gap-3 p-4 border border-solid border-n-weak rounded-xl"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-col gap-1">
          <span class="text-heading-3 text-n-slate-12">
            {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_SETUP_TITLE') }}
          </span>
          <span class="text-sm font-medium text-n-slate-11">
            <template v-if="isTelegramConnected">
              {{
                $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_CONNECTED_AS')
              }}
              {{ telegramDisplayName }}
            </template>
            <template v-else-if="isTelegramPending">
              {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_PENDING') }}
            </template>
            <template v-else>
              {{
                $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_NOT_CONNECTED')
              }}
            </template>
          </span>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <a
            v-if="!isTelegramConnected && telegramBotLink"
            :href="telegramBotLink"
            target="_blank"
            rel="noopener noreferrer"
            class="px-3 py-2 text-sm font-medium rounded-lg text-n-brand bg-n-brand/10 hover:bg-n-brand/20"
          >
            {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_OPEN_BOT') }}
          </a>
          <button
            v-if="!isTelegramConnected"
            type="button"
            class="px-3 py-2 text-sm font-medium rounded-lg border border-solid border-n-weak text-n-slate-12 hover:bg-n-slate-3"
            @click="refreshTelegramConnection"
          >
            {{
              $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_CHECK_STATUS')
            }}
          </button>
          <button
            v-if="isTelegramConnected"
            type="button"
            class="px-3 py-2 text-sm font-medium rounded-lg border border-solid border-n-weak text-n-ruby-11 hover:bg-n-ruby-3"
            @click="disconnectTelegram"
          >
            {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_DISCONNECT') }}
          </button>
        </div>
      </div>

      <div
        v-if="!isTelegramConnected"
        class="flex flex-col gap-2 p-3 rounded-lg bg-n-slate-2"
      >
        <span class="text-xs leading-4 text-n-slate-11">
          {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.TELEGRAM_TOKEN_HELP') }}
        </span>
      </div>
    </div>

    <div
      class="flex items-center justify-between w-full gap-2 p-4 border border-solid border-n-weak rounded-xl"
    >
      <div class="flex flex-row items-center gap-2">
        <fluent-icon
          icon="alert"
          class="flex-shrink-0 text-n-slate-12"
          size="18"
        />
        <span class="text-body-main text-n-slate-12">
          {{ $t('PROFILE_SETTINGS.FORM.NOTIFICATIONS.BROWSER_PERMISSION') }}
        </span>
      </div>
      <ToggleSwitch
        v-model="hasEnabledPushPermissions"
        @change="onRequestPermissions"
      />
    </div>
  </div>
</template>
