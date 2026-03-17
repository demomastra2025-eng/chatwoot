<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';

const props = defineProps({
  modelValue: {
    type: Array,
    default: () => [],
  },
  resources: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue']);

const { t } = useI18n();

const isOpen = ref(false);
const query = ref('');

const filteredResources = computed(() => {
  const search = query.value.trim().toLowerCase();
  if (!search) return props.resources;

  return props.resources.filter(resource => {
    return [resource.name, resource.specialty]
      .filter(Boolean)
      .some(field => field.toLowerCase().includes(search));
  });
});

const selectedResources = computed(() => {
  return props.resources.filter(resource =>
    props.modelValue.includes(resource.id)
  );
});

const buttonLabel = computed(() => {
  if (!props.modelValue.length) {
    return t('SCHEDULING.TOOLBAR.ALL_RESOURCES');
  }

  if (props.modelValue.length === 1) {
    return (
      selectedResources.value[0]?.name || t('SCHEDULING.TOOLBAR.RESOURCES')
    );
  }

  return t('SCHEDULING.TOOLBAR.RESOURCES_SELECTED', {
    count: props.modelValue.length,
  });
});

const toggleResource = resourceId => {
  if (props.modelValue.includes(resourceId)) {
    emit(
      'update:modelValue',
      props.modelValue.filter(id => id !== resourceId)
    );
    return;
  }

  emit('update:modelValue', [...props.modelValue, resourceId]);
};

const selectAll = () => {
  emit(
    'update:modelValue',
    props.resources.map(resource => resource.id)
  );
};

const clearSelection = () => {
  emit('update:modelValue', []);
};
</script>

<template>
  <div class="relative">
    <OnClickOutside @trigger="isOpen = false">
      <Button
        size="sm"
        color="slate"
        variant="outline"
        trailing-icon
        :label="buttonLabel"
        class="!h-8 !rounded-lg !bg-n-alpha-black2 !px-3 !py-2 !font-normal !outline-n-weak hover:!outline-n-slate-6"
        :icon="isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'"
        @click="isOpen = !isOpen"
      />

      <div
        v-if="isOpen"
        class="absolute left-0 z-30 mt-2 flex min-w-72 flex-col gap-3 rounded-2xl border border-n-weak bg-n-solid-2/95 p-3 shadow-xl outline outline-1 outline-n-container backdrop-blur-[16px]"
      >
        <Input
          v-model="query"
          size="sm"
          :placeholder="$t('SCHEDULING.TOOLBAR.RESOURCE_SEARCH')"
        />

        <div class="flex items-center justify-between gap-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="t('SCHEDULING.GENERAL.SELECT_ALL')"
            @click="selectAll"
          />
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="t('SCHEDULING.GENERAL.CLEAR')"
            @click="clearSelection"
          />
        </div>

        <div
          class="flex flex-col max-h-72 overflow-y-auto divide-y divide-n-weak"
        >
          <button
            v-for="resource in filteredResources"
            :key="resource.id"
            type="button"
            class="flex items-center gap-3 rounded-xl px-2 py-3 text-left transition-colors hover:bg-n-alpha-2"
            @click="toggleResource(resource.id)"
          >
            <Checkbox
              :model-value="modelValue.includes(resource.id)"
              aria-hidden="true"
              class="pointer-events-none"
              tabindex="-1"
            />
            <Avatar
              :src="resource.photoUrl || ''"
              :name="resource.name"
              :size="28"
            />
            <div class="flex flex-col items-start min-w-0 text-start">
              <span class="text-sm font-medium text-n-slate-12">
                {{ resource.name }}
              </span>
              <span v-if="resource.specialty" class="text-xs text-n-slate-11">
                {{ resource.specialty }}
              </span>
            </div>
          </button>
        </div>
      </div>
    </OnClickOutside>
  </div>
</template>
