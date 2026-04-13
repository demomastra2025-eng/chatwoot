<script>
import { mapGetters } from 'vuex';
import LoadingState from './components/widgets/LoadingState.vue';
import NetworkNotification from './components/NetworkNotification.vue';
import PaymentPendingBanner from './components/app/PaymentPendingBanner.vue';
import PendingEmailVerificationBanner from './components/app/PendingEmailVerificationBanner.vue';
import WootButton from 'dashboard/components-next/button/Button.vue';
import vueActionCable from './helper/actionCable';
import AuthAPI from './api/auth';
import { useRouter } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import WootSnackbarBox from './components/SnackbarContainer.vue';
import { setColorTheme } from './helper/themeHelper';
import { isOnOnboardingView } from 'v3/helpers/RouteHelper';
import { useAccount } from 'dashboard/composables/useAccount';
import { useFontSize } from 'dashboard/composables/useFontSize';
import {
  registerSubscription,
  verifyServiceWorkerExistence,
} from './helper/pushHelper';
import ReconnectService from 'dashboard/helper/ReconnectService';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { emitter } from 'shared/helpers/mitt';
import {
  clearCookiesOnLogoutTo,
  deleteIndexedDBOnLogout,
} from './store/utils/api';

export default {
  name: 'App',

  components: {
    WootButton,
    LoadingState,
    NetworkNotification,
    PaymentPendingBanner,
    WootSnackbarBox,
    PendingEmailVerificationBanner,
  },
  setup() {
    const router = useRouter();
    const store = useStore();
    const { accountId } = useAccount();
    // Use the font size composable (it automatically sets up the watcher)
    const { currentFontSize } = useFontSize();
    const { uiSettings } = useUISettings();

    return {
      router,
      store,
      currentAccountId: accountId,
      currentFontSize,
      uiSettings,
    };
  },
  data() {
    return {
      latestChatwootVersion: null,
      reconnectService: null,
      sessionReplacedState: {
        isOpen: false,
        message: '',
      },
    };
  },
  computed: {
    ...mapGetters({
      getAccount: 'accounts/getAccount',
      isRTL: 'accounts/isRTL',
      currentUser: 'getCurrentUser',
      authUIFlags: 'getAuthUIFlags',
      accountUIFlags: 'accounts/getUIFlags',
    }),
    hideOnOnboardingView() {
      return !isOnOnboardingView(this.$route);
    },
  },

  watch: {
    currentAccountId: {
      immediate: true,
      handler() {
        if (this.currentAccountId) {
          this.initializeAccount();
        }
      },
    },
  },
  mounted() {
    this.initializeColorTheme();
    this.listenToThemeChanges();
    // If user locale is set, use it; otherwise use account locale
    this.setLocale(
      this.uiSettings?.locale || window.chatwootConfig.selectedLocale
    );
  },
  unmounted() {
    emitter.off('auth:session_replaced', this.onSessionReplaced);
    if (this.reconnectService) {
      this.reconnectService.disconnect();
    }
  },
  created() {
    emitter.on('auth:session_replaced', this.onSessionReplaced);
  },
  methods: {
    initializeColorTheme() {
      setColorTheme(window.matchMedia('(prefers-color-scheme: dark)').matches);
    },
    listenToThemeChanges() {
      const mql = window.matchMedia('(prefers-color-scheme: dark)');
      mql.onchange = e => setColorTheme(e.matches);
    },
    onSessionReplaced({ message }) {
      this.sessionReplacedState = {
        isOpen: true,
        message:
          message || this.$t('GENERAL.AUTH_SESSION_REPLACED.DESCRIPTION'),
      };
    },
    confirmSessionReplaced() {
      deleteIndexedDBOnLogout();
      clearCookiesOnLogoutTo('/app/login');
    },
    setLocale(locale) {
      this.$root.$i18n.locale = locale;
      document.documentElement.lang = locale;
      if (window.chatwootConfig) {
        window.chatwootConfig.selectedLocale = locale;
      }
    },
    async initializeAccount() {
      await this.$store.dispatch('accounts/get');
      this.$store.dispatch('setActiveAccount', {
        accountId: this.currentAccountId,
      });
      const { locale, latest_chatwoot_version: latestChatwootVersion } =
        this.getAccount(this.currentAccountId);
      const { pubsub_token: pubsubToken } = this.currentUser || {};
      const authClientId = AuthAPI.getAuthData()?.client;
      // If user locale is set, use it; otherwise use account locale
      this.setLocale(this.uiSettings?.locale || locale);
      this.latestChatwootVersion = latestChatwootVersion;
      vueActionCable.init(this.store, pubsubToken, authClientId);
      this.reconnectService = new ReconnectService(this.store, this.router);
      window.reconnectService = this.reconnectService;

      verifyServiceWorkerExistence(registration =>
        registration.pushManager.getSubscription().then(subscription => {
          if (subscription) {
            registerSubscription();
          }
        })
      );
    },
  },
};
</script>

<template>
  <div
    v-if="!authUIFlags.isFetching && !accountUIFlags.isFetchingItem"
    id="app"
    class="flex flex-col w-full h-full min-h-0 overflow-hidden bg-n-background"
    :dir="isRTL ? 'rtl' : 'ltr'"
  >
    <!-- Onelink intentionally hides the global update banner in the app chrome. -->
    <template v-if="currentAccountId">
      <PendingEmailVerificationBanner v-if="hideOnOnboardingView" />
      <PaymentPendingBanner v-if="hideOnOnboardingView" />
    </template>
    <router-view v-slot="{ Component }">
      <transition name="fade" mode="out-in">
        <component :is="Component" />
      </transition>
    </router-view>
    <div
      v-if="sessionReplacedState.isOpen"
      class="fixed inset-0 z-[1100] flex items-center justify-center bg-n-alpha-black1 backdrop-blur-[6px] p-4"
    >
      <div
        class="w-full max-w-md rounded-2xl border border-n-weak bg-n-alpha-3 backdrop-blur-[100px] shadow-xl p-6 flex flex-col gap-4"
      >
        <div class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('GENERAL.AUTH_SESSION_REPLACED.TITLE') }}
          </h2>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ sessionReplacedState.message }}
          </p>
        </div>
        <WootButton
          class="w-full"
          color="blue"
          :label="$t('GENERAL.AUTH_SESSION_REPLACED.ACTION')"
          @click="confirmSessionReplaced"
        />
      </div>
    </div>
    <WootSnackbarBox />
    <NetworkNotification />
  </div>
  <LoadingState v-else />
</template>

<style lang="scss">
@import './assets/scss/app';

.v-popper--theme-tooltip .v-popper__inner {
  background: black !important;
  font-size: 0.75rem;
  padding: 4px 8px !important;
  border-radius: 6px;
  font-weight: 400;
}

.v-popper--theme-tooltip .v-popper__arrow-container {
  display: none;
}
</style>
