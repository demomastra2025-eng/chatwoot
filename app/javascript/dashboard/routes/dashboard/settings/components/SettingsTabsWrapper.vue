<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  keepAlive: {
    type: Boolean,
    default: true,
  },
  showTabs: {
    type: Boolean,
    default: true,
  },
  showBackButton: {
    type: Boolean,
    default: true,
  },
  fullWidth: {
    type: Boolean,
    default: false,
  },
  tabs: {
    type: Array,
    required: true,
  },
});

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const settingsBackRoutes = {
  crm_settings_index: 'crm_deals_index',
  crm_task_settings_index: 'crm_tasks_index',
};

const canShowTab = tab => {
  if (tab.visible === false) {
    return false;
  }

  if (!tab.featureFlag) {
    return true;
  }

  return isFeatureEnabledonAccount.value(accountId.value, tab.featureFlag);
};

const visibleTabs = computed(() => props.tabs.filter(canShowTab));

const translatedTabs = computed(() =>
  visibleTabs.value.map(tab => ({
    ...tab,
    // Tabs are configured by route modules and intentionally use i18n keys.
    // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
    label: t(tab.labelKey),
  }))
);

const activeTabIndex = computed(() => {
  const routeName = route.name;
  const index = visibleTabs.value.findIndex(tab => {
    const activeOn = tab.activeOn || [tab.routeName];
    return activeOn.includes(routeName);
  });

  return index >= 0 ? index : 0;
});

const settingsBackRouteName = computed(() => settingsBackRoutes[route.name]);

const settingsBackRoute = computed(() => {
  if (!settingsBackRouteName.value) {
    return null;
  }

  return {
    name: settingsBackRouteName.value,
    params: {
      accountId: route.params.accountId,
    },
  };
});

const switchTab = tab => {
  if (!tab?.routeName || tab.routeName === route.name) {
    return;
  }

  router.push({
    name: tab.routeName,
    params: {
      accountId: route.params.accountId,
    },
  });
};

const onBack = () => {
  if (window.history.length > 2) {
    router.go(-1);
    return;
  }

  router.push(settingsBackRoute.value);
};
</script>

<template>
  <div
    class="flex flex-col w-full h-full m-0 overflow-auto bg-n-surface-1"
    :class="fullWidth ? 'p-0' : 'pb-8 pt-4 px-6'"
  >
    <div
      class="flex flex-col w-full mx-auto gap-6"
      :class="fullWidth ? 'max-w-none' : 'max-w-5xl'"
    >
      <NextButton
        v-if="showBackButton && settingsBackRoute"
        :label="t('GENERAL_SETTINGS.BACK')"
        icon="i-lucide-chevron-left"
        faded
        primary
        sm
        class="w-fit"
        @click="onBack"
      />

      <TabBar
        v-if="showTabs && translatedTabs.length > 1"
        :tabs="translatedTabs"
        :initial-active-tab="activeTabIndex"
        class="flex-shrink-0"
        @tab-changed="switchTab"
      />

      <router-view v-slot="{ Component }">
        <keep-alive v-if="keepAlive">
          <component :is="Component" :key="route.fullPath" />
        </keep-alive>
        <component :is="Component" v-else :key="route.fullPath" />
      </router-view>
    </div>
  </div>
</template>
