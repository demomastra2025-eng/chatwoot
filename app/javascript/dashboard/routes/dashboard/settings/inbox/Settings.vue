<script>
import { mapGetters } from 'vuex';
import { shouldBeUrl } from 'shared/helpers/Validators';
import { useAlert } from 'dashboard/composables';
import { useVuelidate } from '@vuelidate/core';
import Avatar from 'next/avatar/Avatar.vue';
import SettingIntroBanner from 'dashboard/components/widgets/SettingIntroBanner.vue';
import SettingsSection from '../../../../components/SettingsSection.vue';
import inboxMixin from 'shared/mixins/inboxMixin';
import FacebookReauthorize from './facebook/Reauthorize.vue';
import InstagramReauthorize from './channels/instagram/Reauthorize.vue';
import TiktokReauthorize from './channels/tiktok/Reauthorize.vue';
import DuplicateInboxBanner from './channels/instagram/DuplicateInboxBanner.vue';
import MicrosoftReauthorize from './channels/microsoft/Reauthorize.vue';
import GoogleReauthorize from './channels/google/Reauthorize.vue';
import WhatsappReauthorize from './channels/whatsapp/Reauthorize.vue';
import InboxHealthAPI from 'dashboard/api/inboxHealth';
import PreChatFormSettings from './PreChatForm/Settings.vue';
import WeeklyAvailability from './components/WeeklyAvailability.vue';
import GreetingsEditor from 'shared/components/GreetingsEditor.vue';
import ConfigurationPage from './settingsPage/ConfigurationPage.vue';
import CustomerSatisfactionPage from './settingsPage/CustomerSatisfactionPage.vue';
import CollaboratorsPage from './settingsPage/CollaboratorsPage.vue';
import WidgetBuilder from './WidgetBuilder.vue';
import BotConfiguration from './components/BotConfiguration.vue';
import AccountHealth from './components/AccountHealth.vue';
import { FEATURE_FLAGS } from '../../../../featureFlags';
import SenderNameExamplePreview from './components/SenderNameExamplePreview.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { getInboxIconByType } from 'dashboard/helper/inbox';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import InboxSelect from 'dashboard/components-next/select/Select.vue';

const WHATSAPP_WEB_IGNORE_JIDS_EXAMPLE =
  '15550001111@s.whatsapp.net\\n15550002222@s.whatsapp.net';

