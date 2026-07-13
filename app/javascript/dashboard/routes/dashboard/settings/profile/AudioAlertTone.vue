<script setup>
import { computed, onUnmounted } from 'vue';
import Icon from 'next/icon/Icon.vue';
import * as Sentry from '@sentry/vue';
import FormSelect from 'v3/components/Form/Select.vue';

const props = defineProps({
  value: {
    type: String,
    required: true,
  },
  label: {
    type: String,
    default: '',
  },
  tones: {
    type: Array,
    default: () => [
      { value: 'ding', label: 'Ding' },
      { value: 'bell', label: 'Bell' },
      { value: 'chime', label: 'Chime' },
      { value: 'magic', label: 'Magic' },
      { value: 'ping', label: 'Ping' },
    ],
  },
  name: {
    type: String,
    default: 'alertTone',
  },
  audioPath: {
    type: String,
    default: '/audio/dashboard',
  },
});

const emit = defineEmits(['change']);

const alertTones = computed(() => props.tones);

const isAllowedTone = value => props.tones.some(tone => tone.value === value);

const selectedValue = computed({
  get: () =>
    isAllowedTone(props.value) ? props.value : props.tones[0]?.value || '',
  set: value => {
    if (isAllowedTone(value)) emit('change', value);
  },
});

const audio = new Audio();

const playAudio = async () => {
  try {
    audio.pause();
    audio.currentTime = 0;
    const filename = selectedValue.value.endsWith('.mp3')
      ? selectedValue.value
      : `${selectedValue.value}.mp3`;
    audio.src = `${props.audioPath}/${filename}`;
    await audio.play();
  } catch (error) {
    Sentry.captureException(error);
  }
};

onUnmounted(() => {
  audio.pause();
  audio.currentTime = 0;
});
</script>

<template>
  <div class="flex items-center gap-2">
    <FormSelect
      v-model="selectedValue"
      :name="name"
      spacing="compact"
      class="flex-grow"
      :value="selectedValue"
      :options="alertTones"
      :label="label"
    >
      <option
        v-for="tone in alertTones"
        :key="tone.label"
        :value="tone.value"
        :selected="tone.value === selectedValue"
      >
        {{ tone.label }}
      </option>
    </FormSelect>
    <button
      v-tooltip.top="
        $t('PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.PLAY')
      "
      class="border-0 shadow-sm outline-none flex justify-center items-center size-10 appearance-none rounded-xl ring-n-weak ring-1 ring-inset focus:ring-2 focus:ring-inset focus:ring-n-brand flex-shrink-0 mt-[1.75rem]"
      @click="playAudio"
    >
      <Icon icon="i-lucide-volume-2" />
    </button>
  </div>
</template>
