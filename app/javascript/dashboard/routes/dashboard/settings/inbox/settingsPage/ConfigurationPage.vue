<script>
import { useAlert } from 'dashboard/composables';
import inboxMixin from 'shared/mixins/inboxMixin';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SettingsAccordion from 'dashboard/components-next/Settings/SettingsAccordion.vue';
import ImapSettings from '../ImapSettings.vue';
import SmtpSettings from '../SmtpSettings.vue';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import NextButton from 'dashboard/components-next/button/Button.vue';
import TextArea from 'next/textarea/TextArea.vue';
import WhatsappReauthorize from '../channels/whatsapp/Reauthorize.vue';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import {
  virtualPbxErrorText,
  virtualPbxErrorsText,
  virtualPbxRequestErrorText,
} from 'dashboard/api/channel/voice/virtualPbxErrors';
import { sanitizeAllowedDomains } from 'dashboard/helper/URLHelper';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

// Beeline Cloud PBX connects outbound calls dialed as +7XXXXXXXXXX.
const BEELINE_OUTBOUND_DIAL_FORMAT = 'e164_plus';
const DEFAULT_WAZO_SIP_HOST = '188.241.217.162';

const defaultWazoSipHost = () =>
  window.chatwootConfig?.wazoSipHost || DEFAULT_WAZO_SIP_HOST;

const WAZO_CARRIER_PRESETS = {
  altel: { domain: 'astpbx.tele2.kz', host: '91.185.24.71', max: 2 },
  tele2: { domain: 'astpbx.tele2.kz', host: '91.185.24.71', max: 2 },
  kazakhtelecom: {
    domain: 'sip.telecom.kz',
    host: 'sip.telecom.kz',
    max: 5,
  },
  kcell: { domain: 'sip.kcell.kz', host: 'sip.kcell.kz', max: 5 },
  beeline_trunk: {
    domain: 'cloudpbx.beeline.kz',
    host: '46.227.186.231',
    max: 5,
  },
};

const KNOWN_CARRIER_PRESETS = Object.keys(WAZO_CARRIER_PRESETS);

const CARRIER_BADGES = {
  altel: '/integrations/channels/badges/altel.svg',
  tele2: '/integrations/channels/badges/tele2.svg',
  kazakhtelecom: '/integrations/channels/badges/kazakhtelecom.svg',
  kcell: '/integrations/channels/badges/kcell.svg',
  beeline_trunk: '/integrations/channels/badges/beeline.svg',
  beeline: '/integrations/channels/badges/beeline.svg',
  sipuni: '/integrations/channels/badges/sipuni.svg',
  binotel: '/integrations/channels/badges/binotel.svg',
  wazo: '/integrations/channels/badges/custom-sip.svg',
};

const defaultCallRoutingConfig = () => ({
  show_extended_call_card: true,
  inbound: {
    routing_authority: 'onelink',
    schedule_mode: 'always',
    off_hours_action: 'reject',
    off_hours_forward_number: '',
    ring_timeout_seconds: 30,
    skip_busy_operators: true,
    ringtone: 'default',
    groups: [
      {
        id: 'group-1',
        name: '',
        strategy: 'broadcast',
        ring_seconds: 25,
        user_ids: [],
      },
    ],
    fallback_action: 'reject',
    fallback_forward_number: '',
    whatsapp_followup: {
      enabled: false,
      inbox_id: '',
      template_name: '',
      template_language: 'ru',
      custom_message: '',
      cooldown_minutes: 60,
    },
  },
  outbound: {
    access_mode: 'all_members',
    allowed_user_ids: [],
    caller_id_number: '',
  },
});

