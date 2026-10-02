<script>
import { defineAsyncComponent, ref, computed } from 'vue';

import NextSidebar from 'next/sidebar/Sidebar.vue';
import WootKeyShortcutModal from 'dashboard/components/widgets/modal/WootKeyShortcutModal.vue';
import AddAccountModal from 'dashboard/components/app/AddAccountModal.vue';
import UpgradePage from 'dashboard/routes/dashboard/upgrade/UpgradePage.vue';

import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAccount } from 'dashboard/composables/useAccount';
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

const WhatsappCallWidget = defineAsyncComponent(
  () => import('dashboard/components/widgets/WhatsappCallWidget.vue')
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
    UpgradePage,
    FloatingCallWidget,
    PhoneWidget,
    WhatsappCallWidget,
    MobileSidebarLauncher,
  },
  setup() {
    const upgradePageRef = ref(null);
    const { uiSettings, updateUISettings } = useUISettings();
    const { accountId, currentAccount } = useAccount();
    const { width: windowWidth } = useWindowSize();
    const callsStore = useCallsStore();
    const phoneWidgetStore = usePhoneWidgetStore();
    const whatsappCallsStore = useWhatsappCallsStore();

    return {
      uiSettings,
      updateUISettings,
      accountId,
      currentAccount,
      upgradePageRef,
      windowWidth,
      hasActiveCall: computed(() => callsStore.hasActiveCall),
      hasIncomingCall: computed(() => callsStore.hasIncomingCall),
      // Employees with a browser SIP line see their calls inside the phone
      // widget; standalone call cards are only for everyone else.
      showStandaloneCallCards: computed(() => !phoneWidgetStore.available),
      hasWhatsappCall: computed(
        () =>
          whatsappCallsStore.hasActiveCall || whatsappCallsStore.hasIncomingCall
      ),
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
    showUpgradePage() {
      return this.upgradePageRef?.shouldShowUpgradePage;
    },
    bypassUpgradePage() {
      return [
        'billing_settings_index',
        'settings_inbox_list',
        'general_settings_index',
        'agent_list',
      ].includes(this.$route.name);
    },
        isTrialPlan() {
      return this.currentAccount?.custom_attributes?.plan_type === 'trial';
    },
    isTrialExpired() {
      if (!this.isTrialPlan) return false;
      const expiry =
        this.currentAccount?.custom_attributes?.trial_expires_at ||
        this.currentAccount?.custom_attributes?.trial_ends_at;
      if (!expiry) return false;
      return new Date(expiry).getTime() <= this.currentTime;
    },
    trialTimeText() {
      const expiry =
        this.currentAccount?.custom_attributes?.trial_expires_at ||
        this.currentAccount?.custom_attributes?.trial_ends_at;
      if (!expiry) return '3 дн.';
      const totalSeconds = Math.max(
        0,
        Math.floor((new Date(expiry).getTime() - this.currentTime) / 1000)
      );
      const days = Math.floor(totalSeconds / 86400);
      const hours = Math.floor((totalSeconds % 86400) / 3600);
      const minutes = Math.floor((totalSeconds % 3600) / 60);

      if (days > 0) {
        return `${days} дн. ${hours} ч.`;
      }
      if (hours > 0) {
        return `${hours} ч. ${minutes} мин.`;
      }
      return `${minutes} мин.`;
    },
    previouslyUsedDisplayType() {
      const {
        previously_used_conversation_display_type: conversationDisplayType,
      } = this.uiSettings;
      return conversationDisplayType;
    },
  },
  watch: {
    isSmallScreen: {
      handler() {
        const { LAYOUT_TYPES } = wootConstants;
        if (window.innerWidth <= wootConstants.SMALL_SCREEN_BREAKPOINT) {
          this.updateUISettings({
            conversation_display_type: LAYOUT_TYPES.EXPANDED,
          });
        } else {
          this.updateUISettings({
            conversation_display_type: this.previouslyUsedDisplayType,
          });
        }
      },
      immediate: true,
    },
  },
  mounted() {
    this.trialTimer = setInterval(() => {
      this.currentTime = Date.now();
    }, 30000);
  },
  beforeUnmount() {
    if (this.trialTimer) {
      clearInterval(this.trialTimer);
    }
  },
  methods: {
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
      <UpgradePage
        v-show="showUpgradePage"
        ref="upgradePageRef"
        :bypass-upgrade-page="bypassUpgradePage"
      >
        <MobileSidebarLauncher
          :is-mobile-sidebar-open="isMobileSidebarOpen"
          @toggle="toggleMobileSidebar"
        />
      </UpgradePage>
      <template v-if="!showUpgradePage">
        <div class="flex flex-col flex-1 h-full w-full min-h-0 overflow-hidden">
          <!-- Trial Banner -->
          <div
            v-if="isTrialPlan && !isTrialExpired"
            class="flex items-center justify-between px-4 py-2 bg-amber-50 dark:bg-amber-950/40 border-b border-amber-200 dark:border-amber-900/50 text-amber-900 dark:text-amber-100 text-xs sm:text-sm font-medium z-10 flex-shrink-0"
            data-testid="trial-active-banner"
          >
            <div class="flex items-center gap-2 truncate">
              <span>🎁 Пробный период (Full Free): осталось {{ trialTimeText }} | Доступны все каналы и AI</span>
            </div>
            <router-link
              :to="{ name: 'billing_settings_index', params: { accountId } }"
              class="ml-3 px-3 py-1 bg-amber-600 hover:bg-amber-700 text-white text-xs font-semibold rounded-md shadow-xs transition-colors shrink-0"
            >
              Выбрать тариф
            </router-link>
          </div>
          <div
            v-else-if="isTrialPlan && isTrialExpired"
            class="flex items-center justify-between px-4 py-2 bg-red-50 dark:bg-red-950/40 border-b border-red-200 dark:border-red-900/50 text-red-900 dark:text-red-100 text-xs sm:text-sm font-medium z-10 flex-shrink-0"
            data-testid="trial-expired-banner"
          >
            <div class="flex items-center gap-2 truncate">
              <span>⚠️ Пробный период завершён. Выберите тариф для продолжения работы.</span>
            </div>
            <router-link
              :to="{ name: 'billing_settings_index', params: { accountId } }"
              class="ml-3 px-3 py-1 bg-red-600 hover:bg-red-700 text-white text-xs font-semibold rounded-md shadow-xs transition-colors shrink-0"
            >
              Выбрать тариф
            </router-link>
          </div>
          <router-view />
        </div>
        <CommandBar />
        <MobileSidebarLauncher
          :is-mobile-sidebar-open="isMobileSidebarOpen"
          @toggle="toggleMobileSidebar"
        />
        <FloatingCallWidget v-if="showStandaloneCallCards" />
        <PhoneWidget />
        <WhatsappCallWidget v-if="hasWhatsappCall" />
      </template>
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
