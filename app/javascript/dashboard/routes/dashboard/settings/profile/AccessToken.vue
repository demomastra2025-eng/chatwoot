<script setup>
import { ref, computed } from 'vue';
import Input from 'dashboard/components-next/input/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ConfirmButton from 'dashboard/components-next/button/ConfirmButton.vue';

const props = defineProps({
  value: { type: String, default: '' },
  showResetButton: { type: Boolean, default: true },
});

const emit = defineEmits(['onCopy', 'onReset']);

const inputType = ref('password');

const toggleMasked = () => {
  inputType.value = inputType.value === 'password' ? 'text' : 'password';
};

const maskIcon = computed(() => {
  return inputType.value === 'password' ? 'i-lucide-eye' : 'i-lucide-eye-off';
});

const onClick = () => {
  emit('onCopy', props.value);
};

const onReset = () => {
  emit('onReset');
};
</script>

<template>
  <div class="flex flex-col gap-4 sm:flex-row sm:justify-between">
    <Input
      id="access-token"
      name="access_token"
      class="flex-1"
      :aria-label="$t('PROFILE_SETTINGS.FORM.ACCESS_TOKEN.TITLE')"
      :type="inputType"
      :model-value="value"
      readonly
    >
      <template #suffix>
        <NextButton
          class="absolute top-1/2 -translate-y-1/2 ltr:right-1 rtl:left-1"
          type="button"
          variant="ghost"
          color="slate"
          size="sm"
          :icon="maskIcon"
          :aria-label="
            $t(
              `PROFILE_SETTINGS.FORM.ACCESS_TOKEN.${inputType === 'password' ? 'SHOW' : 'HIDE'}`
            )
          "
          :aria-pressed="inputType === 'text'"
          @click="toggleMasked"
        />
      </template>
    </Input>
    <div class="flex flex-row gap-2">
      <NextButton
        :label="$t('PROFILE_SETTINGS.FORM.ACCESS_TOKEN.COPY')"
        slate
        outline
        type="button"
        icon="i-lucide-copy"
        @click="onClick"
      />
      <ConfirmButton
        v-if="showResetButton"
        :label="$t('PROFILE_SETTINGS.FORM.ACCESS_TOKEN.RESET')"
        :confirm-label="$t('PROFILE_SETTINGS.FORM.ACCESS_TOKEN.CONFIRM_RESET')"
        :confirm-hint="$t('PROFILE_SETTINGS.FORM.ACCESS_TOKEN.CONFIRM_HINT')"
        color="slate"
        confirm-color="ruby"
        variant="outline"
        icon="i-lucide-key-round"
        @click="onReset"
      />
    </div>
  </div>
</template>
