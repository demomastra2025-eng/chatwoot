<script>
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { computed } from 'vue';
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useConfig } from 'dashboard/composables/useConfig';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import { FEATURE_FLAGS } from '../../../../featureFlags';
import WithLabel from 'v3/components/Form/WithLabel.vue';
import NextInput from 'next/input/Input.vue';
import NextSelect from 'dashboard/components-next/select/Select.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import AccountId from './components/AccountId.vue';
import BuildInfo from './components/BuildInfo.vue';
import AccountDelete from './components/AccountDelete.vue';
import AudioTranscription from './components/AudioTranscription.vue';
import SectionLayout from './components/SectionLayout.vue';
import WorkspaceLogo from './components/WorkspaceLogo.vue';
import SamlSettings from '../security/components/SamlSettings.vue';
import SamlPaywall from '../security/components/SamlPaywall.vue';

export default {
  components: {
    BaseSettingsHeader,
    NextButton,
    AccountId,
    BuildInfo,
    AccountDelete,
    AudioTranscription,
    SectionLayout,
    WorkspaceLogo,
    WithLabel,
    NextInput,
    NextSelect,
    SamlSettings,
    SamlPaywall,
  },
  setup() {
    const { uiSettings } = useUISettings();
    const { enabledLanguages } = useConfig();
    const { accountId } = useAccount();
    const { shouldShow, shouldShowPaywall } = usePolicy();
    const v$ = useVuelidate();
    const allowedLoginMethods = computed(
      () => window.chatwootConfig.allowedLoginMethods || ['email']
    );
    const shouldShowSaml = computed(() => {
      const hasPermission = shouldShow(
        FEATURE_FLAGS.SAML,
        ['administrator'],
        [INSTALLATION_TYPES.CLOUD, INSTALLATION_TYPES.ENTERPRISE]
      );

      return hasPermission && allowedLoginMethods.value.includes('saml');
    });
    const showSamlPaywall = computed(() => shouldShowPaywall('saml'));

    return {
      uiSettings,
      v$,
      enabledLanguages,
      accountId,
      shouldShowSaml,
      showSamlPaywall,
    };
  },
  data() {
    return {
      id: '',
      name: '',
      locale: 'ru',
      domain: '',
      supportEmail: '',
      features: {},
      logoFile: null,
      logoUrl: '',
    };
  },
  validations: {
    name: {
      required,
    },
    locale: {
      required,
    },
  },
  computed: {
    ...mapGetters({
      getAccount: 'accounts/getAccount',
      uiFlags: 'accounts/getUIFlags',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
      isOnChatwootCloud: 'globalConfig/isOnChatwootCloud',
    }),
    showAudioTranscriptionConfig() {
      return this.isFeatureEnabledonAccount(
        this.accountId,
        FEATURE_FLAGS.CAPTAIN
      );
    },
    languagesSortedByCode() {
      const enabledLanguages = [...this.enabledLanguages];
      return enabledLanguages.sort((l1, l2) =>
        l1.iso_639_1_code.localeCompare(l2.iso_639_1_code)
      );
    },
    isUpdating() {
      return this.uiFlags.isUpdating;
    },
    featureInboundEmailEnabled() {
      return !!this.features?.inbound_emails;
    },
    featureCustomReplyDomainEnabled() {
      return (
        this.featureInboundEmailEnabled && !!this.features.custom_reply_domain
      );
    },
    featureCustomReplyEmailEnabled() {
      return (
        this.featureInboundEmailEnabled && !!this.features.custom_reply_email
      );
    },
  },
  mounted() {
    this.initializeAccount();
  },
  methods: {
    async initializeAccount() {
      try {
        const { name, locale, id, domain, support_email, features, logo_url } =
          this.getAccount(this.accountId);

        this.$root.$i18n.locale = this.uiSettings?.locale || locale;
        this.name = name;
        this.locale = locale;
        this.id = id;
        this.domain = domain;
        this.supportEmail = support_email;
        this.features = features;
        this.logoFile = null;
        this.logoUrl = logo_url || '';
      } catch (error) {
        // Ignore error
      }
    },

    async updateAccount() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        useAlert(this.$t('GENERAL_SETTINGS.FORM.ERROR'));
        return;
      }
      try {
        await this.$store.dispatch('accounts/update', {
          id: this.id,
          locale: this.locale,
          name: this.name,
          domain: this.domain,
          support_email: this.supportEmail,
          logo: this.logoFile,
        });
        this.logoFile = null;
        this.logoUrl = this.getAccount(this.id)?.logo_url || this.logoUrl;
        // If user locale is set, update the locale with user locale
        if (this.uiSettings?.locale) {
          this.$root.$i18n.locale = this.uiSettings?.locale;
        } else {
          // If user locale is not set, update the locale with account locale
          this.$root.$i18n.locale = this.locale;
        }
        this.getAccount(this.id).locale = this.locale;
        useAlert(this.$t('GENERAL_SETTINGS.UPDATE.SUCCESS'));
      } catch (error) {
        useAlert(this.$t('GENERAL_SETTINGS.UPDATE.ERROR'));
      }
    },
    updateWorkspaceLogo({ file, url }) {
      this.logoFile = file;
      this.logoUrl = url;
    },
    async deleteWorkspaceLogo() {
      if (this.logoFile) {
        this.logoFile = null;
        this.logoUrl = this.getAccount(this.id)?.logo_url || '';
        return;
      }

      try {
        await this.$store.dispatch('accounts/deleteLogo', { id: this.id });
        this.logoFile = null;
        this.logoUrl = this.getAccount(this.id)?.logo_url || '';
        useAlert(this.$t('GENERAL_SETTINGS.FORM.LOGO.DELETE_SUCCESS'));
      } catch (error) {
        useAlert(this.$t('GENERAL_SETTINGS.FORM.LOGO.DELETE_ERROR'));
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col w-full max-w-2xl ltr:mr-auto rtl:ml-auto">
    <BaseSettingsHeader :title="$t('GENERAL_SETTINGS.TITLE')" />
    <div class="flex-grow flex-shrink min-w-0 mt-3">
      <SectionLayout
        :title="$t('GENERAL_SETTINGS.FORM.GENERAL_SECTION.TITLE')"
        :description="$t('GENERAL_SETTINGS.FORM.GENERAL_SECTION.NOTE')"
        class="!pt-0"
      >
        <form
          v-if="!uiFlags.isFetchingItem"
          class="grid gap-4"
          @submit.prevent="updateAccount"
        >
          <WorkspaceLogo
            :name="name"
            :src="logoUrl"
            @change="updateWorkspaceLogo"
            @delete="deleteWorkspaceLogo"
          />
          <WithLabel
            name="account-name"
            :has-error="v$.name.$error"
            :label="$t('GENERAL_SETTINGS.FORM.NAME.LABEL')"
            :error-message="$t('GENERAL_SETTINGS.FORM.NAME.ERROR')"
          >
            <NextInput
              v-model="name"
              type="text"
              class="w-full"
              :placeholder="$t('GENERAL_SETTINGS.FORM.NAME.PLACEHOLDER')"
              @blur="v$.name.$touch"
            />
          </WithLabel>
          <WithLabel
            name="site-language"
            :has-error="v$.locale.$error"
            :label="$t('GENERAL_SETTINGS.FORM.LANGUAGE.LABEL')"
            :error-message="$t('GENERAL_SETTINGS.FORM.LANGUAGE.ERROR')"
          >
            <NextSelect v-model="locale" class="!mb-0 text-sm">
              <option
                v-for="lang in languagesSortedByCode"
                :key="lang.iso_639_1_code"
                :value="lang.iso_639_1_code"
              >
                {{ lang.name }}
              </option>
            </NextSelect>
          </WithLabel>
          <WithLabel
            v-if="featureCustomReplyDomainEnabled"
            name="custom-domain"
            :label="$t('GENERAL_SETTINGS.FORM.DOMAIN.LABEL')"
          >
            <NextInput
              v-model="domain"
              type="text"
              class="w-full"
              :placeholder="$t('GENERAL_SETTINGS.FORM.DOMAIN.PLACEHOLDER')"
            />
            <template #help>
              {{
                featureInboundEmailEnabled &&
                $t('GENERAL_SETTINGS.FORM.FEATURES.INBOUND_EMAIL_ENABLED')
              }}

              {{
                featureCustomReplyDomainEnabled &&
                $t('GENERAL_SETTINGS.FORM.FEATURES.CUSTOM_EMAIL_DOMAIN_ENABLED')
              }}
            </template>
          </WithLabel>
          <WithLabel
            v-if="featureCustomReplyEmailEnabled"
            name="support-email"
            :label="$t('GENERAL_SETTINGS.FORM.SUPPORT_EMAIL.LABEL')"
          >
            <NextInput
              v-model="supportEmail"
              type="text"
              class="w-full"
              :placeholder="
                $t('GENERAL_SETTINGS.FORM.SUPPORT_EMAIL.PLACEHOLDER')
              "
            />
          </WithLabel>
          <div>
            <NextButton blue :is-loading="isUpdating" type="submit">
              {{ $t('GENERAL_SETTINGS.SUBMIT') }}
            </NextButton>
          </div>
        </form>
      </SectionLayout>

      <woot-loading-state v-if="uiFlags.isFetchingItem" />
    </div>
    <SamlPaywall v-if="showSamlPaywall" />
    <SamlSettings v-else-if="shouldShowSaml" />
    <SectionLayout
      v-else
      :title="$t('SECURITY_SETTINGS.SAML.TITLE')"
      :description="$t('SECURITY_SETTINGS.SAML.NOTE')"
    >
      <div class="text-sm text-slate-600">
        {{ $t('SECURITY_SETTINGS.SAML_DISABLED_MESSAGE') }}
      </div>
    </SectionLayout>
    <AudioTranscription v-if="showAudioTranscriptionConfig" />
    <AccountId />
    <div v-if="!uiFlags.isFetchingItem && isOnChatwootCloud">
      <AccountDelete />
    </div>
    <BuildInfo />
  </div>
</template>
