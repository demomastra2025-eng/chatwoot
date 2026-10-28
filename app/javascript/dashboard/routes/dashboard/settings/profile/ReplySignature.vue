<script setup>
import { ref, watch } from 'vue';

const props = defineProps({
  modelValue: { type: String, default: '' },
});
const emit = defineEmits(['save']);
const signature = ref(props.modelValue);

watch(
  () => props.modelValue,
  value => {
    signature.value = value;
  }
);
</script>

<template>
  <form
    class="flex flex-col gap-3"
    @submit.prevent="emit('save', signature.trim())"
  >
    <input
      v-model="signature"
      type="text"
      maxlength="200"
      class="w-full rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2"
      :aria-label="$t('PROFILE_SETTINGS.FORM.REPLY_SIGNATURE.TITLE')"
      :placeholder="$t('PROFILE_SETTINGS.FORM.REPLY_SIGNATURE.PLACEHOLDER')"
    />
    <button type="submit" class="button button--primary self-start">
      {{ $t('PROFILE_SETTINGS.FORM.REPLY_SIGNATURE.SAVE') }}
    </button>
  </form>
</template>
