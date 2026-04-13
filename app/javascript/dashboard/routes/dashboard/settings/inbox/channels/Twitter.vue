<script>
import { useAlert } from 'dashboard/composables';
import twitterClient from '../../../../../api/channel/twitterClient';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    NextButton,
  },
  data() {
    return { isRequestingAuthorization: false };
  },
  computed: {
    isTwitterConfigured() {
      return !!window.chatwootConfig?.twitterConfigured;
    },
    helpText() {
      if (this.isTwitterConfigured) {
        return this.$t('INBOX_MGMT.ADD.TWITTER.HELP');
      }

      return this.$t('INBOX_MGMT.ADD.TWITTER.NOT_CONFIGURED');
    },
  },
  methods: {
    async requestAuthorization() {
      if (!this.isTwitterConfigured) {
        return;
      }

      try {
        this.isRequestingAuthorization = true;
        const response = await twitterClient.generateAuthorization();
        const {
          data: { url },
        } = response;
        window.location.href = url;
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.ADD.TWITTER.ERROR_MESSAGE'));
      } finally {
        this.isRequestingAuthorization = false;
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <div class="login-init h-full text-center">
      <form @submit.prevent="requestAuthorization">
        <NextButton
          type="submit"
          icon="i-ri-twitter-x-fill"
          label="Sign in with Twitter"
          :disabled="!isTwitterConfigured"
          :is-loading="isRequestingAuthorization"
        />
      </form>
      <p>{{ helpText }}</p>
    </div>
  </div>
</template>

<style scoped lang="scss">
.login-init {
  @apply pt-[30%] text-center;
  p {
    @apply p-6;
  }
  > a > img {
    @apply w-60;
  }
}
</style>
