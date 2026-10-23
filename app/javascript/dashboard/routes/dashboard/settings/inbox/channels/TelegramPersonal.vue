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
    normalizePhoneNumber(rawValue = '') {
      const cleaned = String(rawValue).replace(/[\s()-]/g, '');
      if (!cleaned) return '';
      if (/^87\d{9}$/.test(cleaned)) {
        return `+7${cleaned.slice(1)}`;
      }
      if (/^\d{6,15}$/.test(cleaned)) {
        return `+${cleaned}`;
      }
      return cleaned;
    },
    onPhoneNumberBlur() {
      this.phoneNumber = this.normalizePhoneNumber(this.phoneNumber);
      this.v$.phoneNumber.$touch();
    },
    async createChannel() {
      this.phoneNumber = this.normalizePhoneNumber(this.phoneNumber);
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
          name: getInboxFlowRouteName(this.$route, 'finish'),
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
  <div class="w-full max-w-2xl">
    <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-6 shadow-sm">
      <PageHeader
        :header-title="$t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.TITLE')"
        :header-content="$t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.DESC')"
      />

      <form
        class="mt-4 flex flex-col gap-5 mx-0"
        @submit.prevent="createChannel()"
      >
        <div class="flex flex-col gap-1.5">
          <label
            class="text-sm font-medium text-n-slate-12"
            :class="{ 'text-n-ruby-11': v$.phoneNumber.$error }"
          >
            {{
              $t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.PHONE_NUMBER.LABEL')
            }}
            <div
              class="mt-1.5 flex items-center rounded-xl border bg-n-alpha-black2 overflow-hidden transition-colors"
              :class="
                v$.phoneNumber.$error
                  ? 'border-n-ruby-8 focus-within:border-n-ruby-9'
                  : 'border-n-weak focus-within:border-n-brand'
              "
            >
              <span
                class="inline-flex items-center px-3.5 py-2.5 bg-n-solid-2 border-r border-n-weak text-xs font-medium text-n-slate-11 select-none"
              >
                {{ 'E.164' }}
              </span>
              <input
                v-model="phoneNumber"
                type="tel"
                autocomplete="tel"
                class="!mb-0 !border-0 !bg-transparent !shadow-none flex-1 px-3.5 py-2.5 text-sm font-medium text-n-slate-12 focus:outline-none"
                :placeholder="
                  $t(
                    'INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.PHONE_NUMBER.PLACEHOLDER'
                  )
                "
                @blur="onPhoneNumberBlur"
              />
            </div>
          </label>
          <p class="text-xs leading-relaxed text-n-slate-11">
            {{
              $t(
                'INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.PHONE_NUMBER.SUBTITLE'
              )
            }}
          </p>
        </div>

        <div class="flex items-center pt-1">
          <NextButton
            :is-loading="uiFlags.isCreating"
            type="submit"
            solid
            blue
            :label="
              $t('INBOX_MGMT.ADD.TELEGRAM_PERSONAL_CHANNEL.SUBMIT_BUTTON')
            "
          />
        </div>
      </form>
    </div>
  </div>
</template>
