<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
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
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      ilinkToken: '',
      providerAccountId: '',
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
      return {
        type: 'weixin',
        ilink_token: this.ilinkToken.trim() || undefined,
        provider_account_id: this.providerAccountId.trim() || undefined,
        display_name: this.displayName.trim() || undefined,
      };
    },
    async createChannel() {
      try {
        const channel = await this.$store.dispatch('inboxes/createChannel', {
          channel: this.normalizedChannelPayload(),
        });

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'agents'),
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
          {{ $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.ILINK_TOKEN.LABEL') }}
          <input
            v-model="ilinkToken"
            type="password"
            autocomplete="off"
            :placeholder="
              $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.ILINK_TOKEN.PLACEHOLDER')
            "
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.ILINK_TOKEN.SUBTITLE') }}
        </p>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label>
          {{ $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.PROVIDER_ACCOUNT_ID.LABEL') }}
          <input
            v-model="providerAccountId"
            type="text"
            autocomplete="off"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.WEIXIN_CHANNEL.PROVIDER_ACCOUNT_ID.PLACEHOLDER'
              )
            "
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WEIXIN_CHANNEL.PROVIDER_ACCOUNT_ID.SUBTITLE') }}
        </p>
      </div>

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
