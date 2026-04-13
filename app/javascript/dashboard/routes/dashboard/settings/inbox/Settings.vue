<script>
import { mapGetters } from 'vuex';
import { shouldBeUrl } from 'shared/helpers/Validators';
import { useAlert } from 'dashboard/composables';
import { useVuelidate } from '@vuelidate/core';
import QRCode from 'qrcode';
import Avatar from 'next/avatar/Avatar.vue';
import SettingIntroBanner from 'dashboard/components/widgets/SettingIntroBanner.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsAccordion from 'dashboard/components-next/Settings/SettingsAccordion.vue';
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
import WhatsAppTemplatesPage from './settingsPage/WhatsAppTemplatesPage.vue';
import BotConfiguration from './components/BotConfiguration.vue';
import AccountHealth from './components/AccountHealth.vue';
import WebsiteTriggerCampaigns from './components/WebsiteTriggerCampaigns.vue';
import { FEATURE_FLAGS } from '../../../../featureFlags';
import SenderNameExamplePreview from './components/SenderNameExamplePreview.vue';
import LockToSingleConversationPreview from './components/LockToSingleConversationPreview.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import SpinnerLoader from 'dashboard/components-next/spinner/Spinner.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { getInboxIconByType } from 'dashboard/helper/inbox';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import { LocalStorage } from 'shared/helpers/localStorage';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import ColorPicker from 'dashboard/components-next/colorpicker/ColorPicker.vue';
import SelectInput from 'dashboard/components-next/select/Select.vue';
import Widget from 'dashboard/modules/widget-preview/components/Widget.vue';
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';

const WHATSAPP_WEB_IGNORE_JIDS_EXAMPLE =
  '15550001111@s.whatsapp.net\\n15550002222@s.whatsapp.net';
const TELEGRAM_PERSONAL_POLL_INTERVAL_MS = 5000;

