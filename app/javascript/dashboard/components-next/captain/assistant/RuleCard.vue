<script setup>
import { computed, h, ref, watch } from 'vue';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';

import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  id: {
    type: [String, Number],
    required: true,
  },
  content: {
    type: String,
    required: true,
  },
  group: {
    type: String,
    default: '',
  },
  isMalformed: {
    type: Boolean,
    default: false,
  },
  malformedMessage: {
    type: String,
    default: '',
  },
  type: {
    type: String,
    default: '',
  },
  enabled: {
    type: Boolean,
    default: true,
  },
  editable: {
    type: Boolean,
    default: true,
  },
  deletable: {
    type: Boolean,
    default: true,
  },
  ruleSlot: {
    type: String,
    default: '',
  },
  selectable: {
    type: Boolean,
    default: false,
  },
  isSelected: {
    type: Boolean,
    default: false,
  },
  typeOptions: {
    type: Array,
    default: () => [],
  },
  typeBadgeMap: {
    type: Object,
    default: () => ({}),
  },
  groupLabel: {
    type: String,
    default: '',
  },
  groupPlaceholder: {
    type: String,
    default: '',
  },
  groupLabels: {
    type: Object,
    default: () => ({}),
  },
  enableCaptainFields: {
    type: Boolean,
    default: false,
  },
  enableCaptainTools: {
    type: Boolean,
    default: false,
  },
  enableCaptainSkills: {
    type: Boolean,
    default: false,
  },
  captainContextAssistantId: {
    type: Number,
    default: null,
  },
  captainContextAccess: {
    type: Object,
    default: null,
  },
  captainToolAccess: {
    type: Object,
    default: null,
  },
  captainToolScope: {
    type: String,
    default: 'agent',
  },
});

const emit = defineEmits(['select', 'hover', 'update', 'edit', 'delete']);
const { formatMessage } = useMessageFormatter();
const isStructuredMode = computed(
  () => props.typeOptions.length > 0 || !!props.type || !!props.group
);

const modelValue = computed({
  get: () => props.isSelected,
  set: () => emit('select', props.id),
});

const isEditing = ref(false);
const localRule = ref({
  id: props.id,
  content: props.content,
  group: props.group,
  type: props.type,
  enabled: props.enabled,
  editable: props.editable,
  deletable: props.deletable,
  slot: props.ruleSlot,
});

watch(
  () => [
    props.id,
    props.content,
    props.group,
    props.type,
    props.enabled,
    props.editable,
    props.deletable,
    props.ruleSlot,
  ],
  ([id, content, group, type, enabled, editable, deletable, slot]) => {
    localRule.value = {
      id,
      content,
      group,
      type,
      enabled,
      editable,
      deletable,
      slot,
    };
  }
);

const startEdit = () => {
  if (!props.editable) return;

  localRule.value = {
    id: props.id,
    content: props.content,
    group: props.group,
    type: props.type,
    enabled: props.enabled,
    editable: props.editable,
    deletable: props.deletable,
    slot: props.ruleSlot,
  };
  isEditing.value = true;
};

const stopEdit = () => {
  isEditing.value = false;
};

const resolveDisplayGroup = value => props.groupLabels[value] || value;
const resolveStoredGroup = value => {
  const normalizedValue = value?.toString().trim() || '';
  const matchedEntry = Object.entries(props.groupLabels).find(
    ([, label]) => label === normalizedValue
  );

  return matchedEntry?.[0] || normalizedValue;
};

const groupInputValue = computed({
  get: () => resolveDisplayGroup(localRule.value.group),
  set: value => {
    localRule.value.group = resolveStoredGroup(value);
  },
});

const saveEdit = () => {
  const trimmedContent = localRule.value.content?.toString().trim();
  if (!trimmedContent) return;

  emit('update', { ...localRule.value, content: trimmedContent });
  emit('edit', {
    id: props.id,
    content: trimmedContent,
  });
  stopEdit();
};

const onToggleEnabled = enabled => {
  if (!isStructuredMode.value) return;

  const sourceRule = isEditing.value
    ? localRule.value
    : {
        id: props.id,
        content: props.content,
        group: props.group,
        type: props.type,
        editable: props.editable,
        deletable: props.deletable,
        slot: props.ruleSlot,
      };

  emit('update', {
    ...sourceRule,
    content: sourceRule.content?.toString().trim() || '',
    enabled,
  });
};

const LINK_RULE_CLASS =
  '[&_a[href^="field://"]]:text-n-teal-11 [&_a[href^="tool://"]]:text-n-iris-11 [&_a[href^="skill://"]]:text-n-amber-11 [&_a]:pointer-events-none [&_a]:cursor-default';

