<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { helpers, required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';

const e164PhoneNumber = helpers.regex(/^\+\d{6,15}$/);

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
      phoneNumber: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    phoneNumber: { required, e164PhoneNumber },
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
            type: 'telegram_personal',
            phone_number: this.phoneNumber.trim(),
          },
        });

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'agents'),
          params: {
            inbox_id: channel.id,
          },
          query: {
            channel_type: 'telegram_personal',
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t(
              'INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.API.ERROR_MESSAGE'
            )
        );
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.phoneNumber.$error }">
          {{
            $t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.PHONE_NUMBER.LABEL')
          }}
          <input
            v-model="phoneNumber"
            type="tel"
            autocomplete="tel"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.PHONE_NUMBER.PLACEHOLDER'
              )
            "
            @blur="v$.phoneNumber.$touch"
          />
        </label>
        <p class="help-text">
          {{
            $t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.PHONE_NUMBER.SUBTITLE')
          }}
        </p>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