export default {
  components: {
    BotConfiguration,
    CollaboratorsPage,
    ConfigurationPage,
    CustomerSatisfactionPage,
    FacebookReauthorize,
    GreetingsEditor,
    WhatsAppTemplatesPage,
    PreChatFormSettings,
    SettingIntroBanner,
    SettingsToggleSection,
    SettingsFieldSection,
    SettingsAccordion,
    WeeklyAvailability,
    SenderNameExamplePreview,
    LockToSingleConversationPreview,
    MicrosoftReauthorize,
    GoogleReauthorize,
    NextButton,
    SpinnerLoader,
    Icon,
    InstagramReauthorize,
    TiktokReauthorize,
    WhatsappReauthorize,
    DuplicateInboxBanner,
    Editor,
    Avatar,
    ColorPicker,
    SelectInput,
    AccountHealth,
    WebsiteTriggerCampaigns,
    Widget,
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
      isRegisteringWebhook: false,
      widgetBubblePosition: 'right',
      widgetBubbleType: 'standard',
      widgetBubbleLauncherTitle: '',
      whatsappWebDiagnostics: null,
      isLoadingWhatsappWebDiagnostics: false,
      isRefreshingWhatsappWebStatus: false,
      isRunningWhatsappWebReconnect: false,
      isRunningWhatsappWebDisconnect: false,
      isRunningWhatsappWebRepair: false,
      isRefreshingWhatsappWebQr: false,
      telegramPersonalDiagnostics: null,
      isLoadingTelegramPersonalDiagnostics: false,
      isRunningTelegramPersonalRequestCode: false,
      isRunningTelegramPersonalRequestQr: false,
      isRunningTelegramPersonalVerifyCode: false,
      isRunningTelegramPersonalVerifyPassword: false,
      isRunningTelegramPersonalReconnect: false,
      isRunningTelegramPersonalHistorySync: false,
      isRunningTelegramPersonalFullHistorySync: false,
      isRunningTelegramPersonalContactsSync: false,
      isRunningTelegramPersonalDisconnect: false,
      telegramPersonalCode: '',
      telegramPersonalPassword: '',
      telegramPersonalQrCode: '',
      telegramPersonalPollingInterval: null,
      isTelegramPersonalRawDiagnosticsVisible: false,
      isRedirectingMissingInbox: false,
      whatsappWebConversationPending: false,
      whatsappWebHistoryLookbackDays: 0,
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
    whatsappWebQrCode() {
      return this.whatsappWebEvolutionState.qrcode?.base64 || '';
    },
    whatsappWebPairingCode() {
      return (
        this.whatsappWebEvolutionState.qrcode?.pairing_code ||
        this.whatsappWebEvolutionState.qrcode?.pairingCode ||
        ''
      );
    },
    formattedWhatsappWebPairingCode() {
      const sanitizedCode = this.whatsappWebPairingCode.replace(/\W/g, '');

      if (!sanitizedCode) {
        return '';
      }

      if (sanitizedCode.length <= 4) {
        return sanitizedCode;
      }

      return `${sanitizedCode.slice(0, 4)}-${sanitizedCode.slice(4)}`;
    },
    shouldShowWhatsappWebQrPreview() {
      return Boolean(
        this.isAWhatsAppWebInbox &&
          this.whatsappWebEvolutionState.status !== 'connected' &&
          (this.whatsappWebQrCode || this.formattedWhatsappWebPairingCode)
      );
    },
    shouldShowWhatsappWebLifecycleSection() {
      return this.isAWhatsAppWebInbox;
    },
    isWhatsappWebDeleting() {
      return isInboxPendingDeletion(this.inbox);
    },
    shouldShowTelegramPersonalLifecycleSection() {
      return this.isATelegramPersonalChannel;
    },
    shouldShowVkCommunityDetailsSection() {
      return this.isAVkCommunityChannel;
    },
    telegramPersonalRuntimeState() {
      return this.inbox?.runtime_state || {};
    },
    telegramPersonalLifecycleState() {
      return (
        this.inbox?.lifecycle_state ||
        this.telegramPersonalRuntimeState.lifecycle_state ||
        'pending_auth'
      );
    },
    telegramPersonalConnectionState() {
      return (
        this.inbox?.connection_state ||
        this.telegramPersonalRuntimeState.connection_state ||
        'disconnected'
      );
    },
    telegramPersonalLastError() {
      return (
        this.inbox?.last_error ||
        this.telegramPersonalDiagnostics?.last_error ||
        this.telegramPersonalRuntimeState.last_error ||
        ''
      );
    },
    isTelegramPersonalConnected() {
      return (
        this.telegramPersonalLifecycleState === 'connected' ||
        this.telegramPersonalDiagnostics?.auth_state === 'authorized' ||
        this.telegramPersonalRuntimeState.auth_state === 'authorized'
      );
    },
    isTelegramPersonalPasswordRequired() {
      return this.telegramPersonalLifecycleState === 'password_required';
    },
    telegramPersonalCodeStepReady() {
      return ['code_sent', 'password_required', 'connected'].includes(
        this.telegramPersonalLifecycleState
      );
    },
    shouldShowTelegramPersonalCodeRequest() {
      return (
        !this.isTelegramPersonalConnected &&
        !this.isTelegramPersonalPasswordRequired &&
        !this.telegramPersonalCodeStepReady
      );
    },
    shouldShowTelegramPersonalCodeVerify() {
      return (
        !this.isTelegramPersonalConnected &&
        !this.isTelegramPersonalPasswordRequired &&
        this.telegramPersonalCodeStepReady
      );
    },
    telegramPersonalQrUrl() {
      return this.telegramPersonalRuntimeState.qr_login_url || '';
    },
    telegramPersonalQrExpiresAt() {
      return this.telegramPersonalRuntimeState.qr_login_expires_at || '';
    },
    telegramPersonalQrButtonLabel() {
      return ['qr_ready', 'qr_expired'].includes(
        this.telegramPersonalLifecycleState
      )
        ? this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REFRESH_QR')
        : this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REQUEST_QR');
    },
    telegramPersonalAuthState() {
      return (
        this.telegramPersonalDiagnostics?.auth_state ||
        this.telegramPersonalRuntimeState.auth_state ||
        this.telegramPersonalLifecycleState
      );
    },
    telegramPersonalHistorySyncState() {
      return (
        this.telegramPersonalDiagnostics?.history_sync_state ||
        this.telegramPersonalRuntimeState.history_sync_state ||
        ''
      );
    },
    telegramPersonalLastHistorySyncAt() {
      return (
        this.telegramPersonalDiagnostics?.last_history_sync_at ||
        this.telegramPersonalRuntimeState.last_history_sync_at ||
        ''
      );
    },
    telegramPersonalHistorySyncCount() {
      return (
        this.telegramPersonalDiagnostics?.history_sync_count ??
        this.telegramPersonalRuntimeState.history_sync_count ??
        0
      );
    },
    telegramPersonalContactsSyncState() {
      return (
        this.telegramPersonalDiagnostics?.contacts_sync_state ||
        this.telegramPersonalRuntimeState.contacts_sync_state ||
        ''
      );
    },
    telegramPersonalLastContactsSyncAt() {
      return (
        this.telegramPersonalDiagnostics?.last_contacts_sync_at ||
        this.telegramPersonalRuntimeState.last_contacts_sync_at ||
        ''
      );
    },
    telegramPersonalContactsSyncCount() {
      return (
        this.telegramPersonalDiagnostics?.contacts_sync_count ??
        this.telegramPersonalRuntimeState.contacts_sync_count ??
        0
      );
    },
    telegramPersonalLastInboundAt() {
      return (
        this.telegramPersonalDiagnostics?.last_inbound_at ||
        this.telegramPersonalRuntimeState.last_inbound_at ||
        ''
      );
    },
    telegramPersonalFloodWaitSeconds() {
      return this.telegramPersonalDiagnostics?.flood_wait_seconds;
    },
    telegramPersonalDiagnosticsJson() {
      return this.telegramPersonalDiagnostics
        ? JSON.stringify(this.telegramPersonalDiagnostics, null, 2)
        : '';
    },
    telegramPersonalIntlLocale() {
      const rawLocale = this.$root?.$i18n?.locale || this.$i18n?.locale || 'en';
      const normalizedLocale = String(rawLocale).replace(/_/g, '-');

      if (Intl.DateTimeFormat.supportedLocalesOf([normalizedLocale]).length) {
        return normalizedLocale;
      }

      const baseLocale = normalizedLocale.split('-')[0];
      if (Intl.DateTimeFormat.supportedLocalesOf([baseLocale]).length) {
        return baseLocale;
      }

      return 'en';
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
            key: 'whatsapp-templates',
            name: this.$t('INBOX_MGMT.TABS.WHATSAPP_TEMPLATES'),
          },
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
      return getInboxIconByType(type, medium, 'line');
    },
    bannerMaxWidth() {
      const narrowTabs = ['collaborators', 'bot-configuration'];
      const wideIfWebWidget = ['configuration', 'inbox-settings'];
      if (narrowTabs.includes(this.selectedTabKey)) return 'max-w-4xl';
      if (wideIfWebWidget.includes(this.selectedTabKey)) {
        return this.isAWebWidgetInbox ? 'max-w-7xl' : 'max-w-4xl';
      }
      return 'max-w-7xl';
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
        this.isAnInstagramChannel ||
        this.isALineChannel ||
        this.isATiktokChannel ||
        this.isATelegramChannel ||
        this.isATelegramPersonalChannel ||
        this.isAVkCommunityChannel
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
    widgetBuilderStorageKey() {
      return `${LOCAL_STORAGE_KEYS.WIDGET_BUILDER}${this.inbox.id}`;
    },
    whatsappWebDiagnosticsCounts() {
      return this.whatsappWebDiagnostics?.counts || {};
    },
    whatsappWebIgnoreJidsPlaceholder() {
      return this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IGNORE_JIDS_PLACEHOLDER', {
        sample_jids: WHATSAPP_WEB_IGNORE_JIDS_EXAMPLE,
      });
    },
    enabledDisabledOptions() {
      return [
        {
          value: true,
          label: this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_ENABLED'),
        },
        {
          value: false,
          label: this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SETTING_DISABLED'),
        },
      ];
    },
  },
  watch: {
    $route(to, from) {
      if (to.name === 'settings_inbox_show') {
        const inboxChanged = to.params.inboxId !== from.params.inboxId;
        if (inboxChanged) {
          this.syncInboxData();
          this.setTabFromRouteParam();
          if (this.isAWhatsAppWebInbox) {
            this.syncWhatsappWebStatus();
            this.fetchWhatsappWebDiagnostics();
          }
          if (this.isATelegramPersonalChannel) {
            this.fetchTelegramPersonalDiagnostics();
          }
        }
      }
    },
    inbox: {
      async handler(newInbox, oldInbox) {
        if (this.currentInboxId && !newInbox?.id) {
          await this.redirectToInboxListIfMissing();
          return;
        }

        if (newInbox?.id !== oldInbox?.id) {
          this.syncInboxData();
          this.fetchHealthData();
          this.$nextTick(() => {
            this.setTabFromRouteParam();
            if (this.isAWhatsAppWebInbox) {
              this.syncWhatsappWebStatus();
              this.fetchWhatsappWebDiagnostics();
            }
            if (this.isATelegramPersonalChannel) {
              this.fetchTelegramPersonalDiagnostics();
            }
          });
        } else {
          this.selectedFeatureFlags = newInbox?.selected_feature_flags || [];
        }
      },
      immediate: true,
    },
    telegramPersonalQrUrl: {
      handler() {
        this.renderTelegramPersonalQrCode();
      },
      immediate: true,
    },
    isTelegramPersonalConnected: {
      handler() {
        this.syncTelegramPersonalPolling();
      },
      immediate: true,
    },
  },
  mounted() {
    this.fetchSharedData();
    this.syncTelegramPersonalPolling();
  },
  beforeUnmount() {
    this.stopTelegramPersonalPolling();
  },
  methods: {
    async ensureCurrentInboxExists() {
      if (!this.currentInboxId) {
        return false;
      }

      if (this.inbox?.id) {
        return true;
      }

      try {
        await this.$store.dispatch('inboxes/get');
      } catch (error) {
        return null;
      }

      return Boolean(
        this.$store.getters['inboxes/getInbox'](this.currentInboxId)?.id
      );
    },
    async redirectToInboxListIfMissing() {
      if (
        !this.currentInboxId ||
        this.isRedirectingMissingInbox ||
        this.$route.name !== 'settings_inbox_show'
      ) {
        return;
      }

      const inboxExists = await this.ensureCurrentInboxExists();
      if (inboxExists !== false) {
        return;
      }

      this.isRedirectingMissingInbox = true;
      this.stopTelegramPersonalPolling();
      this.$router.replace({
        name: 'settings_inbox_list',
        params: { accountId: this.$route.params.accountId },
      });
    },
    fetchSharedData() {
      this.$store.dispatch('agents/get');
      this.$store.dispatch('teams/get');
      this.$store.dispatch('labels/get');
      this.$store.dispatch('portals/index');
    },
    syncInboxData() {
      if (!this.inbox || !this.inbox.id) return;

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
      this.channelWelcomeTitle = this.inbox.welcome_title;
      this.channelWelcomeTagline = this.inbox.welcome_tagline || '';
      this.selectedFeatureFlags = this.inbox.selected_feature_flags || [];
      this.replyTime = this.inbox.reply_time;
      this.locktoSingleConversation = this.inbox.lock_to_single_conversation;
      this.whatsappWebConversationPending =
        this.inbox.conversation_pending || false;
      this.whatsappWebHistoryLookbackDays =
        this.inbox.history_lookback_days ?? 0;
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

      const savedBubbleSettings = LocalStorage.get(
        this.widgetBuilderStorageKey
      );
      if (savedBubbleSettings) {
        this.widgetBubblePosition = savedBubbleSettings.position || 'right';
        this.widgetBubbleType = savedBubbleSettings.type || 'standard';
        this.widgetBubbleLauncherTitle =
          savedBubbleSettings.launcherTitle || '';
      } else {
        this.widgetBubblePosition = 'right';
        this.widgetBubbleType = 'standard';
        this.widgetBubbleLauncherTitle = '';
      }
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
    async registerWebhook() {
      if (!this.inbox) return;

      try {
        this.isRegisteringWebhook = true;
        await InboxHealthAPI.registerWebhook(this.inbox.id);
        useAlert(this.$t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.REGISTER_SUCCESS'));
        await this.fetchHealthData();
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.REGISTER_ERROR')
        );
      } finally {
        this.isRegisteringWebhook = false;
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
      if (
        this.inbox &&
        ['inbox-settings', 'widget-builder'].includes(this.tabs[index]?.key)
      ) {
        this.avatarUrl = this.inbox.avatar_url;
      }
    },
    onTabChange(selectedTabIndex) {
      this.selectedTabIndex = selectedTabIndex;
      this.refreshAvatarUrlOnTabChange(selectedTabIndex);
      this.updateRouteWithoutRefresh(selectedTabIndex);
      if (this.tabs[selectedTabIndex]?.key === 'inbox-settings') {
        this.syncWhatsappWebStatus();
        this.fetchWhatsappWebDiagnostics();
        this.fetchTelegramPersonalDiagnostics();
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
      if (!tabParam) {
        this.selectedTabIndex = 0;
        return;
      }
      const tabIndex = this.tabs.findIndex(tab => tab.key === tabParam);
      this.selectedTabIndex = tabIndex === -1 ? 0 : tabIndex;
    },
    async syncWhatsappWebStatus() {
      if (
        !this.isAWhatsAppWebInbox ||
        !this.currentInboxId ||
        this.isWhatsappWebDeleting
      ) {
        return;
      }

      try {
        this.isRefreshingWhatsappWebStatus = true;
        await this.$store.dispatch('inboxes/refreshWhatsappWebQr', {
          inboxId: this.currentInboxId,
          statusOnly: true,
          includeQrCode: true,
        });
      } catch (error) {
        // Diagnostics should stay non-blocking in settings.
      } finally {
        this.isRefreshingWhatsappWebStatus = false;
      }
    },
    async fetchWhatsappWebDiagnostics() {
      if (
        !this.isAWhatsAppWebInbox ||
        !this.currentInboxId ||
        this.isWhatsappWebDeleting
      ) {
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
    async fetchTelegramPersonalDiagnostics() {
      if (!this.isATelegramPersonalChannel || !this.currentInboxId) {
        this.telegramPersonalDiagnostics = null;
        return;
      }

      try {
        this.isLoadingTelegramPersonalDiagnostics = true;
        this.telegramPersonalDiagnostics = await this.$store.dispatch(
          'inboxes/getTelegramPersonalDiagnostics',
          this.currentInboxId
        );
      } catch (error) {
        this.telegramPersonalDiagnostics = null;
      } finally {
        this.isLoadingTelegramPersonalDiagnostics = false;
      }
    },
    stopTelegramPersonalPolling() {
      if (this.telegramPersonalPollingInterval) {
        window.clearInterval(this.telegramPersonalPollingInterval);
        this.telegramPersonalPollingInterval = null;
      }
    },
    syncTelegramPersonalPolling() {
      this.stopTelegramPersonalPolling();

      if (
        !this.isATelegramPersonalChannel ||
        !this.currentInboxId ||
        this.isTelegramPersonalConnected
      ) {
        return;
      }

      this.telegramPersonalPollingInterval = window.setInterval(() => {
        this.fetchTelegramPersonalDiagnostics();
      }, TELEGRAM_PERSONAL_POLL_INTERVAL_MS);
    },
    async renderTelegramPersonalQrCode() {
      if (!this.telegramPersonalQrUrl) {
        this.telegramPersonalQrCode = '';
        return;
      }

      try {
        this.telegramPersonalQrCode = await QRCode.toDataURL(
          this.telegramPersonalQrUrl,
          {
            margin: 0,
            width: 384,
          }
        );
      } catch (error) {
        this.telegramPersonalQrCode = '';
      }
    },
    async requestTelegramPersonalCode() {
      try {
        this.isRunningTelegramPersonalRequestCode = true;
        await this.$store.dispatch(
          'inboxes/requestTelegramPersonalCode',
          this.currentInboxId
        );
        this.telegramPersonalCode = '';
        this.telegramPersonalPassword = '';
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REQUEST_CODE_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REQUEST_CODE_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalRequestCode = false;
      }
    },
    async requestTelegramPersonalQr() {
      try {
        this.isRunningTelegramPersonalRequestQr = true;
        await this.$store.dispatch(
          'inboxes/requestTelegramPersonalQr',
          this.currentInboxId
        );
        this.telegramPersonalCode = '';
        this.telegramPersonalPassword = '';
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REQUEST_QR_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REQUEST_QR_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalRequestQr = false;
      }
    },
    async verifyTelegramPersonalCode() {
      if (!this.telegramPersonalCode.trim()) {
        useAlert(this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CODE_REQUIRED'));
        return;
      }

      try {
        this.isRunningTelegramPersonalVerifyCode = true;
        await this.$store.dispatch('inboxes/verifyTelegramPersonalCode', {
          inboxId: this.currentInboxId,
          code: this.telegramPersonalCode.trim(),
        });
        this.telegramPersonalCode = '';
        await this.fetchTelegramPersonalDiagnostics();
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.VERIFY_CODE_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalVerifyCode = false;
      }
    },
    async verifyTelegramPersonalPassword() {
      if (!this.telegramPersonalPassword.trim()) {
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.PASSWORD_REQUIRED_ERROR')
        );
        return;
      }

      try {
        this.isRunningTelegramPersonalVerifyPassword = true;
        await this.$store.dispatch('inboxes/verifyTelegramPersonalPassword', {
          inboxId: this.currentInboxId,
          password: this.telegramPersonalPassword.trim(),
        });
        this.telegramPersonalPassword = '';
        await this.fetchTelegramPersonalDiagnostics();
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.VERIFY_PASSWORD_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalVerifyPassword = false;
      }
    },
    async reconnectTelegramPersonal() {
      try {
        this.isRunningTelegramPersonalReconnect = true;
        await this.$store.dispatch(
          'inboxes/reconnectTelegramPersonal',
          this.currentInboxId
        );
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RECONNECT_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RECONNECT_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalReconnect = false;
      }
    },
    async historySyncTelegramPersonal() {
      try {
        this.isRunningTelegramPersonalHistorySync = true;
        await this.$store.dispatch(
          'inboxes/historySyncTelegramPersonal',
          this.currentInboxId
        );
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.HISTORY_SYNC_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.HISTORY_SYNC_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalHistorySync = false;
      }
    },
    async fullHistorySyncTelegramPersonal() {
      try {
        this.isRunningTelegramPersonalFullHistorySync = true;
        await this.$store.dispatch('inboxes/historySyncTelegramPersonal', {
          inboxId: this.currentInboxId,
          payload: {
            force: true,
            reset_cursor: true,
            include_contacts: false,
          },
        });
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalFullHistorySync = false;
      }
    },
    async contactsSyncTelegramPersonal() {
      try {
        this.isRunningTelegramPersonalContactsSync = true;
        await this.$store.dispatch(
          'inboxes/contactsSyncTelegramPersonal',
          this.currentInboxId
        );
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CONTACTS_SYNC_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CONTACTS_SYNC_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalContactsSync = false;
      }
    },
    async disconnectTelegramPersonal() {
      try {
        this.isRunningTelegramPersonalDisconnect = true;
        await this.$store.dispatch(
          'inboxes/disconnectTelegramPersonal',
          this.currentInboxId
        );
        await this.fetchTelegramPersonalDiagnostics();
        useAlert(
          this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.DISCONNECT_SUCCESS')
        );
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.DISCONNECT_ERROR')
        );
      } finally {
        this.isRunningTelegramPersonalDisconnect = false;
      }
    },
    formatTelegramPersonalValue(value) {
      return (
        value || this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.NOT_AVAILABLE')
      );
    },
    formatTelegramPersonalDate(value) {
      if (!value) {
        return this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.NOT_AVAILABLE');
      }

      const parsedValue = new Date(value);
      if (Number.isNaN(parsedValue.getTime())) {
        return value;
      }

      try {
        return new Intl.DateTimeFormat(this.telegramPersonalIntlLocale, {
          dateStyle: 'medium',
          timeStyle: 'short',
          hour12: false,
        }).format(parsedValue);
      } catch {
        return value;
      }
    },
    humanizeTelegramPersonalState(value) {
      if (!value) {
        return this.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.NOT_AVAILABLE');
      }

      const normalizedKey = String(value)
        .trim()
        .replace(/[\s-]+/g, '_')
        .toUpperCase();
      const translationKey = `INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.STATE_LABELS.${normalizedKey}`;
      const translatedValue = this.$t(translationKey);

      if (translatedValue !== translationKey) {
        return translatedValue;
      }

      const normalizedValue = String(value).replace(/_/g, ' ');
      return normalizedValue.charAt(0).toUpperCase() + normalizedValue.slice(1);
    },
    telegramPersonalStateBadgeClass(value) {
      const normalizedValue = String(value || '').toLowerCase();

      if (['connected', 'authorized', 'completed'].includes(normalizedValue)) {
        return 'bg-n-teal-9/10 text-n-teal-11';
      }

      if (
        [
          'pending auth',
          'pending_auth',
          'code sent',
          'code_sent',
          'qr ready',
          'qr_ready',
          'password required',
          'password_required',
          'scheduled',
          'running',
          'delivering',
          'connecting',
        ].includes(normalizedValue)
      ) {
        return 'bg-n-amber-9/10 text-n-slate-12';
      }

      if (
        [
          'failed',
          'disconnected',
          'completed with errors',
          'completed_with_errors',
          'flood wait',
          'flood_wait',
          'cancelled',
        ].includes(normalizedValue)
      ) {
        return 'bg-n-ruby-9/10 text-n-ruby-11';
      }

      return 'bg-n-alpha-2 text-n-slate-11';
    },
    telegramPersonalMetricValueClass(value) {
      if (value) {
        return 'text-n-slate-12';
      }

      return 'text-n-slate-10';
    },
    async reconnectWhatsappWeb() {
      if (this.isWhatsappWebDeleting) {
        return;
      }

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
          error.message ||
            this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.RECONNECT_ERROR')
        );
      } finally {
        this.isRunningWhatsappWebReconnect = false;
      }
    },
    async disconnectWhatsappWeb() {
      if (this.isWhatsappWebDeleting) {
        return;
      }

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
          error.message ||
            this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.DISCONNECT_ERROR')
        );
      } finally {
        this.isRunningWhatsappWebDisconnect = false;
      }
    },
    async repairWhatsappWeb() {
      if (this.isWhatsappWebDeleting) {
        return;
      }

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
      if (this.isWhatsappWebDeleting) {
        return;
      }

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
          error.message ||
            this.$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.QR_REFRESH_ERROR')
        );
      } finally {
        this.isRefreshingWhatsappWebQr = false;
      }
    },
    async updateInbox() {
      const bubbleSettings = {
        position: this.widgetBubblePosition,
        type: this.widgetBubbleType,
        launcherTitle: this.widgetBubbleLauncherTitle,
      };
      LocalStorage.set(this.widgetBuilderStorageKey, bubbleSettings);

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
              )?.id || null
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
        this.showBusinessNameInput = false;
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
        return 0;
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
      this.showBusinessNameInput = true;
      this.$nextTick(() => {
        this.$refs.businessNameInput?.focus();
      });
    },
    hideBusinessNameInput() {
      this.showBusinessNameInput = false;
    },
    toggleLockToSingleConversation(value) {
      this.locktoSingleConversation = value;
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
    v-if="uiFlags.isFetching"
    class="flex items-center justify-center h-full w-full"
  >
    <SpinnerLoader :size="28" class="text-n-blue-9" />
  </div>
  <div
    v-else
    class="grid grid-rows-[auto_1fr] h-full flex-grow flex-shrink pr-0 pl-0 w-full min-w-0 settings"
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
    <section class="w-full overflow-auto py-8">
      <div class="max-w-7xl mx-auto w-full">
        <MicrosoftReauthorize
          v-if="microsoftUnauthorized"
          :inbox="inbox"
          class="mb-4"
          :class="bannerMaxWidth"
        />
        <FacebookReauthorize
          v-if="facebookUnauthorized"
          :inbox="inbox"
          class="mb-4"
          :class="bannerMaxWidth"
        />
        <GoogleReauthorize
          v-if="googleUnauthorized"
          :inbox="inbox"
          class="mb-4"
          :class="bannerMaxWidth"
        />
        <InstagramReauthorize
          v-if="instagramUnauthorized"
          :inbox="inbox"
          class="mb-4"
          :class="bannerMaxWidth"
        />
        <TiktokReauthorize
          v-if="tiktokUnauthorized"
          :inbox="inbox"
          class="mb-4"
          :class="bannerMaxWidth"
        />
        <WhatsappReauthorize
          v-if="whatsappUnauthorized"
          :whatsapp-registration-incomplete="whatsappRegistrationIncomplete"
          :inbox="inbox"
          class="mb-4"
          :class="bannerMaxWidth"
        />
        <DuplicateInboxBanner
          v-if="hasDuplicateInstagramInbox"
          :content="$t('INBOX_MGMT.ADD.INSTAGRAM.DUPLICATE_INBOX_BANNER')"
          class="mx-6 mb-4"
          :class="bannerMaxWidth"
        />

        <div
          v-if="selectedTabKey === 'inbox-settings'"
          class="flex flex-col md:flex-row items-center lg:items-start justify-between gap-5 lg:gap-10 mx-6"
        >
          <div
            class="flex-1 flex flex-col min-w-0"
            :class="{
              'max-w-2xl': isAWebWidgetInbox,
              'max-w-4xl': !isAWebWidgetInbox,
            }"
          >
            <div class="flex flex-col gap-1 items-start mb-4">
              <label class="text-heading-3 text-n-slate-12">
                {{ $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_AVATAR.LABEL') }}
              </label>
              <Avatar
                :src="avatarUrl"
                :size="64"
                :icon-name="inboxIcon"
                name=""
                allow-upload
                rounded-full
                @upload="handleImageUpload"
                @delete="handleAvatarDelete"
              />
            </div>
            <SettingsFieldSection :label="inboxNameLabel">
              <woot-input
                v-model="selectedInboxName"
                class="[&>input]:!mb-0"
                :class="{ error: v$.selectedInboxName.$error }"
                :placeholder="inboxNamePlaceHolder"
                :error="
                  v$.selectedInboxName.$error
                    ? $t('INBOX_MGMT.ADD.CHANNEL_NAME.ERROR')
                    : ''
                "
                @blur="v$.selectedInboxName.$touch"
              />
            </SettingsFieldSection>
            <SettingsFieldSection
              v-if="isAPIInbox && !isAWhatsAppWebInbox"
              :label="
                $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WEBHOOK_URL.LABEL')
              "
            >
              <woot-input
                v-model="webhookUrl"
                class="[&>input]:!mb-0"
                :class="{ error: v$.webhookUrl.$error }"
                :placeholder="
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WEBHOOK_URL.PLACEHOLDER'
                  )
                "
                :error="
                  v$.webhookUrl.$error
                    ? $t(
                        'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WEBHOOK_URL.ERROR'
                      )
                    : ''
                "
                @blur="v$.webhookUrl.$touch"
              />
            </SettingsFieldSection>

            <SettingsFieldSection
              v-if="isAWebWidgetInbox"
              :label="$t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_DOMAIN.LABEL')"
            >
              <woot-input
                v-model="channelWebsiteUrl"
                class="[&>input]:!mb-0"
                :placeholder="
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_DOMAIN.PLACEHOLDER'
                  )
                "
              />
            </SettingsFieldSection>

            <SettingsFieldSection
              v-if="isAWhatsAppChannel"
              :label="$t('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.LABEL')"
            >
              <input
                v-model="whatsAppAPIProviderName"
                type="text"
                disabled
                class="!mb-0"
              />
            </SettingsFieldSection>

            <SettingsFieldSection
              v-if="!isAVoiceChannel"
              :label="$t('INBOX_MGMT.HELP_CENTER.LABEL')"
              :help-text="$t('INBOX_MGMT.HELP_CENTER.SUB_TEXT')"
            >
              <SelectInput
                v-model="selectedPortalSlug"
                :placeholder="$t('INBOX_MGMT.HELP_CENTER.PLACEHOLDER')"
                :options="[
                  { value: '', label: $t('INBOX_MGMT.HELP_CENTER.NONE') },
                  ...portals.map(p => ({ value: p.slug, label: p.name })),
                ]"
              />
            </SettingsFieldSection>

            <SettingsFieldSection
              v-if="canLocktoSingleConversation"
              :label="
                $t('INBOX_MGMT.SETTINGS_POPUP.LOCK_TO_SINGLE_CONVERSATION')
              "
              class="[&>div>div]:justify-end [&>div>div]:flex lg:[&>div:first-child]:h-12 [&>div:first-child]:h-16"
            >
              <template #extra>
                <LockToSingleConversationPreview
                  :lock-to-single-conversation="locktoSingleConversation"
                  @update="toggleLockToSingleConversation"
                />
              </template>
            </SettingsFieldSection>

            <SettingsAccordion
              v-if="shouldShowWhatsappWebLifecycleSection"
              :title="$t('INBOX_MGMT.EDIT.WHATSAPP_WEB.TITLE')"
              class="mt-6"
            >
              <div class="space-y-4">
                <p class="text-body-main text-n-slate-11">
                  {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SUBTITLE') }}
                </p>

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
                        {{
                          whatsappWebEvolutionState.connection_state ||
                          'unknown'
                        }}
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

                <div class="rounded-xl border border-n-strong p-4">
                  <p class="mb-3 text-sm font-medium text-n-slate-12">
                    {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.NATIVE_SETTINGS') }}
                  </p>
                  <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                    <div class="space-y-4">
                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.WHATSAPP_WEB.CONVERSATION_PENDING'
                            )
                          }}
                        </span>
                        <SelectInput
                          v-model="whatsappWebConversationPending"
                          class="w-full"
                          :options="enabledDisabledOptions"
                        />
                        <p class="mt-1 text-sm text-n-slate-10">
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.WHATSAPP_WEB.CONVERSATION_PENDING_HINT'
                            )
                          }}
                        </p>
                      </label>

                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.WHATSAPP_WEB.HISTORY_LOOKBACK_DAYS'
                            )
                          }}
                        </span>
                        <input
                          v-model="whatsappWebHistoryLookbackDays"
                          class="!mb-0 w-full rounded-lg border-0 bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                          type="number"
                          min="0"
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
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IGNORE_JIDS') }}
                        </span>
                        <textarea
                          v-model="whatsappWebIgnoreJids"
                          class="mb-0 min-h-[112px] w-full resize-y rounded-lg border-0 bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                          :placeholder="whatsappWebIgnoreJidsPlaceholder"
                        />
                        <p class="mt-1 text-sm text-n-slate-10">
                          {{
                            $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IGNORE_JIDS_HINT')
                          }}
                        </p>
                      </label>
                    </div>

                    <div class="space-y-4">
                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{
                            $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IMPORT_CONTACTS')
                          }}
                        </span>
                        <SelectInput
                          v-model="whatsappWebImportContacts"
                          class="w-full"
                          :options="enabledDisabledOptions"
                        />
                      </label>

                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{
                            $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.IMPORT_MESSAGES')
                          }}
                        </span>
                        <SelectInput
                          v-model="whatsappWebImportMessages"
                          class="w-full"
                          :options="enabledDisabledOptions"
                        />
                      </label>

                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SYNC_LABELS') }}
                        </span>
                        <SelectInput
                          v-model="whatsappWebSyncLabels"
                          class="w-full"
                          :options="enabledDisabledOptions"
                        />
                      </label>

                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{ $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_MESSAGES') }}
                        </span>
                        <SelectInput
                          v-model="whatsappWebSignMessages"
                          class="w-full"
                          :options="enabledDisabledOptions"
                        />
                      </label>

                      <label class="block">
                        <span
                          class="mb-1 block text-sm font-medium text-n-slate-12"
                        >
                          {{
                            $t('INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_DELIMITER')
                          }}
                        </span>
                        <input
                          v-model="whatsappWebSignDelimiter"
                          class="!mb-0 w-full rounded-lg border-0 bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                          type="text"
                          :placeholder="
                            $t(
                              'INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_DELIMITER_PLACEHOLDER'
                            )
                          "
                        />
                        <p class="mt-1 text-sm text-n-slate-10">
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.WHATSAPP_WEB.SIGN_DELIMITER_HINT'
                            )
                          }}
                        </p>
                      </label>
                    </div>
                  </div>
                </div>

                <div class="rounded-xl border border-n-strong p-4">
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
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
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
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
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
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.WHATSAPP_WEB.PROVISIONAL_CONTACTS'
                          )
                        }}
                      </p>
                      <p class="mt-1 text-lg font-semibold text-n-slate-12">
                        {{
                          whatsappWebDiagnosticsCounts.provisional_contacts ?? 0
                        }}
                      </p>
                    </div>
                  </div>

                  <div
                    v-if="
                      whatsappWebDiagnostics?.samples?.provisional_contacts
                        ?.length
                    "
                    class="mt-4"
                  >
                    <p class="mb-2 text-sm font-medium text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.EDIT.WHATSAPP_WEB.PROVISIONAL_CONTACTS_SAMPLE'
                        )
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
              </div>
            </SettingsAccordion>

            <SettingsAccordion
              v-if="shouldShowTelegramPersonalLifecycleSection"
              :title="$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.TITLE')"
              class="mt-6"
            >
              <div class="space-y-4">
                <p class="text-body-main text-n-slate-11">
                  {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.SUBTITLE') }}
                </p>

                <div class="grid grid-cols-1 gap-4 xl:grid-cols-3">
                  <div
                    class="rounded-2xl border border-n-strong bg-gradient-to-br from-n-alpha-2 via-transparent to-transparent p-5 xl:col-span-2"
                  >
                    <div
                      class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between"
                    >
                      <div>
                        <p class="text-sm font-medium text-n-slate-12">
                          {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.OVERVIEW') }}
                        </p>
                        <p class="mt-1 text-sm text-n-slate-10">
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.OVERVIEW_SUBTITLE'
                            )
                          }}
                        </p>
                      </div>
                      <span
                        class="inline-flex items-center self-start rounded-full px-3 py-1 text-xs font-medium"
                        :class="
                          telegramPersonalStateBadgeClass(
                            telegramPersonalLifecycleState
                          )
                        "
                      >
                        {{
                          humanizeTelegramPersonalState(
                            telegramPersonalLifecycleState
                          )
                        }}
                      </span>
                    </div>

                    <div class="mt-5 grid grid-cols-1 gap-3 md:grid-cols-2">
                      <div
                        class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                      >
                        <div class="flex items-start justify-between gap-3">
                          <div>
                            <p
                              class="text-xs uppercase tracking-wide text-n-slate-10"
                            >
                              {{
                                $t(
                                  'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.PHONE_NUMBER'
                                )
                              }}
                            </p>
                            <p
                              class="mt-2 text-sm font-semibold"
                              :class="
                                telegramPersonalMetricValueClass(
                                  inbox.phone_number
                                )
                              "
                            >
                              {{
                                formatTelegramPersonalValue(inbox.phone_number)
                              }}
                            </p>
                          </div>
                          <span
                            class="rounded-full bg-n-surface-2 p-2 text-n-slate-10"
                          >
                            <Icon icon="i-lucide-smartphone" class="size-4" />
                          </span>
                        </div>
                      </div>

                      <div
                        class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                      >
                        <div class="flex items-start justify-between gap-3">
                          <div>
                            <p
                              class="text-xs uppercase tracking-wide text-n-slate-10"
                            >
                              {{
                                $t(
                                  'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.AUTH_STATE'
                                )
                              }}
                            </p>
                            <p
                              class="mt-2 text-sm font-semibold text-n-slate-12"
                            >
                              {{
                                humanizeTelegramPersonalState(
                                  telegramPersonalAuthState
                                )
                              }}
                            </p>
                          </div>
                          <span
                            class="rounded-full bg-n-surface-2 p-2 text-n-slate-10"
                          >
                            <Icon icon="i-lucide-shield-check" class="size-4" />
                          </span>
                        </div>
                      </div>

                      <div
                        class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                      >
                        <div class="flex items-start justify-between gap-3">
                          <div>
                            <p
                              class="text-xs uppercase tracking-wide text-n-slate-10"
                            >
                              {{
                                $t(
                                  'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CONNECTION'
                                )
                              }}
                            </p>
                            <p
                              class="mt-2 text-sm font-semibold text-n-slate-12"
                            >
                              {{
                                humanizeTelegramPersonalState(
                                  telegramPersonalConnectionState
                                )
                              }}
                            </p>
                          </div>
                          <span
                            class="rounded-full bg-n-surface-2 p-2 text-n-slate-10"
                          >
                            <Icon icon="i-lucide-plug" class="size-4" />
                          </span>
                        </div>
                      </div>

                      <div
                        class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                      >
                        <div class="flex items-start justify-between gap-3">
                          <div>
                            <p
                              class="text-xs uppercase tracking-wide text-n-slate-10"
                            >
                              {{
                                $t(
                                  'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.LAST_SYNCED'
                                )
                              }}
                            </p>
                            <p
                              class="mt-2 text-sm font-semibold text-n-slate-12"
                            >
                              {{
                                formatTelegramPersonalDate(inbox.last_synced_at)
                              }}
                            </p>
                          </div>
                          <span
                            class="rounded-full bg-n-surface-2 p-2 text-n-slate-10"
                          >
                            <Icon icon="i-lucide-clock-3" class="size-4" />
                          </span>
                        </div>
                      </div>
                    </div>

                    <div
                      v-if="telegramPersonalLastError"
                      class="mt-4 rounded-xl border border-n-ruby-8 bg-n-ruby-9/10 p-4"
                    >
                      <p class="text-sm font-medium text-n-ruby-11">
                        {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.LAST_ERROR') }}
                      </p>
                      <p class="mt-1 text-sm text-n-ruby-11">
                        {{ telegramPersonalLastError }}
                      </p>
                    </div>
                  </div>

                  <div class="rounded-2xl border border-n-strong p-5">
                    <p class="text-sm font-medium text-n-slate-12">
                      {{
                        $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.SERVICE_CONTROLS')
                      }}
                    </p>
                    <p class="mt-1 text-sm text-n-slate-10">
                      {{
                        $t(
                          'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.SERVICE_CONTROLS_SUBTITLE'
                        )
                      }}
                    </p>

                    <div class="mt-4 space-y-2">
                      <NextButton
                        class="w-full"
                        outline
                        slate
                        start
                        icon="i-lucide-refresh-cw"
                        :label="
                          $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RECONNECT')
                        "
                        :is-loading="isRunningTelegramPersonalReconnect"
                        @click="reconnectTelegramPersonal"
                      />
                      <NextButton
                        class="w-full"
                        outline
                        ruby
                        start
                        icon="i-lucide-power"
                        :label="
                          $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.DISCONNECT')
                        "
                        :is-loading="isRunningTelegramPersonalDisconnect"
                        @click="disconnectTelegramPersonal"
                      />
                    </div>

                    <div class="mt-4 rounded-xl bg-n-alpha-2 p-4">
                      <p class="text-sm text-n-slate-10">
                        {{
                          $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.AUTO_SYNC_HINT')
                        }}
                      </p>
                    </div>
                  </div>
                </div>

                <div
                  v-if="!isTelegramPersonalConnected"
                  class="rounded-2xl border border-n-strong p-5"
                >
                  <div
                    class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
                  >
                    <div>
                      <p class="text-sm font-medium text-n-slate-12">
                        {{
                          $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.ACCESS_SECTION')
                        }}
                      </p>
                      <p class="mt-1 text-sm text-n-slate-10">
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.ACCESS_SECTION_SUBTITLE'
                          )
                        }}
                      </p>
                    </div>
                    <span
                      class="inline-flex items-center rounded-full px-3 py-1 text-xs font-medium"
                      :class="
                        telegramPersonalStateBadgeClass(
                          telegramPersonalLifecycleState
                        )
                      "
                    >
                      {{
                        humanizeTelegramPersonalState(
                          telegramPersonalLifecycleState
                        )
                      }}
                    </span>
                  </div>

                  <div class="mt-5 grid grid-cols-1 gap-4 lg:grid-cols-2">
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p class="text-sm font-medium text-n-slate-12">
                        {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CODE_LOGIN') }}
                      </p>

                      <template v-if="shouldShowTelegramPersonalCodeRequest">
                        <p class="mt-2 text-sm text-n-slate-10">
                          {{
                            $t(
                              'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE_HINT'
                            )
                          }}
                        </p>
                        <NextButton
                          class="mt-4 w-full sm:w-auto"
                          outline
                          slate
                          start
                          :label="
                            $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REQUEST_CODE')
                          "
                          :is-loading="isRunningTelegramPersonalRequestCode"
                          @click="requestTelegramPersonalCode"
                        />
                      </template>

                      <template
                        v-else-if="shouldShowTelegramPersonalCodeVerify"
                      >
                        <input
                          v-model="telegramPersonalCode"
                          class="mt-4 !mb-0 w-full rounded-lg border-0 bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                          type="text"
                          inputmode="numeric"
                          autocomplete="one-time-code"
                          :placeholder="
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CODE_PLACEHOLDER'
                            )
                          "
                        />
                        <p class="mt-2 text-sm text-n-slate-10">
                          {{
                            $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CODE_HINT')
                          }}
                        </p>
                        <NextButton
                          class="mt-4 w-full sm:w-auto"
                          solid
                          blue
                          start
                          icon="i-lucide-check"
                          :label="
                            $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.VERIFY_CODE')
                          "
                          :is-loading="isRunningTelegramPersonalVerifyCode"
                          @click="verifyTelegramPersonalCode"
                        />
                      </template>
                    </div>

                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <template v-if="!isTelegramPersonalPasswordRequired">
                        <p class="text-sm font-medium text-n-slate-12">
                          {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.QR_LOGIN') }}
                        </p>
                        <p class="mt-2 text-sm text-n-slate-10">
                          {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.QR_HINT') }}
                        </p>
                        <div
                          v-if="telegramPersonalQrCode"
                          class="mt-4 flex items-center justify-center rounded-2xl bg-white p-4"
                        >
                          <img
                            :src="telegramPersonalQrCode"
                            :alt="
                              $t(
                                'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.QR_IMAGE_ALT'
                              )
                            "
                            class="h-auto w-full max-w-[14rem]"
                          />
                        </div>
                        <div
                          v-else
                          class="mt-4 rounded-2xl border border-dashed border-n-strong px-4 py-8 text-center text-sm text-n-slate-10"
                        >
                          {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.QR_EMPTY') }}
                        </div>
                        <p
                          v-if="telegramPersonalQrExpiresAt"
                          class="mt-3 text-xs text-n-slate-10"
                        >
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.QR_EXPIRES_AT',
                              {
                                value: formatTelegramPersonalDate(
                                  telegramPersonalQrExpiresAt
                                ),
                              }
                            )
                          }}
                        </p>
                        <NextButton
                          class="mt-4 w-full sm:w-auto"
                          outline
                          slate
                          start
                          :label="telegramPersonalQrButtonLabel"
                          :is-loading="isRunningTelegramPersonalRequestQr"
                          @click="requestTelegramPersonalQr"
                        />
                      </template>

                      <template v-else>
                        <p class="text-sm font-medium text-n-slate-12">
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.PASSWORD_LABEL'
                            )
                          }}
                        </p>
                        <input
                          v-model="telegramPersonalPassword"
                          class="mt-4 !mb-0 w-full rounded-lg border-0 bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                          type="password"
                          autocomplete="current-password"
                          :placeholder="
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.PASSWORD_PLACEHOLDER'
                            )
                          "
                        />
                        <p class="mt-2 text-sm text-n-slate-10">
                          {{
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.PASSWORD_HINT'
                            )
                          }}
                        </p>
                        <NextButton
                          class="mt-4 w-full sm:w-auto"
                          solid
                          blue
                          start
                          icon="i-lucide-lock-keyhole"
                          :label="
                            $t(
                              'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.VERIFY_PASSWORD'
                            )
                          "
                          :is-loading="isRunningTelegramPersonalVerifyPassword"
                          @click="verifyTelegramPersonalPassword"
                        />
                      </template>
                    </div>
                  </div>
                </div>

                <div class="rounded-2xl border border-n-strong p-5">
                  <div
                    class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
                  >
                    <div>
                      <p class="text-sm font-medium text-n-slate-12">
                        {{
                          $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.IMPORT_SECTION')
                        }}
                      </p>
                      <p class="mt-1 text-sm text-n-slate-10">
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.IMPORT_SECTION_SUBTITLE'
                          )
                        }}
                      </p>
                    </div>
                    <div class="flex flex-wrap gap-2">
                      <span
                        class="inline-flex items-center rounded-full px-3 py-1 text-xs font-medium"
                        :class="
                          telegramPersonalStateBadgeClass(
                            telegramPersonalHistorySyncState
                          )
                        "
                      >
                        {{
                          humanizeTelegramPersonalState(
                            telegramPersonalHistorySyncState
                          )
                        }}
                      </span>
                      <span
                        class="inline-flex items-center rounded-full px-3 py-1 text-xs font-medium"
                        :class="
                          telegramPersonalStateBadgeClass(
                            telegramPersonalContactsSyncState
                          )
                        "
                      >
                        {{
                          humanizeTelegramPersonalState(
                            telegramPersonalContactsSyncState
                          )
                        }}
                      </span>
                    </div>
                  </div>

                  <div class="mt-5 grid grid-cols-1 gap-3 md:grid-cols-2">
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.HISTORY_SYNC_STATE'
                          )
                        }}
                      </p>
                      <p class="mt-2 text-sm font-semibold text-n-slate-12">
                        {{
                          humanizeTelegramPersonalState(
                            telegramPersonalHistorySyncState
                          )
                        }}
                      </p>
                    </div>
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.HISTORY_SYNC_COUNT'
                          )
                        }}
                      </p>
                      <p class="mt-2 text-2xl font-semibold text-n-slate-12">
                        {{ telegramPersonalHistorySyncCount }}
                      </p>
                    </div>
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.LAST_HISTORY_SYNC_AT'
                          )
                        }}
                      </p>
                      <p class="mt-2 text-sm font-semibold text-n-slate-12">
                        {{
                          formatTelegramPersonalDate(
                            telegramPersonalLastHistorySyncAt
                          )
                        }}
                      </p>
                    </div>
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CONTACTS_SYNC_COUNT'
                          )
                        }}
                      </p>
                      <p class="mt-2 text-2xl font-semibold text-n-slate-12">
                        {{ telegramPersonalContactsSyncCount }}
                      </p>
                    </div>
                  </div>

                  <div class="mt-5 flex flex-wrap gap-2">
                    <NextButton
                      class="w-full sm:w-auto"
                      outline
                      slate
                      start
                      icon="i-lucide-download"
                      :label="
                        $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.HISTORY_SYNC')
                      "
                      :is-loading="isRunningTelegramPersonalHistorySync"
                      @click="historySyncTelegramPersonal"
                    />
                    <NextButton
                      class="w-full sm:w-auto"
                      outline
                      slate
                      start
                      icon="i-lucide-history"
                      :label="
                        $t(
                          'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC'
                        )
                      "
                      :is-loading="isRunningTelegramPersonalFullHistorySync"
                      @click="fullHistorySyncTelegramPersonal"
                    />
                    <NextButton
                      class="w-full sm:w-auto"
                      outline
                      slate
                      start
                      icon="i-lucide-users"
                      :label="
                        $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CONTACTS_SYNC')
                      "
                      :is-loading="isRunningTelegramPersonalContactsSync"
                      @click="contactsSyncTelegramPersonal"
                    />
                  </div>
                </div>

                <div class="rounded-2xl border border-n-strong p-5">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <p class="text-sm font-medium text-n-slate-12">
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.DIAGNOSTICS_SECTION'
                          )
                        }}
                      </p>
                      <p class="mt-1 text-sm text-n-slate-10">
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.DIAGNOSTICS_SECTION_SUBTITLE'
                          )
                        }}
                      </p>
                    </div>
                    <div class="flex items-center gap-2">
                      <NextButton
                        ghost
                        slate
                        sm
                        icon="i-lucide-refresh-cw"
                        :is-loading="isLoadingTelegramPersonalDiagnostics"
                        :aria-label="
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REFRESH_DIAGNOSTICS'
                          )
                        "
                        :title="
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.REFRESH_DIAGNOSTICS'
                          )
                        "
                        @click="fetchTelegramPersonalDiagnostics"
                      />
                      <NextButton
                        ghost
                        slate
                        sm
                        icon="i-lucide-bug"
                        :aria-label="
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RAW_DIAGNOSTICS_TOGGLE'
                          )
                        "
                        :title="
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RAW_DIAGNOSTICS_TOGGLE'
                          )
                        "
                        @click="
                          isTelegramPersonalRawDiagnosticsVisible =
                            !isTelegramPersonalRawDiagnosticsVisible
                        "
                      />
                    </div>
                  </div>

                  <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-3">
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.AUTH_STATE') }}
                      </p>
                      <p class="mt-2 text-sm font-semibold text-n-slate-12">
                        {{
                          humanizeTelegramPersonalState(
                            telegramPersonalAuthState
                          )
                        }}
                      </p>
                    </div>
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{ $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.FLOOD_WAIT') }}
                      </p>
                      <p class="mt-2 text-sm font-semibold text-n-slate-12">
                        {{
                          telegramPersonalFloodWaitSeconds === undefined ||
                          telegramPersonalFloodWaitSeconds === null
                            ? $t(
                                'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.NOT_AVAILABLE'
                              )
                            : telegramPersonalFloodWaitSeconds
                        }}
                      </p>
                    </div>
                    <div
                      class="rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                    >
                      <p
                        class="text-xs uppercase tracking-wide text-n-slate-10"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.LAST_INBOUND_AT'
                          )
                        }}
                      </p>
                      <p class="mt-2 text-sm font-semibold text-n-slate-12">
                        {{
                          formatTelegramPersonalDate(
                            telegramPersonalLastInboundAt
                          )
                        }}
                      </p>
                    </div>
                  </div>

                  <div
                    v-if="isTelegramPersonalRawDiagnosticsVisible"
                    class="mt-4 rounded-xl border border-n-strong bg-n-alpha-2 p-4"
                  >
                    <p class="mb-3 text-sm font-medium text-n-slate-12">
                      {{
                        $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RAW_DIAGNOSTICS')
                      }}
                    </p>
                    <woot-code
                      v-if="telegramPersonalDiagnosticsJson"
                      lang="text"
                      :script="telegramPersonalDiagnosticsJson"
                    />
                    <p v-else class="text-sm text-n-slate-10">
                      {{
                        $t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.NOT_AVAILABLE')
                      }}
                    </p>
                  </div>
                </div>
              </div>
            </SettingsAccordion>

            <SettingsAccordion
              v-if="shouldShowVkCommunityDetailsSection"
              :title="$t('INBOX_MGMT.EDIT.VK_COMMUNITY.TITLE')"
              class="mt-6"
            >
              <div class="space-y-4">
                <p class="text-body-main text-n-slate-11">
                  {{ $t('INBOX_MGMT.EDIT.VK_COMMUNITY.SUBTITLE') }}
                </p>

                <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                  <div class="rounded-xl border border-n-strong p-4">
                    <p class="mb-3 text-sm font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.EDIT.VK_COMMUNITY.CALLBACK') }}
                    </p>
                    <div class="space-y-2 text-sm text-n-slate-11">
                      <p>
                        <span class="font-medium text-n-slate-12">{{
                          $t('INBOX_MGMT.EDIT.VK_COMMUNITY.GROUP_ID')
                        }}</span>
                        {{ inbox.group_id }}
                      </p>
                      <p>
                        <span class="font-medium text-n-slate-12">{{
                          $t('INBOX_MGMT.EDIT.VK_COMMUNITY.API_VERSION')
                        }}</span>
                        {{ inbox.api_version }}
                      </p>
                      <p>
                        <span class="font-medium text-n-slate-12">{{
                          $t('INBOX_MGMT.EDIT.VK_COMMUNITY.CALLBACK_ID')
                        }}</span>
                        {{ inbox.callback_id }}
                      </p>
                    </div>
                  </div>

                  <div class="rounded-xl border border-n-strong p-4">
                    <p class="mb-3 text-sm font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.EDIT.VK_COMMUNITY.WEBHOOK_URL') }}
                    </p>
                    <woot-code
                      lang="html"
                      :script="inbox.callback_webhook_url"
                    />
                    <p class="mt-3 text-sm text-n-slate-10">
                      {{ $t('INBOX_MGMT.EDIT.VK_COMMUNITY.WEBHOOK_HINT') }}
                    </p>
                  </div>
                </div>
              </div>
            </SettingsAccordion>

            <SettingsFieldSection
              v-if="isAWebWidgetInbox || isAnEmailChannel"
              :label="$t('INBOX_MGMT.EDIT.SENDER_NAME_SECTION.TITLE')"
              class="[&>div>div]:justify-end [&>div>div]:flex lg:[&>div:first-child]:h-12 [&>div:first-child]:h-16"
            >
              <NextButton
                v-if="!showBusinessNameInput"
                ghost
                blue
                sm
                :label="
                  $t(
                    'INBOX_MGMT.EDIT.SENDER_NAME_SECTION.BUSINESS_NAME.BUTTON_TEXT'
                  )
                "
                @click="onClickShowBusinessNameInput"
              />

              <div
                v-if="showBusinessNameInput"
                v-on-clickaway="hideBusinessNameInput"
                class="flex justify-end gap-2 w-full"
              >
                <input
                  ref="businessNameInput"
                  v-model="businessName"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.EDIT.SENDER_NAME_SECTION.BUSINESS_NAME.PLACEHOLDER'
                    )
                  "
                  class="!mb-0"
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

              <template #extra>
                <SenderNameExamplePreview
                  :sender-name-type="senderNameType"
                  :business-name="businessName"
                  :is-website-channel="isAWebWidgetInbox"
                  @update="toggleSenderNameType"
                />
              </template>
            </SettingsFieldSection>

            <SettingsAccordion
              v-if="isAWebWidgetInbox"
              :title="$t('INBOX_MGMT.WIDGET_FEATURES')"
              class="mt-6"
            >
              <SettingsFieldSection
                :label="
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TITLE.LABEL'
                  )
                "
              >
                <woot-input
                  v-model="channelWelcomeTitle"
                  class="[&>input]:!mb-0"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TITLE.PLACEHOLDER'
                    )
                  "
                />
              </SettingsFieldSection>

              <SettingsFieldSection
                :label="
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TAGLINE.LABEL'
                  )
                "
                class="[&>div]:!items-start [&>div>label]:mt-1"
              >
                <Editor
                  v-model="channelWelcomeTagline"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_WELCOME_TAGLINE.PLACEHOLDER'
                    )
                  "
                  :max-length="255"
                  channel-type="Context::InboxSettings"
                />
              </SettingsFieldSection>

              <SettingsFieldSection
                :label="$t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.WIDGET_COLOR.LABEL')"
              >
                <div class="justify-start">
                  <ColorPicker v-model="inbox.widget_color" />
                </div>
              </SettingsFieldSection>
              <SettingsFieldSection
                :label="
                  $t('INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE')
                "
              >
                <div class="flex items-center gap-6">
                  <div class="flex items-center gap-2">
                    <label class="text-n-slate-11 text-heading-3">
                      {{
                        $t(
                          'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_POSITION_LABEL'
                        )
                      }}
                    </label>
                    <SelectInput
                      v-model="widgetBubblePosition"
                      :options="[
                        {
                          label: $t(
                            'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_POSITION.LEFT'
                          ),
                          value: 'left',
                        },
                        {
                          label: $t(
                            'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_POSITION.RIGHT'
                          ),
                          value: 'right',
                        },
                      ]"
                      class="[&>select]:!p-0 min-w-16 [&>select]:!outline-none"
                    />
                  </div>
                  <div class="h-3 w-px bg-n-weak rounded-lg" />
                  <div class="flex items-center gap-2">
                    <label class="text-n-slate-11 text-heading-3">
                      {{
                        $t(
                          'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_TYPE_LABEL'
                        )
                      }}
                    </label>
                    <SelectInput
                      v-model="widgetBubbleType"
                      :options="[
                        {
                          label: $t(
                            'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_TYPE.STANDARD'
                          ),
                          value: 'standard',
                        },
                        {
                          label: $t(
                            'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_TYPE.EXPANDED_BUBBLE'
                          ),
                          value: 'expanded_bubble',
                        },
                      ]"
                      class="[&>select]:!p-0 min-w-16 [&>select]:!outline-none"
                    />
                  </div>
                </div>
              </SettingsFieldSection>

              <SettingsFieldSection
                :label="
                  $t(
                    'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_LAUNCHER_TITLE.LABEL'
                  )
                "
              >
                <woot-input
                  v-model="widgetBubbleLauncherTitle"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WIDGET_BUBBLE_LAUNCHER_TITLE.PLACE_HOLDER'
                    )
                  "
                  class="[&>input]:!mb-0"
                />
              </SettingsFieldSection>
              <SettingsFieldSection
                :label="$t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.TITLE')"
                :help-text="
                  $t('INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.HELP_TEXT')
                "
              >
                <SelectInput
                  v-model="replyTime"
                  :options="[
                    {
                      value: 'in_a_few_minutes',
                      label: $t(
                        'INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.IN_A_FEW_MINUTES'
                      ),
                    },
                    {
                      value: 'in_a_few_hours',
                      label: $t(
                        'INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.IN_A_FEW_HOURS'
                      ),
                    },
                    {
                      value: 'in_a_day',
                      label: $t(
                        'INBOX_MGMT.ADD.WEBSITE_CHANNEL.REPLY_TIME.IN_A_DAY'
                      ),
                    },
                  ]"
                />
              </SettingsFieldSection>

              <SettingsFieldSection
                :label="$t('INBOX_MGMT.FEATURES.LABEL')"
                class="[&>div]:!items-start [&>div>label]:mt-2"
              >
                <div class="flex flex-col gap-1 items-start">
                  <div class="flex gap-2 pt-2 py-0.5">
                    <input
                      v-model="selectedFeatureFlags"
                      type="checkbox"
                      value="attachments"
                      @input="handleFeatureFlag"
                    />
                    <label for="attachments">
                      {{ $t('INBOX_MGMT.FEATURES.DISPLAY_FILE_PICKER') }}
                    </label>
                  </div>
                  <div class="flex gap-2 py-0.5">
                    <input
                      v-model="selectedFeatureFlags"
                      type="checkbox"
                      value="emoji_picker"
                      @input="handleFeatureFlag"
                    />
                    <label for="emoji_picker">
                      {{ $t('INBOX_MGMT.FEATURES.DISPLAY_EMOJI_PICKER') }}
                    </label>
                  </div>
                  <div class="flex gap-2 py-0.5">
                    <input
                      v-model="selectedFeatureFlags"
                      type="checkbox"
                      value="end_conversation"
                      @input="handleFeatureFlag"
                    />
                    <label for="end_conversation">
                      {{ $t('INBOX_MGMT.FEATURES.ALLOW_END_CONVERSATION') }}
                    </label>
                  </div>
                  <div class="flex gap-2 py-0.5">
                    <input
                      v-model="selectedFeatureFlags"
                      type="checkbox"
                      value="use_inbox_avatar_for_bot"
                      @input="handleFeatureFlag"
                    />
                    <label for="use_inbox_avatar_for_bot">
                      {{ $t('INBOX_MGMT.FEATURES.USE_INBOX_AVATAR_FOR_BOT') }}
                    </label>
                  </div>
                </div>
              </SettingsFieldSection>

              <WebsiteTriggerCampaigns :inbox="inbox" />
            </SettingsAccordion>

            <SettingsAccordion
              :title="$t('INBOX_MGMT.CHANNEL_PREFERENCES')"
              class="mt-6"
            >
              <SettingsToggleSection
                v-model="greetingEnabled"
                :header="
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_TOGGLE.LABEL'
                  )
                "
                :description="
                  $t(
                    'INBOX_MGMT.ADD.WEBSITE_CHANNEL.CHANNEL_GREETING_TOGGLE.HELP_TEXT'
                  )
                "
              >
                <template v-if="greetingEnabled" #editor>
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
                </template>
              </SettingsToggleSection>

              <SettingsToggleSection
                v-if="isAWebWidgetInbox"
                v-model="emailCollectEnabled"
                :header="
                  $t('INBOX_MGMT.SETTINGS_POPUP.ENABLE_EMAIL_COLLECT_BOX')
                "
                :description="
                  $t(
                    'INBOX_MGMT.SETTINGS_POPUP.ENABLE_EMAIL_COLLECT_BOX_SUB_TEXT'
                  )
                "
              />

              <SettingsToggleSection
                v-if="isAWebWidgetInbox"
                v-model="allowMessagesAfterResolved"
                :header="
                  $t('INBOX_MGMT.SETTINGS_POPUP.ALLOW_MESSAGES_AFTER_RESOLVED')
                "
                :description="
                  $t(
                    'INBOX_MGMT.SETTINGS_POPUP.ALLOW_MESSAGES_AFTER_RESOLVED_SUB_TEXT'
                  )
                "
              />

              <SettingsToggleSection
                v-if="isAWebWidgetInbox"
                v-model="continuityViaEmail"
                :header="
                  $t('INBOX_MGMT.SETTINGS_POPUP.ENABLE_CONTINUITY_VIA_EMAIL')
                "
                :description="
                  $t(
                    'INBOX_MGMT.SETTINGS_POPUP.ENABLE_CONTINUITY_VIA_EMAIL_SUB_TEXT'
                  )
                "
              />
            </SettingsAccordion>

            <div class="w-full flex justify-end items-center py-4 mt-2">
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
            </div>
          </div>

          <div
            v-if="isAWebWidgetInbox"
            class="flex-1 sticky top-4 self-start max-w-lg flex-shrink-0 w-full min-w-0"
          >
            <div
              class="flex flex-col outline -outline-offset-1 outline-1 outline-n-weak w-full px-3 pt-3 pb-8 bg-n-surface-1 rounded-2xl min-h-[45rem] overflow-hidden"
            >
              <Widget
                :welcome-heading="channelWelcomeTitle"
                :welcome-tagline="channelWelcomeTagline"
                :website-name="selectedInboxName"
                :logo="avatarUrl"
                is-online
                :reply-time="replyTime"
                :color="inbox.widget_color"
                :widget-bubble-position="widgetBubblePosition"
                :widget-bubble-launcher-title="widgetBubbleLauncherTitle"
                :widget-bubble-type="widgetBubbleType"
                :web-widget-script="inbox.web_widget_script"
              />
            </div>
          </div>
        </div>

        <div v-if="selectedTabKey === 'collaborators'" class="mx-6 max-w-4xl">
          <CollaboratorsPage :inbox="inbox" />
        </div>
        <div
          v-if="selectedTabKey === 'configuration'"
          class="mx-6"
          :class="isAWebWidgetInbox ? 'max-w-7xl' : 'max-w-4xl'"
        >
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
        <div v-if="selectedTabKey === 'bot-configuration'">
          <BotConfiguration :inbox="inbox" />
        </div>
        <div v-if="selectedTabKey === 'whatsapp-health'">
          <AccountHealth
            :health-data="healthData"
            :is-registering-webhook="isRegisteringWebhook"
            @register-webhook="registerWebhook"
          />
        </div>
        <div v-if="selectedTabKey === 'whatsapp-templates'">
          <WhatsAppTemplatesPage :inbox="inbox" />
        </div>
      </div>
    </section>
  </div>
</template>