const renderRuleContent = content => () =>
  h('span', {
    class: `block text-sm text-n-slate-12 prose prose-sm min-w-0 break-words ${LINK_RULE_CLASS}`,
    innerHTML: formatMessage(content, false),
  });

const typeBadge = computed(() => props.typeBadgeMap[props.type] || {});
</script>

<template>
  <CardLayout
    selectable
    class="relative [&>div]:!py-5"
    :class="{
      '[&>div]:ltr:!pl-10 [&>div]:rtl:!pr-10': selectable,
      'opacity-80': !enabled && !isEditing,
    }"
    layout="row"
    @mouseenter="emit('hover', true)"
    @mouseleave="emit('hover', false)"
  >
    <div v-if="selectable" class="absolute top-6 ltr:left-3 rtl:right-3">
      <Checkbox v-model="modelValue" />
    </div>

    <div class="flex w-full gap-4">
      <div
        v-if="isStructuredMode && deletable"
        class="captain-rule-handle mt-0.5 flex items-start text-n-slate-10 cursor-grab active:cursor-grabbing"
      >
        <Icon icon="i-lucide-grip-vertical" class="size-4" />
      </div>

      <div class="flex min-w-0 flex-1 flex-col gap-3">
        <div class="flex items-center justify-between gap-3">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span
              v-if="typeBadge.label"
              class="inline-flex rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
              :class="typeBadge.className"
            >
              {{ typeBadge.label }}
            </span>
            <span
              v-if="!editable && isStructuredMode"
              class="inline-flex rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] font-medium text-n-slate-11"
            >
              <span class="i-lucide-lock mr-1 size-3" />
              {{ typeBadge.lockedLabel }}
            </span>
            <span
              v-if="!enabled && isStructuredMode"
              class="inline-flex rounded-full bg-n-alpha-2 px-2 py-0.5 text-[0.6875rem] font-medium text-n-slate-11"
            >
              {{ typeBadge.disabledLabel }}
            </span>
          </div>

          <div class="flex items-center gap-2">
            <Switch
              v-if="isStructuredMode"
              :model-value="enabled"
              @click.stop
              @keydown.stop
              @change="onToggleEnabled"
            />
            <template v-if="editable">
              <Button
                v-if="!isEditing"
                icon="i-lucide-pen"
                slate
                xs
                ghost
                @click="startEdit"
              />
              <template v-else>
                <Button
                  icon="i-lucide-check"
                  slate
                  xs
                  ghost
                  @click="saveEdit"
                />
                <Button icon="i-lucide-x" slate xs ghost @click="stopEdit" />
              </template>
              <span v-if="deletable" class="h-4 w-px bg-n-weak" />
            </template>
            <Button
              v-if="deletable"
              icon="i-lucide-trash"
              slate
              xs
              ghost
              @click="emit('delete', id)"
            />
          </div>
        </div>

        <template v-if="isEditing && editable">
          <div v-if="isStructuredMode" class="grid grid-cols-2 gap-3">
            <div class="flex min-w-0 flex-col gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ groupLabel }}
              </span>
              <Input
                v-model="groupInputValue"
                :placeholder="groupPlaceholder"
              />
            </div>
            <div class="flex min-w-0 flex-col gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ typeBadge.typeLabel }}
              </span>
              <Select
                v-model="localRule.type"
                :options="typeOptions"
                class="w-full"
              />
            </div>
          </div>

          <Editor
            v-model="localRule.content"
            override-line-breaks
            auto-height
            :editor-key="`captain:rule:${id}`"
            focus-on-mount
            :show-character-count="false"
            :enable-captain-tools="enableCaptainTools"
            :enable-captain-fields="enableCaptainFields"
            :enable-captain-skills="enableCaptainSkills"
            :captain-context-assistant-id="captainContextAssistantId"
            :captain-context-access="captainContextAccess"
            :captain-tool-access="captainToolAccess"
            :captain-tool-scope="captainToolScope"
          />
        </template>

        <template v-else>
          <div class="flex flex-col gap-2">
            <p
              v-if="isMalformed && malformedMessage"
              class="rounded-lg border border-n-ruby-6/40 bg-n-ruby-2/40 px-3 py-2 text-sm text-n-ruby-11"
            >
              {{ malformedMessage }}
            </p>
            <component :is="renderRuleContent(content)" />
          </div>
        </template>
      </div>
    </div>
  </CardLayout>
</template>
