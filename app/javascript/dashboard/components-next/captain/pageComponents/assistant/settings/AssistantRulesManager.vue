<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { picoSearch } from '@scmmishra/pico-search';
import { useStore } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import SuggestedRules from 'dashboard/components-next/captain/assistant/SuggestedRules.vue';
import AddNewRulesDialog from 'dashboard/components-next/captain/assistant/AddNewRulesDialog.vue';
import RuleCard from 'dashboard/components-next/captain/assistant/RuleCard.vue';
import BulkSelectBar from 'dashboard/components-next/captain/assistant/BulkSelectBar.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
  items: {
    type: Array,
    default: () => [],
  },
  field: {
    type: String,
    required: true,
    validator: value => ['guardrails', 'response_guidelines'].includes(value),
  },
  heading: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  showHeader: {
    type: Boolean,
    default: true,
  },
  contextAccess: {
    type: Object,
    default: null,
  },
  toolAccess: {
    type: Object,
    default: null,
  },
});

const { t } = useI18n();
const store = useStore();
const { uiSettings, updateUISettings } = useUISettings();

const searchQuery = ref('');
const newDialogRule = ref('');
const bulkSelectedIds = ref(new Set());
const hoveredCard = ref(null);

const uiSuggestionKey = computed(() =>
  props.field === 'guardrails'
    ? 'show_guardrails_suggestions'
    : 'show_response_guidelines_suggestions'
);

const copy = computed(() => {
  if (props.field === 'guardrails') {
    return {
      title: t('CAPTAIN.ASSISTANTS.GUARDRAILS.TITLE'),
      description: t('CAPTAIN.ASSISTANTS.GUARDRAILS.DESCRIPTION'),
      selectedAll: count =>
        t('CAPTAIN.ASSISTANTS.GUARDRAILS.BULK_ACTION.UNSELECT_ALL', {
          count,
        }),
      selectAll: count =>
        t('CAPTAIN.ASSISTANTS.GUARDRAILS.BULK_ACTION.SELECT_ALL', { count }),
      selected: count =>
        t('CAPTAIN.ASSISTANTS.GUARDRAILS.BULK_ACTION.SELECTED', { count }),
      deleteLabel: t(
        'CAPTAIN.ASSISTANTS.GUARDRAILS.BULK_ACTION.BULK_DELETE_BUTTON'
      ),
      addSuccess: t('CAPTAIN.ASSISTANTS.GUARDRAILS.API.ADD.SUCCESS'),
      addError: t('CAPTAIN.ASSISTANTS.GUARDRAILS.API.ADD.ERROR'),
      updateSuccess: t('CAPTAIN.ASSISTANTS.GUARDRAILS.API.UPDATE.SUCCESS'),
      updateError: t('CAPTAIN.ASSISTANTS.GUARDRAILS.API.UPDATE.ERROR'),
      deleteSuccess: t('CAPTAIN.ASSISTANTS.GUARDRAILS.API.DELETE.SUCCESS'),
      deleteError: t('CAPTAIN.ASSISTANTS.GUARDRAILS.API.DELETE.ERROR'),
      suggestedTitle: t('CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.SUGGESTED.TITLE'),
      suggestedAddSingle: t(
        'CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.SUGGESTED.ADD_SINGLE'
      ),
      newPlaceholder: t('CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.NEW.PLACEHOLDER'),
      newTitle: t('CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.NEW.TITLE'),
      newCreate: t('CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.NEW.CREATE'),
      newCancel: t('CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.NEW.CANCEL'),
      searchPlaceholder: t(
        'CAPTAIN.ASSISTANTS.GUARDRAILS.LIST.SEARCH_PLACEHOLDER'
      ),
      empty: t('CAPTAIN.ASSISTANTS.GUARDRAILS.EMPTY_MESSAGE'),
      searchEmpty: t('CAPTAIN.ASSISTANTS.GUARDRAILS.SEARCH_EMPTY_MESSAGE'),
      exampleSensitiveInfo: t(
        'CAPTAIN.ASSISTANTS.GUARDRAILS.EXAMPLES.SENSITIVE_INFO'
      ),
      exampleUnsafeLanguage: t(
        'CAPTAIN.ASSISTANTS.GUARDRAILS.EXAMPLES.UNSAFE_LANGUAGE'
      ),
      exampleDiagnosis: t('CAPTAIN.ASSISTANTS.GUARDRAILS.EXAMPLES.DIAGNOSIS'),
    };
  }

  return {
    title: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.TITLE'),
    description: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.DESCRIPTION'),
    selectedAll: count =>
      t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.BULK_ACTION.UNSELECT_ALL', {
        count,
      }),
    selectAll: count =>
      t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.BULK_ACTION.SELECT_ALL', {
        count,
      }),
    selected: count =>
      t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.BULK_ACTION.SELECTED', {
        count,
      }),
    deleteLabel: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.BULK_ACTION.BULK_DELETE_BUTTON'
    ),
    addSuccess: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.API.ADD.SUCCESS'),
    addError: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.API.ADD.ERROR'),
    updateSuccess: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.API.UPDATE.SUCCESS'
    ),
    updateError: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.API.UPDATE.ERROR'),
    deleteSuccess: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.API.DELETE.SUCCESS'
    ),
    deleteError: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.API.DELETE.ERROR'),
    suggestedTitle: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.ADD.SUGGESTED.TITLE'
    ),
    suggestedAddSingle: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.ADD.SUGGESTED.ADD_SINGLE'
    ),
    newPlaceholder: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.ADD.NEW.PLACEHOLDER'
    ),
    newTitle: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.ADD.NEW.TITLE'),
    newCreate: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.ADD.NEW.CREATE'),
    newCancel: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.ADD.NEW.CANCEL'),
    searchPlaceholder: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.LIST.SEARCH_PLACEHOLDER'
    ),
    empty: t('CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.EMPTY_MESSAGE'),
    searchEmpty: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.SEARCH_EMPTY_MESSAGE'
    ),
    exampleOpenDirectly: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.EXAMPLES.OPEN_DIRECTLY'
    ),
    exampleClarifyFirst: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.EXAMPLES.CLARIFY_FIRST'
    ),
    exampleCloseWithNextStep: t(
      'CAPTAIN.ASSISTANTS.RESPONSE_GUIDELINES.EXAMPLES.CLOSE_WITH_NEXT_STEP'
    ),
  };
});

