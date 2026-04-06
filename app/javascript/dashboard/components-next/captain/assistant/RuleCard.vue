<script setup>
import { computed, h, ref, watch } from 'vue';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  content: {
    type: String,
    required: true,
  },
  enableCaptainFields: {
    type: Boolean,
    default: false,
  },
  enableCaptainTools: {
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
  selectable: {
    type: Boolean,
    default: false,
  },
  isSelected: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['select', 'hover', 'edit', 'delete']);
const { formatMessage } = useMessageFormatter();

const modelValue = computed({
  get: () => props.isSelected,
  set: () => emit('select', props.id),
});

const isEditing = ref(false);
const editedContent = ref(props.content);

// Local content to display to avoid flicker until parent prop updates on inline edit
const localContent = ref(props.content);

// Keeps localContent in sync when parent updates content prop
watch(
  () => props.content,
  newVal => {
    localContent.value = newVal;
  }
);

const startEdit = () => {
  isEditing.value = true;
  editedContent.value = props.content;
};

const saveEdit = () => {
  isEditing.value = false;
  // Update local content
  localContent.value = editedContent.value;
  emit('edit', { id: props.id, content: editedContent.value });
};

const LINK_RULE_CLASS =
  '[&_a[href^="field://"]]:text-n-teal-11 [&_a[href^="tool://"]]:text-n-iris-11 [&_a]:pointer-events-none [&_a]:cursor-default';

const renderRuleContent = content => () =>
  h('span', {
    class: `block text-sm text-n-slate-12 prose prose-sm min-w-0 break-words ${LINK_RULE_CLASS}`,
    innerHTML: formatMessage(content, false),
  });
</script>

<template>
  <CardLayout
    selectable
    class="relative [&>div]:!py-5 [&>div]:ltr:!pr-4 [&>div]:rtl:!pl-4"
    layout="row"
    @mouseenter="emit('hover', true)"
    @mouseleave="emit('hover', false)"
  >
    <div v-show="selectable" class="absolute top-6 ltr:left-3 rtl:right-3">
      <Checkbox v-model="modelValue" />
    </div>
    <Editor
      v-if="isEditing"
      v-model="editedContent"
      focus-on-mount
      :show-character-count="false"
      :enable-captain-tools="enableCaptainTools"
      :enable-captain-fields="enableCaptainFields"
      :captain-context-assistant-id="captainContextAssistantId"
      :captain-context-access="captainContextAccess"
      :captain-tool-access="captainToolAccess"
      :captain-tool-scope="captainToolScope"
      class="flex-1"
    />
    <component :is="renderRuleContent(localContent)" v-else class="flex-1" />
    <div class="flex items-center gap-2">
      <template v-if="isEditing">
        <Button icon="i-lucide-check" slate xs ghost @click="saveEdit" />
        <span class="w-px h-4 bg-n-weak" />
      </template>
      <Button icon="i-lucide-pen" slate xs ghost @click="startEdit" />
      <span class="w-px h-4 bg-n-weak" />
      <Button
        icon="i-lucide-trash"
        slate
        xs
        ghost
        @click="emit('delete', id)"
      />
    </div>
  </CardLayout>
</template>
