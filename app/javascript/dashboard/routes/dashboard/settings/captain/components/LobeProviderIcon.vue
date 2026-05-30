<script setup>
import { computed } from 'vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import {
  LOBE_PROVIDER_ALIASES,
  LOBE_PROVIDER_ICONS,
} from './lobeProviderIcons';

const props = defineProps({
  providerKey: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    default: '',
  },
});

defineOptions({ inheritAttrs: false });

const normalizeProviderKey = value =>
  value
    .toString()
    .trim()
    .toLowerCase()
    .replace(/^~+/, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');

const icon = computed(() => {
  const iconId = LOBE_PROVIDER_ALIASES[normalizeProviderKey(props.providerKey)];
  return iconId ? LOBE_PROVIDER_ICONS[iconId] : null;
});

const titleLabel = computed(() => props.title || icon.value?.title || '');

const elementAttrs = element => {
  const attrs = { ...element };
  delete attrs.type;

  if (attrs.clipRule) {
    attrs['clip-rule'] = attrs.clipRule;
    delete attrs.clipRule;
  }

  if (attrs.fillRule) {
    attrs['fill-rule'] = attrs.fillRule;
    delete attrs.fillRule;
  }

  return attrs;
};
</script>

<template>
  <svg
    v-if="icon"
    v-bind="$attrs"
    :viewBox="icon.viewBox"
    fill="currentColor"
    fill-rule="evenodd"
    aria-hidden="true"
    xmlns="http://www.w3.org/2000/svg"
  >
    <title v-if="titleLabel">{{ titleLabel }}</title>
    <template
      v-for="(element, index) in icon.elements"
      :key="`${element.type}-${index}`"
    >
      <path v-if="element.type === 'path'" v-bind="elementAttrs(element)" />
      <circle
        v-else-if="element.type === 'circle'"
        v-bind="elementAttrs(element)"
      />
      <ellipse
        v-else-if="element.type === 'ellipse'"
        v-bind="elementAttrs(element)"
      />
      <rect
        v-else-if="element.type === 'rect'"
        v-bind="elementAttrs(element)"
      />
    </template>
  </svg>
  <Icon v-else v-bind="$attrs" icon="i-lucide-building-2" />
</template>