const suggestedItems = computed(() => {
  if (props.field === 'guardrails') {
    return [
      {
        id: 1,
        content: copy.value.exampleSensitiveInfo,
      },
      {
        id: 2,
        content: copy.value.exampleUnsafeLanguage,
      },
      {
        id: 3,
        content: copy.value.exampleDiagnosis,
      },
    ];
  }

  return [
    {
      id: 1,
      content: copy.value.exampleOpenDirectly,
    },
    {
      id: 2,
      content: copy.value.exampleClarifyFirst,
    },
    {
      id: 3,
      content: copy.value.exampleCloseWithNextStep,
    },
  ];
});

const displayItems = computed(() =>
  props.items.map((content, index) => ({ id: index, content }))
);

const filteredItems = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return displayItems.value;
  return picoSearch(displayItems.value, query, ['content']);
});

const shouldShowSuggestedRules = computed(
  () => uiSettings.value?.[uiSuggestionKey.value] !== false
);

const headerTitle = computed(() => props.heading || copy.value.title);

const headerDescription = computed(
  () => props.description || copy.value.description
);

const buildSelectedCountLabel = computed(() => {
  const count = displayItems.value.length || 0;
  const isAllSelected = bulkSelectedIds.value.size === count && count > 0;
  return isAllSelected
    ? copy.value.selectedAll(count)
    : copy.value.selectAll(count);
});

const selectedCountLabel = computed(() =>
  copy.value.selected(bulkSelectedIds.value.size)
);

const handleRuleSelect = id => {
  const selected = new Set(bulkSelectedIds.value);
  selected[selected.has(id) ? 'delete' : 'add'](id);
  bulkSelectedIds.value = selected;
};

const handleRuleHover = (isHovered, id) => {
  hoveredCard.value = isHovered ? id : null;
};

const closeSuggestedRules = () => {
  updateUISettings({ [uiSuggestionKey.value]: false });
};

const saveItems = async list => {
  await store.dispatch('captainAssistants/update', {
    id: props.assistantId,
    assistant: { [props.field]: list },
  });
};

const addItem = async content => {
  try {
    const updated = [...props.items, content];
    await saveItems(updated);
    useAlert(copy.value.addSuccess);
  } catch {
    useAlert(copy.value.addError);
  }
};

