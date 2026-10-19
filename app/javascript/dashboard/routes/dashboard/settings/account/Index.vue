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
import WithLabel from 'v3/components/Form/WithLabel.vue';
import NextInput from 'next/input/Input.vue';
import NextSelect from 'dashboard/components-next/select/Select.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import AccountId from './components/AccountId.vue';
import AccountDelete from './components/AccountDelete.vue';
import SectionLayout from './components/SectionLayout.vue';
import WorkspaceLogo from './components/WorkspaceLogo.vue';
import { setDashboardLocale } from 'dashboard/i18n';

export default {
  components: {
    BaseSettingsHeader,
    NextButton,
    AccountId,
    AccountDelete,
    SectionLayout,
    WorkspaceLogo,
    WithLabel,
    NextInput,
    NextSelect,
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
    const { checkPermissions } = usePolicy();
    const v$ = useVuelidate({ $scope: false });
    const canManageWorkspace = computed(() =>
      checkPermissions(['administrator'])
    );

    return {
      uiSettings,
      v$,
      enabledLanguages,
      accountId,
      canManageWorkspace,
    };
  },
  data() {
    return {
      id: '',
      name: '',
      locale: 'ru',
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
    accountRecord() {
      return this.getAccount(this.accountId);
    },
    isWorkspaceReadOnly() {
      return !this.canManageWorkspace;
    },
    hasWorkspaceChanges() {
      const account = this.accountRecord;
      if (!account?.id || Number(this.id) !== Number(account.id)) return false;

      return (
        Boolean(this.logoFile) ||
        this.normalizeTextField(this.name) !==
          this.normalizeTextField(account.name) ||
        this.locale !== account.locale
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
  },
  async mounted() {
    await this.hydrateAccountForm();
    window.addEventListener('beforeunload', this.handleBeforeUnload);
  },
  beforeUnmount() {
    window.removeEventListener('beforeunload', this.handleBeforeUnload);
  },
  methods: {
    normalizeTextField(value) {
      return String(value || '').trim();
    },
    normalizedFormPayload() {
      return {
        id: this.id,
        locale: this.locale,
        name: this.normalizeTextField(this.name),
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
      const { name, locale, id, features, logo_url } = account;

      await this.applySelectedLocale(this.uiSettings?.locale || locale);
      this.name = name || '';
      this.locale = locale;
      this.id = id;
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
      if (!this.accountRecord?.id) return;

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
    <div class="w-full max-w-3xl mt-4">
      <main class="min-w-0">
        <div
          v-if="isWorkspaceReadOnly"
          class="mb-6 flex items-start gap-2 rounded-xl bg-n-amber-3 px-4 py-3 text-sm text-n-amber-11"
        >
          <span class="i-lucide-lock-keyhole mt-0.5" />
          <span>{{ $t('GENERAL_SETTINGS.READ_ONLY') }}</span>
        </div>

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
          </form>
        </SectionLayout>

        <woot-loading-state v-if="uiFlags.isFetchingItem" />

        <div v-if="accountRecord?.id" class="border-t border-n-weak py-6">
          <AccountId />
        </div>

        <div
          v-if="
            accountRecord?.id &&
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
      class="sticky bottom-4 z-20 mt-6 flex w-full max-w-3xl flex-col items-start gap-3 rounded-xl outline outline-1 -outline-offset-1 outline-n-weak bg-n-background/95 px-4 py-3 shadow-lg backdrop-blur"
    >
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
      <div class="flex items-center gap-2 text-sm text-n-slate-11">
        <span class="i-lucide-circle-alert text-n-amber-10" />
        {{ $t('GENERAL_SETTINGS.UNSAVED.MESSAGE') }}
      </div>
    </div>
  </div>
</template>
