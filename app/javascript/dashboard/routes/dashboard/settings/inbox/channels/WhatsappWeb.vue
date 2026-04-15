<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';

const shouldBeKazakhstanPhoneNumber = (value = '') => /^7\d{10}$/.test(value);

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
      phonePrefix: '+',
      phoneNumber: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    phoneNumber: { required, shouldBeKazakhstanPhoneNumber },
  },
  methods: {
    normalizedPhoneNumber() {
      const digits = this.phoneNumber.replace(/\D/g, '');
      return digits ? `+${digits}` : '';
    },
    onPhoneNumberInput(event) {
      this.phoneNumber = event.target.value.replace(/\D/g, '').slice(0, 11);
    },
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const channel = await this.$store.dispatch('inboxes/createChannel', {
          channel: {
            type: 'whatsapp_web',
            phone_number: this.normalizedPhoneNumber(),
            history_lookback_days: 0,
          },
        });

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'agents'),
          params: {
            inbox_id: channel.id,
          },
          query: {
            channel_type: 'whatsapp_web',
          },
        });
      } catch (error) {
        useAlert(
          this.$t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.API.ERROR_MESSAGE')
        );
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.phoneNumber.$error }">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.LABEL') }}
          <div class="flex items-center gap-1">
            <span
              class="pointer-events-none inline-flex items-center mb-4 text-[1.35rem] font-light leading-none text-n-slate-11"
            >
              {{ phonePrefix }}
            </span>
            <input
              v-model="phoneNumber"
              type="tel"
              :placeholder="
                $t(
                  'INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.PLACEHOLDER'
                )
              "
              inputmode="numeric"
              autocomplete="tel"
              maxlength="11"
              @input="onPhoneNumberInput"
              @blur="v$.phoneNumber.$touch"
            />
          </div>
          <span v-if="v$.phoneNumber.$error" class="message">{{
            $t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.ERROR')
          }}</span>
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.SUBTITLE') }}
        </p>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
