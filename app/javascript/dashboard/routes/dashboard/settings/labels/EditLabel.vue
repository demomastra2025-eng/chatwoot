<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import validations, { getLabelTitleErrorMessage } from './validations';
import { useVuelidate } from '@vuelidate/core';
import { labelDisplayTitle } from 'dashboard/helper/labels';

import EmojiInput from 'shared/components/emoji/EmojiInput.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    EmojiInput,
    NextButton,
  },
  props: {
    selectedResponse: {
      type: Object,
      default: () => ({}),
    },
  },
  emits: ['close'],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      title: '',
      description: '',
      showOnSidebar: true,
      color: '',
      markerType: 'color',
      emoji: '',
    };
  },
  validations,
  computed: {
    ...mapGetters({
      uiFlags: 'labels/getUIFlags',
    }),
    pageTitle() {
      return `${this.$t('LABEL_MGMT.EDIT.TITLE')} - ${labelDisplayTitle(
        this.selectedResponse
      )}`;
    },
    labelTitleErrorMessage() {
      const errorMessage = getLabelTitleErrorMessage(this.v$);
      return this.$t(errorMessage);
    },
    markerEmojiInvalid() {
      return this.markerType === 'emoji' && !this.emoji;
    },
  },
  mounted() {
    this.setFormValues();
  },
  methods: {
    onClose() {
      this.$emit('close');
    },
    selectMarkerType(type) {
      this.markerType = type;
    },
    selectEmoji(emoji) {
      this.emoji = emoji;
    },
    setFormValues() {
      this.title = labelDisplayTitle(this.selectedResponse);
      this.description = this.selectedResponse.description;
      this.showOnSidebar = true;
      this.color = this.selectedResponse.color;
      this.markerType = this.selectedResponse.marker_type || 'color';
      this.emoji = this.selectedResponse.emoji || '';
    },
    editLabel() {
      this.$store
        .dispatch('labels/update', {
          id: this.selectedResponse.id,
          color: this.color,
          description: this.description,
          display_title: this.title.trim(),
          marker_type: this.markerType,
          emoji: this.markerType === 'emoji' ? this.emoji : null,
          show_on_sidebar: this.showOnSidebar,
        })
        .then(() => {
          useAlert(this.$t('LABEL_MGMT.EDIT.API.SUCCESS_MESSAGE'));
          setTimeout(() => this.onClose(), 10);
        })
        .catch(() => {
          useAlert(this.$t('LABEL_MGMT.EDIT.API.ERROR_MESSAGE'));
        });
    },
  },
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <woot-modal-header :header-title="pageTitle" />
    <form class="flex flex-wrap mx-0" @submit.prevent="editLabel">
      <woot-input
        v-model="title"
        :class="{ error: v$.title.$error }"
        class="w-full"
        :label="$t('LABEL_MGMT.FORM.NAME.LABEL')"
        :placeholder="$t('LABEL_MGMT.FORM.NAME.PLACEHOLDER')"
        :error="labelTitleErrorMessage"
        @input="v$.title.$touch"
        @blur="v$.title.$touch"
      />
      <woot-input
        v-model="description"
        :class="{ error: v$.description.$error }"
        class="w-full"
        :label="$t('LABEL_MGMT.FORM.DESCRIPTION.LABEL')"
        :placeholder="$t('LABEL_MGMT.FORM.DESCRIPTION.PLACEHOLDER')"
        @input="v$.description.$touch"
        @blur="v$.description.$touch"
      />

      <div class="w-full mb-4">
        <span class="block mb-2 text-sm font-medium text-n-slate-12">
          {{ $t('LABEL_MGMT.FORM.MARKER.LABEL') }}
        </span>
        <div class="flex gap-2">
          <NextButton
            type="button"
            sm
            faded
            :slate="markerType !== 'color'"
            :blue="markerType === 'color'"
            :label="$t('LABEL_MGMT.FORM.MARKER.COLOR')"
            @click.prevent="selectMarkerType('color')"
          />
          <NextButton
            type="button"
            sm
            faded
            :slate="markerType !== 'emoji'"
            :blue="markerType === 'emoji'"
            :label="$t('LABEL_MGMT.FORM.MARKER.EMOJI')"
            @click.prevent="selectMarkerType('emoji')"
          />
        </div>
      </div>

      <div v-if="markerType === 'color'" class="w-full">
        <label>
          {{ $t('LABEL_MGMT.FORM.COLOR.LABEL') }}
          <woot-color-picker v-model="color" />
        </label>
      </div>

      <div v-else class="w-full mb-4">
        <div class="mb-2 flex items-center justify-between gap-2">
          <label class="block text-sm font-medium text-n-slate-12">
            {{ $t('LABEL_MGMT.FORM.EMOJI.LABEL') }}
          </label>
          <div
            class="inline-flex h-9 min-w-9 items-center justify-center rounded-full border border-n-weak bg-n-alpha-1 px-2.5 text-xl leading-none text-n-slate-12"
            aria-live="polite"
          >
            <span v-if="emoji">{{ emoji }}</span>
            <span v-else class="i-lucide-smile size-4 text-n-slate-10" />
          </div>
        </div>
        <EmojiInput
          inline
          :on-click="selectEmoji"
          :show-remove-button="!!emoji"
        />
      </div>

      <div class="flex items-center justify-end w-full gap-2 px-0 py-2">
        <NextButton
          faded
          slate
          type="reset"
          :label="$t('LABEL_MGMT.FORM.CANCEL')"
          @click.prevent="onClose"
        />
        <NextButton
          type="submit"
          :label="$t('LABEL_MGMT.FORM.EDIT')"
          :disabled="
            v$.title.$invalid || markerEmojiInvalid || uiFlags.isUpdating
          "
          :is-loading="uiFlags.isUpdating"
        />
      </div>
    </form>
  </div>
</template>
