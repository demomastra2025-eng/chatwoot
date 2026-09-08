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
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
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
import SectionLayout from './components/SectionLayout.vue';
import WorkspaceLogo from './components/WorkspaceLogo.vue';
import MediaTranscription from './components/MediaTranscription.vue';
import SamlSettings from '../security/components/SamlSettings.vue';
import SamlPaywall from '../security/components/SamlPaywall.vue';
import { setDashboardLocale } from 'dashboard/i18n';

export default {
  components: {
    BaseSettingsHeader,
    NextButton,
    AccountId,
    BuildInfo,
    AccountDelete,
    SectionLayout,
    WorkspaceLogo,
    MediaTranscription,
    WithLabel,
    NextInput,
    NextSelect,
    SamlSettings,
    SamlPaywall,
  },
  beforeRouteLeave(to, from, next) {
    if (this.confirmWorkspaceNavigation()) {
      next();
      return;
    }

    next(false);
  },
  beforeRouteUpdate(to, from, next) {
    const isWorkspaceChange = to.params.accountId !== from.params.accountId;
    if (!isWorkspaceChange || this.confirmWorkspaceNavigation()) {
      next();
      return;
    }

    next(false);
  },
  setup() {
    const { uiSettings } = useUISettings();
    const { enabledLanguages } = useConfig();
    const { accountId } = useAccount();
    const { shouldShow, shouldShowPaywall, checkPermissions } = usePolicy();
    const v$ = useVuelidate({ $scope: false });
    const allowedLoginMethods = computed(
      () => window.chatwootConfig?.allowedLoginMethods || ['email']
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
    const canManageWorkspace = computed(() =>
      checkPermissions(['administrator'])
    );

    return {
      uiSettings,
      v$,
      enabledLanguages,
      accountId,
      shouldShowSaml,
      showSamlPaywall,
      canManageWorkspace,
    };
  },
  data() {
    return {
      activeWorkspaceSection: 'general',
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
      isOnChatwootCloud: 'globalConfig/isOnChatwootCloud',
    }),
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
    accountRecord() {
      return this.getAccount(this.accountId);
    },
    isWorkspaceReadOnly() {
      return !this.canManageWorkspace;
    },
    workspaceSections() {
      const sections = [
        {
          id: 'general',
          icon: 'i-lucide-building-2',
          label: this.$t('GENERAL_SETTINGS.SECTIONS.GENERAL'),
        },
        {
          id: 'communications',
          icon: 'i-lucide-messages-square',
          label: this.$t('GENERAL_SETTINGS.SECTIONS.COMMUNICATIONS'),
        },
        {
          id: 'security',
          icon: 'i-lucide-shield-check',
          label: this.$t('GENERAL_SETTINGS.SECTIONS.SECURITY'),
        },
        {
          id: 'technical',
          icon: 'i-lucide-braces',
          label: this.$t('GENERAL_SETTINGS.SECTIONS.TECHNICAL'),
        },
      ];

      if (this.isOnChatwootCloud && !this.isWorkspaceReadOnly) {
        sections.push({
          id: 'danger',
          icon: 'i-lucide-triangle-alert',
          label: this.$t('GENERAL_SETTINGS.SECTIONS.DANGER'),
          danger: true,
        });
      }

      return sections;
    },
    hasWorkspaceChanges() {
      const account = this.accountRecord;
      if (!account?.id || Number(this.id) !== Number(account.id)) return false;

      return (
        Boolean(this.logoFile) ||
        this.normalizeTextField(this.name) !==
          this.normalizeTextField(account.name) ||
        this.locale !== account.locale ||
        this.normalizeTextField(this.domain) !==
          this.normalizeTextField(account.domain) ||
        this.normalizeTextField(this.supportEmail) !==
          this.normalizeTextField(account.support_email)
      );
    },
  },
  watch: {
    accountRecord: {
      immediate: true,
      async handler() {
        await this.hydrateAccountForm();
      },
    },
    workspaceSections: {
      immediate: true,
      handler() {
        this.ensureActiveWorkspaceSection();
      },
    },
  },
  async mounted() {
    await this.hydrateAccountForm();
    window.addEventListener('beforeunload', this.handleBeforeUnload);
  },
  beforeUnmount() {
    window.removeEventListener('beforeunload', this.handleBeforeUnload);
  },
  methods: {
    ensureActiveWorkspaceSection() {
      const sectionIsAvailable = this.workspaceSections.some(
        section => section.id === this.activeWorkspaceSection
      );
      if (!sectionIsAvailable) this.activeWorkspaceSection = 'general';
    },
    normalizeTextField(value) {
      return String(value || '').trim();
    },
    normalizedFormPayload() {
      return {
        id: this.id,
        locale: this.locale,
        name: this.normalizeTextField(this.name),
        domain: this.normalizeTextField(this.domain),
        support_email: this.normalizeTextField(this.supportEmail),
        logo: this.logoFile,
      };
    },
    async applySelectedLocale(locale) {
      const selectedLocale = await setDashboardLocale(locale);
      document.documentElement.lang = selectedLocale;
      if (window.chatwootConfig) {
        window.chatwootConfig.selectedLocale = selectedLocale;
      }
    },
    async applyAccountToForm(account) {
      const { name, locale, id, domain, support_email, features, logo_url } =
        account;

      await this.applySelectedLocale(this.uiSettings?.locale || locale);
      this.name = name || '';
      this.locale = locale;
      this.id = id;
      this.domain = domain || '';
      this.supportEmail = support_email || '';
      this.features = features;
      this.logoFile = null;
      this.logoUrl = logo_url || '';
    },

    async hydrateAccountForm() {
      const account = this.accountRecord;
      if (!account?.id) {
        return;
      }

      const isSameAccount = Number(this.id) === Number(account.id);
      const shouldHydrate =
        !this.id || !isSameAccount || !this.hasWorkspaceChanges;

      if (shouldHydrate) {
        await this.applyAccountToForm(account);
      }
    },

    workspaceFormValidationMessage() {
      if (!this.name) {
        return this.$t('GENERAL_SETTINGS.FORM.NAME.ERROR');
      }

      if (!this.locale) {
        return (
          this.$t('GENERAL_SETTINGS.FORM.LANGUAGE.ERROR') ||
          this.$t('GENERAL_SETTINGS.FORM.ERROR')
        );
      }

      return this.$t('GENERAL_SETTINGS.FORM.ERROR');
    },

    async validateWorkspaceForm() {
      const isValid = await this.v$.$validate();
      if (isValid && this.name) {
        return true;
      }

      useAlert(this.workspaceFormValidationMessage());
      return false;
    },

    async updateAccount() {
      if (this.isWorkspaceReadOnly) {
        useAlert(this.$t('GENERAL_SETTINGS.LIMIT_MESSAGES.NON_ADMIN'));
        return;
      }

      const payload = this.normalizedFormPayload();
      this.name = payload.name;
      this.domain = payload.domain;
      this.supportEmail = payload.support_email;
      this.v$.$touch();
      if (!(await this.validateWorkspaceForm())) {
        return;
      }
      try {
        await this.$store.dispatch('accounts/update', payload);
        this.logoFile = null;
        this.logoUrl = this.getAccount(this.id)?.logo_url || this.logoUrl;
        const selectedLocale = this.uiSettings?.locale || this.locale;
        await this.applySelectedLocale(selectedLocale);
        await this.hydrateAccountForm();
        useAlert(this.$t('GENERAL_SETTINGS.UPDATE.SUCCESS'));
      } catch (error) {
        const errorMessage = parseAPIErrorResponse(error);
        useAlert(
          (typeof errorMessage === 'string' && errorMessage) ||
            error?.message ||
            this.$t('GENERAL_SETTINGS.UPDATE.ERROR')
        );
      }
    },
    async discardWorkspaceChanges() {
      await this.applyAccountToForm(this.accountRecord);
      this.v$.$reset();
    },
    confirmWorkspaceNavigation() {
      if (!this.hasWorkspaceChanges) return true;

      // Native navigation protection is required before the component unmounts.
      // eslint-disable-next-line no-alert
      return window.confirm(this.$t('GENERAL_SETTINGS.UNSAVED.CONFIRM_LEAVE'));
    },
    handleBeforeUnload(event) {
      if (!this.hasWorkspaceChanges) return;

      event.preventDefault();
      event.returnValue = '';
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
  <div class="flex flex-col w-full">
    <BaseSettingsHeader :title="$t('GENERAL_SETTINGS.TITLE')" />
    <div
      class="grid grid-cols-1 md:grid-cols-[13rem_minmax(0,45rem)] items-start gap-6 mt-5"
    >
      <nav
        class="flex md:flex-col gap-1 overflow-x-auto md:overflow-visible md:sticky md:top-4"
        :aria-label="$t('GENERAL_SETTINGS.SECTIONS.NAVIGATION')"
      >
        <button
          v-for="section in workspaceSections"
          :key="section.id"
          type="button"
          class="flex flex-none items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium text-left transition-colors"
          :class="{
            'bg-n-alpha-2 text-n-slate-12':
              activeWorkspaceSection === section.id && !section.danger,
            'bg-n-ruby-3 text-n-ruby-11':
              activeWorkspaceSection === section.id && section.danger,
            'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12':
              activeWorkspaceSection !== section.id && !section.danger,
            'text-n-ruby-10 hover:bg-n-ruby-3':
              activeWorkspaceSection !== section.id && section.danger,
          }"
          :aria-current="
            activeWorkspaceSection === section.id ? 'page' : undefined
          "
          @click="activeWorkspaceSection = section.id"
        >
          <span :class="section.icon" class="text-base" />
          {{ section.label }}
        </button>
      </nav>

      <main
        class="min-w-0 rounded-xl border border-n-weak bg-n-background px-5 md:px-7 shadow-sm"
      >
        <div
          v-if="isWorkspaceReadOnly"
          class="mt-6 flex items-start gap-2 rounded-lg bg-n-amber-3 px-4 py-3 text-sm text-n-amber-11"
        >
          <span class="i-lucide-lock-keyhole mt-0.5" />
          <span>{{ $t('GENERAL_SETTINGS.READ_ONLY') }}</span>
        </div>

        <template v-if="activeWorkspaceSection === 'general'">
          <SectionLayout
            :title="$t('GENERAL_SETTINGS.FORM.GENERAL_SECTION.TITLE')"
            :description="$t('GENERAL_SETTINGS.FORM.GENERAL_SECTION.NOTE')"
            class="!pt-6"
          >
            <form
              v-if="!uiFlags.isFetchingItem"
              class="grid gap-4"
              @submit.prevent="updateAccount"
            >
              <WorkspaceLogo
                :name="name"
                :src="logoUrl"
                :disabled="isWorkspaceReadOnly"
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
                  :disabled="isWorkspaceReadOnly"
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
                <NextSelect
                  v-model="locale"
                  class="!mb-0 text-sm"
                  :disabled="isWorkspaceReadOnly"
                >
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
                  :disabled="isWorkspaceReadOnly"
                  :placeholder="$t('GENERAL_SETTINGS.FORM.DOMAIN.PLACEHOLDER')"
                />
                <template #help>
                  {{
                    featureInboundEmailEnabled &&
                    $t('GENERAL_SETTINGS.FORM.FEATURES.INBOUND_EMAIL_ENABLED')
                  }}

                  {{
                    featureCustomReplyDomainEnabled &&
                    $t(
                      'GENERAL_SETTINGS.FORM.FEATURES.CUSTOM_EMAIL_DOMAIN_ENABLED'
                    )
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
                  :disabled="isWorkspaceReadOnly"
                  :placeholder="
                    $t('GENERAL_SETTINGS.FORM.SUPPORT_EMAIL.PLACEHOLDER')
                  "
                />
              </WithLabel>
            </form>
          </SectionLayout>

          <woot-loading-state v-if="uiFlags.isFetchingItem" />
        </template>

        <MediaTranscription
          v-else-if="
            activeWorkspaceSection === 'communications' &&
            !uiFlags.isFetchingItem
          "
          :disabled="isWorkspaceReadOnly"
        />

        <template v-else-if="activeWorkspaceSection === 'security'">
          <SamlPaywall v-if="showSamlPaywall" />
          <SamlSettings v-else-if="shouldShowSaml" />
          <SectionLayout
            v-else
            :title="$t('SECURITY_SETTINGS.SAML.TITLE')"
            :description="$t('SECURITY_SETTINGS.SAML.NOTE')"
          >
            <div class="text-sm text-n-slate-11">
              {{ $t('SECURITY_SETTINGS.SAML_DISABLED_MESSAGE') }}
            </div>
          </SectionLayout>
        </template>

        <template v-else-if="activeWorkspaceSection === 'technical'">
          <AccountId />
          <BuildInfo />
        </template>

        <div
          v-else-if="
            activeWorkspaceSection === 'danger' &&
            !uiFlags.isFetchingItem &&
            isOnChatwootCloud &&
            !isWorkspaceReadOnly
          "
        >
          <AccountDelete />
        </div>
      </main>
    </div>

    <div
      v-if="hasWorkspaceChanges && !isWorkspaceReadOnly"
      class="sticky bottom-4 z-20 mt-6 ml-auto flex w-full max-w-[45rem] items-center justify-between gap-4 rounded-xl border border-n-weak bg-n-background/95 px-4 py-3 shadow-lg backdrop-blur"
    >
      <div class="flex items-center gap-2 text-sm text-n-slate-11">
        <span class="i-lucide-circle-alert text-n-amber-10" />
        {{ $t('GENERAL_SETTINGS.UNSAVED.MESSAGE') }}
      </div>
      <div class="flex items-center gap-2">
        <NextButton
          faded
          slate
          sm
          :label="$t('GENERAL_SETTINGS.UNSAVED.DISCARD')"
          @click="discardWorkspaceChanges"
        />
        <NextButton
          blue
          sm
          :label="$t('GENERAL_SETTINGS.SUBMIT')"
          :is-loading="isUpdating"
          @click="updateAccount"
        />
      </div>
    </div>
  </div>
</template>
