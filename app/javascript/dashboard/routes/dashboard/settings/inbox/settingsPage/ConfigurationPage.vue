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
  },
  watch: {
    inbox() {
      this.setDefaults();
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
        :label="$t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_ROUTING_TITLE')"
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_ROUTING_SUBTITLE')
        "
      >
        <FonosterRoutingForm :inbox="inbox" @saved="handleFonosterRouteSaved" />
      </SettingsFieldSection>
      <SettingsFieldSection
        :label="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_READINESS_TITLE')
        "
        :help-text="
          $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_READINESS_SUBTITLE')
        "
      >
        <FonosterReadiness :key="fonosterReadinessKey" :inbox="inbox" />
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
