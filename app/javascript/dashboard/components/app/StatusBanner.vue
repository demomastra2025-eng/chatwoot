<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import MessageFormatter from 'shared/helpers/MessageFormatter';
import { LocalStorage } from 'shared/helpers/localStorage';

const BANNER_COLOR_MAP = {
  info: 'blue',
  warning: 'amber',
  error: 'ruby',
};

const { t } = useI18n();
const globalConfig = useMapGetter('globalConfig/get');

const persistedDismissedBannerIds = LocalStorage.get(
  LOCAL_STORAGE_KEYS.DISMISSED_PLATFORM_BANNERS
);
const dismissedBannerIds = ref(
  Array.isArray(persistedDismissedBannerIds) ? persistedDismissedBannerIds : []
);

const dismissKey = banner => `${banner.id}-${banner.updated_at}`;

const visibleBanners = computed(() => {
  const banners = globalConfig.value?.activePlatformBanners || [];
  return banners.filter(
    banner => !dismissedBannerIds.value.includes(dismissKey(banner))
  );
});

const formattedMessage = message =>
  new MessageFormatter(message).formattedMessage;

const bannerColor = bannerType => BANNER_COLOR_MAP[bannerType] || 'slate';

const dismissBanner = banner => {
  const key = dismissKey(banner);
  if (dismissedBannerIds.value.includes(key)) return;

  dismissedBannerIds.value.push(key);
  LocalStorage.set(
    LOCAL_STORAGE_KEYS.DISMISSED_PLATFORM_BANNERS,
    dismissedBannerIds.value
  );
};
</script>

<template>
  <Banner
    v-for="banner in visibleBanners"
    :key="banner.id"
    :color="bannerColor(banner.banner_type)"
    :action-label="t('GENERAL_SETTINGS.DISMISS')"
    class="!rounded-none !justify-center [&_.link]:underline [&_p]:m-0"
    @action="dismissBanner(banner)"
  >
    <span
      v-dompurify-html="formattedMessage(banner.banner_message)"
      class="text-xs"
    />
  </Banner>
</template>
