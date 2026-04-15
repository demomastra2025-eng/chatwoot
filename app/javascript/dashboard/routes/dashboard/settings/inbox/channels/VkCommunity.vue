<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { numeric, required } from '@vuelidate/validators';
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
      groupId: '',
      accessToken: '',
      secret: '',
      confirmationToken: '',
      apiVersion: '5.199',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    groupId: { required, numeric },
    accessToken: { required },
    secret: { required },
    confirmationToken: { required },
    apiVersion: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const channel = await this.$store.dispatch('inboxes/createChannel', {
          channel: {
            type: 'vk_community',
            group_id: Number(this.groupId),
            access_token: this.accessToken.trim(),
            secret: this.secret.trim(),
            confirmation_token: this.confirmationToken.trim(),
            api_version: this.apiVersion.trim(),
          },
        });

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'agents'),
          params: {
            inbox_id: channel.id,
          },
          query: {
            channel_type: 'vk_community',
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.API.ERROR_MESSAGE')
        );
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.groupId.$error }">
          {{ $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.GROUP_ID.LABEL') }}
          <input
            v-model="groupId"
            type="text"
            inputmode="numeric"
            :placeholder="
              $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.GROUP_ID.PLACEHOLDER')
            "
            @blur="v$.groupId.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.accessToken.$error }">
          {{ $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.ACCESS_TOKEN.LABEL') }}
          <input
            v-model="accessToken"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.ACCESS_TOKEN.PLACEHOLDER')
            "
            @blur="v$.accessToken.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.secret.$error }">
          {{ $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.SECRET.LABEL') }}
          <input
            v-model="secret"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.SECRET.PLACEHOLDER')
            "
            @blur="v$.secret.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.confirmationToken.$error }">
          {{
            $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.CONFIRMATION_TOKEN.LABEL')
          }}
          <input
            v-model="confirmationToken"
            type="text"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.CONFIRMATION_TOKEN.PLACEHOLDER'
              )
            "
            @blur="v$.confirmationToken.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.apiVersion.$error }">
          {{ $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.API_VERSION.LABEL') }}
          <input
            v-model="apiVersion"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.API_VERSION.PLACEHOLDER')
            "
            @blur="v$.apiVersion.$touch"
          />
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.VK_COMMUNITY_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