export default {
  components: {
    BotConfiguration,
    CollaboratorsPage,
    ConfigurationPage,
    CustomerSatisfactionPage,
    FacebookReauthorize,
    GreetingsEditor,
    PreChatFormSettings,
    SettingIntroBanner,
    SettingsSection,
    WeeklyAvailability,
    WidgetBuilder,
    SenderNameExamplePreview,
    MicrosoftReauthorize,
    GoogleReauthorize,
    NextButton,
    Checkbox,
    InboxSelect,
    InstagramReauthorize,
    TiktokReauthorize,
    WhatsappReauthorize,
    DuplicateInboxBanner,
    Editor,
    Avatar,
    AccountHealth,
  },
  mixins: [inboxMixin],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      avatarFile: null,
      avatarUrl: '',
      greetingEnabled: true,
      greetingMessage: '',
      emailCollectEnabled: false,
      senderNameType: 'friendly',
      businessName: '',
      locktoSingleConversation: false,
      allowMessagesAfterResolved: true,
      continuityViaEmail: true,
      selectedInboxName: '',
      channelWebsiteUrl: '',
      webhookUrl: '',
      channelWelcomeTitle: '',
      channelWelcomeTagline: '',
      selectedFeatureFlags: [],
      replyTime: '',
      selectedTabIndex: 0,
      selectedPortalSlug: '',
      showBusinessNameInput: false,
      healthData: null,
      isLoadingHealth: false,
      healthError: null,
      whatsappWebDiagnostics: null,
      isLoadingWhatsappWebDiagnostics: false,
      isRefreshingWhatsappWebStatus: false,
      isRunningWhatsappWebReconnect: false,
      isRunningWhatsappWebDisconnect: false,
      isRunningWhatsappWebRepair: false,
      isRefreshingWhatsappWebQr: false,
      whatsappWebConversationPending: false,
      whatsappWebHistoryLookbackDays: 365,
      whatsappWebIgnoreJids: '',
      whatsappWebSignMessages: false,
      whatsappWebSignDelimiter: '\\n',
      whatsappWebImportContacts: true,
      whatsappWebImportMessages: true,
      whatsappWebSyncLabels: true,
    };
  },
  computed: {
    ...mapGetters({
      accountId: 'getCurrentAccountId',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
      uiFlags: 'inboxes/getUIFlags',
      portals: 'portals/allPortals',
    }),
    selectedTabKey() {
      return this.tabs[this.selectedTabIndex]?.key;
    },
    shouldShowWhatsAppConfiguration() {
      return this.isAWhatsAppCloudChannel;
    },
    isAWhatsAppWebInbox() {
      return this.inbox?.channel_type === 'Channel::WhatsappWeb';
    },
    whatsappWebEvolutionState() {
      return this.inbox?.additional_attributes?.evolution || {};
    },
    shouldShowWhatsappWebLifecycleSection() {
      return this.isAWhatsAppWebInbox;
    },
    whatsAppAPIProviderName() {
      if (this.isAWhatsAppCloudChannel) {
        return this.$t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.WHATSAPP_CLOUD');
      }
      if (this.is360DialogWhatsAppChannel) {
        return this.$t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.360_DIALOG');
      }
      if (this.isATwilioWhatsAppChannel) {
        return this.$t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.TWILIO');
      }
      return '';
    },
    tabs() {
      let visibleToAllChannelTabs = [
        {
          key: 'inbox-settings',
          name: this.$t('INBOX_MGMT.TABS.SETTINGS'),
        },
        {
          key: 'collaborators',
          name: this.$t('INBOX_MGMT.TABS.COLLABORATORS'),
        },
      ];

      if (!this.isAVoiceChannel) {
        visibleToAllChannelTabs = [
          ...visibleToAllChannelTabs,
          {
            key: 'business-hours',
            name: this.$t('INBOX_MGMT.TABS.BUSINESS_HOURS'),
          },
          {
            key: 'csat',
            name: this.$t('INBOX_MGMT.TABS.CSAT'),
          },
        ];
      }

      if (this.isAWebWidgetInbox) {
        visibleToAllChannelTabs = [
          ...visibleToAllChannelTabs,
          {
            key: 'pre-chat-form',
            name: this.$t('INBOX_MGMT.TABS.PRE_CHAT_FORM'),
          },
          {
            key: 'widget-builder',
            name: this.$t('INBOX_MGMT.TABS.WIDGET_BUILDER'),
          },
        ];
      }

      if (
        this.isATwilioChannel ||
        this.isALineChannel ||
        (this.isAPIInbox && !this.isAWhatsAppWebInbox) ||
        this.isAVoiceChannel ||
        (this.isAnEmailChannel && !this.inbox.provider) ||
        this.shouldShowWhatsAppConfiguration ||
        this.isAWebWidgetInbox
      ) {
        visibleToAllChannelTabs = [
          ...visibleToAllChannelTabs,
          {
            key: 'configuration',
            name: this.$t('INBOX_MGMT.TABS.CONFIGURATION'),
          },
        ];
      }

      if (
        this.isFeatureEnabledonAccount(this.accountId, FEATURE_FLAGS.AGENT_BOTS)
      ) {
        visibleToAllChannelTabs = [
          ...visibleToAllChannelTabs,
          {
            key: 'bot-configuration',
            name: this.$t('INBOX_MGMT.TABS.BOT_CONFIGURATION'),
          },
        ];
      }
      if (this.shouldShowWhatsAppConfiguration) {
        visibleToAllChannelTabs = [
          ...visibleToAllChannelTabs,
          {
            key: 'whatsapp-health',
            name: this.$t('INBOX_MGMT.TABS.ACCOUNT_HEALTH'),
          },
        ];
      }

      return visibleToAllChannelTabs;
    },
    currentInboxId() {
      return this.$route.params.inboxId;
    },
    inbox() {
      return this.$store.getters['inboxes/getInbox'](this.currentInboxId);
    },
    inboxIcon() {
      const { medium, channel_type: type } = this.inbox;
      return getInboxIconByType(type, medium);
    },
    inboxName() {
      if (this.isATwilioSMSChannel || this.isATwilioWhatsAppChannel) {
        return `${this.inbox.name} (${
          this.inbox.messaging_service_sid || this.inbox.phone_number
        })`;
      }
      if (this.isAWhatsAppChannel) {
        return `${this.inbox.name} (${this.inbox.phone_number})`;
      }
      if (this.isAnEmailChannel) {
        return `${this.inbox.name} (${this.inbox.email})`;
      }
      return this.inbox.name;
    },
    canLocktoSingleConversation() {
      return (
        this.isASmsInbox ||
        this.isAWhatsAppChannel ||
        this.isAFacebookInbox ||
        this.isAPIInbox ||
        this.isATelegramChannel
      );
    },
    inboxNameLabel() {
      if (this.isAWebWidgetInbox) {
        return this.$t('INBOX_MGMT.ADD.WEBSITE_NAME.LABEL');
      }
      return this.$t('INBOX_MGMT.ADD.CHANNEL_NAME.LABEL');
    },
    inboxNamePlaceHolder() {
      if (this.isAWebWidgetInbox) {
        return this.$t('INBOX_MGMT.ADD.WEBSITE_NAME.PLACEHOLDER');
      }
      return this.$t('INBOX_MGMT.ADD.CHANNEL_NAME.PLACEHOLDER');
    },
    textAreaChannels() {
      if (
        this.isATwilioChannel ||
        this.isATwitterInbox ||
        this.isAFacebookInbox
      )
        return true;
      return false;
    },
    instagramUnauthorized() {
      return this.isAnInstagramChannel && this.inbox.reauthorization_required;
    },
    tiktokUnauthorized() {
      return this.isATiktokChannel && this.inbox.reauthorization_required;
    },
    // Check if a instagram inbox exists with the same instagram_id
    hasDuplicateInstagramInbox() {
      const instagramId = this.inbox.instagram_id;
      const instagramInbox =
        this.$store.getters['inboxes/getInstagramInboxByInstagramId'](
          instagramId
        );

      return this.inbox.channel_type === INBOX_TYPES.FB && instagramInbox;
    },
    microsoftUnauthorized() {
      return this.isAMicrosoftInbox && this.inbox.reauthorization_required;
    },
    facebookUnauthorized() {
      return this.isAFacebookInbox && this.inbox.reauthorization_required;
    },
    googleUnauthorized() {
      const isLegacyInbox = ['imap.gmail.com', 'imap.google.com'].includes(
        this.inbox.imap_address
      );

      return (
        (this.isAGoogleInbox || isLegacyInbox) &&
        this.inbox.reauthorization_required
      );
    },
    isEmbeddedSignupWhatsApp() {
      return this.inbox.provider_config?.source === 'embedded_signup';
    },
    whatsappUnauthorized() {
      return (
        this.isAWhatsAppCloudChannel &&
        this.isEmbeddedSignupWhatsApp &&
        this.inbox.reauthorization_required
      );
    },
    whatsappRegistrationIncomplete() {
      if (
        !this.healthData ||
        !this.isAWhatsAppCloudChannel ||
        !this.isEmbeddedSignupWhatsApp
      ) {
        return false;
      }

      return (
        this.healthData.platform_type === 'NOT_APPLICABLE' ||
        this.healthData.throughput?.level === 'NOT_APPLICABLE'
      );
    },
    whatsappWebDiagnosticsCounts() {
      return this.whatsappWebDiagnostics?.counts || {};
    },
    whatsappWebIgnoreJidsPlaceholder() {
      return this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IGNORE_JIDS_PLACEHOLDER', {
        sample_jids: WHATSAPP_WEB_IGNORE_JIDS_EXAMPLE,
      });
    },
  },
  watch: {
    $route(to) {
      if (to.name === 'settings_inbox_show') {
        this.fetchInboxSettings();
      }
    },
    inbox: {
      handler() {
        this.fetchHealthData();
      },
      immediate: false,
    },
  },
  mounted() {
    this.fetchInboxSettings();
    this.fetchPortals();
    this.fetchHealthData();
  },
  methods: {
    fetchPortals() {
      this.$store.dispatch('portals/index');
    },
    async fetchHealthData() {
      if (!this.inbox) return;

      if (!this.isAWhatsAppCloudChannel) {
        return;
      }

      try {
        this.isLoadingHealth = true;
        this.healthError = null;
        const response = await InboxHealthAPI.getHealthStatus(this.inbox.id);
        this.healthData = response.data;
      } catch (error) {
        this.healthError = error.message || 'Failed to fetch health data';
      } finally {
        this.isLoadingHealth = false;
      }
    },
    handleFeatureFlag(e) {
      this.selectedFeatureFlags = this.toggleInput(
        this.selectedFeatureFlags,
        e.target.value
      );
    },
    toggleInput(selected, current) {
      if (selected.includes(current)) {
        const newSelectedFlags = selected.filter(flag => flag !== current);
        return newSelectedFlags;
      }
      return [...selected, current];
    },
    refreshAvatarUrlOnTabChange(index) {
      // Refresh avatar URL on tab change from inbox-settings and widget-builder tabs, to ensure real-time updates
      if (
        this.inbox &&
        ['inbox-settings', 'widget-builder'].includes(this.tabs[index].key)
      )
        this.avatarUrl = this.inbox.avatar_url;
    },
    onTabChange(selectedTabIndex) {
      this.selectedTabIndex = selectedTabIndex;
      this.refreshAvatarUrlOnTabChange(selectedTabIndex);
      this.updateRouteWithoutRefresh(selectedTabIndex);
      if (this.tabs[selectedTabIndex]?.key === 'inbox-settings') {
        this.syncWhatsappWebStatus();
        this.fetchWhatsappWebDiagnostics();
      }
    },
    updateRouteWithoutRefresh(selectedTabIndex) {
      const tab = this.tabs[selectedTabIndex];
      if (!tab) return;

      const { accountId, inboxId } = this.$route.params;
      const baseUrl = `/app/accounts/${accountId}/settings/inboxes/${inboxId}`;

      // Append the tab key only if it's not the default.
      const newUrl =
        tab.key === 'inbox-settings' ? baseUrl : `${baseUrl}/${tab.key}`;
      // Update URL without triggering route watcher
      window.history.replaceState(null, '', newUrl);
    },
    setTabFromRouteParam() {
      const { tab: tabParam } = this.$route.params;
      if (!tabParam) return;
      const tabIndex = this.tabs.findIndex(tab => tab.key === tabParam);

      this.selectedTabIndex = tabIndex === -1 ? 0 : tabIndex;
    },
    fetchInboxSettings() {
      this.selectedAgents = [];
      this.$store.dispatch('agents/get');
      this.$store.dispatch('teams/get');
      this.$store.dispatch('labels/get');
      this.$store.dispatch('inboxes/get').then(() => {
        this.avatarUrl = this.inbox.avatar_url;
        this.selectedInboxName = this.inbox.name;
        this.webhookUrl = this.inbox.webhook_url;
        this.greetingEnabled = this.inbox.greeting_enabled || false;
        this.greetingMessage = this.inbox.greeting_message || '';
        this.emailCollectEnabled = this.inbox.enable_email_collect;
        this.senderNameType = this.inbox.sender_name_type;
        this.businessName = this.inbox.business_name;
        this.allowMessagesAfterResolved =
          this.inbox.allow_messages_after_resolved;
        this.continuityViaEmail = this.inbox.continuity_via_email;
        this.channelWebsiteUrl = this.inbox.website_url;
        this.channelWelcomeTitle = this.inbox.welcome_title || '';
        this.channelWelcomeTagline = this.inbox.welcome_tagline || '';
        this.selectedFeatureFlags = this.inbox.selected_feature_flags || [];
        this.replyTime = this.inbox.reply_time;
        this.locktoSingleConversation = this.inbox.lock_to_single_conversation;
        this.whatsappWebConversationPending =
          this.inbox.conversation_pending || false;
        this.whatsappWebHistoryLookbackDays =
          this.inbox.history_lookback_days || 365;
        this.whatsappWebIgnoreJids = (this.inbox.ignore_jids || []).join('\n');
        this.whatsappWebSignMessages = this.inbox.sign_messages || false;
        this.whatsappWebSignDelimiter = this.inbox.sign_delimiter || '\\n';
        this.whatsappWebImportContacts =
          this.inbox.import_contacts !== undefined
            ? this.inbox.import_contacts
            : true;
        this.whatsappWebImportMessages =
          this.inbox.import_messages !== undefined
            ? this.inbox.import_messages
            : true;
        this.whatsappWebSyncLabels =
          this.inbox.sync_labels !== undefined ? this.inbox.sync_labels : true;
        this.selectedPortalSlug = this.inbox.help_center
          ? this.inbox.help_center.slug
          : '';

        // Set initial tab after inbox data is loaded
        this.setTabFromRouteParam();
        this.syncWhatsappWebStatus();
        this.fetchWhatsappWebDiagnostics();
      });
    },
    async syncWhatsappWebStatus() {
      if (!this.isAWhatsAppWebInbox || !this.currentInboxId) {
        return;
      }

      try {
        this.isRefreshingWhatsappWebStatus = true;
        await this.$store.dispatch('inboxes/refreshWhatsappWebQr', {
          inboxId: this.currentInboxId,
          statusOnly: true,
        });
      } catch (error) {
        // Diagnostics should stay non-blocking in settings.
      } finally {
        this.isRefreshingWhatsappWebStatus = false;
      }
    },
    async fetchWhatsappWebDiagnostics() {
      if (!this.isAWhatsAppWebInbox || !this.currentInboxId) {
        this.whatsappWebDiagnostics = null;
        return;
      }

      try {
        this.isLoadingWhatsappWebDiagnostics = true;
        this.whatsappWebDiagnostics = await this.$store.dispatch(
          'inboxes/getWhatsappWebDiagnostics',
          this.currentInboxId
        );
      } catch (error) {
        this.whatsappWebDiagnostics = null;
      } finally {
        this.isLoadingWhatsappWebDiagnostics = false;
      }
    },
    async reconnectWhatsappWeb() {
      try {
        this.isRunningWhatsappWebReconnect = true;
        await this.$store.dispatch(
          'inboxes/reconnectWhatsappWeb',
          this.currentInboxId
        );
        await this.fetchWhatsappWebDiagnostics();
        useAlert(this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.RECONNECT_STARTED'));
      } catch (error) {
        useAlert(
          error.message || this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.RECONNECT_ERROR')
        );
      } finally {
        this.isRunningWhatsappWebReconnect = false;
      }
    },
    async disconnectWhatsappWeb() {
      try {
        this.isRunningWhatsappWebDisconnect = true;
        await this.$store.dispatch(
          'inboxes/disconnectWhatsappWeb',
          this.currentInboxId
        );
        await this.fetchWhatsappWebDiagnostics();
        useAlert(this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.DISCONNECT_SUCCESS'));
      } catch (error) {
        useAlert(
          error.message || this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.DISCONNECT_ERROR')
        );
      } finally {
        this.isRunningWhatsappWebDisconnect = false;
      }
    },
    async repairWhatsappWeb() {
      try {
        this.isRunningWhatsappWebRepair = true;
        await this.$store.dispatch(
          'inboxes/repairWhatsappWeb',
          this.currentInboxId
        );
        await this.fetchWhatsappWebDiagnostics();
        useAlert(this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.REPAIR_SUCCESS'));
      } catch (error) {
        useAlert(
          error.message || this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.REPAIR_ERROR')
        );
      } finally {
        this.isRunningWhatsappWebRepair = false;
      }
    },
    async refreshWhatsappWebQr() {
      try {
        this.isRefreshingWhatsappWebQr = true;
        await this.$store.dispatch('inboxes/refreshWhatsappWebQr', {
          inboxId: this.currentInboxId,
          statusOnly: false,
        });
        await this.fetchWhatsappWebDiagnostics();
        useAlert(this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.QR_REFRESH_SUCCESS'));
      } catch (error) {
        useAlert(
          error.message || this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.QR_REFRESH_ERROR')
        );
      } finally {
        this.isRefreshingWhatsappWebQr = false;
      }
    },
    async updateInbox() {
      try {
        const channelPayload = {
          widget_color: this.inbox.widget_color,
          website_url: this.channelWebsiteUrl,
          webhook_url: this.webhookUrl,
          welcome_title: this.channelWelcomeTitle || '',
          welcome_tagline: this.channelWelcomeTagline || '',
          selectedFeatureFlags: this.selectedFeatureFlags,
          reply_time: this.replyTime || 'in_a_few_minutes',
          continuity_via_email: this.continuityViaEmail,
        };

        if (this.isAWhatsAppWebInbox) {
          channelPayload.conversation_pending =
            this.whatsappWebConversationPending;
          channelPayload.history_lookback_days =
            this.normalizedWhatsappWebHistoryLookbackDays();
          channelPayload.ignore_jids = this.normalizedWhatsappWebIgnoreJids();
          channelPayload.sign_messages = this.whatsappWebSignMessages;
          channelPayload.sign_delimiter =
            this.whatsappWebSignDelimiter || '\\n';
          channelPayload.import_contacts = this.whatsappWebImportContacts;
          channelPayload.import_messages = this.whatsappWebImportMessages;
          channelPayload.sync_labels = this.whatsappWebSyncLabels;
        }

        const payload = {
          id: this.currentInboxId,
          name: this.selectedInboxName?.trim(),
          enable_email_collect: this.emailCollectEnabled,
          allow_messages_after_resolved: this.allowMessagesAfterResolved,
          greeting_enabled: this.greetingEnabled,
          greeting_message: this.greetingMessage || '',
          portal_id: this.selectedPortalSlug
            ? this.portals.find(
                portal => portal.slug === this.selectedPortalSlug
              ).id
            : null,
          lock_to_single_conversation: this.locktoSingleConversation,
          sender_name_type: this.senderNameType,
          business_name: this.businessName || null,
          channel: channelPayload,
        };
        if (this.avatarFile) {
          payload.avatar = this.avatarFile;
        }
        await this.$store.dispatch('inboxes/updateInbox', payload);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(error.message || this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    handleImageUpload({ file, url }) {
      this.avatarFile = file;
      this.avatarUrl = url;
    },
    async handleAvatarDelete() {
      try {
        await this.$store.dispatch(
          'inboxes/deleteInboxAvatar',
          this.currentInboxId
        );
        this.avatarFile = null;
        this.avatarUrl = '';
        useAlert(this.$t('INBOX_MGMT.DELETE.API.AVATAR_SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(
          error.message
            ? error.message
            : this.$t('INBOX_MGMT.DELETE.API.AVATAR_ERROR_MESSAGE')
        );
      }
    },
    toggleSenderNameType(key) {
      this.senderNameType = key;
    },
    normalizedWhatsappWebHistoryLookbackDays() {
      const value = Number(this.whatsappWebHistoryLookbackDays);

      if (!Number.isFinite(value) || value <= 0) {
        return 365;
      }

      return Math.min(Math.trunc(value), 3650);
    },
    normalizedWhatsappWebIgnoreJids() {
      return this.whatsappWebIgnoreJids
        .split(/[\n,]+/)
        .map(value => value.trim())
        .filter(Boolean);
    },
    onClickShowBusinessNameInput() {
      this.showBusinessNameInput = !this.showBusinessNameInput;
      if (this.showBusinessNameInput) {
        this.$nextTick(() => {
          this.$refs.businessNameInput.focus();
        });
      }
    },
  },
  validations: {
    webhookUrl: {
      shouldBeUrl,
    },
    selectedInboxName: {},
  },
};
</script>

<template>
  <div
    class="overflow-auto flex-grow flex-shrink pr-0 pl-0 w-full min-w-0 settings"
  >
    <SettingIntroBanner
      :header-image="inbox.avatarUrl"
      :header-title="inboxName"
    >
      <woot-tabs
        class="[&_ul]:p-0 top-px relative"
        :index="selectedTabIndex"
        :border="false"
        @change="onTabChange"
      >
        <woot-tabs-item
          v-for="(tab, index) in tabs"
          :key="tab.key"
          :index="index"
          :name="tab.name"
          :show-badge="false"
          is-compact
        />
      </woot-tabs>
    </SettingIntroBanner>
    <section class="mx-auto w-full max-w-6xl">
      <MicrosoftReauthorize v-if="microsoftUnauthorized" :inbox="inbox" />
      <FacebookReauthorize v-if="facebookUnauthorized" :inbox="inbox" />
      <GoogleReauthorize v-if="googleUnauthorized" :inbox="inbox" />
      <InstagramReauthorize v-if="instagramUnauthorized" :inbox="inbox" />
      <TiktokReauthorize v-if="tiktokUnauthorized" :inbox="inbox" />
      <WhatsappReauthorize
        v-if="whatsappUnauthorized"
        :whatsapp-registration-incomplete="whatsappRegistrationIncomplete"
        :inbox="inbox"
      />
      <DuplicateInboxBanner
        v-if="hasDuplicateInstagramInbox"
        :content="$t('INBOX_MGMT.ADD.INSTAGRAM.DUPLICATE_INBOX_BANNER')"
        class="mx-8 mt-5"
      />
      <div v-if="selectedTabKey === 'inbox-settings'" class="mx-8">
        <SettingsSection
          :title="$t('INBOX_MGMT.SETTINGS_POPUP.INBOX_UPDATE_TITLE')"
          :sub-title="$t('INBOX_MGMT.SETTINGS_POPUP.INBOX_UPDATE_SUB_TEXT')"
          :show-border="false"
        >
          <div class="flex flex-col gap-1 items-start mb-4">
            <label class="mb-0.5 text-sm font-medium text-n-slate-12">
              {{ $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_AVATAR.LABEL') }}
            </label>
            <Avatar
              :src="avatarUrl"
              :size="72"
              :icon-name="inboxIcon"
              name=""
              allow-upload
              rounded-full
              @upload="handleImageUpload"
              @delete="handleAvatarDelete"
            />
          </div>
          <woot-input
            v-model="selectedInboxName"
            class="pb-4"
            :class="{ error: v$.selectedInboxName.$error }"
            :label="inboxNameLabel"
            :placeholder="inboxNamePlaceHolder"
            :error="
              v$.selectedInboxName.$error
                ? $t('INBOX_MGMT.ADD.CHANNEL_NAME.ERROR')
                : ''
            "
            @blur="v$.selectedInboxName.$touch"
          />
          <woot-input
            v-if="isAPIInbox && channelType !== 'Channel::WhatsappWeb'"
            v-model="webhookUrl"
            class="pb-4"
            :class="{ error: v$.webhookUrl.$error }"
            :label="
              $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WEBHOOK_URL.LABEL')
            "
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WEBHOOK_URL.PLACEHOLDER'
              )
            "
            :error="
              v$.webhookUrl.$error
                ? $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WEBHOOK_URL.ERROR')
                : ''
            "
            @blur="v$.webhookUrl.$touch"
          />
          <woot-input
            v-if="isAWebWidgetInbox"
            v-model="channelWebsiteUrl"
            class="pb-4"
            :label="$t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_DOMAIN.LABEL')"
            :placeholder="
              $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_DOMAIN.PLACEHOLDER')
            "
          />
          <woot-input
            v-if="isAWebWidgetInbox"
            v-model="channelWelcomeTitle"
            class="pb-4"
            :label="
              $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TITLE.LABEL')
            "
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TITLE.PLACEHOLDER'
              )
            "
          />

          <Editor
            v-if="isAWebWidgetInbox"
            v-model="channelWelcomeTagline"
            class="mb-4"
            :label="
              $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TAGLINE.LABEL')
            "
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TAGLINE.PLACEHOLDER'
              )
            "
            :max-length="255"
            channel-type="Context::InboxSettings"
          />

          <label v-if="isAWebWidgetInbox" class="pb-4">
            {{ $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.WIDGET_COLOR.LABEL') }}
            <woot-color-picker v-model="inbox.widget_color" />
          </label>

          <label v-if="isAWhatsAppChannel" class="pb-4">
            {{ $t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.LABEL') }}
            <input v-model="whatsAppAPIProviderName" type="text" disabled />
          </label>

          <label class="pb-4">
            {{
              $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_TOGGLE.LABEL')
            }}
            <InboxSelect v-model="greetingEnabled">
              <option :value="true">
                {{
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_TOGGLE.ENABLED'
                  )
                }}
              </option>
              <option :value="false">
                {{
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_TOGGLE.DISABLED'
                  )
                }}
              </option>
            </InboxSelect>
            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{
                $t(
                  'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_TOGGLE.HELP_TEXT'
                )
              }}
            </p>
          </label>
          <div v-if="greetingEnabled" class="pb-4">
            <GreetingsEditor
              v-model="greetingMessage"
              :label="
                $t(
                  'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_MESSAGE.LABEL'
                )
              "
              :placeholder="
                $t(
                  'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_MESSAGE.PLACEHOLDER'
                )
              "
              :richtext="!textAreaChannels"
            />
          </div>
          <label v-if="isAWebWidgetInbox" class="pb-4">
            {{ $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.TITLE') }}
            <InboxSelect v-model="replyTime">
              <option key="in_a_few_minutes" value="in_a_few_minutes">
                {{
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.IN_A_FEW_MINUTES'
                  )
                }}
              </option>
              <option key="in_a_few_hours" value="in_a_few_hours">
                {{
                  $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.IN_A_FEW_HOURS')
                }}
              </option>
              <option key="in_a_day" value="in_a_day">
                {{ $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.IN_A_DAY') }}
              </option>
            </InboxSelect>

            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{ $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.HELP_TEXT') }}
            </p>
          </label>

          <label v-if="isAWebWidgetInbox" class="pb-4">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.ENABLE_EMAIL_COLLECT_BOX') }}
            <InboxSelect v-model="emailCollectEnabled">
              <option :value="true">
                {{ $t('INBOX_MGMT.EDIT.EMAIL_COLLECT_BOX.ENABLED') }}
              </option>
              <option :value="false">
                {{ $t('INBOX_MGMT.EDIT.EMAIL_COLLECT_BOX.DISABLED') }}
              </option>
            </InboxSelect>
            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{
                $t(
                  'INBOX_MGMT.SETTINGS_POPUP.ENABLE_EMAIL_COLLECT_BOX_SUB_TEXT'
                )
              }}
            </p>
          </label>

          <label v-if="isAWebWidgetInbox" class="pb-4">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.ALLOW_MESSAGES_AFTER_RESOLVED') }}
            <InboxSelect v-model="allowMessagesAfterResolved">
              <option :value="true">
                {{
                  $t('INBOX_MGMT.EDIT.ALLOW_MESSAGES_AFTER_RESOLVED.ENABLED')
                }}
              </option>
              <option :value="false">
                {{
                  $t('INBOX_MGMT.EDIT.ALLOW_MESSAGES_AFTER_RESOLVED.DISABLED')
                }}
              </option>
            </InboxSelect>
            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{
                $t(
                  'INBOX_MGMT.SETTINGS_POPUP.ALLOW_MESSAGES_AFTER_RESOLVED_SUB_TEXT'
                )
              }}
            </p>
          </label>

          <label v-if="isAWebWidgetInbox" class="pb-4">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.ENABLE_CONTINUITY_VIA_EMAIL') }}
            <InboxSelect v-model="continuityViaEmail">
              <option :value="true">
                {{ $t('INBOX_MGMT.EDIT.ENABLE_CONTINUITY_VIA_EMAIL.ENABLED') }}
              </option>
              <option :value="false">
                {{ $t('INBOX_MGMT.EDIT.ENABLE_CONTINUITY_VIA_EMAIL.DISABLED') }}
              </option>
            </InboxSelect>
            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{
                $t(
                  'INBOX_MGMT.SETTINGS_POPUP.ENABLE_CONTINUITY_VIA_EMAIL_SUB_TEXT'
                )
              }}
            </p>
          </label>
          <div v-if="!isAVoiceChannel" class="pb-4">
            <label>
              {{ $t('INBOX_MGMT.HELP_CENTER.LABEL') }}
            </label>
            <InboxSelect v-model="selectedPortalSlug" class="filter__question">
              <option value="">
                {{ $t('INBOX_MGMT.HELP_CENTER.PLACEHOLDER') }}
              </option>
              <option v-for="p in portals" :key="p.slug" :value="p.slug">
                {{ p.name }}
              </option>
            </InboxSelect>
            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{ $t('INBOX_MGMT.HELP_CENTER.SUB_TEXT') }}
            </p>
          </div>
          <label v-if="canLocktoSingleConversation" class="pb-4">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.LOCK_TO_SINGLE_CONVERSATION') }}
            <InboxSelect v-model="locktoSingleConversation">
              <option :value="true">
                {{ $t('INBOX_MGMT.EDIT.LOCK_TO_SINGLE_CONVERSATION.ENABLED') }}
              </option>
              <option :value="false">
                {{ $t('INBOX_MGMT.EDIT.LOCK_TO_SINGLE_CONVERSATION.DISABLED') }}
              </option>
            </InboxSelect>
            <p class="pb-1 text-sm not-italic text-n-slate-11">
              {{
                $t(
                  'INBOX_MGMT.SETTINGS_POPUP.LOCK_TO_SINGLE_CONVERSATION_SUB_TEXT'
                )
              }}
            </p>
          </label>

          <label v-if="isAWebWidgetInbox">
            {{ $t('INBOX_MGMT.FEATURES.LABEL') }}
          </label>
          <div v-if="isAWebWidgetInbox" class="flex gap-2 pt-2 pb-4">
            <Checkbox
              id="attachments"
              v-model="selectedFeatureFlags"
              value="attachments"
              @change="handleFeatureFlag"
            />
            <label for="attachments">
              {{ $t('INBOX_MGMT.FEATURES.DISPLAY_FILE_PICKER') }}
            </label>
          </div>
          <div v-if="isAWebWidgetInbox" class="flex gap-2 pb-4">
            <Checkbox
              id="emoji_picker"
              v-model="selectedFeatureFlags"
              value="emoji_picker"
              @change="handleFeatureFlag"
            />
            <label for="emoji_picker">
              {{ $t('INBOX_MGMT.FEATURES.DISPLAY_EMOJI_PICKER') }}
            </label>
          </div>
          <div v-if="isAWebWidgetInbox" class="flex gap-2 pb-4">
            <Checkbox
              id="end_conversation"
              v-model="selectedFeatureFlags"
              value="end_conversation"
              @change="handleFeatureFlag"
            />
            <label for="end_conversation">
              {{ $t('INBOX_MGMT.FEATURES.ALLOW_END_CONVERSATION') }}
            </label>
          </div>
          <div v-if="isAWebWidgetInbox" class="flex gap-2 pb-4">
            <Checkbox
              id="use_inbox_avatar_for_bot"
              v-model="selectedFeatureFlags"
              value="use_inbox_avatar_for_bot"
              @change="handleFeatureFlag"
            />
            <label for="use_inbox_avatar_for_bot">
              {{ $t('INBOX_MGMT.FEATURES.USE_INBOX_AVATAR_FOR_BOT') }}
            </label>
          </div>
        </SettingsSection>
        <SettingsSection
          v-if="shouldShowWhatsappWebLifecycleSection"
          :title="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.TITLE')"
          :sub-title="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SUBTITLE')"
          :show-border="false"
        >
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <div class="rounded-xl border border-n-strong p-4">
              <p class="mb-3 text-sm font-medium text-n-slate-12">
                {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.CONNECTION_STATE') }}
              </p>
              <div class="space-y-2 text-sm text-n-slate-11">
                <p>
                  <span class="font-medium text-n-slate-12">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.STATUS')
                  }}</span>
                  {{ whatsappWebEvolutionState.status || 'unknown' }}
                </p>
                <p>
                  <span class="font-medium text-n-slate-12">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.CONNECTION')
                  }}</span>
                  {{ whatsappWebEvolutionState.connection_state || 'unknown' }}
                </p>
                <p>
                  <span class="font-medium text-n-slate-12">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.INSTANCE')
                  }}</span>
                  {{
                    whatsappWebEvolutionState.instance_name ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
                <p>
                  <span class="font-medium text-n-slate-12">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NUMBER')
                  }}</span>
                  {{
                    whatsappWebEvolutionState.number ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
                <p>
                  <span class="font-medium text-n-slate-12">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.LAST_SYNCED')
                  }}</span>
                  {{
                    whatsappWebEvolutionState.last_synced_at ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
                <p>
                  <span class="font-medium text-n-slate-12">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SERVICE_USER')
                  }}</span>
                  {{
                    whatsappWebEvolutionState.service_user?.email ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
                <p v-if="whatsappWebEvolutionState.last_error">
                  <span class="font-medium text-rose-600">{{
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.LAST_ERROR')
                  }}</span>
                  {{ whatsappWebEvolutionState.last_error }}
                </p>
              </div>
            </div>

            <div class="rounded-xl border border-n-strong p-4">
              <p class="mb-3 text-sm font-medium text-n-slate-12">
                {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.OPERATOR_ACTIONS') }}
              </p>
              <div class="flex flex-wrap gap-2">
                <NextButton
                  outline
                  slate
                  :label="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.RECONNECT')"
                  :is-loading="isRunningWhatsappWebReconnect"
                  @click="reconnectWhatsappWeb"
                />
                <NextButton
                  outline
                  slate
                  :label="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.REFRESH_QR')"
                  :is-loading="isRefreshingWhatsappWebQr"
                  @click="refreshWhatsappWebQr"
                />
                <NextButton
                  outline
                  slate
                  :label="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.DISCONNECT')"
                  :is-loading="isRunningWhatsappWebDisconnect"
                  @click="disconnectWhatsappWeb"
                />
                <NextButton
                  outline
                  slate
                  :label="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.REPAIR_SYNC')"
                  :is-loading="isRunningWhatsappWebRepair"
                  @click="repairWhatsappWeb"
                />
              </div>
              <p class="mt-3 text-sm text-n-slate-10">
                {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.AUTO_SYNC_HINT') }}
              </p>
            </div>
          </div>

          <div class="mt-4 rounded-xl border border-n-strong p-4">
            <p class="mb-3 text-sm font-medium text-n-slate-12">
              {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NATIVE_SETTINGS') }}
            </p>
            <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
              <div class="space-y-4">
                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{
                      $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.CONVERSATION_PENDING')
                    }}
                  </span>
                  <InboxSelect v-model="whatsappWebConversationPending">
                    <option :value="true">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_ENABLED') }}
                    </option>
                    <option :value="false">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_DISABLED') }}
                    </option>
                  </InboxSelect>
                  <p class="mt-1 text-sm text-n-slate-10">
                    {{
                      $t(
                        'INBOX_MGMT.EDIT.WHATSAPP_WEB.CONVERSATION_PENDING_HINT'
                      )
                    }}
                  </p>
                </label>

                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{
                      $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.HISTORY_LOOKBACK_DAYS')
                    }}
                  </span>
                  <input
                    v-model="whatsappWebHistoryLookbackDays"
                    class="mb-0"
                    type="number"
                    min="1"
                    max="3650"
                  />
                  <p class="mt-1 text-sm text-n-slate-10">
                    {{
                      $t(
                        'INBOX_MGMT.EDIT.WHATSAPP_WEB.HISTORY_LOOKBACK_DAYS_HINT'
                      )
                    }}
                  </p>
                </label>

                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IGNORE_JIDS') }}
                  </span>
                  <textarea
                    v-model="whatsappWebIgnoreJids"
                    class="mb-0 min-h-[112px] w-full resize-y"
                    :placeholder="whatsappWebIgnoreJidsPlaceholder"
                  />
                  <p class="mt-1 text-sm text-n-slate-10">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IGNORE_JIDS_HINT') }}
                  </p>
                </label>
              </div>

              <div class="space-y-4">
                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IMPORT_CONTACTS') }}
                  </span>
                  <InboxSelect v-model="whatsappWebImportContacts">
                    <option :value="true">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_ENABLED') }}
                    </option>
                    <option :value="false">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_DISABLED') }}
                    </option>
                  </InboxSelect>
                </label>

                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IMPORT_MESSAGES') }}
                  </span>
                  <InboxSelect v-model="whatsappWebImportMessages">
                    <option :value="true">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_ENABLED') }}
                    </option>
                    <option :value="false">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_DISABLED') }}
                    </option>
                  </InboxSelect>
                </label>

                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SYNC_LABELS') }}
                  </span>
                  <InboxSelect v-model="whatsappWebSyncLabels">
                    <option :value="true">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_ENABLED') }}
                    </option>
                    <option :value="false">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_DISABLED') }}
                    </option>
                  </InboxSelect>
                </label>

                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_MESSAGES') }}
                  </span>
                  <InboxSelect v-model="whatsappWebSignMessages">
                    <option :value="true">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_ENABLED') }}
                    </option>
                    <option :value="false">
                      {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_DISABLED') }}
                    </option>
                  </InboxSelect>
                </label>

                <label class="block">
                  <span class="mb-1 block text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_DELIMITER') }}
                  </span>
                  <input
                    v-model="whatsappWebSignDelimiter"
                    class="mb-0"
                    type="text"
                    :placeholder="
                      $t(
                        'INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_DELIMITER_PLACEHOLDER'
                      )
                    "
                  />
                  <p class="mt-1 text-sm text-n-slate-10">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_DELIMITER_HINT') }}
                  </p>
                </label>
              </div>
            </div>
          </div>

          <div class="mt-4 rounded-xl border border-n-strong p-4">
            <div class="flex items-center justify-between gap-3">
              <p class="text-sm font-medium text-n-slate-12">
                {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.DIAGNOSTICS') }}
              </p>
              <span
                v-if="
                  isLoadingWhatsappWebDiagnostics ||
                  isRefreshingWhatsappWebStatus
                "
                class="text-sm text-n-slate-10"
              >
                {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.REFRESHING') }}
              </span>
            </div>
            <div class="mt-3 grid grid-cols-1 gap-3 md:grid-cols-3">
              <div class="rounded-lg bg-n-alpha-2 p-3">
                <p class="text-xs uppercase tracking-wide text-n-slate-10">
                  {{
                    $t(
                      'INBOX_MGMT.EDIT.WHATSAPP_WEB.MISSING_PROVIDER_MESSAGE_ID'
                    )
                  }}
                </p>
                <p class="mt-1 text-lg font-semibold text-n-slate-12">
                  {{
                    whatsappWebDiagnosticsCounts.messages_missing_provider_message_id ??
                    0
                  }}
                </p>
              </div>
              <div class="rounded-lg bg-n-alpha-2 p-3">
                <p class="text-xs uppercase tracking-wide text-n-slate-10">
                  {{
                    $t(
                      'INBOX_MGMT.EDIT.WHATSAPP_WEB.MISSING_PROVIDER_CONVERSATION_ID'
                    )
                  }}
                </p>
                <p class="mt-1 text-lg font-semibold text-n-slate-12">
                  {{
                    whatsappWebDiagnosticsCounts.conversations_missing_provider_conversation_id ??
                    0
                  }}
                </p>
              </div>
              <div class="rounded-lg bg-n-alpha-2 p-3">
                <p class="text-xs uppercase tracking-wide text-n-slate-10">
                  {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.PROVISIONAL_CONTACTS') }}
                </p>
                <p class="mt-1 text-lg font-semibold text-n-slate-12">
                  {{ whatsappWebDiagnosticsCounts.provisional_contacts ?? 0 }}
                </p>
              </div>
            </div>

            <div
              v-if="
                whatsappWebDiagnostics?.samples?.provisional_contacts?.length
              "
              class="mt-4"
            >
              <p class="mb-2 text-sm font-medium text-n-slate-12">
                {{
                  $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.PROVISIONAL_CONTACTS_SAMPLE')
                }}
              </p>
              <div
                v-for="contact in whatsappWebDiagnostics.samples
                  .provisional_contacts"
                :key="contact.id"
                class="mb-2 rounded-lg border border-n-strong p-3 text-sm text-n-slate-11"
              >
                <p class="font-medium text-n-slate-12">
                  {{ contact.name || `Contact #${contact.id}` }}
                </p>
                <p>
                  {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.RAW_JID') }}
                  {{
                    contact.raw_jid ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
                <p>
                  {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.CANONICAL_JID') }}
                  {{
                    contact.canonical_jid ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
                <p>
                  {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IDENTIFIER') }}
                  {{
                    contact.identifier ||
                    $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NOT_AVAILABLE')
                  }}
                </p>
              </div>
            </div>
          </div>
        </SettingsSection>
        <SettingsSection
          v-if="isAWebWidgetInbox || isAnEmailChannel"
          :title="$t('INBOX_MGMT.EDIT.SENDER_NAME_SECTION.TITLE')"
          :sub-title="$t('INBOX_MGMT.EDIT.SENDER_NAME_SECTION.SUB_TEXT')"
          :show-border="false"
        >
          <div class="pb-4">
            <SenderNameExamplePreview
              :sender-name-type="senderNameType"
              :business-name="businessName"
              @update="toggleSenderNameType"
            />
            <div class="flex flex-col gap-2 items-start mt-2">
              <NextButton
                ghost
                blue
                :label="
                  $t(
                    'INBOX_MGMT.EDIT.SENDER_NAME_SECTION.BUSINESS_NAME.BUTTON_TEXT'
                  )
                "
                @click="onClickShowBusinessNameInput"
              />
              <div v-if="showBusinessNameInput" class="flex gap-2 w-[80%]">
                <input
                  ref="businessNameInput"
                  v-model="businessName"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.EDIT.SENDER_NAME_SECTION.BUSINESS_NAME.PLACEHOLDER'
                    )
                  "
                  class="mb-0"
                  type="text"
                />
                <NextButton
                  :label="
                    $t(
                      'INBOX_MGMT.EDIT.SENDER_NAME_SECTION.BUSINESS_NAME.SAVE_BUTTON_TEXT'
                    )
                  "
                  class="flex-shrink-0"
                  @click="updateInbox"
                />
              </div>
            </div>
          </div>
        </SettingsSection>
        <SettingsSection :show-border="false">
          <NextButton
            v-if="isAPIInbox"
            type="submit"
            :disabled="v$.webhookUrl.$invalid"
            :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
            :is-loading="uiFlags.isUpdating"
            @click="updateInbox"
          />
          <NextButton
            v-else
            type="submit"
            :disabled="v$.$invalid"
            :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
            :is-loading="uiFlags.isUpdating"
            @click="updateInbox"
          />
        </SettingsSection>
      </div>

      <div v-if="selectedTabKey === 'collaborators'" class="mx-8">
        <CollaboratorsPage :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'configuration'">
        <ConfigurationPage :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'csat'">
        <CustomerSatisfactionPage :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'pre-chat-form'">
        <PreChatFormSettings :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'business-hours'">
        <WeeklyAvailability :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'widget-builder'">
        <WidgetBuilder :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'bot-configuration'">
        <BotConfiguration :inbox="inbox" />
      </div>
      <div v-if="selectedTabKey === 'whatsapp-health'">
        <AccountHealth :health-data="healthData" />
      </div>
    </section>
  </div>
</template>