export default {
  components: {
    SettingsFieldSection,
    SettingsToggleSection,
    SettingsAccordion,
    ImapSettings,
    SmtpSettings,
    NextButton,
    TextArea,
    WhatsappReauthorize,
  },
  mixins: [inboxMixin],
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      hmacMandatory: false,
      allowMobileWebview: false,
      whatsAppInboxAPIKey: '',
      isRequestingReauthorization: false,
      isSyncingTemplates: false,
      allowedDomains: '',
      isUpdatingAllowedDomains: false,
      callingEnabled: false,
      aiVoiceEnabled: false,
      isSettingDefaults: false,
      virtualPbxStatusPayload: null,
      virtualPbxLoadError: '',
      isLoadingVirtualPbxStatus: false,
      virtualPbxInboxMembers: [],
      virtualPbxProfileCounter: 0,
      isUpdatingVirtualPbx: false,
      isLoadingVirtualPbxPlan: false,
      isProvisioningVirtualPbx: false,
      isReconcilingVirtualPbx: false,
      isProbingVirtualPbxChannels: false,
      virtualPbxProvisioningPlan: null,
      virtualPbxProvisioningRuns: [],
      virtualPbxReconcileResult: null,
      sipuniWebhookToken: '',
      isUpdatingSipuniWebhook: false,
      binotelWebhookToken: '',
      isUpdatingBinotelWebhook: false,
      beelineWebhookToken: '',
      beelineApiToken: '',
      beelineApiTokenConfigured: false,
      isUpdatingBeelineWebhook: false,
      virtualPbxLockedCarrierKind: '',
      callRoutingTab: 'inbound',
      callRoutingDirty: false,
      isSavingWhatsAppCallRouting: false,
      callRoutingForm: defaultCallRoutingConfig(),
      virtualPbxForm: {
        channelName: '',
        providerKind: '',
        displayPhoneNumber: '',
        providerAccountNumber: '',
        ingressNumber: '',
        connectionHost: '',
        connectionPort: '5060',
        connectionTransport: 'udp',
        connectionSipDomain: '',
        connectionOutboundProxy: '',
        connectionCodec: '',
        outboundDialFormat: 'kz_trunk',
        connectionUsername: '',
        connectionPassword: '',
        carrierKind: '',
        maxChannels: 2,
        detectedChannelLimit: null,
        lastChannelLimitHitAt: '',
        lastChannelProbeAt: '',
        channelDetectionSource: '',
        reservedInboundChannels: 0,
        ringStrategy: 'all',
        groupExtension: '',
        trunkUsername: '',
        trunkPassword: '',
        trunkPasswordConfigured: false,
        trunkDomain: '',
        trunkHost: '',
        routingMode: 'operator',
        operatorDistributionMode: 'broadcast',
        maxCallDurationMinutes: 30,
        profiles: [],
      },
    };
  },
  validations: {
    whatsAppInboxAPIKey: { required },
  },
  computed: {
    isEmbeddedSignupWhatsApp() {
      return this.inbox.provider_config?.source === 'embedded_signup';
    },
    isCoexistenceWhatsApp() {
      return (
        this.isEmbeddedSignupWhatsApp &&
        this.inbox.provider_config?.embedded_signup_flow === 'coexistence'
      );
    },
    coexistenceSync() {
      return this.inbox.provider_config?.coexistence_sync || null;
    },
    coexistenceSyncStateLabel() {
      const state = this.coexistenceSync?.state || 'pending';
      const stateLabels = {
        pending: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.PENDING'
        ),
        requesting: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.REQUESTING'
        ),
        requested: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.REQUESTED'
        ),
        syncing: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.SYNCING'
        ),
        reconciling: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.RECONCILING'
        ),
        completed: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.COMPLETED'
        ),
        failed: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.FAILED'
        ),
        history_failed: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.HISTORY_FAILED'
        ),
        history_declined: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.HISTORY_DECLINED'
        ),
        request_outcome_unknown: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.REQUEST_OUTCOME_UNKNOWN'
        ),
        manual_recovery_required: this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.MANUAL_RECOVERY_REQUIRED'
        ),
      };
      return (
        stateLabels[state] ||
        this.$t(
          'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.UNKNOWN'
        )
      );
    },
    coexistenceSyncProgress() {
      const progress = Number(this.coexistenceSync?.history_progress);
      if (!Number.isFinite(progress)) return null;
      return Math.min(Math.max(progress, 0), 100);
    },
    coexistenceSyncFailureCount() {
      return this.coexistenceSync?.history_failed_messages?.length || 0;
    },
    coexistenceRecoveryRequired() {
      const recoveryStates = [
        'failed',
        'history_failed',
        'history_declined',
        'request_outcome_unknown',
        'manual_recovery_required',
      ];
      return (
        recoveryStates.includes(this.coexistenceSync?.state) ||
        this.coexistenceSync?.contacts_state === 'manual_recovery_required'
      );
    },
    whatsappAppId() {
      return window.chatwootConfig?.whatsappAppId;
    },
    isForwardingEnabled() {
      return !!this.inbox.forwarding_enabled;
    },
    isAWhatsAppWebInbox() {
      return this.inbox.channel_type === 'Channel::WhatsappWeb';
    },
    isVirtualPbxVoiceInbox() {
      return (
        this.inbox.channel_type === 'Channel::Voice' &&
        ['asterisk_analog', 'sipuni', 'binotel', 'beeline', 'wazo'].includes(
          this.inbox.provider
        )
      );
    },
    isSipuniVoiceInbox() {
      return (
        this.inbox.channel_type === 'Channel::Voice' &&
        this.inbox.provider === 'sipuni'
      );
    },
    isBinotelVoiceInbox() {
      return (
        this.inbox.channel_type === 'Channel::Voice' &&
        this.inbox.provider === 'binotel'
      );
    },
    isBeelineVoiceInbox() {
      return (
        this.inbox.channel_type === 'Channel::Voice' &&
        this.inbox.provider === 'beeline'
      );
    },
    sipuniWebhookUrl() {
      const token = this.sipuniWebhookToken.trim();
      if (!token) return '';

      const baseUrl =
        window.chatwootConfig?.hostURL || window.location.origin || '';
      return `${baseUrl.replace(/\/$/, '')}/sipuni/events/${encodeURIComponent(token)}`;
    },
    binotelWebhookUrl() {
      const token = this.binotelWebhookToken.trim();
      if (!token) return '';

      const baseUrl =
        window.chatwootConfig?.hostURL || window.location.origin || '';
      return `${baseUrl.replace(/\/$/, '')}/binotel/events/${encodeURIComponent(token)}`;
    },
    beelineWebhookUrl() {
      const token = this.beelineWebhookToken.trim();
      if (!token) return '';

      const baseUrl =
        window.chatwootConfig?.hostURL || window.location.origin || '';
      return `${baseUrl.replace(/\/$/, '')}/beeline/events/${encodeURIComponent(token)}`;
    },
    virtualPbxLoadKey() {
      return [
        this.inbox.id || '',
        this.inbox.channel_type || '',
        this.inbox.provider || '',
      ].join(':');
    },
    virtualPbxConfig() {
      return (
        this.virtualPbxStatusPayload?.ui_config ||
        this.virtualPbxStatusPayload?.config ||
        null
      );
    },
    virtualPbxWarnings() {
      return this.virtualPbxStatusPayload?.warnings || [];
    },
    virtualPbxErrors() {
      return this.virtualPbxStatusPayload?.errors || [];
    },
    virtualPbxSyncStatus() {
      return (
        this.virtualPbxConfig?.status?.label ||
        this.virtualPbxConfig?.status?.status ||
        ''
      );
    },
    virtualPbxPlanOperations() {
      return this.virtualPbxProvisioningPlan?.operations || [];
    },
    virtualPbxLastProvisioningRun() {
      return this.virtualPbxProvisioningRuns?.[0] || null;
    },
    isVirtualPbxRemoteCommitAllowed() {
      return !!this.virtualPbxConfig?.permissions?.remote_commit_allowed;
    },
    isVirtualPbxReadOnly() {
      return !!(
        this.virtualPbxConfig?.status?.read_only ||
        this.virtualPbxConfig?.ownership?.read_only
      );
    },
    virtualPbxProviderKind() {
      return (
        this.virtualPbxForm.providerKind ||
        this.virtualPbxConfig?.provider_kind ||
        ''
      );
    },
    isVirtualPbxSipCredentialsVisible() {
      return ['asterisk_analog', 'sipuni', 'binotel', 'beeline'].includes(
        this.virtualPbxProviderKind
      );
    },
    isVirtualPbxProviderOwnedSip() {
      return ['sipuni', 'binotel'].includes(this.virtualPbxProviderKind);
    },
    isVirtualPbxLocalNativeProvider() {
      return [
        'asterisk_analog',
        'sipuni',
        'binotel',
        'beeline',
        'wazo',
      ].includes(this.virtualPbxProviderKind);
    },
    showVirtualPbxTechnicalSettings() {
      return !this.isVirtualPbxProviderOwnedSip;
    },
    virtualPbxManagementLabel() {
      if (this.isVirtualPbxProviderOwnedSip) {
        return this.$t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE'
        );
      }

      return this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.MANAGEMENT_TITLE');
    },
    virtualPbxManagementHelpText() {
      if (this.isVirtualPbxProviderOwnedSip) {
        return this.$t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.HINT'
        );
      }

      return this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.MANAGEMENT_SUBTITLE');
    },
    isVirtualPbxAsteriskAnalog() {
      return this.virtualPbxProviderKind === 'asterisk_analog';
    },
    isVirtualPbxBeeline() {
      return this.virtualPbxProviderKind === 'beeline';
    },
    isVirtualPbxWazo() {
      return this.virtualPbxProviderKind === 'wazo';
    },
    isVirtualPbxCarrierLocked() {
      return Boolean(this.virtualPbxLockedCarrierKind);
    },
    isVirtualPbxKnownCarrierPreset() {
      return KNOWN_CARRIER_PRESETS.includes(this.virtualPbxForm.carrierKind);
    },
    virtualPbxCarrierBadgeUrl() {
      return (
        CARRIER_BADGES[this.virtualPbxForm.carrierKind] ||
        CARRIER_BADGES[this.virtualPbxProviderKind] ||
        ''
      );
    },
    callRoutingRingtoneOptions() {
      return [
        {
          value: 'default',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.DEFAULT'
          ),
        },
        {
          value: 'classic',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.CLASSIC'
          ),
        },
        {
          value: 'soft',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.SOFT'
          ),
        },
        {
          value: 'urgent',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.URGENT'
          ),
        },
      ];
    },
    callRoutingGroupStrategyOptions() {
      return [
        {
          value: 'broadcast',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUP_STRATEGIES.BROADCAST'
          ),
        },
        {
          value: 'least_recent',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUP_STRATEGIES.LEAST_RECENT'
          ),
        },
        {
          value: 'round_robin',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUP_STRATEGIES.ROUND_ROBIN'
          ),
        },
      ];
    },
    callRoutingActionOptions() {
      return [
        {
          value: 'reject',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.REJECT'
          ),
        },
        {
          value: 'ai',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.AI'
          ),
        },
        {
          value: 'forward',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.FORWARD'
          ),
        },
      ];
    },
    virtualPbxTransportOptions() {
      return ['udp', 'tcp', 'tls'];
    },
    virtualPbxOutboundDialFormatOptions() {
      const kzTrunk = {
        value: 'kz_trunk',
        label: this.$t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.KZ_TRUNK'
        ),
      };
      const stripPlus = {
        value: 'strip_plus',
        label: this.$t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.STRIP_PLUS'
        ),
      };

      if (this.isVirtualPbxBeeline) {
        return [
          {
            value: BEELINE_OUTBOUND_DIAL_FORMAT,
            label: this.$t(
              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.E164_PLUS'
            ),
          },
          kzTrunk,
          stripPlus,
        ];
      }

      return [
        kzTrunk,
        stripPlus,
        {
          value: 'e164',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.E164'
          ),
        },
      ];
    },
    isVirtualPbxDialFormatEditable() {
      return this.isVirtualPbxAsteriskAnalog || this.isVirtualPbxBeeline;
    },
    virtualPbxProviderOptions() {
      return [
        {
          value: 'sipuni',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.SIPUNI'
          ),
        },
        {
          value: 'binotel',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.BINOTEL'
          ),
        },
        {
          value: 'asterisk_analog',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.ASTERISK_ANALOG'
          ),
        },
        {
          value: 'beeline',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.BEELINE'
          ),
        },
        {
          value: 'wazo',
          label: this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.WAZO'),
        },
      ];
    },
    virtualPbxCarrierOptions() {
      return [
        {
          value: 'altel',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIERS.ALTEL'
          ),
        },
        {
          value: 'tele2',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIERS.TELE2'
          ),
        },
        {
          value: 'kazakhtelecom',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIERS.KAZAKHTELECOM'
          ),
        },
        {
          value: 'kcell',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIERS.KCELL'
          ),
        },
        {
          value: 'beeline_trunk',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIERS.BEELINE_TRUNK'
          ),
        },
        {
          value: 'custom',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIERS.CUSTOM'
          ),
        },
      ];
    },
    virtualPbxRingStrategyOptions() {
      return [
        {
          value: 'all',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.RING_STRATEGIES.ALL'
          ),
        },
        {
          value: 'least_recent',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.RING_STRATEGIES.LEAST_RECENT'
          ),
        },
        {
          value: 'memorized_round_robin',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.RING_STRATEGIES.MEMORIZED_ROUND_ROBIN'
          ),
        },
      ];
    },
    virtualPbxRoutingOptions() {
      return [
        {
          value: 'operator',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ROUTING.MODE.OPERATOR'
          ),
        },
        {
          value: 'reject',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ROUTING.MODE.REJECT'
          ),
        },
      ];
    },
    virtualPbxOperatorDistributionOptions() {
      return [
        {
          value: 'broadcast',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OPERATOR_DISTRIBUTION.BROADCAST'
          ),
        },
        {
          value: 'targeted',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OPERATOR_DISTRIBUTION.TARGETED'
          ),
        },
      ];
    },
    virtualPbxMemberOptions() {
      const byId = new Map();
      const addMember = member => {
        const id = Number(member?.id || member?.user_id);
        if (!id || byId.has(id)) return;

        byId.set(id, {
          value: id,
          label:
            member.name ||
            member.user_name ||
            member.available_name ||
            member.email ||
            `#${id}`,
        });
      };

      (this.virtualPbxInboxMembers || []).forEach(addMember);
      (
        this.inbox.members ||
        this.inbox.agents ||
        this.inbox.users ||
        []
      ).forEach(addMember);
      (
        this.virtualPbxConfig?.employees ||
        this.virtualPbxConfig?.profiles ||
        []
      ).forEach(profile =>
        addMember({
          id: profile.user_id,
          name: profile.user_name,
        })
      );

      return Array.from(byId.values());
    },
    whatsappInboxOptions() {
      const allInboxes =
        this.$store?.getters?.['inboxes/getInboxes'] || this.inboxes || [];
      return allInboxes.filter(item => {
        const channelType = String(
          item?.channel_type || item?.channelType || ''
        );
        const provider = String(item?.provider || '').toLowerCase();
        return (
          channelType === 'Channel::Whatsapp' ||
          channelType === 'Channel::WhatsappWeb' ||
          (channelType === 'Channel::TwilioSms' &&
            item?.medium === 'whatsapp') ||
          channelType.toLowerCase().includes('whatsapp') ||
          provider.includes('whatsapp')
        );
      });
    },
    selectedWhatsappFollowupInbox() {
      const inboxId = Number(
        this.callRoutingForm?.inbound?.whatsapp_followup?.inbox_id || 0
      );
      if (!inboxId) return null;
      return (
        this.whatsappInboxOptions.find(item => Number(item.id) === inboxId) ||
        null
      );
    },
    isSelectedWhatsappFollowupOfficial() {
      const inbox = this.selectedWhatsappFollowupInbox;
      if (!inbox) return false;
      const channelType = String(
        inbox.channel_type || inbox.channelType || ''
      );
      const provider = String(inbox.provider || '').toLowerCase();
      if (
        channelType === 'Channel::WhatsappWeb' ||
        provider === 'whatsapp_web' ||
        provider === 'baileys' ||
        provider === 'personal' ||
        provider === 'unofficial'
      ) {
        return false;
      }
      return (
        channelType === 'Channel::Whatsapp' ||
        provider === 'whatsapp_cloud' ||
        provider === '360dialog' ||
        Array.isArray(inbox.message_templates)
      );
    },
    selectedWhatsappFollowupTemplates() {
      const inbox = this.selectedWhatsappFollowupInbox;
      if (!inbox) return [];
      const templates =
        this.$store?.getters?.['inboxes/getWhatsAppTemplates']?.(inbox.id) ||
        inbox.message_templates ||
        inbox.messageTemplates ||
        [];
      return Array.isArray(templates)
        ? templates.filter(
            tpl =>
              tpl &&
              tpl.name &&
              (!tpl.status || String(tpl.status).toLowerCase() === 'approved')
          )
        : [];
    },
    effectiveAiMaxConcurrentCalls() {
      const limit = Number(
        this.virtualPbxForm.maxChannels ||
          this.virtualPbxConfig?.connection?.ai_max_concurrent_calls ||
          2
      );
      return Number.isFinite(limit) && limit > 0 ? limit : 1;
    },
    isExternalPbxRoutingAuthority() {
      return (
        this.isVirtualPbxVoiceInbox &&
        !this.isVirtualPbxWazo &&
        this.callRoutingForm?.inbound?.routing_authority === 'external_pbx'
      );
    },
  },
  watch: {
    inbox() {
      this.setDefaults();
    },
    virtualPbxLoadKey() {
      this.loadVirtualPbxStatus();
      this.loadVirtualPbxMembers();
    },
    allowMobileWebview() {
      if (!this.isSettingDefaults) this.handleMobileWebviewFlag();
    },
    hmacMandatory() {
      if (!this.isSettingDefaults && this.isAWebWidgetInbox)
        this.handleHmacFlag();
    },
  },
  mounted() {
    this.setDefaults();
    this.loadVirtualPbxStatus();
    this.loadVirtualPbxMembers();
  },
  methods: {
    setDefaults() {
      this.isSettingDefaults = true;
      this.hmacMandatory = this.inbox.hmac_mandatory || false;
      this.allowMobileWebview = (
        this.inbox.selected_feature_flags || []
      ).includes('allow_mobile_webview');
      this.allowedDomains = this.inbox.allowed_domains || '';
      this.callingEnabled = Object.prototype.hasOwnProperty.call(
        this.inbox.provider_config || {},
        'calling_enabled'
      )
        ? !!this.inbox.provider_config.calling_enabled
        : !!this.inbox.provider_config?.calling_capable;
      this.aiVoiceEnabled = !!this.inbox.provider_config?.ai_voice_enabled;
      if (this.isAWhatsAppChannel && !this.isATwilioChannel) {
        this.callRoutingForm = this.normalizeCallRoutingConfig(
          this.inbox.provider_config?.call_routing
        );
        this.callRoutingDirty = false;
      }
      this.sipuniWebhookToken =
        this.inbox.provider_config?.sipuni_events_webhook_token ||
        this.inbox.provider_config?.sipuni_webhook_token ||
        '';
      this.binotelWebhookToken =
        this.inbox.provider_config?.binotel_events_webhook_token ||
        this.inbox.provider_config?.binotel_webhook_token ||
        '';
      this.beelineWebhookToken =
        this.inbox.provider_config?.beeline_events_webhook_token ||
        this.inbox.provider_config?.beeline_webhook_token ||
        '';
      this.beelineApiToken = '';
      this.beelineApiTokenConfigured = Boolean(
        this.inbox.provider_config?.beeline_api_token_configured ||
          this.inbox.provider_config?.beeline_api_token
      );
      this.$nextTick(() => {
        this.isSettingDefaults = false;
      });
    },
    handleHmacFlag() {
      this.updateInbox();
    },
    async updateInbox() {
      try {
        const payload = {
          id: this.inbox.id,
          formData: false,
          channel: {
            hmac_mandatory: this.hmacMandatory,
          },
        };
        await this.$store.dispatch('inboxes/updateInbox', payload);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    async handleMobileWebviewFlag() {
      try {
        const currentFlags = this.inbox.selected_feature_flags || [];
        const selectedFlags = this.allowMobileWebview
          ? [...currentFlags, 'allow_mobile_webview']
          : currentFlags.filter(f => f !== 'allow_mobile_webview');

        const payload = {
          id: this.inbox.id,
          formData: false,
          channel: {
            selected_feature_flags: selectedFlags,
          },
        };
        await this.$store.dispatch('inboxes/updateInbox', payload);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    async updateAllowedDomains() {
      this.isUpdatingAllowedDomains = true;
      const sanitizedAllowedDomains = sanitizeAllowedDomains(
        this.allowedDomains
      );
      try {
        const payload = {
          id: this.inbox.id,
          formData: false,
          channel: {
            allowed_domains: sanitizedAllowedDomains,
          },
        };
        await this.$store.dispatch('inboxes/updateInbox', payload);
        this.allowedDomains = sanitizedAllowedDomains;
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdatingAllowedDomains = false;
      }
    },
    async updateWhatsAppInboxAPIKey() {
      try {
        const payload = {
          id: this.inbox.id,
          formData: false,
          channel: {},
        };

        payload.channel.provider_config = { api_key: this.whatsAppInboxAPIKey };

        await this.$store.dispatch('inboxes/updateInbox', payload);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    routingModeLabel(mode) {
      switch (mode) {
        case 'app':
          return this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ROUTING.MODE.APP');
        case 'ai':
          return this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ROUTING.MODE.AI');
        case 'reject':
          return this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ROUTING.MODE.REJECT'
          );
        case 'operator':
        default:
          return this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ROUTING.MODE.OPERATOR'
          );
      }
    },
    virtualPbxI18n() {
      return { t: this.$t.bind(this), te: this.$te?.bind(this) };
    },
    formatVirtualPbxMessages(messages) {
      return virtualPbxErrorsText(messages, this.virtualPbxI18n());
    },
    virtualPbxErrorLabel(error) {
      return virtualPbxErrorText(error, this.virtualPbxI18n());
    },
    isValidVirtualPbxPort(value) {
      const port = String(value || '').trim();
      if (!/^\d+$/.test(port)) return false;

      const numericPort = Number(port);
      return (
        Number.isInteger(numericPort) &&
        numericPort >= 1 &&
        numericPort <= 65535
      );
    },
    handleVirtualPbxError(error) {
      useAlert(
        virtualPbxRequestErrorText(
          error,
          this.virtualPbxI18n(),
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_ERROR')
        )
      );
    },
    async loadVirtualPbxStatus() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) {
        this.virtualPbxStatusPayload = null;
        this.virtualPbxLoadError = '';
        return;
      }

      this.isLoadingVirtualPbxStatus = true;
      this.virtualPbxLoadError = '';
      try {
        const response = await VoiceAPI.getVirtualPbxStatus(this.inbox.id);
        this.virtualPbxStatusPayload = response?.payload || null;
        this.virtualPbxProvisioningPlan =
          this.virtualPbxStatusPayload?.provisioning_plan || null;
        this.prefillVirtualPbxForm();
        await this.loadVirtualPbxProvisioningRuns();
      } catch (error) {
        this.virtualPbxStatusPayload = null;
        this.virtualPbxLoadError = virtualPbxRequestErrorText(
          error,
          this.virtualPbxI18n(),
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.LOAD_ERROR')
        );
      } finally {
        this.isLoadingVirtualPbxStatus = false;
      }
    },
    async loadVirtualPbxMembers() {
      if (
        (!this.isVirtualPbxVoiceInbox && !this.isAWhatsAppChannel) ||
        !this.inbox.id
      ) {
        this.virtualPbxInboxMembers = [];
        return;
      }

      try {
        const response = await this.$store.dispatch('inboxMembers/get', {
          inboxId: this.inbox.id,
        });
        this.virtualPbxInboxMembers = this.normalizeVirtualPbxMembers(
          response?.data?.payload || response?.payload || response || []
        );
      } catch {
        this.virtualPbxInboxMembers = [];
      }
    },
    async loadVirtualPbxProvisioningRuns() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) {
        this.virtualPbxProvisioningRuns = [];
        return;
      }

      try {
        const response = await VoiceAPI.getVirtualPbxProvisioningRuns(
          this.inbox.id
        );
        this.virtualPbxProvisioningRuns =
          response?.payload?.provisioning_runs || [];
      } catch {
        this.virtualPbxProvisioningRuns = [];
      }
    },
    async loadVirtualPbxProvisioningPlan() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) return;

      this.isLoadingVirtualPbxPlan = true;
      try {
        const response = await VoiceAPI.getVirtualPbxProvisioningPlan(
          this.inbox.id,
          { operation: 'update', includeDiagnostics: false }
        );
        this.virtualPbxProvisioningPlan =
          response?.payload?.provisioning_plan || null;
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISIONING_PLAN_READY')
        );
      } catch (error) {
        this.handleVirtualPbxError(error);
      } finally {
        this.isLoadingVirtualPbxPlan = false;
      }
    },
    async provisionVirtualPbxChannel() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) return;
      if (
        this.isVirtualPbxWazo &&
        // Explicit safety gate for a remote Wazo control-plane mutation.
        // eslint-disable-next-line no-alert
        !window.confirm(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.WAZO_APPLY_CONFIRM')
        )
      ) {
        return;
      }

      this.isProvisioningVirtualPbx = true;
      try {
        const response = await VoiceAPI.provisionVirtualPbxChannel(
          this.inbox.id,
          {
            remoteCommit: this.isVirtualPbxWazo,
            includeDiagnostics: false,
          }
        );
        const payload = response?.payload || {};
        this.virtualPbxProvisioningPlan = payload.provisioning_plan || null;
        await this.loadVirtualPbxProvisioningRuns();

        if (payload.errors?.length) {
          useAlert(
            this.formatVirtualPbxMessages(payload.errors) ||
              this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISION_BLOCKED')
          );
          return;
        }

        useAlert(this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISION_SUCCESS'));
        await this.loadVirtualPbxStatus();
      } catch (error) {
        this.handleVirtualPbxError(error);
      } finally {
        this.isProvisioningVirtualPbx = false;
      }
    },
    async reconcileVirtualPbxChannel() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) return;

      this.isReconcilingVirtualPbx = true;
      try {
        const response = await VoiceAPI.reconcileVirtualPbxChannel(
          this.inbox.id,
          { includeDiagnostics: false }
        );
        this.virtualPbxReconcileResult = response?.payload || null;
        await this.loadVirtualPbxStatus();
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.RECONCILE_COMPLETE')
        );
      } catch (error) {
        this.handleVirtualPbxError(error);
      } finally {
        this.isReconcilingVirtualPbx = false;
      }
    },
    normalizeVirtualPbxMembers(members) {
      return (members || [])
        .map(member => ({
          id: Number(member.id || member.user_id),
          name:
            member.name ||
            member.user_name ||
            member.available_name ||
            member.email ||
            '',
        }))
        .filter(member => member.id);
    },
    nextVirtualPbxProfileId() {
      this.virtualPbxProfileCounter += 1;
      return `virtual-pbx-profile-${this.virtualPbxProfileCounter}`;
    },
    emptyVirtualPbxProfile() {
      return {
        clientId: this.nextVirtualPbxProfileId(),
        profileKind: 'human_operator',
        userId: '',
        userName: '',
        internalExtension: '',
        sipUsername: '',
        originalSipUsername: '',
        sipPassword: '',
        sipPasswordConfigured: false,
        enabled: true,
      };
    },
    normalizeVirtualPbxProfiles(profiles) {
      return (profiles || []).map(profile => ({
        clientId: this.nextVirtualPbxProfileId(),
        id: profile.id || null,
        profileKind:
          profile.profile_kind ||
          (profile.voice_agent ? 'voice_agent' : 'human_operator'),
        userId: Number(profile.user_id) || '',
        userName: profile.user_name || '',
        internalExtension: profile.internal_extension || '',
        sipUsername: profile.sip_username || '',
        originalSipUsername: profile.sip_username || '',
        sipPassword: '',
        sipPasswordConfigured: !!(
          profile.sip_password_configured || profile.access_configured
        ),
        enabled: profile.enabled !== false,
      }));
    },
    addVirtualPbxProfile() {
      this.virtualPbxForm.profiles.push(this.emptyVirtualPbxProfile());
    },
    removeVirtualPbxProfile(index) {
      this.virtualPbxForm.profiles.splice(index, 1);
    },
    hasAnotherVirtualPbxVoiceAgentProfile(index) {
      return this.virtualPbxForm.profiles.some(
        (profile, profileIndex) =>
          profileIndex !== index && profile.profileKind === 'voice_agent'
      );
    },
    isVirtualPbxVoiceAgentToggleDisabled(profile, index) {
      return (
        this.isVirtualPbxReadOnly ||
        (profile.profileKind !== 'voice_agent' &&
          this.hasAnotherVirtualPbxVoiceAgentProfile(index))
      );
    },
    onVirtualPbxProfileKindChange(profile) {
      if (profile.profileKind === 'voice_agent') {
        profile.userId = '';
      }
    },
    prefillVirtualPbxForm() {
      const config = this.virtualPbxConfig;
      if (!config) return;

      const phoneNumbers = config.phone_numbers || {};
      const channel = config.channel || {};
      const connection = config.connection || {};
      const providerConnection = {
        ...connection,
        ...(config.resources?.provider_connection || {}),
      };
      const providerConnectionMetadata = providerConnection.metadata || {};
      const routing = config.routing || {};
      const providerKind =
        channel.provider_kind ||
        connection.provider_kind ||
        config.provider_kind ||
        'sipuni';
      const carrierKind =
        channel.carrier_kind ||
        providerConnection.carrier_kind ||
        providerConnectionMetadata.carrier_kind ||
        '';
      const carrierPreset = WAZO_CARRIER_PRESETS[carrierKind] || null;
      this.virtualPbxLockedCarrierKind = carrierKind;

      this.virtualPbxForm = {
        ...this.virtualPbxForm,
        channelName: channel.name || config.name || this.inbox.name || '',
        providerKind,
        displayPhoneNumber:
          channel.display_phone_number ||
          phoneNumbers.display_phone_number ||
          this.inbox.phone_number ||
          '',
        providerAccountNumber:
          connection.provider_number ||
          phoneNumbers.provider_account_number ||
          '',
        ingressNumber: phoneNumbers.ingress_number || '',
        connectionHost:
          providerConnection.host ||
          (providerKind === 'wazo' ? defaultWazoSipHost() : ''),
        connectionPort: String(providerConnection.port || 5060),
        connectionTransport: providerConnection.transport || 'udp',
        connectionSipDomain:
          providerConnection.sip_domain ||
          providerConnectionMetadata.sip_domain ||
          '',
        connectionOutboundProxy:
          providerConnection.outbound_proxy ||
          providerConnectionMetadata.outbound_proxy ||
          '',
        connectionCodec:
          providerConnection.codec || providerConnectionMetadata.codec || '',
        outboundDialFormat:
          providerConnection.outbound_dial_format ||
          providerConnectionMetadata.outbound_dial_format ||
          (providerKind === 'beeline'
            ? BEELINE_OUTBOUND_DIAL_FORMAT
            : 'kz_trunk'),
        carrierKind,
        maxChannels: Number(
          providerConnection.max_channels ||
            providerConnectionMetadata.max_channels ||
            carrierPreset?.max ||
            2
        ),
        detectedChannelLimit:
          Number(
            providerConnection.detected_channel_limit ||
              providerConnectionMetadata.detected_channel_limit ||
              providerConnectionMetadata.wazo_detected_channel_limit
          ) || null,
        lastChannelLimitHitAt:
          providerConnection.last_channel_limit_hit_at ||
          providerConnectionMetadata.wazo_last_channel_limit_hit_at ||
          '',
        lastChannelProbeAt:
          providerConnection.last_channel_probe_at ||
          providerConnectionMetadata.last_channel_probe_at ||
          '',
        channelDetectionSource:
          providerConnection.detection_source ||
          providerConnectionMetadata.detection_source ||
          '',
        reservedInboundChannels: Number(
          providerConnection.reserved_inbound_channels ??
            providerConnectionMetadata.reserved_inbound_channels ??
            0
        ),
        ringStrategy:
          providerConnection.ring_strategy ||
          providerConnectionMetadata.ring_strategy ||
          'all',
        groupExtension:
          providerConnection.group_extension ||
          providerConnectionMetadata.group_extension ||
          '',
        trunkUsername:
          providerConnection.trunk_username ||
          providerConnectionMetadata.trunk_username ||
          '',
        trunkPassword: '',
        trunkPasswordConfigured: Boolean(
          providerConnection.trunk_password_configured ||
            providerConnectionMetadata.trunk_password_configured
        ),
        trunkDomain:
          providerConnection.trunk_domain ||
          providerConnectionMetadata.trunk_domain ||
          carrierPreset?.domain ||
          '',
        trunkHost:
          providerConnection.trunk_host ||
          providerConnectionMetadata.trunk_host ||
          carrierPreset?.host ||
          '',
        connectionUsername: providerConnection.username || '',
        connectionPassword: '',
        routingMode: routing.mode || 'operator',
        operatorDistributionMode:
          routing.operator_distribution_mode || 'broadcast',
        maxCallDurationMinutes: Math.round(
          Number(routing.max_call_duration_seconds || 1800) / 60
        ),
        profiles: this.normalizeVirtualPbxProfiles(
          config.employees || config.profiles || []
        ),
      };
      this.callRoutingForm = this.normalizeCallRoutingConfig(
        routing.call_routing
      );
      this.callRoutingDirty = false;
    },
    applyDetectedChannelLimit() {
      const limit = Number(this.virtualPbxForm.detectedChannelLimit);
      if (limit > 0) {
        this.virtualPbxForm.maxChannels = limit;
      }
    },
    async probeVirtualPbxChannelCapacity() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) return;

      this.isProbingVirtualPbxChannels = true;
      try {
        const response = await VoiceAPI.probeVirtualPbxChannelCapacity(
          this.inbox.id
        );
        const payload = response?.payload || {};
        if (payload.ui_config) {
          this.virtualPbxStatusPayload = {
            ...(this.virtualPbxStatusPayload || {}),
            ...payload,
            ui_config: payload.ui_config,
          };
        }
        const probe = payload.channel_capacity_probe || {};
        const detected = Number(
          probe.detected_channel_limit ||
            payload.channel_capacity?.detected_channel_limit ||
            payload.ui_config?.connection?.detected_channel_limit ||
            payload.config?.connection?.detected_channel_limit ||
            0
        );
        if (detected > 0) {
          this.virtualPbxForm.detectedChannelLimit = detected;
          this.virtualPbxForm.maxChannels = detected;
        }
        if (probe.probed_at) {
          this.virtualPbxForm.lastChannelProbeAt = probe.probed_at;
        }
        if (probe.detection_source) {
          this.virtualPbxForm.channelDetectionSource = probe.detection_source;
        }
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.PROBE_CHANNELS_SUCCESS',
            { count: detected || this.virtualPbxForm.maxChannels }
          )
        );
      } catch (error) {
        this.handleVirtualPbxError(error);
      } finally {
        this.isProbingVirtualPbxChannels = false;
      }
    },
    setCallRoutingAuthority(authority) {
      if (this.isVirtualPbxWazo) {
        this.callRoutingForm.inbound.routing_authority = 'onelink';
        return;
      }
      this.callRoutingForm.inbound.routing_authority =
        authority === 'external_pbx' ? 'external_pbx' : 'onelink';
      this.markCallRoutingDirty();
    },
    normalizeCallRoutingConfig(raw) {
      const defaults = defaultCallRoutingConfig();
      if (!raw || typeof raw !== 'object') return defaults;

      const inbound = raw.inbound || {};
      const outbound = raw.outbound || {};
      const rawFollowup = inbound.whatsapp_followup || {};
      const rawGroups = Array.isArray(inbound.groups) ? inbound.groups : [];
      const groups = rawGroups.length
        ? rawGroups.map((group, idx) => ({
            id: group.id || `group-${idx + 1}`,
            name: group.name || '',
            strategy: group.strategy || 'broadcast',
            ring_seconds: Number(group.ring_seconds || 25),
            user_ids: Array.isArray(group.user_ids)
              ? group.user_ids
                  .map(id => Number(id))
                  .filter(id => Number.isFinite(id) && id > 0)
              : [],
          }))
        : defaults.inbound.groups;
      const isWazo =
        this.isVirtualPbxWazo || this.virtualPbxForm?.providerKind === 'wazo';
      const routingAuthority = isWazo
        ? 'onelink'
        : inbound.routing_authority === 'external_pbx'
          ? 'external_pbx'
          : 'onelink';

      return {
        show_extended_call_card:
          raw.show_extended_call_card !== undefined
            ? Boolean(raw.show_extended_call_card)
            : defaults.show_extended_call_card,
        inbound: {
          routing_authority: routingAuthority,
          schedule_mode:
            inbound.schedule_mode || defaults.inbound.schedule_mode,
          off_hours_action:
            inbound.off_hours_action || defaults.inbound.off_hours_action,
          off_hours_forward_number: inbound.off_hours_forward_number || '',
          ring_timeout_seconds: Number(
            inbound.ring_timeout_seconds ||
              defaults.inbound.ring_timeout_seconds
          ),
          skip_busy_operators:
            inbound.skip_busy_operators !== undefined
              ? Boolean(inbound.skip_busy_operators)
              : defaults.inbound.skip_busy_operators,
          ringtone: inbound.ringtone || defaults.inbound.ringtone,
          groups,
          fallback_action:
            inbound.fallback_action || defaults.inbound.fallback_action,
          fallback_forward_number: inbound.fallback_forward_number || '',
          whatsapp_followup: {
            enabled: Boolean(rawFollowup.enabled),
            inbox_id: rawFollowup.inbox_id ? Number(rawFollowup.inbox_id) : '',
            template_name: rawFollowup.template_name || '',
            template_language: rawFollowup.template_language || 'ru',
            custom_message: rawFollowup.custom_message || '',
            cooldown_minutes: Number(rawFollowup.cooldown_minutes || 60),
          },
        },
        outbound: {
          access_mode: outbound.access_mode || defaults.outbound.access_mode,
          allowed_user_ids: Array.isArray(outbound.allowed_user_ids)
            ? outbound.allowed_user_ids
                .map(id => Number(id))
                .filter(id => Number.isFinite(id) && id > 0)
            : [],
          caller_id_number: outbound.caller_id_number || '',
        },
      };
    },
    serializeCallRoutingConfig() {
      const inbound = this.callRoutingForm.inbound || {};
      const outbound = this.callRoutingForm.outbound || {};
      const followup = inbound.whatsapp_followup || {};
      const isWazo =
        this.isVirtualPbxWazo || this.virtualPbxForm?.providerKind === 'wazo';
      const routingAuthority = isWazo
        ? 'onelink'
        : inbound.routing_authority === 'external_pbx'
          ? 'external_pbx'
          : 'onelink';

      return {
        show_extended_call_card:
          this.callRoutingForm.show_extended_call_card !== false,
        inbound: {
          routing_authority: routingAuthority,
          schedule_mode: inbound.schedule_mode || 'always',
          off_hours_action: inbound.off_hours_action || 'reject',
          off_hours_forward_number: (
            inbound.off_hours_forward_number || ''
          ).trim(),
          ring_timeout_seconds: Number(inbound.ring_timeout_seconds || 30),
          skip_busy_operators: Boolean(inbound.skip_busy_operators),
          ringtone: inbound.ringtone || 'default',
          groups: (inbound.groups || []).map((group, idx) => ({
            id: group.id || `group-${idx + 1}`,
            name: (group.name || '').trim(),
            strategy: group.strategy || 'broadcast',
            ring_seconds: Number(group.ring_seconds || 25),
            user_ids: (group.user_ids || [])
              .map(id => Number(id))
              .filter(id => Number.isFinite(id) && id > 0),
          })),
          fallback_action: inbound.fallback_action || 'reject',
          fallback_forward_number: (
            inbound.fallback_forward_number || ''
          ).trim(),
          whatsapp_followup: {
            enabled: Boolean(followup.enabled),
            inbox_id: followup.inbox_id ? Number(followup.inbox_id) : null,
            template_name: (followup.template_name || '').trim(),
            template_language: (followup.template_language || 'ru').trim(),
            custom_message: (followup.custom_message || '').trim(),
            cooldown_minutes: Math.min(
              Math.max(Number(followup.cooldown_minutes || 60), 5),
              1440
            ),
          },
        },
        outbound: {
          access_mode: outbound.access_mode || 'all_members',
          allowed_user_ids: (outbound.allowed_user_ids || [])
            .map(id => Number(id))
            .filter(id => Number.isFinite(id) && id > 0),
          caller_id_number: (outbound.caller_id_number || '').trim(),
        },
      };
    },
    markCallRoutingDirty() {
      this.callRoutingDirty = true;
    },
    addCallRoutingGroup() {
      const nextIndex = (this.callRoutingForm.inbound.groups?.length || 0) + 1;
      this.callRoutingForm.inbound.groups.push({
        id: `group-${Date.now()}-${nextIndex}`,
        name: '',
        strategy: 'broadcast',
        ring_seconds: 25,
        user_ids: [],
      });
      this.markCallRoutingDirty();
    },
    removeCallRoutingGroup(index) {
      if (this.callRoutingForm.inbound.groups.length <= 1) return;
      this.callRoutingForm.inbound.groups.splice(index, 1);
      this.markCallRoutingDirty();
    },
    toggleCallRoutingGroupUser(group, userId) {
      const numericId = Number(userId);
      if (!numericId) return;
      const existingIndex = (group.user_ids || []).indexOf(numericId);
      if (existingIndex >= 0) {
        group.user_ids.splice(existingIndex, 1);
      } else {
        group.user_ids.push(numericId);
      }
      this.markCallRoutingDirty();
    },
    toggleCallRoutingOutboundUser(userId) {
      const numericId = Number(userId);
      if (!numericId) return;
      const list = this.callRoutingForm.outbound.allowed_user_ids;
      const existingIndex = list.indexOf(numericId);
      if (existingIndex >= 0) {
        list.splice(existingIndex, 1);
      } else {
        list.push(numericId);
      }
      this.markCallRoutingDirty();
    },
    async saveWhatsAppCallRouting() {
      this.isSavingWhatsAppCallRouting = true;
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...this.inbox.provider_config,
              call_routing: this.serializeCallRoutingConfig(),
            },
          },
        });
        this.callRoutingDirty = false;
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isSavingWhatsAppCallRouting = false;
      }
    },
    validateVirtualPbxForm() {
      const form = this.virtualPbxForm;
      if (
        this.showVirtualPbxTechnicalSettings &&
        (!form.channelName.trim() || !form.displayPhoneNumber.trim())
      ) {
        useAlert(this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.REQUIRED_FIELDS'));
        return false;
      }

      return (
        this.validateVirtualPbxConnection() &&
        this.validateVirtualPbxProfiles() &&
        this.validateVirtualPbxProfileCredentials()
      );
    },
    validateVirtualPbxConnection() {
      const form = this.virtualPbxForm;
      if (!this.showVirtualPbxTechnicalSettings) return true;

      if (!form.connectionHost.trim()) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.REQUIRED')
        );
        return false;
      }
      if (
        this.isVirtualPbxBeeline &&
        (!form.connectionSipDomain.trim() ||
          !form.connectionOutboundProxy.trim())
      ) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.BEELINE_REQUIRED_FIELDS')
        );
        return false;
      }
      if (
        this.isVirtualPbxAsteriskAnalog &&
        !this.isValidVirtualPbxPort(form.connectionPort)
      ) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.INVALID')
        );
        return false;
      }

      return true;
    },
    validateVirtualPbxProfiles() {
      const invalidProfile = this.virtualPbxForm.profiles.find(profile => {
        const isVoiceAgent = profile.profileKind === 'voice_agent';
        return (
          (!isVoiceAgent && !profile.userId) ||
          !profile.internalExtension.trim()
        );
      });

      if (invalidProfile) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.REQUIRED')
        );
        return false;
      }

      const voiceAgentProfiles = this.virtualPbxForm.profiles.filter(
        profile => profile.profileKind === 'voice_agent'
      );
      if (voiceAgentProfiles.length > 1) {
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.VOICE_AGENT_UNIQUE'
          )
        );
        return false;
      }

      return true;
    },
    validateVirtualPbxProfileCredentials() {
      if (!this.isVirtualPbxSipCredentialsVisible) return true;

      const invalidProfile = this.virtualPbxForm.profiles.find(profile => {
        const isVoiceAgent = profile.profileKind === 'voice_agent';
        const hasUsername = !!profile.sipUsername?.trim();
        const hasPassword = !!profile.sipPassword?.trim();
        const usernameChanged =
          (profile.sipUsername || '').trim() !==
          (profile.originalSipUsername || '').trim();

        if (isVoiceAgent && !hasUsername) return true;
        if (!hasUsername) return hasPassword;
        if (hasPassword) return false;

        return !profile.sipPasswordConfigured || usernameChanged;
      });

      if (!invalidProfile) return true;

      useAlert(
        this.$t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SIP_PAIR_REQUIRED'
        )
      );
      return false;
    },
    virtualPbxSipPasswordPlaceholder(profile) {
      if (profile.sipPasswordConfigured) return '********';

      return this.$t(
        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.PLACEHOLDER'
      );
    },
    virtualPbxProfilesPayload() {
      return this.virtualPbxForm.profiles.map(profile => {
        const payload = {
          profile_kind: profile.profileKind || 'human_operator',
          internal_extension: profile.internalExtension.trim(),
          enabled: profile.enabled !== false,
        };
        if (profile.id) {
          payload.id = profile.id;
        }
        if (payload.profile_kind !== 'voice_agent') {
          payload.user_id = profile.userId;
        }
        const sipUsername = profile.sipUsername?.trim();
        const sipPassword = profile.sipPassword?.trim();
        if (this.isVirtualPbxSipCredentialsVisible && sipUsername) {
          payload.sip_username = sipUsername;
        }
        if (this.isVirtualPbxSipCredentialsVisible && sipPassword) {
          payload.sip_password = sipPassword;
        }
        return payload;
      });
    },
    virtualPbxUpdatePayload() {
      const form = this.virtualPbxForm;
      const payload = {
        expected_configuration_version:
          this.virtualPbxConfig?.configuration_version,
        provider_kind: form.providerKind,
        channel_name: form.channelName.trim(),
        display_phone_number: form.displayPhoneNumber.trim(),
        routing: {
          mode: form.routingMode,
          fallback_mode: 'reject',
          operator_distribution_mode:
            form.operatorDistributionMode || 'broadcast',
          max_call_duration_seconds:
            Number(form.maxCallDurationMinutes || 30) * 60,
        },
        profiles: this.virtualPbxProfilesPayload(),
        metadata: {
          source: 'virtual_pbx_ui',
        },
      };

      if (
        this.callRoutingDirty ||
        Boolean(this.virtualPbxConfig?.routing?.call_routing)
      ) {
        payload.routing.call_routing = this.serializeCallRoutingConfig();
      }

      if (this.isVirtualPbxDialFormatEditable) {
        payload.metadata.outbound_dial_format = form.outboundDialFormat;
      }

      payload.connection = {
        host: form.connectionHost.trim(),
      };

      if (this.isVirtualPbxAsteriskAnalog) {
        payload.connection.port = form.connectionPort.trim();
        payload.connection.transport = form.connectionTransport;
      }
      if (this.isVirtualPbxBeeline) {
        payload.connection.port = '5060';
        payload.connection.transport = 'udp';
        payload.connection.sip_domain = form.connectionSipDomain.trim();
        payload.connection.outbound_proxy = form.connectionOutboundProxy.trim();
        payload.connection.codec = 'pcma';
      }
      if (this.isVirtualPbxWazo) {
        payload.connection.max_channels = Number(form.maxChannels || 2);
        payload.connection.reserved_inbound_channels = Number(
          form.reservedInboundChannels || 0
        );
        if (form.carrierKind) {
          payload.connection.carrier_kind = form.carrierKind;
          payload.metadata.carrier_kind = form.carrierKind;
        }
        if (form.ringStrategy && form.ringStrategy !== 'all') {
          payload.connection.ring_strategy = form.ringStrategy;
        } else if (form.carrierKind && form.ringStrategy) {
          payload.connection.ring_strategy = form.ringStrategy;
        }
        if (form.groupExtension && String(form.groupExtension).trim()) {
          payload.connection.group_extension = String(
            form.groupExtension
          ).trim();
        }
        if (form.trunkUsername && form.trunkUsername.trim()) {
          payload.connection.trunk_username = form.trunkUsername.trim();
        }
        if (form.trunkPassword && form.trunkPassword.trim()) {
          payload.connection.trunk_password = form.trunkPassword.trim();
        }
        if (form.trunkDomain && form.trunkDomain.trim()) {
          payload.connection.trunk_domain = form.trunkDomain.trim();
        }
        if (form.trunkHost && form.trunkHost.trim()) {
          payload.connection.trunk_host = form.trunkHost.trim();
        }
      }

      return payload;
    },
    onVirtualPbxCarrierChange() {
      const preset = WAZO_CARRIER_PRESETS[this.virtualPbxForm.carrierKind];
      if (!preset) return;
      this.virtualPbxForm.trunkDomain = preset.domain;
      this.virtualPbxForm.trunkHost = preset.host;
      if (!this.virtualPbxForm.maxChannels) {
        this.virtualPbxForm.maxChannels = preset.max;
      }
    },
    async updateVirtualPbxChannel() {
      if (this.isVirtualPbxReadOnly) {
        useAlert(this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.READ_ONLY'));
        return;
      }

      if (!this.validateVirtualPbxForm()) return;

      this.isUpdatingVirtualPbx = true;
      try {
        const response = await VoiceAPI.updateVirtualPbxChannel(
          this.inbox.id,
          this.virtualPbxUpdatePayload(),
          { dryRun: false, remoteCommit: false }
        );
        const errors = response?.payload?.errors || [];
        if (errors.length) {
          useAlert(this.formatVirtualPbxMessages(errors));
          return;
        }

        useAlert(this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_SUCCESS'));
        await this.loadVirtualPbxStatus();
      } catch (error) {
        this.handleVirtualPbxError(error);
      } finally {
        this.isUpdatingVirtualPbx = false;
      }
    },
    async handleReconfigure() {
      if (this.$refs.whatsappReauth) {
        await this.$refs.whatsappReauth.requestAuthorization();
      }
    },
    async updateCallingEnabled() {
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...this.inbox.provider_config,
              calling_enabled: this.callingEnabled,
            },
          },
        });
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    async updateAiVoiceEnabled() {
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...this.inbox.provider_config,
              ai_voice_enabled: this.aiVoiceEnabled,
            },
          },
        });
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    generateSipuniWebhookToken() {
      if (window.crypto?.getRandomValues) {
        const bytes = new Uint8Array(24);
        window.crypto.getRandomValues(bytes);
        this.sipuniWebhookToken = Array.from(bytes, byte =>
          byte.toString(16).padStart(2, '0')
        ).join('');
        return;
      }

      this.sipuniWebhookToken = `${Date.now()}${Math.random()
        .toString(36)
        .slice(2)}`;
    },
    async copySipuniWebhookUrl() {
      if (!this.sipuniWebhookUrl) return;

      try {
        await copyTextToClipboard(this.sipuniWebhookUrl);
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_COPY_SUCCESS'
          )
        );
      } catch {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    async updateSipuniWebhookToken() {
      const token = this.sipuniWebhookToken.trim();
      if (!token) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_REQUIRED')
        );
        return;
      }

      this.isUpdatingSipuniWebhook = true;
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...this.inbox.provider_config,
              sipuni_events_webhook_token: token,
            },
          },
        });
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_SUCCESS')
        );
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdatingSipuniWebhook = false;
      }
    },
    generateBinotelWebhookToken() {
      if (window.crypto?.getRandomValues) {
        const bytes = new Uint8Array(24);
        window.crypto.getRandomValues(bytes);
        this.binotelWebhookToken = Array.from(bytes, byte =>
          byte.toString(16).padStart(2, '0')
        ).join('');
        return;
      }

      this.binotelWebhookToken = `${Date.now()}${Math.random()
        .toString(36)
        .slice(2)}`;
    },
    async copyBinotelWebhookUrl() {
      if (!this.binotelWebhookUrl) return;

      try {
        await copyTextToClipboard(this.binotelWebhookUrl);
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_COPY_SUCCESS'
          )
        );
      } catch {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    async updateBinotelWebhookToken() {
      const token = this.binotelWebhookToken.trim();
      if (!token) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_REQUIRED')
        );
        return;
      }

      this.isUpdatingBinotelWebhook = true;
      try {
        const providerConfig = { ...this.inbox.provider_config };
        delete providerConfig.binotel_webhook_token;
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...providerConfig,
              binotel_events_webhook_token: token,
            },
          },
        });
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_SUCCESS')
        );
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdatingBinotelWebhook = false;
      }
    },
    generateBeelineWebhookToken() {
      if (window.crypto?.getRandomValues) {
        const bytes = new Uint8Array(24);
        window.crypto.getRandomValues(bytes);
        this.beelineWebhookToken = Array.from(bytes, byte =>
          byte.toString(16).padStart(2, '0')
        ).join('');
        return;
      }

      this.beelineWebhookToken = `${Date.now()}${Math.random()
        .toString(36)
        .slice(2)}`;
    },
    async copyBeelineWebhookUrl() {
      if (!this.beelineWebhookUrl) return;

      try {
        await copyTextToClipboard(this.beelineWebhookUrl);
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_COPY_SUCCESS'
          )
        );
      } catch {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    async updateBeelineWebhookToken() {
      let token = this.beelineWebhookToken.trim();
      const apiToken = this.beelineApiToken.trim();
      if (!token && !apiToken && !this.beelineApiTokenConfigured) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_REQUIRED')
        );
        return;
      }
      if (!token && (apiToken || this.beelineApiTokenConfigured)) {
        this.generateBeelineWebhookToken();
        token = this.beelineWebhookToken.trim();
      }

      this.isUpdatingBeelineWebhook = true;
      try {
        const providerConfig = { ...this.inbox.provider_config };
        delete providerConfig.beeline_webhook_token;
        delete providerConfig.beeline_api_token_configured;
        if (token) {
          providerConfig.beeline_events_webhook_token = token;
        }
        if (apiToken) {
          providerConfig.beeline_api_token = apiToken;
        }
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: providerConfig,
          },
        });
        if (apiToken) {
          this.beelineApiTokenConfigured = true;
          this.beelineApiToken = '';
        }
        useAlert(
          this.$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_SUCCESS')
        );
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdatingBeelineWebhook = false;
      }
    },
    async syncTemplates() {
      this.isSyncingTemplates = true;
      try {
        await this.$store.dispatch('inboxes/syncTemplates', this.inbox.id);
        useAlert(
          this.$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUCCESS')
        );
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isSyncingTemplates = false;
      }
    },
  },
};
</script>

