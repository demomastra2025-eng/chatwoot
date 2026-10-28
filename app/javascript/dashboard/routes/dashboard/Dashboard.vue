<script>
import { defineAsyncComponent, computed } from 'vue';

import NextSidebar from 'next/sidebar/Sidebar.vue';
import WootKeyShortcutModal from 'dashboard/components/widgets/modal/WootKeyShortcutModal.vue';
import AddAccountModal from 'dashboard/components/app/AddAccountModal.vue';

import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import { useWindowSize } from '@vueuse/core';

import wootConstants from 'dashboard/constants/globals';

const CommandBar = defineAsyncComponent(
  () => import('./commands/commandbar.vue')
);

const FloatingCallWidget = defineAsyncComponent(
  () => import('dashboard/components/widgets/FloatingCallWidget.vue')
);

const PhoneWidget = defineAsyncComponent(
  () => import('dashboard/components/widgets/PhoneWidget.vue')
);

import MobileSidebarLauncher from 'dashboard/components-next/sidebar/MobileSidebarLauncher.vue';
import { useCallsStore } from 'dashboard/stores/calls';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';

export default {
  components: {
    NextSidebar,
    CommandBar,
    WootKeyShortcutModal,
    AddAccountModal,
    FloatingCallWidget,
    PhoneWidget,
    MobileSidebarLauncher,
  },
  setup() {
    const { uiSettings, updateUISettings } = useUISettings();
    const { accountId, currentAccount } = useAccount();
    const { shouldShow } = usePolicy();
    const { width: windowWidth } = useWindowSize();
    const callsStore = useCallsStore();
    const phoneWidgetStore = usePhoneWidgetStore();
    const whatsappCallsStore = useWhatsappCallsStore();

    const hasWhatsappCall = computed(
      () =>
        whatsappCallsStore.hasActiveCall || whatsappCallsStore.hasIncomingCall
    );

    return {
      uiSettings,
      updateUISettings,
      accountId,
      currentAccount,
      // The plan page is administrator-only and only exists on cloud installations.
      canChoosePlan: computed(() =>
        shouldShow('', ['administrator'], [INSTALLATION_TYPES.CLOUD])
      ),
      isAccountAdmin: computed(() => shouldShow('', ['administrator'])),
      windowWidth,
      hasActiveCall: computed(() => callsStore.hasActiveCall),
      hasIncomingCall: computed(() => callsStore.hasIncomingCall),
      // Employees with a browser SIP line or an active/incoming WhatsApp call
      // see their calls inside the unified phone widget; standalone call cards
      // are only for everyone else.
      showStandaloneCallCards: computed(
        () => !phoneWidgetStore.available && !hasWhatsappCall.value
      ),
      hasWhatsappCall,
    };
  },
  data() {
    return {
      showAccountModal: false,
      showCreateAccountModal: false,
      showShortcutModal: false,
      isMobileSidebarOpen: false,
      currentTime: Date.now(),
      trialTimer: null,
    };
  },
  computed: {
    isSmallScreen() {
      return this.windowWidth < wootConstants.SMALL_SCREEN_BREAKPOINT;
    },
    isTrialPlan() {
      return (
        this.isAccountAdmin &&
        this.currentAccount?.custom_attributes?.plan_type === 'trial'
      );
    },
    trialExpiry() {
      const attributes = this.currentAccount?.custom_attributes;
      return attributes?.trial_expires_at || attributes?.trial_ends_at;
    },
    trialExpiryDate() {
      if (!this.trialExpiry) return '';
      return new Intl.DateTimeFormat('ru-RU', {
        day: '2-digit',
        month: '2-digit',
        timeZone: this.currentAccount?.timezone || 'Asia/Almaty',
      }).format(new Date(this.trialExpiry));
    },
    isTrialExpired() {
      if (!this.isTrialPlan || !this.trialExpiry) return false;
      return new Date(this.trialExpiry).getTime() <= this.currentTime;
    },
    trialTimeText() {
      if (!this.trialExpiry) {
        return this.$t('TRIAL_BANNER.TIME.DAYS_HOURS', { days: 3, hours: 0 });
      }
      const totalSeconds = Math.max(
        0,
        Math.floor(
          (new Date(this.trialExpiry).getTime() - this.currentTime) / 1000
        )
      );
      const days = Math.floor(totalSeconds / 86400);
      const hours = Math.floor((totalSeconds % 86400) / 3600);
      const minutes = Math.floor((totalSeconds % 3600) / 60);

      if (days > 0)
        return this.$t('TRIAL_BANNER.TIME.DAYS_HOURS', { days, hours });
      if (hours > 0)
        return this.$t('TRIAL_BANNER.TIME.HOURS_MINUTES', { hours, minutes });
      return this.$t('TRIAL_BANNER.TIME.MINUTES', { minutes });
    },
    previouslyUsedDisplayType() {
      const {
        previously_used_conversation_display_type: conversationDisplayType,
      } = this.uiSettings;
      return conversationDisplayType;
    },
  },
  watch: {
    // The layout is a per-user setting shared by every device, so a phone has
    // to apply the expanded layout when the page loads, not only when the
    // window later crosses the breakpoint. Otherwise a condensed layout left
    // by a desktop session shows the list and the open dialog side by side on
    // a phone. Writes only when the effective layout actually changes.
    isSmallScreen: {
      handler() {
        const { LAYOUT_TYPES } = wootConstants;
        const targetDisplayType =
          window.innerWidth <= wootConstants.SMALL_SCREEN_BREAKPOINT
            ? LAYOUT_TYPES.EXPANDED
            : this.previouslyUsedDisplayType || LAYOUT_TYPES.CONDENSED;
        const currentDisplayType =
          this.uiSettings?.conversation_display_type || LAYOUT_TYPES.CONDENSED;
        if (currentDisplayType !== targetDisplayType) {
          this.updateUISettings({
            conversation_display_type: targetDisplayType,
          });
        }
      },
      immediate: true,
    },
    isTrialPlan: {
      handler(isTrial) {
        if (isTrial) {
          this.startTrialTimer();
        } else {
          this.stopTrialTimer();
        }
      },
      immediate: true,
    },
  },
  beforeUnmount() {
    this.stopTrialTimer();
  },
  methods: {
    startTrialTimer() {
      if (this.trialTimer) return;
      this.currentTime = Date.now();
      this.trialTimer = setInterval(() => {
        this.currentTime = Date.now();
      }, 30000);
    },
    stopTrialTimer() {
      if (!this.trialTimer) return;
      clearInterval(this.trialTimer);
      this.trialTimer = null;
    },
    toggleMobileSidebar() {
      this.isMobileSidebarOpen = !this.isMobileSidebarOpen;
    },
    closeMobileSidebar() {
      this.isMobileSidebarOpen = false;
    },
    openCreateAccountModal() {
      this.showAccountModal = false;
      this.showCreateAccountModal = true;
    },
    closeCreateAccountModal() {
      this.showCreateAccountModal = false;
    },
    toggleAccountModal() {
      this.showAccountModal = !this.showAccountModal;
    },
    toggleKeyShortcutModal() {
      this.showShortcutModal = true;
    },
    closeKeyShortcutModal() {
      this.showShortcutModal = false;
    },
  },
};
</script>

