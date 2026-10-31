<script>
import Banner from 'dashboard/components/ui/Banner.vue';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import { LocalStorage } from 'shared/helpers/localStorage';
import { mapGetters } from 'vuex';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { hasAnUpdateAvailable } from './versionCheckHelper';

export default {
  components: { Banner },
  props: {
    latestOnelinkVersion: { type: String, default: '' },
    latestChatwootVersion: { type: String, default: '' },
  },
  setup() {
    const { isAdmin } = useAdmin();
    return {
      isAdmin,
    };
  },
  data() {
    return { userDismissedBanner: false };
  },
  computed: {
    ...mapGetters({ globalConfig: 'globalConfig/get' }),
    latestVersion() {
      return this.latestOnelinkVersion || this.latestChatwootVersion;
    },
    updateAvailable() {
      return hasAnUpdateAvailable(
        this.latestVersion,
        this.globalConfig.appVersion
      );
    },
    bannerMessage() {
      return this.$t('GENERAL_SETTINGS.UPDATE_CHATWOOT', {
        latestOneLinkVersion: this.latestVersion,
      });
    },
    shouldShowBanner() {
      return (
        !this.userDismissedBanner &&
        this.globalConfig.displayManifest &&
        this.updateAvailable &&
        !this.isVersionNotificationDismissed(this.latestVersion) &&
        this.isAdmin
      );
    },
  },
  methods: {
    isVersionNotificationDismissed(version) {
      const dismissedVersions =
        LocalStorage.get(LOCAL_STORAGE_KEYS.DISMISSED_UPDATES) || [];
      return dismissedVersions.includes(version);
    },
    dismissUpdateBanner() {
      let updatedDismissedItems =
        LocalStorage.get(LOCAL_STORAGE_KEYS.DISMISSED_UPDATES) || [];
      if (updatedDismissedItems instanceof Array) {
        updatedDismissedItems.push(this.latestVersion);
      } else {
        updatedDismissedItems = [this.latestVersion];
      }
      LocalStorage.set(
        LOCAL_STORAGE_KEYS.DISMISSED_UPDATES,
        updatedDismissedItems
      );
      this.userDismissedBanner = true;
    },
  },
};
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <Banner
    v-if="shouldShowBanner"
    color-scheme="primary"
    :banner-message="bannerMessage"
    href-link="https://t.me/onelink_ai"
    :href-link-text="$t('GENERAL_SETTINGS.LEARN_MORE')"
    has-close-button
    @close="dismissUpdateBanner"
  />
</template>
