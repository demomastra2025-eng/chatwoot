<script setup>
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

defineProps({
  name: {
    type: String,
    default: '',
  },
  src: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['change', 'delete']);
</script>

<template>
  <div class="flex flex-col gap-2">
    <span class="text-sm font-medium text-n-slate-12">
      {{ $t('GENERAL_SETTINGS.FORM.LOGO.LABEL') }}
    </span>
    <Avatar
      :src="src || ''"
      :name="name || ''"
      :size="72"
      allow-upload
      @upload="emit('change', $event)"
      @delete="emit('delete')"
    />
  </div>
</template>
