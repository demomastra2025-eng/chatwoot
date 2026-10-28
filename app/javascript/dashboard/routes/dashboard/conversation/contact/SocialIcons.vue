<script>
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

export default {
  props: {
    socialProfiles: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      socialMediaLinks: [
        { key: 'facebook', icon: 'facebook', link: 'https://facebook.com/' },
        { key: 'twitter', icon: 'twitter', link: 'https://twitter.com/' },
        { key: 'linkedin', icon: 'linkedin', link: 'https://linkedin.com/' },
        { key: 'github', icon: 'github', link: 'https://github.com/' },
        { key: 'instagram', icon: 'instagram', link: 'https://instagram.com/' },
        { key: 'telegram', icon: 'telegram', link: 'https://t.me/' },
        { key: 'tiktok', icon: 'tiktok', link: 'https://tiktok.com/@' },
      ],
    };
  },
  computed: {
    availableProfiles() {
      return this.socialMediaLinks.filter(mediaLink =>
        Boolean(this.cleanValue(mediaLink.key))
      );
    },
  },
  methods: {
    cleanValue(key) {
      return String(this.socialProfiles[key] || '')
        .trim()
        .replace(/^@+/, '');
    },
    formatHandle(key) {
      const clean = this.cleanValue(key);
      return clean ? `@${clean}` : '';
    },
    profileHref(profile) {
      return `${profile.link}${this.cleanValue(profile.key)}`;
    },
    async onCopy(value) {
      if (!value) return;
      await copyTextToClipboard(value);
      useAlert(this.$t('CONTACT_PANEL.COPY_SUCCESSFUL'));
    },
  },
};
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <div
    v-if="availableProfiles.length"
    class="flex flex-col items-start gap-1.5 w-full"
    data-test="social-profiles"
  >
    <div
      v-for="profile in availableProfiles"
      :key="profile.key"
      class="group/social inline-flex max-w-full items-center gap-2 rounded-md bg-n-alpha-1 px-2 py-1 text-xs text-n-slate-12"
      :data-test="`social-profile-${profile.key}`"
    >
      <a
        :href="profileHref(profile)"
        target="_blank"
        rel="noopener noreferrer nofollow"
        class="inline-flex min-w-0 items-center gap-1.5 text-n-slate-12 hover:underline"
      >
        <fluent-icon
          :icon="`brand-${profile.key}`"
          size="16"
          class="text-n-slate-11 shrink-0"
        />
        <span class="truncate">{{ formatHandle(profile.key) }}</span>
      </a>
      <button
        type="button"
        class="inline-flex size-4 shrink-0 items-center justify-center rounded text-n-slate-10 opacity-0 transition-opacity hover:text-n-slate-12 focus:opacity-100 group-hover/social:opacity-100"
        :aria-label="$t('CONTACT_PANEL.COPY_SUCCESSFUL')"
        :data-test="`social-profile-copy-${profile.key}`"
        @click.stop.prevent="onCopy(formatHandle(profile.key))"
      >
        <fluent-icon icon="clipboard" size="12" />
      </button>
    </div>
  </div>
</template>