<template>
  <div v-if="isATwilioChannel">
    <SettingsFieldSection
      :label="$t('INBOX_MGMT.ADD.TWILIO.API_CALLBACK.TITLE')"
      :help-text="$t('INBOX_MGMT.ADD.TWILIO.API_CALLBACK.SUBTITLE')"
    >
      <woot-code :script="inbox.callback_webhook_url" lang="html" />
    </SettingsFieldSection>
    <SettingsFieldSection
      v-if="isATwilioWhatsAppChannel"
      :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_TITLE')"
      :help-text="
        $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUBHEADER')
      "
    >
      <NextButton :disabled="isSyncingTemplates" @click="syncTemplates">
        {{ $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON') }}
      </NextButton>
    </SettingsFieldSection>
  </div>
  <div v-else-if="isAVoiceChannel" class="space-y-4">
    <template v-if="inbox.provider === 'twilio'">
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.TWILIO_VOICE_URL_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.TWILIO_VOICE_URL_SUBTITLE')
        "
      >
        <woot-code :script="inbox.voice_call_webhook_url" lang="html" />
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.TWILIO_STATUS_URL_TITLE')
        "
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.TWILIO_STATUS_URL_SUBTITLE')
        "
      >
        <woot-code :script="inbox.voice_status_webhook_url" lang="html" />
      </SettingsFieldSection>
    </template>
    <template v-else>
      <SettingsFieldSection
        v-if="!isVirtualPbxVoiceInbox"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LEGACY_VOICE_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LEGACY_VOICE_SUBTITLE')
        "
      >
        <div class="flex flex-col gap-4">
          <woot-code :script="inbox.telephony?.number_ref || ''" lang="text" />
          <div class="text-sm text-n-slate-11">
            <span class="after:content-[':']">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ROUTING_MODE') }}
            </span>
            {{ routingModeLabel(inbox.telephony?.routing_policy?.mode) }}
          </div>
          <div v-if="inbox.telephony?.app_ref" class="text-sm text-n-slate-11">
            <span class="after:content-[':']">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.PRIMARY_APP_REF') }}
            </span>
            {{ inbox.telephony.app_ref }}
          </div>
          <div
            v-if="inbox.telephony?.routing_policy?.ai_app_ref"
            class="text-sm text-n-slate-11"
          >
            <span class="after:content-[':']">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.AI_APP_REF') }}
            </span>
            {{ inbox.telephony.routing_policy.ai_app_ref }}
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        v-if="isSipuniVoiceInbox"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_SUBTITLE')
        "
      >
        <div class="flex flex-col gap-4">
          <woot-code
            v-if="sipuniWebhookUrl"
            :script="sipuniWebhookUrl"
            lang="html"
          />
          <div
            v-else
            class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4 text-sm text-n-amber-11"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_EMPTY') }}
          </div>

          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_TOKEN') }}
            <input
              v-model="sipuniWebhookToken"
              class="rounded-lg border border-n-weak py-2 font-mono text-sm"
              type="text"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              :placeholder="
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_TOKEN_PLACEHOLDER'
                )
              "
            />
          </label>

          <div class="flex flex-wrap gap-3">
            <NextButton type="button" @click="generateSipuniWebhookToken">
              {{
                $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_GENERATE')
              }}
            </NextButton>
            <NextButton
              type="button"
              :disabled="!sipuniWebhookUrl"
              @click="copySipuniWebhookUrl"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_COPY') }}
            </NextButton>
            <NextButton
              type="button"
              :is-loading="isUpdatingSipuniWebhook"
              @click="updateSipuniWebhookToken"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_SAVE') }}
            </NextButton>
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        v-if="isBinotelVoiceInbox"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_SUBTITLE')
        "
      >
        <div class="flex flex-col gap-4">
          <woot-code
            v-if="binotelWebhookUrl"
            :script="binotelWebhookUrl"
            lang="html"
          />
          <div
            v-else
            class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4 text-sm text-n-amber-11"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_EMPTY') }}
          </div>

          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_TOKEN') }}
            <input
              v-model="binotelWebhookToken"
              class="rounded-lg border border-n-weak py-2 font-mono text-sm"
              type="text"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              :placeholder="
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_TOKEN_PLACEHOLDER'
                )
              "
            />
          </label>

          <div class="flex flex-wrap gap-3">
            <NextButton type="button" @click="generateBinotelWebhookToken">
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_GENERATE'
                )
              }}
            </NextButton>
            <NextButton
              type="button"
              :disabled="!binotelWebhookUrl"
              @click="copyBinotelWebhookUrl"
            >
              {{
                $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_COPY')
              }}
            </NextButton>
            <NextButton
              type="button"
              :is-loading="isUpdatingBinotelWebhook"
              @click="updateBinotelWebhookToken"
            >
              {{
                $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_SAVE')
              }}
            </NextButton>
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        v-if="isBeelineVoiceInbox"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_SUBTITLE')
        "
      >
        <div class="flex flex-col gap-4">
          <woot-code
            v-if="beelineWebhookUrl"
            :script="beelineWebhookUrl"
            lang="html"
          />
          <div
            v-else
            class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4 text-sm text-n-amber-11"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_EMPTY') }}
          </div>

          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TOKEN') }}
            <input
              v-model="beelineWebhookToken"
              data-testid="beeline-webhook-token-input"
              class="rounded-lg border border-n-weak py-2 font-mono text-sm"
              type="text"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              :placeholder="
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TOKEN_PLACEHOLDER'
                )
              "
            />
          </label>

          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_API_TOKEN') }}
            <input
              v-model="beelineApiToken"
              data-testid="beeline-api-token-input"
              class="rounded-lg border border-n-weak py-2 font-mono text-sm"
              type="password"
              autocomplete="new-password"
              autocapitalize="off"
              spellcheck="false"
              :placeholder="
                beelineApiTokenConfigured
                  ? '********'
                  : $t(
                      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_API_TOKEN_PLACEHOLDER'
                    )
              "
            />
            <span
              v-if="beelineApiTokenConfigured"
              data-testid="beeline-api-token-configured-hint"
              class="text-xs text-n-teal-11"
            >
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_API_TOKEN_CONFIGURED_HINT'
                )
              }}
            </span>
          </label>

          <div class="flex flex-wrap gap-3">
            <NextButton
              type="button"
              data-testid="beeline-webhook-generate"
              @click="generateBeelineWebhookToken"
            >
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_GENERATE'
                )
              }}
            </NextButton>
            <NextButton
              type="button"
              data-testid="beeline-webhook-copy"
              :disabled="!beelineWebhookUrl"
              @click="copyBeelineWebhookUrl"
            >
              {{
                $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_COPY')
              }}
            </NextButton>
            <NextButton
              type="button"
              data-testid="beeline-webhook-save"
              :is-loading="isUpdatingBeelineWebhook"
              @click="updateBeelineWebhookToken"
            >
              {{
                $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_SAVE')
              }}
            </NextButton>
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="virtualPbxManagementLabel"
        :help-text="virtualPbxManagementHelpText"
      >
        <div v-if="isLoadingVirtualPbxStatus" class="text-sm text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LOADING') }}
        </div>
        <div
          v-else-if="virtualPbxLoadError"
          class="rounded-xl border border-n-ruby-4 bg-n-ruby-2/40 p-4 text-sm text-n-ruby-11"
        >
          {{ virtualPbxLoadError }}
        </div>
        <form
          v-else
          class="flex flex-col gap-4"
          @submit.prevent="updateVirtualPbxChannel"
        >
          <div
            v-if="isVirtualPbxReadOnly"
            class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4 text-sm text-n-amber-11"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.READ_ONLY') }}
          </div>
          <div
            v-if="virtualPbxWarnings.length"
            class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4 text-sm text-n-amber-11"
          >
            <div class="mb-1 font-medium">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.WARNINGS_TITLE') }}
            </div>
            <ul class="list-disc pl-5">
              <li v-for="warning in virtualPbxWarnings" :key="warning.code">
                {{ warning.message || warning.code }}
              </li>
            </ul>
          </div>
          <div
            v-if="virtualPbxErrors.length"
            class="rounded-xl border border-n-ruby-4 bg-n-ruby-2/40 p-4 text-sm text-n-ruby-11"
          >
            <ul class="list-disc pl-5">
              <li v-for="error in virtualPbxErrors" :key="error.code">
                {{ virtualPbxErrorLabel(error) }}
              </li>
            </ul>
          </div>

          <label
            v-if="showVirtualPbxTechnicalSettings"
            class="flex flex-col gap-1 text-sm text-n-slate-12"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CHANNEL_NAME.LABEL') }}
            <input
              v-model="virtualPbxForm.channelName"
              class="rounded-lg border border-n-weak py-2 text-sm"
              :disabled="isVirtualPbxReadOnly"
              type="text"
            />
          </label>

          <div
            v-if="showVirtualPbxTechnicalSettings"
            class="grid grid-cols-1 gap-4 md:grid-cols-2"
          >
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              <span class="flex items-center gap-2">
                <img
                  v-if="virtualPbxCarrierBadgeUrl"
                  :src="virtualPbxCarrierBadgeUrl"
                  alt=""
                  class="h-5 w-5 rounded object-contain"
                  data-testid="virtual-pbx-carrier-badge"
                />
                {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.LABEL') }}
              </span>
              <select
                v-model="virtualPbxForm.providerKind"
                data-testid="virtual-pbx-provider-kind"
                class="rounded-lg border border-n-weak py-2 text-sm disabled:bg-n-alpha-1 disabled:text-n-slate-11"
                :disabled="true"
              >
                <option value="" disabled>
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.PLACEHOLDER'
                    )
                  }}
                </option>
                <option
                  v-for="option in virtualPbxProviderOptions"
                  :key="option.value"
                  :value="option.value"
                >
                  {{ option.label }}
                </option>
              </select>
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.LABEL') }}
              <input
                v-model="virtualPbxForm.displayPhoneNumber"
                class="rounded-lg border border-n-weak py-2 text-sm"
                :disabled="isVirtualPbxReadOnly"
                type="text"
              />
            </label>
          </div>

          <div
            v-if="showVirtualPbxTechnicalSettings"
            class="rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OPERATOR_DISTRIBUTION.LABEL'
                )
              }}
              <select
                v-model="virtualPbxForm.operatorDistributionMode"
                class="rounded-lg border border-n-weak py-2 text-sm"
                :disabled="isVirtualPbxReadOnly"
              >
                <option
                  v-for="option in virtualPbxOperatorDistributionOptions"
                  :key="option.value"
                  :value="option.value"
                >
                  {{ option.label }}
                </option>
              </select>
            </label>
            <label class="mt-4 flex flex-col gap-1 text-sm text-n-slate-12">
              {{
                $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.MAX_CALL_DURATION.LABEL')
              }}
              <input
                v-model.number="virtualPbxForm.maxCallDurationMinutes"
                class="rounded-lg border border-n-weak py-2 text-sm"
                :disabled="isVirtualPbxReadOnly"
                type="number"
                min="5"
                max="240"
                step="5"
              />
              <span class="text-label-small text-n-slate-11">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.MAX_CALL_DURATION.DESCRIPTION'
                  )
                }}
              </span>
            </label>
          </div>

          <div
            v-if="showVirtualPbxTechnicalSettings"
            class="rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <div class="mb-3 space-y-1">
              <h3 class="text-sm font-medium text-n-slate-12">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.PROVIDER_CONNECTION')
                }}
              </h3>
              <p class="mb-0 text-sm text-n-slate-11">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.JANUS_SIP_SUBTITLE')
                }}
              </p>
            </div>
            <div class="grid grid-cols-1 gap-4 md:grid-cols-4">
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.LABEL')
                }}
                <input
                  v-model="virtualPbxForm.connectionHost"
                  data-testid="virtual-pbx-connection-host"
                  class="rounded-lg border border-n-weak py-2 text-sm disabled:bg-n-alpha-1 disabled:text-n-slate-11"
                  :disabled="isVirtualPbxReadOnly || isVirtualPbxWazo"
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.PLACEHOLDER'
                    )
                  "
                />
              </label>
              <label
                v-if="isVirtualPbxBeeline"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.SIP_DOMAIN.LABEL') }}
                <input
                  v-model="virtualPbxForm.connectionSipDomain"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.SIP_DOMAIN.PLACEHOLDER'
                    )
                  "
                />
              </label>
              <label
                v-if="isVirtualPbxBeeline"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_PROXY.LABEL')
                }}
                <input
                  v-model="virtualPbxForm.connectionOutboundProxy"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_PROXY.PLACEHOLDER'
                    )
                  "
                />
              </label>
              <label
                v-if="isVirtualPbxAsteriskAnalog"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.LABEL')
                }}
                <input
                  v-model="virtualPbxForm.connectionPort"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="number"
                  min="1"
                  max="65535"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.PLACEHOLDER'
                    )
                  "
                />
              </label>
              <label
                v-if="isVirtualPbxAsteriskAnalog"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.TRANSPORT.LABEL') }}
                <select
                  v-model="virtualPbxForm.connectionTransport"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                >
                  <option
                    v-for="option in virtualPbxTransportOptions"
                    :key="option"
                    :value="option"
                  >
                    {{ option.toUpperCase() }}
                  </option>
                </select>
              </label>
              <label
                v-if="isVirtualPbxDialFormatEditable"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.LABEL'
                  )
                }}
                <select
                  v-model="virtualPbxForm.outboundDialFormat"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                >
                  <option
                    v-for="option in virtualPbxOutboundDialFormatOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </label>
            </div>
            <p
              v-if="isVirtualPbxBeeline"
              class="mb-0 mt-4 border-t border-n-weak pt-4 text-sm text-n-slate-11"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.BEELINE_CONFIG_HINT') }}
            </p>
          </div>

          <div
            v-if="showVirtualPbxTechnicalSettings && isVirtualPbxWazo"
            data-testid="virtual-pbx-wazo-carrier-settings"
            class="rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <div class="mb-3 space-y-1">
              <h3 class="text-sm font-medium text-n-slate-12">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TITLE')
                }}
              </h3>
              <p class="mb-0 text-sm text-n-slate-11">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.SUBTITLE'
                  )
                }}
              </p>
            </div>
            <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIER_KIND_LABEL'
                  )
                }}
                <select
                  v-model="virtualPbxForm.carrierKind"
                  data-testid="virtual-pbx-carrier-kind"
                  class="rounded-lg border border-n-weak py-2 text-sm disabled:bg-n-alpha-1 disabled:text-n-slate-11"
                  :disabled="isVirtualPbxReadOnly || isVirtualPbxCarrierLocked"
                  @change="onVirtualPbxCarrierChange"
                >
                  <option value="">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.CARRIER_KIND_PLACEHOLDER'
                      )
                    }}
                  </option>
                  <option
                    v-for="option in virtualPbxCarrierOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.MAX_CHANNELS_LABEL'
                  )
                }}
                <div class="flex items-center gap-2">
                  <input
                    v-model.number="virtualPbxForm.maxChannels"
                    class="flex-1 rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                    type="number"
                    min="1"
                    max="100"
                  />
                  <NextButton
                    type="button"
                    data-testid="virtual-pbx-probe-channels-btn"
                    outline
                    slate
                    xs
                    :is-loading="isProbingVirtualPbxChannels"
                    :disabled="
                      isVirtualPbxReadOnly || isProbingVirtualPbxChannels
                    "
                    @click="probeVirtualPbxChannelCapacity"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.PROBE_CHANNELS_BUTTON'
                      )
                    }}
                  </NextButton>
                </div>
                <div
                  v-if="virtualPbxForm.detectedChannelLimit"
                  data-testid="virtual-pbx-detected-channel-limit"
                  class="mt-1 flex items-center justify-between gap-2 rounded-lg bg-n-amber-2/50 px-2.5 py-1.5 text-xs text-n-amber-11"
                >
                  <span>
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.DETECTED_LIMIT_BADGE',
                        { count: virtualPbxForm.detectedChannelLimit }
                      )
                    }}
                  </span>
                  <button
                    v-if="
                      virtualPbxForm.maxChannels !==
                      virtualPbxForm.detectedChannelLimit
                    "
                    type="button"
                    data-testid="virtual-pbx-apply-detected-limit"
                    class="font-medium underline"
                    :disabled="isVirtualPbxReadOnly"
                    @click="applyDetectedChannelLimit"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.APPLY_DETECTED_LIMIT'
                      )
                    }}
                  </button>
                </div>
                <div
                  data-testid="virtual-pbx-ai-concurrency-badge"
                  class="mt-1 rounded-lg bg-n-brand/10 px-2.5 py-1.5 text-xs text-n-brand"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.AI_CONCURRENCY_BADGE',
                      { count: effectiveAiMaxConcurrentCalls }
                    )
                  }}
                </div>
                <span class="text-label-small text-n-slate-11">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.DETECTED_LIMIT_HINT'
                    )
                  }}
                </span>
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.RESERVED_INBOUND_LABEL'
                  )
                }}
                <input
                  v-model.number="virtualPbxForm.reservedInboundChannels"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="number"
                  min="0"
                  max="50"
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.RING_STRATEGY_LABEL'
                  )
                }}
                <select
                  v-model="virtualPbxForm.ringStrategy"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                >
                  <option
                    v-for="option in virtualPbxRingStrategyOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.GROUP_EXTENSION_LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxForm.groupExtension"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="text"
                  :placeholder="String(2001)"
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_USERNAME_LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxForm.trunkUsername"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_USERNAME_PLACEHOLDER'
                    )
                  "
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_PASSWORD_LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxForm.trunkPassword"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  :disabled="isVirtualPbxReadOnly"
                  type="password"
                  autocomplete="new-password"
                  :placeholder="
                    virtualPbxForm.trunkPasswordConfigured
                      ? '********'
                      : $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_PASSWORD_PLACEHOLDER'
                        )
                  "
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_DOMAIN_LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxForm.trunkDomain"
                  data-testid="virtual-pbx-trunk-domain"
                  class="rounded-lg border border-n-weak py-2 text-sm disabled:bg-n-alpha-1 disabled:text-n-slate-11"
                  :disabled="
                    isVirtualPbxReadOnly || isVirtualPbxKnownCarrierPreset
                  "
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_DOMAIN_PLACEHOLDER'
                    )
                  "
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_HOST_LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxForm.trunkHost"
                  data-testid="virtual-pbx-trunk-host"
                  class="rounded-lg border border-n-weak py-2 text-sm disabled:bg-n-alpha-1 disabled:text-n-slate-11"
                  :disabled="
                    isVirtualPbxReadOnly || isVirtualPbxKnownCarrierPreset
                  "
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_HOST_PLACEHOLDER'
                    )
                  "
                />
              </label>
            </div>
          </div>

          <div
            class="rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <div class="mb-3 space-y-1">
              <h3 class="text-sm font-medium text-n-slate-12">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE')
                }}
              </h3>
              <p class="mb-0 text-sm text-n-slate-11">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.HINT')
                }}
              </p>
            </div>

            <div class="flex flex-col divide-y divide-n-weak">
              <div
                v-for="(profile, index) in virtualPbxForm.profiles"
                :key="profile.clientId"
                class="grid grid-cols-1 gap-3 py-4 first:pt-0 last:pb-0 md:grid-cols-2"
              >
                <label
                  v-if="profile.profileKind !== 'voice_agent'"
                  class="flex flex-col gap-1 text-sm text-n-slate-12"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.EMPLOYEE_LABEL'
                    )
                  }}
                  <select
                    v-model.number="profile.userId"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                  >
                    <option disabled value="">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SELECT_PLACEHOLDER'
                        )
                      }}
                    </option>
                    <option
                      v-for="option in virtualPbxMemberOptions"
                      :key="option.value"
                      :value="option.value"
                    >
                      {{ option.label }}
                    </option>
                  </select>
                </label>

                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.LABEL'
                    )
                  }}
                  <input
                    v-model="profile.internalExtension"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                    type="text"
                    :placeholder="
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.PLACEHOLDER'
                      )
                    "
                  />
                </label>

                <label
                  v-if="isVirtualPbxSipCredentialsVisible"
                  class="flex flex-col gap-1 text-sm text-n-slate-12"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
                    )
                  }}
                  <input
                    v-model="profile.sipUsername"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                    type="text"
                    :placeholder="
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.PLACEHOLDER'
                      )
                    "
                  />
                </label>

                <label
                  v-if="isVirtualPbxSipCredentialsVisible"
                  class="flex flex-col gap-1 text-sm text-n-slate-12"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
                    )
                  }}
                  <input
                    v-model="profile.sipPassword"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                    type="password"
                    autocomplete="new-password"
                    :placeholder="virtualPbxSipPasswordPlaceholder(profile)"
                  />
                </label>

                <label
                  class="flex items-center gap-2 text-sm text-n-slate-12 md:col-span-2"
                >
                  <input
                    v-model="profile.profileKind"
                    :disabled="
                      isVirtualPbxVoiceAgentToggleDisabled(profile, index)
                    "
                    type="checkbox"
                    true-value="voice_agent"
                    false-value="human_operator"
                    @change="onVirtualPbxProfileKindChange(profile)"
                  />
                  <span class="font-medium">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.VOICE_AGENT_LABEL'
                      )
                    }}
                  </span>
                </label>

                <div class="md:col-span-2">
                  <button
                    type="button"
                    class="p-0 text-sm text-n-ruby-10"
                    :disabled="isVirtualPbxReadOnly"
                    @click="removeVirtualPbxProfile(index)"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.REMOVE',
                        { index: index + 1 }
                      )
                    }}
                  </button>
                </div>
              </div>
            </div>

            <NextButton
              type="button"
              class="mt-3"
              outline
              slate
              sm
              :disabled="isVirtualPbxReadOnly"
              @click="addVirtualPbxProfile"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.ADD') }}
            </NextButton>
          </div>

          <div
            data-testid="call-routing-builder"
            class="rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <div
              class="mb-4 flex flex-col gap-3 border-b border-n-weak pb-3 md:flex-row md:items-center md:justify-between"
            >
              <div class="space-y-1">
                <h3 class="text-sm font-medium text-n-slate-12">
                  {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.TITLE') }}
                </h3>
                <p class="mb-0 text-sm text-n-slate-11">
                  {{
                    $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SUBTITLE')
                  }}
                </p>
              </div>
              <div
                class="inline-flex rounded-lg bg-n-alpha-1 p-1"
                role="tablist"
              >
                <button
                  type="button"
                  data-testid="call-routing-tab-inbound"
                  class="rounded-md px-3 py-1.5 text-xs font-medium transition"
                  :class="
                    callRoutingTab === 'inbound'
                      ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                      : 'text-n-slate-11'
                  "
                  @click="callRoutingTab = 'inbound'"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.INBOUND_TAB'
                    )
                  }}
                </button>
                <button
                  type="button"
                  data-testid="call-routing-tab-outbound"
                  class="rounded-md px-3 py-1.5 text-xs font-medium transition"
                  :class="
                    callRoutingTab === 'outbound'
                      ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                      : 'text-n-slate-11'
                  "
                  @click="callRoutingTab = 'outbound'"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND_TAB'
                    )
                  }}
                </button>
              </div>
            </div>

            <div
              v-if="callRoutingTab === 'inbound'"
              data-testid="call-routing-inbound-panel"
              class="flex flex-col gap-4"
            >
              <div
                v-if="isVirtualPbxVoiceInbox && !isVirtualPbxWazo"
                data-testid="call-routing-authority-selector"
                class="rounded-lg bg-n-alpha-1 p-3"
              >
                <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.TITLE'
                    )
                  }}
                </div>
                <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
                  <button
                    type="button"
                    data-testid="call-routing-authority-external-pbx"
                    class="flex flex-col items-start gap-1 rounded-lg border p-3 text-left transition"
                    :class="
                      callRoutingForm.inbound.routing_authority ===
                      'external_pbx'
                        ? 'border-n-brand bg-n-brand/10 text-n-slate-12'
                        : 'border-n-weak bg-n-solid-2 text-n-slate-11'
                    "
                    :disabled="isVirtualPbxReadOnly"
                    @click="setCallRoutingAuthority('external_pbx')"
                  >
                    <span class="text-sm font-medium text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.EXTERNAL_PBX'
                        )
                      }}
                    </span>
                    <span class="text-xs text-n-slate-11">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.EXTERNAL_PBX_DESC'
                        )
                      }}
                    </span>
                  </button>
                  <button
                    type="button"
                    data-testid="call-routing-authority-onelink"
                    class="flex flex-col items-start gap-1 rounded-lg border p-3 text-left transition"
                    :class="
                      callRoutingForm.inbound.routing_authority !==
                      'external_pbx'
                        ? 'border-n-brand bg-n-brand/10 text-n-slate-12'
                        : 'border-n-weak bg-n-solid-2 text-n-slate-11'
                    "
                    :disabled="isVirtualPbxReadOnly"
                    @click="setCallRoutingAuthority('onelink')"
                  >
                    <span class="text-sm font-medium text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.ONELINK'
                        )
                      }}
                    </span>
                    <span class="text-xs text-n-slate-11">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.ONELINK_DESC'
                        )
                      }}
                    </span>
                  </button>
                </div>
              </div>

              <div
                v-if="isVirtualPbxWazo"
                data-testid="call-routing-wazo-onelink-badge"
                class="flex flex-col gap-1 rounded-lg border border-n-brand/30 bg-n-brand/10 p-3 text-xs text-n-slate-12"
              >
                <span class="font-medium text-n-brand">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.WAZO_ALWAYS_ONELINK_HINT'
                    )
                  }}
                </span>
                <span class="text-n-slate-11">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.AI_CONCURRENCY_BADGE',
                      { count: effectiveAiMaxConcurrentCalls }
                    )
                  }}
                </span>
              </div>

              <div
                v-if="!isExternalPbxRoutingAuthority"
                class="rounded-lg bg-n-alpha-1 p-3"
              >
                <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                  1.
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.TITLE'
                    )
                  }}
                </div>
                <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.MODE_LABEL'
                      )
                    }}
                    <select
                      v-model="callRoutingForm.inbound.schedule_mode"
                      data-testid="call-routing-schedule-mode"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      @change="markCallRoutingDirty"
                    >
                      <option value="always">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.ALWAYS'
                          )
                        }}
                      </option>
                      <option value="business_hours">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.BUSINESS_HOURS'
                          )
                        }}
                      </option>
                    </select>
                  </label>
                  <label
                    v-if="
                      callRoutingForm.inbound.schedule_mode === 'business_hours'
                    "
                    class="flex flex-col gap-1 text-sm text-n-slate-12"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.OFF_HOURS_ACTION_LABEL'
                      )
                    }}
                    <select
                      v-model="callRoutingForm.inbound.off_hours_action"
                      data-testid="call-routing-off-hours-action"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      @change="markCallRoutingDirty"
                    >
                      <option
                        v-for="option in callRoutingActionOptions"
                        :key="option.value"
                        :value="option.value"
                      >
                        {{ option.label }}
                      </option>
                    </select>
                  </label>
                  <label
                    v-if="
                      callRoutingForm.inbound.schedule_mode ===
                        'business_hours' &&
                      callRoutingForm.inbound.off_hours_action === 'forward'
                    "
                    class="flex flex-col gap-1 text-sm text-n-slate-12"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.FORWARD_NUMBER_LABEL'
                      )
                    }}
                    <input
                      v-model="callRoutingForm.inbound.off_hours_forward_number"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      type="text"
                      placeholder="+77000000000"
                      @input="markCallRoutingDirty"
                    />
                  </label>
                </div>
              </div>

              <div
                v-if="!isExternalPbxRoutingAuthority"
                class="rounded-lg bg-n-alpha-1 p-3"
              >
                <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                  2.
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.TITLE'
                    )
                  }}
                </div>
                <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.RING_TIMEOUT_LABEL'
                      )
                    }}
                    <input
                      v-model.number="callRoutingForm.inbound.ring_timeout_seconds"
                      data-testid="call-routing-ring-timeout"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      type="number"
                      min="5"
                      max="180"
                      @input="markCallRoutingDirty"
                    />
                  </label>
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.RINGTONE_LABEL'
                      )
                    }}
                    <select
                      v-model="callRoutingForm.inbound.ringtone"
                      data-testid="call-routing-ringtone"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      @change="markCallRoutingDirty"
                    >
                      <option
                        v-for="option in callRoutingRingtoneOptions"
                        :key="option.value"
                        :value="option.value"
                      >
                        {{ option.label }}
                      </option>
                    </select>
                  </label>
                  <label class="flex items-center gap-2 pt-6 text-sm text-n-slate-12">
                    <input
                      v-model="callRoutingForm.inbound.skip_busy_operators"
                      type="checkbox"
                      :disabled="isVirtualPbxReadOnly"
                      @change="markCallRoutingDirty"
                    />
                    <span>
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.SKIP_BUSY_LABEL'
                        )
                      }}
                    </span>
                  </label>
                </div>
              </div>

              <div
                v-if="!isExternalPbxRoutingAuthority"
                class="rounded-lg bg-n-alpha-1 p-3"
              >
                <div class="mb-2 flex items-center justify-between">
                  <div class="text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                    3.
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.TITLE'
                      )
                    }}
                  </div>
                  <NextButton
                    type="button"
                    data-testid="call-routing-add-group"
                    outline
                    slate
                    xs
                    :disabled="isVirtualPbxReadOnly"
                    @click="addCallRoutingGroup"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.ADD_GROUP'
                      )
                    }}
                  </NextButton>
                </div>
                <div class="flex flex-col gap-3">
                  <div
                    v-for="(group, groupIndex) in callRoutingForm.inbound.groups"
                    :key="group.id"
                    data-testid="call-routing-group-card"
                    class="rounded-lg border border-n-weak bg-n-solid-2 p-3"
                  >
                    <div class="mb-2 flex items-center justify-between">
                      <span class="text-xs font-medium text-n-slate-11">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.STEP_LABEL',
                            { index: groupIndex + 1 }
                          )
                        }}
                      </span>
                      <button
                        v-if="callRoutingForm.inbound.groups.length > 1"
                        type="button"
                        class="text-xs text-n-ruby-10"
                        :disabled="isVirtualPbxReadOnly"
                        @click="removeCallRoutingGroup(groupIndex)"
                      >
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.REMOVE_GROUP'
                          )
                        }}
                      </button>
                    </div>
                    <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
                      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.NAME_LABEL'
                          )
                        }}
                        <input
                          v-model="group.name"
                          class="rounded-lg border border-n-weak py-1.5 text-sm"
                          :disabled="isVirtualPbxReadOnly"
                          type="text"
                          :placeholder="
                            $t(
                              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.NAME_PLACEHOLDER'
                            )
                          "
                          @input="markCallRoutingDirty"
                        />
                      </label>
                      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.STRATEGY_LABEL'
                          )
                        }}
                        <select
                          v-model="group.strategy"
                          class="rounded-lg border border-n-weak py-1.5 text-sm"
                          :disabled="isVirtualPbxReadOnly"
                          @change="markCallRoutingDirty"
                        >
                          <option
                            v-for="option in callRoutingGroupStrategyOptions"
                            :key="option.value"
                            :value="option.value"
                          >
                            {{ option.label }}
                          </option>
                        </select>
                      </label>
                      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.RING_SECONDS_LABEL'
                          )
                        }}
                        <input
                          v-model.number="group.ring_seconds"
                          class="rounded-lg border border-n-weak py-1.5 text-sm"
                          :disabled="isVirtualPbxReadOnly"
                          type="number"
                          min="5"
                          max="120"
                          @input="markCallRoutingDirty"
                        />
                      </label>
                    </div>
                    <div class="mt-3">
                      <div class="mb-1.5 text-xs text-n-slate-11">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.OPERATORS_LABEL'
                          )
                        }}
                      </div>
                      <div class="flex flex-wrap gap-2">
                        <button
                          v-for="member in virtualPbxMemberOptions"
                          :key="member.value"
                          type="button"
                          class="rounded-full border px-2.5 py-1 text-xs transition"
                          :class="
                            (group.user_ids || []).includes(member.value)
                              ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                              : 'border-n-weak text-n-slate-11'
                          "
                          :disabled="isVirtualPbxReadOnly"
                          @click="toggleCallRoutingGroupUser(group, member.value)"
                        >
                          {{ member.label }}
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <div class="rounded-lg bg-n-alpha-1 p-3">
                <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                  4.
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.FALLBACK.TITLE'
                    )
                  }}
                </div>
                <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.FALLBACK.ACTION_LABEL'
                      )
                    }}
                    <select
                      v-model="callRoutingForm.inbound.fallback_action"
                      data-testid="call-routing-fallback-action"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      @change="markCallRoutingDirty"
                    >
                      <option
                        v-for="option in callRoutingActionOptions"
                        :key="option.value"
                        :value="option.value"
                      >
                        {{ option.label }}
                      </option>
                    </select>
                  </label>
                  <label
                    v-if="callRoutingForm.inbound.fallback_action === 'forward'"
                    class="flex flex-col gap-1 text-sm text-n-slate-12"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.FALLBACK.FORWARD_NUMBER_LABEL'
                      )
                    }}
                    <input
                      v-model="callRoutingForm.inbound.fallback_forward_number"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="isVirtualPbxReadOnly"
                      type="text"
                      placeholder="+77000000000"
                      @input="markCallRoutingDirty"
                    />
                  </label>
                </div>

                <div class="mt-3 border-t border-n-weak pt-3 flex flex-col gap-3">
                  <label class="flex items-center gap-2 text-sm text-n-slate-12">
                    <input
                      v-model="callRoutingForm.inbound.whatsapp_followup.enabled"
                      data-testid="call-routing-whatsapp-followup-enabled"
                      type="checkbox"
                      :disabled="isVirtualPbxReadOnly"
                      @change="markCallRoutingDirty"
                    />
                    <span>
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.ENABLED_LABEL'
                        )
                      }}
                    </span>
                  </label>

                  <div
                    v-if="callRoutingForm.inbound.whatsapp_followup.enabled"
                    data-testid="call-routing-whatsapp-followup-panel"
                    class="grid grid-cols-1 gap-3 md:grid-cols-2"
                  >
                    <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.INBOX_LABEL'
                        )
                      }}
                      <select
                        v-model="callRoutingForm.inbound.whatsapp_followup.inbox_id"
                        data-testid="call-routing-whatsapp-inbox"
                        class="rounded-lg border border-n-weak py-2 text-sm"
                        :disabled="isVirtualPbxReadOnly"
                        @change="markCallRoutingDirty"
                      >
                        <option value="">
                          {{
                            $t(
                              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.INBOX_PLACEHOLDER'
                            )
                          }}
                        </option>
                        <option
                          v-for="waInbox in whatsappInboxOptions"
                          :key="waInbox.id"
                          :value="waInbox.id"
                        >
                          {{ waInbox.name }}
                        </option>
                      </select>
                    </label>

                    <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.COOLDOWN_LABEL'
                        )
                      }}
                      <input
                        v-model.number="
                          callRoutingForm.inbound.whatsapp_followup.cooldown_minutes
                        "
                        data-testid="call-routing-whatsapp-cooldown"
                        class="rounded-lg border border-n-weak py-2 text-sm"
                        :disabled="isVirtualPbxReadOnly"
                        type="number"
                        min="5"
                        max="1440"
                        @input="markCallRoutingDirty"
                      />
                    </label>

                    <label
                      v-if="
                        selectedWhatsappFollowupInbox &&
                        isSelectedWhatsappFollowupOfficial
                      "
                      class="flex flex-col gap-1 text-sm text-n-slate-12 md:col-span-2"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.TEMPLATE_LABEL'
                        )
                      }}
                      <select
                        v-model="
                          callRoutingForm.inbound.whatsapp_followup.template_name
                        "
                        data-testid="call-routing-whatsapp-template"
                        class="rounded-lg border border-n-weak py-2 text-sm"
                        :disabled="isVirtualPbxReadOnly"
                        @change="markCallRoutingDirty"
                      >
                        <option value="">
                          {{
                            $t(
                              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.TEMPLATE_PLACEHOLDER'
                            )
                          }}
                        </option>
                        <option
                          v-for="tpl in selectedWhatsappFollowupTemplates"
                          :key="`${tpl.name}:${tpl.language || 'ru'}`"
                          :value="tpl.name"
                        >
                          {{ tpl.name }} ({{ tpl.language || 'ru' }})
                        </option>
                      </select>
                    </label>

                    <label
                      v-else-if="selectedWhatsappFollowupInbox"
                      class="flex flex-col gap-1 text-sm text-n-slate-12 md:col-span-2"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.CUSTOM_MESSAGE_LABEL'
                        )
                      }}
                      <input
                        v-model="
                          callRoutingForm.inbound.whatsapp_followup.custom_message
                        "
                        data-testid="call-routing-whatsapp-custom-message"
                        class="rounded-lg border border-n-weak py-2 text-sm"
                        :disabled="isVirtualPbxReadOnly"
                        type="text"
                        :placeholder="
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.CUSTOM_MESSAGE_PLACEHOLDER'
                          )
                        "
                        @input="markCallRoutingDirty"
                      />
                    </label>
                  </div>
                </div>
              </div>

              <div class="rounded-lg bg-n-alpha-1 p-3">
                <label class="flex items-center gap-2 text-sm text-n-slate-12">
                  <input
                    v-model="callRoutingForm.show_extended_call_card"
                    data-testid="call-routing-show-extended-call-card"
                    type="checkbox"
                    :disabled="isVirtualPbxReadOnly"
                    @change="markCallRoutingDirty"
                  />
                  <span>
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.CALL_CARD.SHOW_EXTENDED_LABEL'
                      )
                    }}
                  </span>
                </label>
              </div>
            </div>

            <div
              v-else
              data-testid="call-routing-outbound-panel"
              class="flex flex-col gap-4"
            >
              <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ACCESS_MODE_LABEL'
                    )
                  }}
                  <select
                    v-model="callRoutingForm.outbound.access_mode"
                    data-testid="call-routing-outbound-access-mode"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                    @change="markCallRoutingDirty"
                  >
                    <option value="all_members">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ALL_MEMBERS'
                        )
                      }}
                    </option>
                    <option value="selected_operators">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.SELECTED_OPERATORS'
                        )
                      }}
                    </option>
                  </select>
                </label>
                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.CALLER_ID_LABEL'
                    )
                  }}
                  <input
                    v-model="callRoutingForm.outbound.caller_id_number"
                    data-testid="call-routing-outbound-caller-id"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    :disabled="isVirtualPbxReadOnly"
                    type="text"
                    :placeholder="
                      virtualPbxForm.displayPhoneNumber || '+77000000000'
                    "
                    @input="markCallRoutingDirty"
                  />
                </label>
              </div>
              <div
                v-if="
                  callRoutingForm.outbound.access_mode === 'selected_operators'
                "
                class="rounded-lg bg-n-alpha-1 p-3"
              >
                <div class="mb-1.5 text-xs text-n-slate-11">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ALLOWED_OPERATORS_LABEL'
                    )
                  }}
                </div>
                <div class="flex flex-wrap gap-2">
                  <button
                    v-for="member in virtualPbxMemberOptions"
                    :key="member.value"
                    type="button"
                    class="rounded-full border px-2.5 py-1 text-xs transition"
                    :class="
                      callRoutingForm.outbound.allowed_user_ids.includes(
                        member.value
                      )
                        ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                        : 'border-n-weak text-n-slate-11'
                    "
                    :disabled="isVirtualPbxReadOnly"
                    @click="toggleCallRoutingOutboundUser(member.value)"
                  >
                    {{ member.label }}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <div
            v-if="isVirtualPbxAsteriskAnalog"
            class="grid grid-cols-1 gap-4 md:grid-cols-2"
          >
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ROUTING_MODE') }}
              <select
                v-model="virtualPbxForm.routingMode"
                class="rounded-lg border border-n-weak py-2 text-sm"
                :disabled="isVirtualPbxReadOnly"
              >
                <option
                  v-for="option in virtualPbxRoutingOptions"
                  :key="option.value"
                  :value="option.value"
                >
                  {{ option.label }}
                </option>
              </select>
            </label>
          </div>

          <div class="flex flex-wrap gap-3">
            <NextButton
              :disabled="isVirtualPbxReadOnly"
              :is-loading="isUpdatingVirtualPbx"
              type="submit"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_BUTTON') }}
            </NextButton>
            <NextButton
              data-testid="virtual-pbx-plan"
              type="button"
              :is-loading="isLoadingVirtualPbxPlan"
              @click="loadVirtualPbxProvisioningPlan"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PLAN_BUTTON') }}
            </NextButton>
            <NextButton
              data-testid="virtual-pbx-reconcile"
              type="button"
              :is-loading="isReconcilingVirtualPbx"
              @click="reconcileVirtualPbxChannel"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.RECONCILE_BUTTON') }}
            </NextButton>
            <NextButton
              v-if="isVirtualPbxWazo"
              data-testid="virtual-pbx-wazo-apply"
              type="button"
              :disabled="!isVirtualPbxRemoteCommitAllowed"
              :is-loading="isProvisioningVirtualPbx"
              @click="provisionVirtualPbxChannel"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISION_BUTTON') }}
            </NextButton>
          </div>

          <div
            v-if="virtualPbxPlanOperations.length"
            class="rounded-xl p-4 text-sm text-n-slate-11 outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <div class="mb-2 font-medium text-n-slate-12">
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PLAN_OPERATIONS') }}
            </div>
            <ul class="list-disc pl-5">
              <li
                v-for="operation in virtualPbxPlanOperations"
                :key="`${operation.action || operation.key || operation.code}-${operation.ref || operation.description}`"
              >
                {{
                  operation.description ||
                  operation.action ||
                  operation.key ||
                  operation.code ||
                  operation.id
                }}
              </li>
            </ul>
          </div>
        </form>
      </SettingsFieldSection>
    </template>
  </div>

  <div v-else-if="isALineChannel">
    <SettingsFieldSection
      :label="$t('INBOX_MGMT.ADD.LINE_CHANNEL.API_CALLBACK.TITLE')"
      :help-text="$t('INBOX_MGMT.ADD.LINE_CHANNEL.API_CALLBACK.SUBTITLE')"
    >
      <woot-code :script="inbox.callback_webhook_url" lang="html" />
    </SettingsFieldSection>
  </div>
  <div v-else-if="isAWebWidgetInbox">
    <div class="space-y-4">
      <SettingsToggleSection
        :header="$t('INBOX_MGMT.SETTINGS_POPUP.ALLOWED_DOMAINS.TITLE')"
        :description="
          $t('INBOX_MGMT.SETTINGS_POPUP.ALLOWED_DOMAINS.DESCRIPTION')
        "
        hide-toggle
      >
        <template #editor>
          <TextArea
            v-model="allowedDomains"
            :placeholder="
              $t('INBOX_MGMT.SETTINGS_POPUP.ALLOWED_DOMAINS.PLACEHOLDER')
            "
            auto-height
            resize
            class="w-full [&>div]:!bg-transparent [&>div]:!border-none [&>div]:!border-0 [&>div]:px-0 [&>div]:pb-0 [&>div]:pt-0"
          />
          <div class="mt-3 flex justify-end">
            <NextButton
              :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
              :is-loading="isUpdatingAllowedDomains"
              @click="updateAllowedDomains"
            />
          </div>
        </template>
      </SettingsToggleSection>
      <SettingsToggleSection
        v-model="allowMobileWebview"
        :header="$t('INBOX_MGMT.SETTINGS_POPUP.ALLOW_MOBILE_WEBVIEW.LABEL')"
        :description="
          $t('INBOX_MGMT.SETTINGS_POPUP.ALLOW_MOBILE_WEBVIEW.SUBTITLE')
        "
      />
    </div>

    <SettingsAccordion
      :title="$t('INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.TITLE')"
      class="mt-6"
    >
      <SettingsToggleSection
        :header="$t('INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.TITLE')"
        :description="
          $t('INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.DESCRIPTION')
        "
        hide-toggle
      >
        <template #editor>
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.SECRET_KEY') }}
          </p>
          <woot-code :script="inbox.hmac_token" />
          <p class="mt-1.5 text-label-small text-n-slate-11">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.HMAC_DESCRIPTION') }}
          </p>
        </template>
      </SettingsToggleSection>

      <SettingsToggleSection
        v-model="hmacMandatory"
        :header="
          $t('INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.REQUIRE_LABEL')
        "
        :description="
          $t(
            'INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.REQUIRE_DESCRIPTION'
          )
        "
      />
    </SettingsAccordion>
  </div>
  <div v-else-if="isAPIInbox && !isAWhatsAppWebInbox">
    <SettingsFieldSection
      :label="$t('INBOX_MGMT.SETTINGS_POPUP.INBOX_IDENTIFIER')"
      :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.INBOX_IDENTIFIER_SUB_TEXT')"
    >
      <woot-code :script="inbox.inbox_identifier" />
    </SettingsFieldSection>

    <SettingsFieldSection
      :label="$t('INBOX_MGMT.SETTINGS_POPUP.HMAC_VERIFICATION')"
      :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.HMAC_DESCRIPTION')"
    >
      <woot-code :script="inbox.hmac_token" />
    </SettingsFieldSection>
    <SettingsFieldSection
      :label="$t('INBOX_MGMT.SETTINGS_POPUP.HMAC_MANDATORY_VERIFICATION')"
      :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.HMAC_MANDATORY_DESCRIPTION')"
    >
      <div class="flex gap-2 items-center">
        <input
          id="hmacMandatory"
          v-model="hmacMandatory"
          type="checkbox"
          @change="handleHmacFlag"
        />
        <label for="hmacMandatory" class="text-body-main text-n-slate-12">
          {{ $t('INBOX_MGMT.EDIT.ENABLE_HMAC.LABEL') }}
        </label>
      </div>
    </SettingsFieldSection>
  </div>
  <div v-else-if="isAnEmailChannel">
    <div>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.SETTINGS_POPUP.FORWARD_EMAIL_TITLE')"
        :help-text="
          isForwardingEnabled
            ? $t('INBOX_MGMT.SETTINGS_POPUP.FORWARD_EMAIL_SUB_TEXT')
            : ''
        "
      >
        <woot-code
          v-if="isForwardingEnabled"
          :script="inbox.forward_to_email"
        />
        <div
          v-else
          class="py-2 px-3 bg-n-amber-3 outline-n-amber-4 text-n-amber-11 outline outline-1 -outline-offset-1 rounded-xl"
        >
          <p class="text-body-para mb-0">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.FORWARD_EMAIL_NOT_CONFIGURED') }}
          </p>
        </div>
      </SettingsFieldSection>
    </div>
    <ImapSettings :inbox="inbox" />
    <SmtpSettings v-if="inbox.imap_enabled" :inbox="inbox" />
  </div>
  <div v-else-if="isAWhatsAppChannel && !isATwilioChannel">
    <div v-if="inbox.provider_config">
      <SettingsFieldSection
        v-if="isCoexistenceWhatsApp && coexistenceSync"
        :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_TITLE')"
        :help-text="
          $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_DESCRIPTION')
        "
      >
        <div
          data-testid="whatsapp-coexistence-sync-status"
          class="flex flex-col gap-2 items-start"
        >
          <p class="mb-0 text-sm font-medium text-n-slate-12">
            {{ coexistenceSyncStateLabel }}
          </p>
          <p
            v-if="coexistenceSyncProgress !== null"
            class="mb-0 text-sm text-n-slate-11"
          >
            {{
              $t(
                'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_PROGRESS',
                {
                  progress: coexistenceSyncProgress,
                }
              )
            }}
          </p>
          <p
            v-if="coexistenceSyncFailureCount"
            class="mb-0 text-sm text-n-amber-11"
          >
            {{
              $t(
                'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_FAILURES',
                {
                  count: coexistenceSyncFailureCount,
                }
              )
            }}
          </p>
          <p
            v-if="coexistenceSync.last_error"
            class="mb-0 text-sm text-n-ruby-11"
          >
            {{ coexistenceSync.last_error }}
          </p>
          <NextButton
            v-if="coexistenceRecoveryRequired"
            data-testid="whatsapp-coexistence-sync-recover"
            @click="handleReconfigure"
          >
            {{
              $t(
                'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_RECOVER_BUTTON'
              )
            }}
          </NextButton>
        </div>
      </SettingsFieldSection>

      <!-- Embedded Signup Section -->
      <template v-if="isEmbeddedSignupWhatsApp">
        <SettingsFieldSection
          v-if="whatsappAppId"
          :label="
            $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_EMBEDDED_SIGNUP_TITLE')
          "
          :help-text="`${$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_EMBEDDED_SIGNUP_SUBHEADER')} ${$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_EMBEDDED_SIGNUP_DESCRIPTION')}`"
        >
          <div class="flex flex-col gap-1 items-start">
            <NextButton @click="handleReconfigure">
              {{ $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_RECONFIGURE_BUTTON') }}
            </NextButton>
          </div>
        </SettingsFieldSection>
      </template>

      <!-- Manual Setup Section -->
      <template v-else>
        <SettingsFieldSection
          :label="
            $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_WEBHOOK_CALLBACK_TITLE')
          "
          :help-text="
            $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_WEBHOOK_REDACTED_SUBHEADER')
          "
        >
          <woot-code :script="inbox.callback_webhook_url" />
        </SettingsFieldSection>
        <SettingsFieldSection
          :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_UPDATE_TITLE')"
          :help-text="
            $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_UPDATE_SUBHEADER')
          "
        >
          <div
            class="flex flex-1 justify-between items-center whatsapp-settings--content"
          >
            <woot-input
              v-model="whatsAppInboxAPIKey"
              type="password"
              autocomplete="off"
              class="flex-1 mr-2 [&>input]:!mb-0"
              :placeholder="
                $t(
                  'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_UPDATE_PLACEHOLDER'
                )
              "
            />
            <NextButton
              :disabled="v$.whatsAppInboxAPIKey.$invalid"
              @click="updateWhatsAppInboxAPIKey"
            >
              {{
                $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_UPDATE_BUTTON')
              }}
            </NextButton>
          </div>
        </SettingsFieldSection>
      </template>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_TITLE')"
        :help-text="
          $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUBHEADER')
        "
      >
        <NextButton :disabled="isSyncingTemplates" @click="syncTemplates">
          {{ $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON') }}
        </NextButton>
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_CALLING_TITLE')"
        :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_CALLING_SUBHEADER')"
      >
        <div class="flex gap-2 items-center">
          <input
            id="callingEnabled"
            v-model="callingEnabled"
            type="checkbox"
            @change="updateCallingEnabled"
          />
          <label for="callingEnabled" class="text-body-main text-n-slate-12">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_CALLING_LABEL') }}
          </label>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        v-if="callingEnabled"
        :label="$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SUBTITLE')
        "
      >
        <div
          data-testid="whatsapp-call-routing-builder"
          class="flex flex-col gap-4 rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
        >
          <div class="inline-flex self-start rounded-lg bg-n-alpha-1 p-1">
            <button
              type="button"
              data-testid="whatsapp-call-routing-tab-inbound"
              class="rounded-md px-3 py-1.5 text-xs font-medium transition"
              :class="
                callRoutingTab === 'inbound'
                  ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                  : 'text-n-slate-11'
              "
              @click="callRoutingTab = 'inbound'"
            >
              {{
                $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.INBOUND_TAB')
              }}
            </button>
            <button
              type="button"
              data-testid="whatsapp-call-routing-tab-outbound"
              class="rounded-md px-3 py-1.5 text-xs font-medium transition"
              :class="
                callRoutingTab === 'outbound'
                  ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                  : 'text-n-slate-11'
              "
              @click="callRoutingTab = 'outbound'"
            >
              {{
                $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND_TAB')
              }}
            </button>
          </div>

          <div
            v-if="callRoutingTab === 'inbound'"
            class="flex flex-col gap-4"
          >
            <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.MODE_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.inbound.schedule_mode"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  @change="markCallRoutingDirty"
                >
                  <option value="always">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.ALWAYS'
                      )
                    }}
                  </option>
                  <option value="business_hours">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.BUSINESS_HOURS'
                      )
                    }}
                  </option>
                </select>
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.RING_TIMEOUT_LABEL'
                  )
                }}
                <input
                  v-model.number="callRoutingForm.inbound.ring_timeout_seconds"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  type="number"
                  min="5"
                  max="180"
                  @input="markCallRoutingDirty"
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.FALLBACK.ACTION_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.inbound.fallback_action"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  @change="markCallRoutingDirty"
                >
                  <option
                    v-for="option in callRoutingActionOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </select>
              </label>
            </div>

            <div class="rounded-lg bg-n-alpha-1 p-3">
              <div class="mb-2 flex items-center justify-between">
                <div class="text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.TITLE'
                    )
                  }}
                </div>
                <NextButton
                  type="button"
                  outline
                  slate
                  xs
                  @click="addCallRoutingGroup"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.ADD_GROUP'
                    )
                  }}
                </NextButton>
              </div>
              <div class="flex flex-col gap-3">
                <div
                  v-for="group in callRoutingForm.inbound.groups"
                  :key="group.id"
                  class="rounded-lg border border-n-weak bg-n-solid-2 p-3"
                >
                  <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
                    <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.STRATEGY_LABEL'
                        )
                      }}
                      <select
                        v-model="group.strategy"
                        class="rounded-lg border border-n-weak py-1.5 text-sm"
                        @change="markCallRoutingDirty"
                      >
                        <option
                          v-for="option in callRoutingGroupStrategyOptions"
                          :key="option.value"
                          :value="option.value"
                        >
                          {{ option.label }}
                        </option>
                      </select>
                    </label>
                    <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.RING_SECONDS_LABEL'
                        )
                      }}
                      <input
                        v-model.number="group.ring_seconds"
                        class="rounded-lg border border-n-weak py-1.5 text-sm"
                        type="number"
                        min="5"
                        max="120"
                        @input="markCallRoutingDirty"
                      />
                    </label>
                  </div>
                  <div class="mt-3">
                    <div class="mb-1.5 text-xs text-n-slate-11">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.OPERATORS_LABEL'
                        )
                      }}
                    </div>
                    <div class="flex flex-wrap gap-2">
                      <button
                        v-for="member in virtualPbxMemberOptions"
                        :key="member.value"
                        type="button"
                        class="rounded-full border px-2.5 py-1 text-xs transition"
                        :class="
                          (group.user_ids || []).includes(member.value)
                            ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                            : 'border-n-weak text-n-slate-11'
                        "
                        @click="toggleCallRoutingGroupUser(group, member.value)"
                      >
                        {{ member.label }}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div class="rounded-lg bg-n-alpha-1 p-3 flex flex-col gap-3">
              <label class="flex items-center gap-2 text-sm text-n-slate-12">
                <input
                  v-model="callRoutingForm.inbound.whatsapp_followup.enabled"
                  type="checkbox"
                  @change="markCallRoutingDirty"
                />
                <span>
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.ENABLED_LABEL'
                    )
                  }}
                </span>
              </label>
              <label class="flex items-center gap-2 text-sm text-n-slate-12">
                <input
                  v-model="callRoutingForm.show_extended_call_card"
                  type="checkbox"
                  @change="markCallRoutingDirty"
                />
                <span>
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.CALL_CARD.SHOW_EXTENDED_LABEL'
                    )
                  }}
                </span>
              </label>
            </div>
          </div>

          <div v-else class="flex flex-col gap-3">
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ACCESS_MODE_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.outbound.access_mode"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  @change="markCallRoutingDirty"
                >
                  <option value="all_members">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ALL_MEMBERS'
                      )
                    }}
                  </option>
                  <option value="selected_operators">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.SELECTED_OPERATORS'
                      )
                    }}
                  </option>
                </select>
              </label>
            </div>
            <div
              v-if="
                callRoutingForm.outbound.access_mode === 'selected_operators'
              "
              class="rounded-lg bg-n-alpha-1 p-3"
            >
              <div class="mb-1.5 text-xs text-n-slate-11">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ALLOWED_OPERATORS_LABEL'
                  )
                }}
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  v-for="member in virtualPbxMemberOptions"
                  :key="member.value"
                  type="button"
                  class="rounded-full border px-2.5 py-1 text-xs transition"
                  :class="
                    callRoutingForm.outbound.allowed_user_ids.includes(
                      member.value
                    )
                      ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                      : 'border-n-weak text-n-slate-11'
                  "
                  @click="toggleCallRoutingOutboundUser(member.value)"
                >
                  {{ member.label }}
                </button>
              </div>
            </div>
          </div>

          <div class="flex justify-start">
            <NextButton
              type="button"
              data-testid="whatsapp-call-routing-save"
              :is-loading="isSavingWhatsAppCallRouting"
              @click="saveWhatsAppCallRouting"
            >
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SAVE_BUTTON'
                )
              }}
            </NextButton>
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_AI_VOICE_TITLE')"
        :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_AI_VOICE_SUBHEADER')"
      >
        <div class="flex gap-2 items-center">
          <input
            id="aiVoiceEnabled"
            v-model="aiVoiceEnabled"
            type="checkbox"
            @change="updateAiVoiceEnabled"
          />
          <label for="aiVoiceEnabled" class="text-body-main text-n-slate-12">
            {{ $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_AI_VOICE_LABEL') }}
          </label>
        </div>
      </SettingsFieldSection>
    </div>
    <WhatsappReauthorize
      v-if="isEmbeddedSignupWhatsApp"
      ref="whatsappReauth"
      :inbox="inbox"
      class="hidden"
    />
  </div>
</template>

<style lang="scss" scoped>
.whatsapp-settings--content {
  ::v-deep input {
    margin-bottom: 0;
  }
}
</style>