const editItem = async ({ id, content }) => {
  try {
    const updated = [...props.items];
    updated[id] = content;
    await saveItems(updated);
    useAlert(copy.value.updateSuccess);
  } catch {
    useAlert(copy.value.updateError);
  }
};

const deleteItem = async id => {
  try {
    const updated = props.items.filter((_, index) => index !== id);
    await saveItems(updated);
    useAlert(copy.value.deleteSuccess);
  } catch {
    useAlert(copy.value.deleteError);
  }
};

const bulkDeleteItems = async () => {
  try {
    if (bulkSelectedIds.value.size === 0) return;
    const updated = props.items.filter(
      (_, index) => !bulkSelectedIds.value.has(index)
    );
    await saveItems(updated);
    bulkSelectedIds.value = new Set();
    useAlert(copy.value.deleteSuccess);
  } catch {
    useAlert(copy.value.deleteError);
  }
};

const addAllExample = async () => {
  updateUISettings({ [uiSuggestionKey.value]: false });
  try {
    const exampleContents = suggestedItems.value.map(item => item.content);
    await saveItems([...props.items, ...exampleContents]);
    useAlert(copy.value.addSuccess);
  } catch {
    useAlert(copy.value.addError);
  }
};
</script>

<template>
  <div class="flex flex-col gap-6">
    <SettingsHeader
      v-if="showHeader"
      :heading="headerTitle"
      :description="headerDescription"
    />

    <div v-if="shouldShowSuggestedRules" class="flex flex-col gap-4">
      <SuggestedRules
        :title="copy.suggestedTitle"
        :items="suggestedItems"
        @add="addAllExample"
        @close="closeSuggestedRules"
      >
        <template #default="{ item }">
          <div class="flex w-full items-center justify-between gap-3">
            <span class="text-sm text-n-slate-12">
              {{ item.content }}
            </span>
            <Button
              :label="copy.suggestedAddSingle"
              ghost
              xs
              slate
              class="!text-sm !text-n-slate-11 flex-shrink-0"
              @click="addItem(item.content)"
            />
          </div>
        </template>
      </SuggestedRules>
    </div>

    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between gap-4">
        <BulkSelectBar
          v-model="bulkSelectedIds"
          :all-items="displayItems"
          :select-all-label="buildSelectedCountLabel"
          :selected-count-label="selectedCountLabel"
          :delete-label="copy.deleteLabel"
          @bulk-delete="bulkDeleteItems"
        >
          <template #default-actions>
            <AddNewRulesDialog
              v-model="newDialogRule"
              enable-captain-tools
              enable-captain-fields
              :captain-context-assistant-id="assistantId"
              :captain-context-access="contextAccess"
              :captain-tool-access="toolAccess"
              captain-tool-scope="agent"
              :placeholder="copy.newPlaceholder"
              :button-label="copy.newTitle"
              :confirm-label="copy.newCreate"
              :cancel-label="copy.newCancel"
              @add="addItem"
            />
          </template>
        </BulkSelectBar>

        <div
          v-if="displayItems.length && bulkSelectedIds.size === 0"
          class="min-w-0 w-full max-w-[22.5rem]"
        >
          <Input v-model="searchQuery" :placeholder="copy.searchPlaceholder" />
        </div>
      </div>

      <div v-if="displayItems.length === 0" class="mb-2 mt-1">
        <span class="text-sm text-n-slate-11">
          {{ copy.empty }}
        </span>
      </div>
      <div v-else-if="filteredItems.length === 0" class="mb-2 mt-1">
        <span class="text-sm text-n-slate-11">
          {{ copy.searchEmpty }}
        </span>
      </div>
      <div v-else class="flex flex-col gap-2">
        <RuleCard
          v-for="item in filteredItems"
          :id="item.id"
          :key="item.id"
          :content="item.content"
          enable-captain-tools
          enable-captain-fields
          :captain-context-assistant-id="assistantId"
          :captain-context-access="contextAccess"
          :captain-tool-access="toolAccess"
          captain-tool-scope="agent"
          :is-selected="bulkSelectedIds.has(item.id)"
          :selectable="hoveredCard === item.id || bulkSelectedIds.size > 0"
          @select="handleRuleSelect"
          @edit="editItem"
          @delete="deleteItem"
          @hover="isHovered => handleRuleHover(isHovered, item.id)"
        />
      </div>
    </div>
  </div>
</template>