<template>
  <div
    class="flex flex-grow w-full h-full min-h-0 overflow-hidden text-n-slate-12"
  >
    <NextSidebar
      :is-mobile-sidebar-open="isMobileSidebarOpen"
      @toggle-account-modal="toggleAccountModal"
      @open-key-shortcut-modal="toggleKeyShortcutModal"
      @close-key-shortcut-modal="closeKeyShortcutModal"
      @show-create-account-modal="openCreateAccountModal"
      @close-mobile-sidebar="closeMobileSidebar"
    />

    <main
      class="flex flex-1 h-full w-full min-h-0 px-0 overflow-hidden bg-n-surface-1"
    >
      <!-- Only trial accounts get the banner (and the extra wrapper it needs); every other account keeps the
           original layout with the routed page as a direct child. -->
      <div
        v-if="isTrialPlan"
        class="flex flex-col flex-1 h-full w-full min-h-0 overflow-hidden"
        data-testid="trial-banner-layout"
      >
        <div
          v-if="!isTrialExpired"
          class="flex items-center justify-between px-4 py-2 bg-amber-50 dark:bg-amber-950/40 border-b border-amber-200 dark:border-amber-900/50 text-amber-900 dark:text-amber-100 text-xs sm:text-sm font-medium z-10 flex-shrink-0"
          data-testid="trial-active-banner"
        >
          <div class="flex items-center gap-2 truncate">
            <span>{{
              $t('TRIAL_BANNER.ACTIVE', {
                time: trialTimeText,
                date: trialExpiryDate,
              })
            }}</span>
          </div>
          <router-link
            v-if="canChoosePlan"
            :to="{ name: 'billing_settings_index', params: { accountId } }"
            class="ml-3 px-3 py-1 bg-amber-600 hover:bg-amber-700 text-white text-xs font-semibold rounded-md shadow-xs transition-colors shrink-0"
          >
            {{ $t('TRIAL_BANNER.CHOOSE_PLAN') }}
          </router-link>
        </div>
        <div
          v-else
          class="flex items-center justify-between px-4 py-2 bg-red-50 dark:bg-red-950/40 border-b border-red-200 dark:border-red-900/50 text-red-900 dark:text-red-100 text-xs sm:text-sm font-medium z-10 flex-shrink-0"
          data-testid="trial-expired-banner"
        >
          <div class="flex items-center gap-2 truncate">
            <span>{{ $t('TRIAL_BANNER.EXPIRED') }}</span>
          </div>
          <router-link
            v-if="canChoosePlan"
            :to="{ name: 'billing_settings_index', params: { accountId } }"
            class="ml-3 px-3 py-1 bg-red-600 hover:bg-red-700 text-white text-xs font-semibold rounded-md shadow-xs transition-colors shrink-0"
          >
            {{ $t('TRIAL_BANNER.CHOOSE_PLAN') }}
          </router-link>
        </div>
        <router-view />
      </div>
      <router-view v-else />
      <CommandBar />
      <MobileSidebarLauncher
        :is-mobile-sidebar-open="isMobileSidebarOpen"
        @toggle="toggleMobileSidebar"
      />
      <FloatingCallWidget v-if="showStandaloneCallCards" />
      <PhoneWidget />
      <AddAccountModal
        :show="showCreateAccountModal"
        @close-account-create-modal="closeCreateAccountModal"
      />
      <WootKeyShortcutModal
        v-model:show="showShortcutModal"
        @close="closeKeyShortcutModal"
        @clickaway="closeKeyShortcutModal"
      />
    </main>
  </div>
</template>
