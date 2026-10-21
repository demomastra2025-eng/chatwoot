<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
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
      botToken: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    botToken: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const telegramChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            channel: {
              type: 'telegram',
              bot_token: this.botToken.trim(),
            },
          }
        );

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'agents'),
          params: {
            page: 'new',
            inbox_id: telegramChannel.id,
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.API.ERROR_MESSAGE')
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
        :header-title="$t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.TITLE')"
        :header-content="$t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.DESC')"
      />

      <form
        class="mt-4 flex flex-col gap-5 mx-0"
        @submit.prevent="createChannel()"
      >
        <div class="flex flex-col gap-1.5">
          <label
            class="text-sm font-medium text-n-slate-12"
            :class="{ 'text-n-ruby-11': v$.botToken.$error }"
          >
            {{ $t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.BOT_TOKEN.LABEL') }}
            <div
              class="mt-1.5 flex items-center rounded-xl border bg-n-alpha-black2 overflow-hidden transition-colors"
              :class="
                v$.botToken.$error
                  ? 'border-n-ruby-8 focus-within:border-n-ruby-9'
                  : 'border-n-weak focus-within:border-n-brand'
              "
            >
              <span
                class="inline-flex items-center px-3.5 py-2.5 bg-n-solid-2 border-r border-n-weak text-xs font-mono text-n-slate-11 select-none"
              >
                {{ 'TOKEN' }}
              </span>
              <input
                v-model="botToken"
                type="text"
                class="!mb-0 !border-0 !bg-transparent !shadow-none flex-1 px-3.5 py-2.5 font-mono text-sm text-n-slate-12 focus:outline-none"
                :placeholder="
                  $t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.BOT_TOKEN.PLACEHOLDER')
                "
                @blur="v$.botToken.$touch"
              />
            </div>
          </label>
          <p class="text-xs leading-relaxed text-n-slate-11">
            {{ $t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.BOT_TOKEN.SUBTITLE') }}
          </p>
        </div>

        <div class="flex items-center pt-1">
          <NextButton
            :is-loading="uiFlags.isCreating"
            type="submit"
            solid
            blue
            :label="$t('INBOX_MGMT.ADD.TELEGRAM_CHANNEL.SUBMIT_BUTTON')"
          />
        </div>
      </form>
    </div>
  </div>
</template>
