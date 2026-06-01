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
      profileUrn: '',
      displayName: '',
      liAt: '',
      jsessionid: '',
      csrfToken: '',
      xLiTrack: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    profileUrn: { required },
    liAt: { required },
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
            type: 'linkedin_personal',
            profile_urn: this.profileUrn.trim(),
            display_name: this.displayName.trim(),
            li_at: this.liAt.trim(),
            jsessionid: this.jsessionid.trim(),
            csrf_token: this.csrfToken.trim(),
            x_li_track: this.xLiTrack.trim(),
          },
        });
        try {
          await this.$store.dispatch(
            'inboxes/reconnectLinkedinPersonal',
            channel.id
          );
        } catch (error) {
          useAlert(
            error.message ||
              this.$t(
                'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.API.RECONNECT_WARNING'
              )
          );
        }

        router.replace({
          name: getInboxFlowRouteName(this.$route, 'agents'),
          params: {
            inbox_id: channel.id,
          },
          query: {
            channel_type: 'linkedin_personal',
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t(
              'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.API.ERROR_MESSAGE'
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
      :header-title="$t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.profileUrn.$error }">
          {{ $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.PROFILE_URN.LABEL') }}
          <input
            v-model="profileUrn"
            type="text"
            autocomplete="off"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.PROFILE_URN.PLACEHOLDER'
              )
            "
            @blur="v$.profileUrn.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label>
          {{
            $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.DISPLAY_NAME.LABEL')
          }}
          <input
            v-model="displayName"
            type="text"
            autocomplete="off"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.DISPLAY_NAME.PLACEHOLDER'
              )
            "
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.liAt.$error }">
          {{ $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.LI_AT.LABEL') }}
          <input
            v-model="liAt"
            type="password"
            autocomplete="off"
            :placeholder="
              $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.LI_AT.PLACEHOLDER')
            "
            @blur="v$.liAt.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label>
          {{ $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.JSESSIONID.LABEL') }}
          <input
            v-model="jsessionid"
            type="password"
            autocomplete="off"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.JSESSIONID.PLACEHOLDER'
              )
            "
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label>
          {{ $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.CSRF_TOKEN.LABEL') }}
          <input
            v-model="csrfToken"
            type="password"
            autocomplete="off"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.CSRF_TOKEN.PLACEHOLDER'
              )
            "
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label>
          {{ $t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.X_LI_TRACK.LABEL') }}
          <textarea
            v-model="xLiTrack"
            rows="3"
            autocomplete="off"
            :placeholder="
              $t(
                'INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.X_LI_TRACK.PLACEHOLDER'
              )
            "
          />
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.LINKEDIN_PERSONAL_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
