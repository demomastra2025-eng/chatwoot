<script setup>
import { computed, nextTick, ref, watch } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
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
const triggerRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

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
    return t('SCHEDULING.TOOLBAR.RESOURCES_SELECTED', { count: 0 });
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

const resolveTeleportTarget = () => {
  const overlayElement = triggerRef.value?.closest('dialog[open], .modal-mask');
  teleportTarget.value = overlayElement || 'body';
};

const updateDropdownPosition = () => {
  if (!isOpen.value || !triggerRef.value) return;

  const rect = triggerRef.value.getBoundingClientRect();
  const viewportPadding = 8;
  const width = Math.min(
    Math.max(rect.width, 288),
    window.innerWidth - viewportPadding * 2
  );
  const left = Math.min(
    Math.max(rect.left, viewportPadding),
    window.innerWidth - width - viewportPadding
  );
  const top = Math.max(rect.bottom + 8, viewportPadding);
  const maxHeight = Math.max(window.innerHeight - top - viewportPadding, 240);

  dropdownStyle.value = {
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(maxHeight)}px`,
    top: `${Math.round(top)}px`,
    width: `${Math.round(width)}px`,
  };
};

const toggleDropdown = () => {
  isOpen.value = !isOpen.value;

  if (!isOpen.value) return;

  resolveTeleportTarget();
  query.value = '';
  nextTick(() => {
    updateDropdownPosition();
  });
};

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

watch(
  () => props.resources,
  () => {
    if (!isOpen.value) return;
    nextTick(() => updateDropdownPosition());
  },
  { deep: true }
);

useEventListener(window, 'resize', updateDropdownPosition);
useEventListener(window, 'scroll', updateDropdownPosition, {
  capture: true,
  passive: true,
});
</script>

<template>
  <div ref="triggerRef" class="relative max-w-full min-w-0">
    <OnClickOutside
      :options="{ ignore: ['.scheduling-resource-filter-dropdown'] }"
      @trigger="isOpen = false"
    >
      <Button
        size="sm"
        color="slate"
        variant="outline"
        justify="start"
        class="!h-10 !max-w-full !rounded-lg !bg-n-alpha-black2 !px-3 !py-2 !font-normal !outline-n-weak hover:!outline-n-slate-6"
        @click="toggleDropdown"
      >
        <span class="min-w-0 flex-1 truncate text-left text-sm text-n-slate-12">
          {{ buttonLabel }}
        </span>
        <span
          class="size-4 shrink-0 text-n-slate-10"
          :class="[isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down']"
          aria-hidden="true"
        />
      </Button>

      <Teleport :to="teleportTarget">
        <div
          v-if="isOpen"
          class="scheduling-resource-filter-dropdown fixed z-50 flex min-w-72 flex-col gap-3 rounded-2xl border border-n-weak bg-n-solid-2/95 p-3 shadow-xl outline outline-1 outline-n-container backdrop-blur-[16px]"
          :style="dropdownStyle"
        >
          <Input
            v-model="query"
            size="sm"
            :placeholder="$t('SCHEDULING.TOOLBAR.RESOURCE_SEARCH')"
          />

          <div class="flex shrink-0 items-center justify-between gap-2">
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

          <div class="min-h-0 overflow-y-auto">
            <div class="flex flex-col divide-y divide-n-weak">
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
                  <span
                    v-if="resource.specialty"
                    class="text-xs text-n-slate-11"
                  >
                    {{ resource.specialty }}
                  </span>
                </div>
              </button>
            </div>
          </div>
        </div>
      </Teleport>
    </OnClickOutside>
  </div>
</template>
