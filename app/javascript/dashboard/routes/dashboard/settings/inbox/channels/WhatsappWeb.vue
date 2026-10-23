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
      let digits = event.target.value.replace(/\D/g, '').slice(0, 11);
      if (digits.startsWith('87')) {
        digits = `7${digits.slice(1)}`;
      }
      this.phoneNumber = digits;
    },
    async createChannel() {
      if (this.phoneNumber.startsWith('87')) {
        this.phoneNumber = `7${this.phoneNumber.slice(1)}`;
      }
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
          name: getInboxFlowRouteName(this.$route, 'finish'),
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
    <div class="w-full max-w-2xl">
      <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-6 shadow-sm">
        <PageHeader
          :header-title="$t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.TITLE')"
          :header-content="$t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.DESC')"
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
              {{ $t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.LABEL') }}
              <div
                class="mt-1.5 flex items-center rounded-xl border bg-n-alpha-black2 overflow-hidden transition-colors"
                :class="
                  v$.phoneNumber.$error
                    ? 'border-n-ruby-8 focus-within:border-n-ruby-9'
                    : 'border-n-weak focus-within:border-n-brand'
                "
              >
                <span
                  class="pointer-events-none inline-flex items-center px-3.5 py-2.5 bg-n-solid-2 border-r border-n-weak text-sm font-semibold text-n-slate-11 select-none"
                >
                  {{ phonePrefix }}
                </span>
                <input
                  v-model="phoneNumber"
                  type="tel"
                  class="!mb-0 !border-0 !bg-transparent !shadow-none flex-1 px-3.5 py-2.5 text-sm font-medium text-n-slate-12 focus:outline-none"
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
              <span
                v-if="v$.phoneNumber.$error"
                class="mt-1 block text-xs text-n-ruby-11"
              >
                {{
                  $t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.ERROR')
                }}
              </span>
            </label>
            <p class="text-xs leading-relaxed text-n-slate-11">
              {{
                $t('INBOX_MGMT.ADD.WHATSAPP_WEB_CHANNEL.PHONE_NUMBER.SUBTITLE')
              }}
            </p>
          </div>

          <div class="flex items-center pt-1">
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
    </div>
  </div>
</template>
