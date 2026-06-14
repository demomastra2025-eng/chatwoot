<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import validations, { getLabelTitleErrorMessage } from './validations';
import { getRandomColor } from 'dashboard/helper/labelColor';
import { useVuelidate } from '@vuelidate/core';

import EmojiInput from 'shared/components/emoji/EmojiInput.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    EmojiInput,
    NextButton,
  },
  props: {
    prefillTitle: {
      type: String,
      default: '',
    },
  },
  emits: ['close'],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      color: '#000',
      description: '',
      title: '',
      markerType: 'color',
      emoji: '',
      showEmojiPicker: false,
      showOnSidebar: true,
    };
  },
  validations,
  computed: {
    ...mapGetters({
      uiFlags: 'labels/getUIFlags',
    }),
    labelTitleErrorMessage() {
      const errorMessage = getLabelTitleErrorMessage(this.v$);
      return this.$t(errorMessage);
    },
    markerEmojiInvalid() {
      return this.markerType === 'emoji' && !this.emoji;
    },
  },
  mounted() {
    this.color = getRandomColor();
    this.title = this.prefillTitle;
  },
  methods: {
    onClose() {
      this.$emit('close');
    },
    selectMarkerType(type) {
      this.markerType = type;
      this.showEmojiPicker = false;
    },
    selectEmoji(emoji) {
      this.emoji = emoji;
      this.showEmojiPicker = false;
    },
    async addLabel() {
      try {
        await this.$store.dispatch('labels/create', {
          color: this.color,
          description: this.description,
          display_title: this.title.trim(),
          marker_type: this.markerType,
          emoji: this.markerType === 'emoji' ? this.emoji : null,
          show_on_sidebar: this.showOnSidebar,
        });
        useAlert(this.$t('LABEL_MGMT.ADD.API.SUCCESS_MESSAGE'));
        this.onClose();
      } catch (error) {
        const errorMessage =
          error.message || this.$t('LABEL_MGMT.ADD.API.ERROR_MESSAGE');
        useAlert(errorMessage);
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <woot-modal-header
      :header-title="$t('LABEL_MGMT.ADD.TITLE')"
      :header-content="$t('LABEL_MGMT.ADD.DESC')"
    />
    <form class="flex flex-wrap mx-0" @submit.prevent="addLabel">
      <woot-input
        v-model="title"
        :class="{ error: v$.title.$error }"
        class="w-full"
        :label="$t('LABEL_MGMT.FORM.NAME.LABEL')"
        :placeholder="$t('LABEL_MGMT.FORM.NAME.PLACEHOLDER')"
        :error="labelTitleErrorMessage"
        data-testid="label-title"
        @input="v$.title.$touch"
        @blur="v$.title.$touch"
      />

      <woot-input
        v-model="description"
        :class="{ error: v$.description.$error }"
        class="w-full"
        :label="$t('LABEL_MGMT.FORM.DESCRIPTION.LABEL')"
        :placeholder="$t('LABEL_MGMT.FORM.DESCRIPTION.PLACEHOLDER')"
        data-testid="label-description"
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

      <div v-else class="relative w-full mb-4">
        <label class="block mb-2 text-sm font-medium text-n-slate-12">
          {{ $t('LABEL_MGMT.FORM.EMOJI.LABEL') }}
        </label>
        <button
          type="button"
          class="flex h-10 min-w-24 items-center justify-center rounded-lg border border-n-strong px-3 text-xl text-n-slate-12 hover:bg-n-alpha-2"
          @click.prevent="showEmojiPicker = !showEmojiPicker"
        >
          {{ emoji || $t('LABEL_MGMT.FORM.EMOJI.PLACEHOLDER') }}
        </button>
        <EmojiInput
          v-if="showEmojiPicker"
          :on-click="selectEmoji"
          show-remove-button
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
          data-testid="label-submit"
          :label="$t('LABEL_MGMT.FORM.CREATE')"
          :disabled="
            v$.title.$invalid || markerEmojiInvalid || uiFlags.isCreating
          "
          :is-loading="uiFlags.isCreating"
        />
      </div>
    </form>
  </div>
</template>
