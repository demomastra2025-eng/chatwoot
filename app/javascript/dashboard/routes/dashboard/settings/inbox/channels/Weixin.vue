<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';

export default {
  components: {
    PageHeader,
    NextButton,
  },
  data() {
    return {
      displayName: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  methods: {
    normalizedChannelPayload() {
      const displayName = this.displayName.trim();
      const payload = { type: 'weixin' };

      if (displayName) {
        payload.display_name = displayName;
      }

      return payload;
    },
    async requestInitialQr(inboxId) {
      try {
        await this.$store.dispatch('inboxes/requestWeixinQr', inboxId);
      } catch (error) {
        useAlert(
          error.message || this.$t('INBOX_MGMT.FINISH.WEIXIN.REQUEST_QR_ERROR')
        );
      }
    },
    async createChannel() {
      try {
        const channel = await this.$store.dispatch('inboxes/createChannel', {
          channel: this.normalizedChannelPayload(),
        });

        await this.requestInitialQr(channel.id);

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'finish'),
          params: {
            inbox_id: channel.id,
          },
          query: {
            channel_type: 'weixin',
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.API.ERROR_MESSAGE')
        );
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label>
          {{ $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.LABEL') }}
          <input
            v-model="displayName"
            type="text"
            autocomplete="off"
            :placeholder="
              $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.PLACEHOLDER')
            "
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.SUBTITLE') }}
        </p>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
