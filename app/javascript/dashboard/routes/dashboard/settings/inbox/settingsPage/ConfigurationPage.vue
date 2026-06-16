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
import FonosterReadiness from '../components/FonosterReadiness.vue';
import FonosterRoutingForm from '../components/FonosterRoutingForm.vue';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import { sanitizeAllowedDomains } from 'dashboard/helper/URLHelper';

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
    FonosterReadiness,
    FonosterRoutingForm,
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
      fonosterReadinessKey: 0,
      virtualPbxStatusPayload: null,
      virtualPbxLoadError: '',
      isLoadingVirtualPbxStatus: false,
      virtualPbxInboxMembers: [],
      virtualPbxProfileCounter: 0,
      isUpdatingVirtualPbx: false,
      isLoadingVirtualPbxPlan: false,
      isProvisioningVirtualPbx: false,
      isReconcilingVirtualPbx: false,
      virtualPbxProvisioningPlan: null,
      virtualPbxProvisioningRuns: [],
      virtualPbxReconcileResult: null,
      virtualPbxForm: {
        channelName: '',
        providerKind: 'sipuni',
        displayPhoneNumber: '',
        providerAccountNumber: '',
        ingressNumber: '',
        connectionHost: '',
        connectionPort: '5060',
        connectionTransport: 'udp',
        connectionUsername: '',
        connectionPassword: '',
        routingMode: 'operator',
        operatorAgentAor: '',
        profiles: [],
      },
      sipuniIntegrationSecret: '',
      isUpdatingSipuniIntegrationSecret: false,
    };
  },
  validations: {
    whatsAppInboxAPIKey: { required },
  },
  computed: {
    isEmbeddedSignupWhatsApp() {
      return this.inbox.provider_config?.source === 'embedded_signup';
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
        this.inbox.provider === 'fonoster'
      );
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
    virtualPbxTransportOptions() {
      return ['udp', 'tcp', 'tls'];
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
          value: 'asterisk_analog',
          label: this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.ASTERISK_ANALOG'
          ),
        },
      ];
    },
    virtualPbxRoutingOptions() {
      return [
        {
          value: 'operator',
          label: this.$t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.OPERATOR'),
        },
        {
          value: 'reject',
          label: this.$t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.REJECT'),
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
  },
  watch: {
    inbox() {
      this.setDefaults();
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

        payload.channel.provider_config = {
          ...this.inbox.provider_config,
          api_key: this.whatsAppInboxAPIKey,
        };

        await this.$store.dispatch('inboxes/updateInbox', payload);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
    routingModeLabel(mode) {
      switch (mode) {
        case 'app':
          return this.$t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.APP');
        case 'ai':
          return this.$t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.AI');
        case 'reject':
          return this.$t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.REJECT');
        case 'operator':
        default:
          return this.$t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.OPERATOR');
      }
    },
    handleFonosterRouteSaved() {
      this.fonosterReadinessKey += 1;
      this.loadVirtualPbxStatus();
    },
    formatVirtualPbxMessages(messages) {
      return (messages || []).map(item => item.message || item.code).join(', ');
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
        error?.response?.data?.message ||
          error?.response?.data?.error ||
          error?.message ||
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_ERROR')
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
        this.virtualPbxLoadError =
          error?.response?.data?.message ||
          error?.response?.data?.error ||
          error?.message ||
          this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.LOAD_ERROR');
      } finally {
        this.isLoadingVirtualPbxStatus = false;
      }
    },
    async loadVirtualPbxMembers() {
      if (!this.isVirtualPbxVoiceInbox || !this.inbox.id) {
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

      this.isProvisioningVirtualPbx = true;
      try {
        const response = await VoiceAPI.provisionVirtualPbxChannel(
          this.inbox.id,
          { remoteCommit: true, includeDiagnostics: false }
        );
        const payload = response?.payload || {};
        this.virtualPbxProvisioningPlan = payload.provisioning_plan || null;
        await this.loadVirtualPbxProvisioningRuns();

        if (payload.status === 'blocked') {
          useAlert(
            payload.errors?.[0]?.message ||
              payload.errors?.[0]?.code ||
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
    prefillVirtualPbxForm() {
      const config = this.virtualPbxConfig;
      if (!config) return;

      const phoneNumbers = config.phone_numbers || {};
      const channel = config.channel || {};
      const connection = config.connection || {};
      const providerConnection = config.resources?.provider_connection || {};
      const routing = config.routing || {};

      this.virtualPbxForm = {
        ...this.virtualPbxForm,
        channelName: channel.name || config.name || this.inbox.name || '',
        providerKind:
          channel.provider_kind ||
          connection.provider_kind ||
          config.provider_kind ||
          'sipuni',
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
        connectionHost: providerConnection.host || '',
        connectionPort: String(providerConnection.port || 5060),
        connectionTransport: providerConnection.transport || 'udp',
        connectionUsername: providerConnection.username || '',
        connectionPassword: '',
        routingMode: routing.mode || 'operator',
        operatorAgentAor: routing.operator_agent_aor || '',
        profiles: this.normalizeVirtualPbxProfiles(
          config.employees || config.profiles || []
        ),
      };
    },
    validateVirtualPbxForm() {
      const form = this.virtualPbxForm;
      if (!form.channelName.trim() || !form.displayPhoneNumber.trim()) {
        useAlert(this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.REQUIRED_FIELDS'));
        return false;
      }

      return (
        this.validateVirtualPbxProfiles() &&
        this.validateVirtualPbxProfileCredentials()
      );
    },
    validateVirtualPbxProfiles() {
      const invalidProfile = this.virtualPbxForm.profiles.find(profile => {
        return !profile.userId || !profile.internalExtension.trim();
      });

      if (!invalidProfile) return true;

      useAlert(
        this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.REQUIRED')
      );
      return false;
    },
    validateVirtualPbxProfileCredentials() {
      const invalidProfile = this.virtualPbxForm.profiles.find(profile => {
        const hasUsername = !!profile.sipUsername?.trim();
        const hasPassword = !!profile.sipPassword?.trim();
        const usernameChanged =
          (profile.sipUsername || '').trim() !==
          (profile.originalSipUsername || '').trim();

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
          user_id: profile.userId,
          internal_extension: profile.internalExtension.trim(),
          enabled: profile.enabled !== false,
        };
        const sipUsername = profile.sipUsername?.trim();
        const sipPassword = profile.sipPassword?.trim();
        if (sipUsername) payload.sip_username = sipUsername;
        if (sipPassword) payload.sip_password = sipPassword;
        return payload;
      });
    },
    virtualPbxUpdatePayload() {
      const form = this.virtualPbxForm;
      return {
        provider_kind: form.providerKind,
        channel_name: form.channelName.trim(),
        display_phone_number: form.displayPhoneNumber.trim(),
        routing: {
          mode: form.routingMode,
          fallback_mode: 'reject',
        },
        profiles: this.virtualPbxProfilesPayload(),
        metadata: {
          source: 'virtual_pbx_ui',
        },
      };
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
          { dryRun: false, remoteCommit: true }
        );
        const errors = response?.payload?.errors || [];
        if (errors.length) {
          useAlert(this.formatVirtualPbxMessages(errors));
          return;
        }

        useAlert(this.$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_SUCCESS'));
        this.fonosterReadinessKey += 1;
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
    async updateSipuniIntegrationSecret() {
      const integrationSecret = this.sipuniIntegrationSecret.trim();
      if (!integrationSecret) return;

      this.isUpdatingSipuniIntegrationSecret = true;
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...this.inbox.provider_config,
              integration_secret: integrationSecret,
            },
          },
        });
        this.sipuniIntegrationSecret = '';
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdatingSipuniIntegrationSecret = false;
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
    <template v-else-if="inbox.provider === 'sipuni'">
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_SUBTITLE')
        "
      >
        <woot-code
          :script="inbox.sipuni_events_webhook_url || ''"
          lang="html"
        />
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_MODE_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_MODE_SUBTITLE')
        "
      >
        <div class="flex flex-col gap-2 text-sm text-n-slate-11">
          <div>
            <span class="after:content-[':']">
              {{ $t('INBOX_MGMT.ADD.VOICE.SIPUNI.ACCOUNT_NUMBER.LABEL') }}
            </span>
            {{ inbox.provider_config?.account_number || '-' }}
          </div>
          <div v-if="inbox.provider_config?.default_internal_number">
            <span class="after:content-[':']">
              {{
                $t('INBOX_MGMT.ADD.VOICE.SIPUNI.DEFAULT_INTERNAL_NUMBER.LABEL')
              }}
            </span>
            {{ inbox.provider_config.default_internal_number }}
          </div>
          <div>
            <span class="after:content-[':']">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.CALL_SURFACE') }}
            </span>
            {{
              $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_EXTERNAL_SOFTPHONE')
            }}
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_OUTBOUND_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_OUTBOUND_SUBTITLE')
        "
      >
        <div class="flex flex-col gap-3 md:flex-row md:items-end">
          <woot-input
            v-model="sipuniIntegrationSecret"
            type="password"
            class="flex-1 [&>input]:!mb-0"
            :placeholder="
              $t('INBOX_MGMT.ADD.VOICE.SIPUNI.INTEGRATION_SECRET.PLACEHOLDER')
            "
          />
          <NextButton
            :disabled="!sipuniIntegrationSecret.trim()"
            :is-loading="isUpdatingSipuniIntegrationSecret"
            @click="updateSipuniIntegrationSecret"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_UPDATE_KEY') }}
          </NextButton>
        </div>
      </SettingsFieldSection>
    </template>
    <template v-else>
      <SettingsFieldSection
        v-if="!isVirtualPbxVoiceInbox"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_TITLE')"
        :help-text="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_SUBTITLE')"
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
          <div
            v-if="inbox.telephony?.routing_policy?.operator_agent_aor"
            class="text-sm text-n-slate-11"
          >
            <span class="after:content-[':']">
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.OPERATOR_AGENT_AOR') }}
            </span>
            {{ inbox.telephony.routing_policy.operator_agent_aor }}
          </div>
        </div>
      </SettingsFieldSection>
      <SettingsFieldSection
        v-if="!isVirtualPbxVoiceInbox"
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_ROUTING_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_ROUTING_SUBTITLE')
        "
      >
        <FonosterRoutingForm :inbox="inbox" @saved="handleFonosterRouteSaved" />
      </SettingsFieldSection>
      <SettingsFieldSection
        v-if="!isVirtualPbxVoiceInbox"
        :label="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_READINESS_TITLE')
        "
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_READINESS_SUBTITLE')
        "
      >
        <FonosterReadiness :key="fonosterReadinessKey" :inbox="inbox" />
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.MANAGEMENT_TITLE')"
        :help-text="$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.MANAGEMENT_SUBTITLE')"
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
                {{ error.message || error.code }}
              </li>
            </ul>
          </div>

          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CHANNEL_NAME.LABEL') }}
            <input
              v-model="virtualPbxForm.channelName"
              class="rounded-lg border border-n-weak py-2 text-sm"
              :disabled="isVirtualPbxReadOnly"
              type="text"
            />
          </label>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.LABEL') }}
              <select
                v-model="virtualPbxForm.providerKind"
                class="rounded-lg border border-n-weak py-2 text-sm"
                :disabled="isVirtualPbxReadOnly"
              >
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

          <div class="rounded-xl border border-n-weak p-4">
            <div class="mb-3 space-y-1">
              <h3 class="text-sm font-medium text-n-slate-12">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE')
                }}
              </h3>
              <p class="text-sm text-n-slate-11">
                {{
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.HINT')
                }}
              </p>
            </div>

            <div class="flex flex-col gap-3">
              <div
                v-for="(profile, index) in virtualPbxForm.profiles"
                :key="profile.clientId"
                class="grid grid-cols-1 gap-3 rounded-lg border border-n-weak p-3 md:grid-cols-2"
              >
                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
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

                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
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

                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
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

                <div class="md:col-span-2">
                  <button
                    type="button"
                    class="text-sm text-n-ruby-10"
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

            <button
              type="button"
              class="mt-3 rounded-lg border border-n-weak py-2 text-sm text-n-slate-12"
              :disabled="isVirtualPbxReadOnly"
              @click="addVirtualPbxProfile"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.ADD') }}
            </button>
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
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
          :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_WEBHOOK_TITLE')"
          :help-text="
            $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_WEBHOOK_SUBHEADER')
          "
        >
          <woot-code :script="inbox.provider_config.webhook_verify_token" />
        </SettingsFieldSection>
        <SettingsFieldSection
          :label="$t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_TITLE')"
          :help-text="
            $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_SUBHEADER')
          "
        >
          <woot-code :script="inbox.provider_config.api_key" />
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
              type="text"
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
