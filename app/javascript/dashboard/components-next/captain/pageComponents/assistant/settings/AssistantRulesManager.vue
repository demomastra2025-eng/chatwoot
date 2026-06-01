<script setup>
import { computed, ref, watch } from 'vue';
import Draggable from 'vuedraggable';
import { picoSearch } from '@scmmishra/pico-search';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import BulkSelectBar from 'dashboard/components-next/captain/assistant/BulkSelectBar.vue';
import InlineRuleComposer from 'dashboard/components-next/captain/assistant/InlineRuleComposer.vue';
import RuleCard from 'dashboard/components-next/captain/assistant/RuleCard.vue';
import SuggestedRules from 'dashboard/components-next/captain/assistant/SuggestedRules.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
  showHeader: {
    type: Boolean,
    default: true,
  },
});
const RULE_TYPE_SYSTEM = 'system';
const RULE_TYPE_RESPONSE_GUIDELINE = 'response_guideline';
const RULE_TYPE_GUARDRAIL = 'guardrail';
const RULE_TYPES = [
  RULE_TYPE_SYSTEM,
  RULE_TYPE_RESPONSE_GUIDELINE,
  RULE_TYPE_GUARDRAIL,
];

const { t } = useI18n();
const store = useStore();
const { uiSettings, updateUISettings } = useUISettings();

const searchQuery = ref('');
const bulkSelectedIds = ref(new Set());
const orderedRules = ref([]);
const isCreatingRule = ref(false);

const rules = computed(() => props.assistant?.config?.rules || []);
const CANONICAL_GROUPS = {
  strict: 'Strict rules',
  conversation: 'Conversation flow',
  restrictions: 'Restrictions',
  assistantStructure: 'Assistant structure',
  scenarioStructure: 'Scenario structure',
  runtimeContext: 'Runtime context',
};

const defaultGroups = computed(() => ({
  [RULE_TYPE_SYSTEM]: CANONICAL_GROUPS.strict,
  [RULE_TYPE_RESPONSE_GUIDELINE]: CANONICAL_GROUPS.conversation,
  [RULE_TYPE_GUARDRAIL]: CANONICAL_GROUPS.restrictions,
}));

const normalizeRuleType = rule => rule?.type?.toString().trim() || '';
const normalizedRuleContent = rule => rule?.content?.toString() || '';
const trimmedRuleContent = rule => normalizedRuleContent(rule).trim();

const isMalformedRule = rule => {
  const type = normalizeRuleType(rule);
  return !RULE_TYPES.includes(type) || !trimmedRuleContent(rule);
};

const normalizeRuleForList = (rule, index) => {
  const type = normalizeRuleType(rule);
  const isSystemRule = type === RULE_TYPE_SYSTEM;

  return {
    ...rule,
    id: rule?.id || `assistant_rule_malformed_${index}`,
    type,
    group: rule?.group?.toString().trim() || defaultGroups.value[type] || '',
    content: normalizedRuleContent(rule),
    enabled: rule?.enabled !== false,
    editable: isSystemRule ? false : rule?.editable !== false,
    deletable: isSystemRule ? false : rule?.deletable !== false,
    slot: rule?.slot || '',
    isMalformed: isMalformedRule(rule),
  };
};

const syncOrderedRules = list => {
  const sourceList = Array.isArray(list) ? list : [];

  orderedRules.value = sourceList.map((rule, index) =>
    normalizeRuleForList(rule, index)
  );
};

watch(
  rules,
  value => {
    syncOrderedRules(value);
  },
  { immediate: true, deep: true }
);

watch(
  () => props.assistantId,
  () => {
    bulkSelectedIds.value = new Set();
    isCreatingRule.value = false;
    searchQuery.value = '';
  }
);

const typeOptions = computed(() => [
  {
    value: RULE_TYPE_SYSTEM,
    label: t('CAPTAIN.ASSISTANTS.RULES.TYPES.SYSTEM'),
  },
  {
    value: RULE_TYPE_RESPONSE_GUIDELINE,
    label: t('CAPTAIN.ASSISTANTS.RULES.TYPES.RESPONSE_GUIDELINE'),
  },
  {
    value: RULE_TYPE_GUARDRAIL,
    label: t('CAPTAIN.ASSISTANTS.RULES.TYPES.GUARDRAIL'),
  },
]);

const customRuleTypeOptions = computed(() =>
  typeOptions.value.filter(option => option.value !== RULE_TYPE_SYSTEM)
);

const typeBadgeMap = computed(() => ({
  [RULE_TYPE_SYSTEM]: {
    label: t('CAPTAIN.ASSISTANTS.RULES.TYPES.SYSTEM'),
    className: 'bg-n-brand/10 text-n-brand',
    lockedLabel: t('CAPTAIN.ASSISTANTS.RULES.SYSTEM_LOCKED'),
    disabledLabel: t('CAPTAIN.ASSISTANTS.RULES.STATUS.DISABLED'),
    typeLabel: t('CAPTAIN.ASSISTANTS.RULES.FORM.TYPE'),
  },
  [RULE_TYPE_RESPONSE_GUIDELINE]: {
    label: t('CAPTAIN.ASSISTANTS.RULES.TYPES.RESPONSE_GUIDELINE'),
    className: 'bg-n-teal-2 text-n-teal-11',
    lockedLabel: t('CAPTAIN.ASSISTANTS.RULES.SYSTEM_LOCKED'),
    disabledLabel: t('CAPTAIN.ASSISTANTS.RULES.STATUS.DISABLED'),
    typeLabel: t('CAPTAIN.ASSISTANTS.RULES.FORM.TYPE'),
  },
  [RULE_TYPE_GUARDRAIL]: {
    label: t('CAPTAIN.ASSISTANTS.RULES.TYPES.GUARDRAIL'),
    className: 'bg-n-ruby-2 text-n-ruby-11',
    lockedLabel: t('CAPTAIN.ASSISTANTS.RULES.SYSTEM_LOCKED'),
    disabledLabel: t('CAPTAIN.ASSISTANTS.RULES.STATUS.DISABLED'),
    typeLabel: t('CAPTAIN.ASSISTANTS.RULES.FORM.TYPE'),
  },
}));

const groupLabels = computed(() => ({
  [CANONICAL_GROUPS.strict]: t('CAPTAIN.ASSISTANTS.RULES.GROUPS.STRICT'),
  [CANONICAL_GROUPS.conversation]: t(
    'CAPTAIN.ASSISTANTS.RULES.GROUPS.CONVERSATION'
  ),
  [CANONICAL_GROUPS.restrictions]: t(
    'CAPTAIN.ASSISTANTS.RULES.GROUPS.RESTRICTIONS'
  ),
  [CANONICAL_GROUPS.assistantStructure]: t(
    'CAPTAIN.ASSISTANTS.RULES.GROUPS.ASSISTANT_STRUCTURE'
  ),
  [CANONICAL_GROUPS.scenarioStructure]: t(
    'CAPTAIN.ASSISTANTS.RULES.GROUPS.SCENARIO_STRUCTURE'
  ),
  [CANONICAL_GROUPS.runtimeContext]: t(
    'CAPTAIN.ASSISTANTS.RULES.GROUPS.RUNTIME_CONTEXT'
  ),
}));

const suggestedItems = computed(() => [
  {
    id: 'rule_open_directly',
    type: RULE_TYPE_RESPONSE_GUIDELINE,
    group: defaultGroups.value[RULE_TYPE_RESPONSE_GUIDELINE],
    content: t('CAPTAIN.ASSISTANTS.RULES.EXAMPLES.OPEN_DIRECTLY'),
  },
  {
    id: 'rule_clarify_first',
    type: RULE_TYPE_RESPONSE_GUIDELINE,
    group: defaultGroups.value[RULE_TYPE_RESPONSE_GUIDELINE],
    content: t('CAPTAIN.ASSISTANTS.RULES.EXAMPLES.CLARIFY_FIRST'),
  },
  {
    id: 'rule_sensitive_info',
    type: RULE_TYPE_GUARDRAIL,
    group: defaultGroups.value[RULE_TYPE_GUARDRAIL],
    content: t('CAPTAIN.ASSISTANTS.RULES.EXAMPLES.SENSITIVE_INFO'),
  },
  {
    id: 'rule_diagnosis',
    type: RULE_TYPE_GUARDRAIL,
    group: defaultGroups.value[RULE_TYPE_GUARDRAIL],
    content: t('CAPTAIN.ASSISTANTS.RULES.EXAMPLES.DIAGNOSIS'),
  },
]);

const shouldShowSuggestedRules = computed(
  () => uiSettings.value?.show_assistant_rules_suggestions !== false
);

const systemPromptRules = computed(() =>
  orderedRules.value.filter(rule => rule.type === RULE_TYPE_SYSTEM)
);

const systemPromptRuleIds = computed(
  () => new Set(systemPromptRules.value.map(rule => rule.id?.toString()))
);

const customRules = computed(() =>
  orderedRules.value.filter(
    rule =>
      rule.type !== RULE_TYPE_SYSTEM &&
      !systemPromptRuleIds.value.has(rule.id?.toString())
  )
);

const searchableCustomRules = computed(() =>
  customRules.value.map(rule => ({
    ...rule,
    searchableType: typeBadgeMap.value[rule.type]?.label || '',
  }))
);

const filteredCustomRules = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return searchableCustomRules.value;

  return picoSearch(searchableCustomRules.value, query, [
    'content',
    'group',
    'searchableType',
  ]);
});

const selectableRules = computed(() =>
  customRules.value.filter(rule => rule.deletable !== false)
);

const hasCustomRules = computed(() => customRules.value.length > 0);

const shouldShowCustomRulesEmptyState = computed(() => {
  return (
    !searchQuery.value.trim() && !hasCustomRules.value && !isCreatingRule.value
  );
});

const buildSelectedCountLabel = computed(() => {
  const count = selectableRules.value.length || 0;
  const isAllSelected = bulkSelectedIds.value.size === count && count > 0;
  return isAllSelected
    ? t('CAPTAIN.ASSISTANTS.RULES.BULK_ACTION.UNSELECT_ALL', { count })
    : t('CAPTAIN.ASSISTANTS.RULES.BULK_ACTION.SELECT_ALL', { count });
});

const selectedCountLabel = computed(() =>
  t('CAPTAIN.ASSISTANTS.RULES.BULK_ACTION.SELECTED', {
    count: bulkSelectedIds.value.size,
  })
);

const displayGroupName = groupName => groupLabels.value[groupName] || groupName;

const createRuleId = () =>
  `assistant_rule_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

const serializeRules = list => {
  const normalizedList = Array.isArray(list) ? list : [];
  const reservedSystemRuleIds = new Set(
    normalizedList
      .filter(rule => normalizeRuleType(rule) === RULE_TYPE_SYSTEM)
      .map(rule => rule.id?.toString())
  );

  return normalizedList
    .filter(rule => !isMalformedRule(rule))
    .filter(
      rule =>
        normalizeRuleType(rule) === RULE_TYPE_SYSTEM ||
        !reservedSystemRuleIds.has(rule.id?.toString())
    )
    .map(rule => ({
      id: rule.id,
      type: normalizeRuleType(rule),
      group:
        rule.group?.toString().trim() ||
        defaultGroups.value[normalizeRuleType(rule)] ||
        '',
      content: trimmedRuleContent(rule),
      slot: rule.slot?.toString().trim() || '',
      enabled: rule.enabled !== false,
      editable: rule.editable !== false,
      deletable: rule.deletable !== false,
    }));
};

const normalizeIncomingRule = rule => ({
  id: rule.id || createRuleId(),
  type: rule.type,
  group: rule.group || defaultGroups.value[rule.type] || '',
  content: rule.content,
  slot: rule.slot || '',
  enabled: rule.enabled !== false,
  editable: rule.type === RULE_TYPE_SYSTEM ? false : rule.editable !== false,
  deletable: rule.type === RULE_TYPE_SYSTEM ? false : rule.deletable !== false,
});

const persistRules = async nextRules => {
  if (nextRules.some(isMalformedRule)) {
    throw new Error(t('CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULES_ERROR'));
  }

  const normalizedNextRules = nextRules.map((rule, index) =>
    normalizeRuleForList(normalizeIncomingRule(rule), index)
  );

  await store.dispatch('captainAssistants/update', {
    id: props.assistantId,
    config: {
      ...(props.assistant?.config || {}),
      rules: serializeRules(normalizedNextRules),
    },
  });
  syncOrderedRules(normalizedNextRules);
  await store.dispatch('captainAssistants/show', props.assistantId);
};

const saveRules = async nextRules => {
  try {
    await persistRules(nextRules);
    useAlert(t('CAPTAIN.ASSISTANTS.RULES.API.UPDATE.SUCCESS'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.RULES.API.UPDATE.ERROR'));
  }
};

const buildPayload = () => {
  if (orderedRules.value.some(isMalformedRule)) {
    throw new Error(t('CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULES_ERROR'));
  }

  return {
    assistant: {
      config: {
        rules: serializeRules(orderedRules.value),
      },
    },
  };
};

const openRuleComposer = () => {
  isCreatingRule.value = true;
};

const closeRuleComposer = () => {
  isCreatingRule.value = false;
};

const addRule = async rule => {
  const nextRules = [...orderedRules.value, normalizeIncomingRule(rule)];

  try {
    await persistRules(nextRules);
    closeRuleComposer();
    useAlert(t('CAPTAIN.ASSISTANTS.RULES.API.ADD.SUCCESS'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.RULES.API.ADD.ERROR'));
  }
};

const updateRule = async updatedRule => {
  const nextRules = orderedRules.value.map(rule =>
    rule.id === updatedRule.id ? normalizeIncomingRule(updatedRule) : rule
  );

  await saveRules(nextRules);
};

const updateRuleDraft = updatedRule => {
  orderedRules.value = orderedRules.value.map(rule =>
    rule.id === updatedRule.id ? normalizeIncomingRule(updatedRule) : rule
  );
};

const deleteRule = async ruleId => {
  const nextRules = orderedRules.value.filter(rule => rule.id !== ruleId);

  try {
    await persistRules(nextRules);
    bulkSelectedIds.value.delete(ruleId);
    bulkSelectedIds.value = new Set(bulkSelectedIds.value);
    useAlert(t('CAPTAIN.ASSISTANTS.RULES.API.DELETE.SUCCESS'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.RULES.API.DELETE.ERROR'));
  }
};

const bulkDeleteRules = async () => {
  const selectedIds = new Set(bulkSelectedIds.value);
  const nextRules = orderedRules.value.filter(
    rule => !selectedIds.has(rule.id)
  );

  try {
    await persistRules(nextRules);
    bulkSelectedIds.value = new Set();
    useAlert(t('CAPTAIN.ASSISTANTS.RULES.API.DELETE.SUCCESS'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.RULES.API.DELETE.ERROR'));
  }
};

const addSuggestedRule = async item => {
  const exists = orderedRules.value.some(
    rule =>
      rule.type === item.type &&
      rule.group === item.group &&
      rule.content === item.content
  );
  if (exists) return;

  await addRule(item);
};

const addAllSuggestedRules = async () => {
  const existingKeys = new Set(
    orderedRules.value
      .filter(rule => !isMalformedRule(rule))
      .map(rule => `${rule.type}:${rule.group}:${trimmedRuleContent(rule)}`)
  );
  const additions = suggestedItems.value
    .filter(
      item => !existingKeys.has(`${item.type}:${item.group}:${item.content}`)
    )
    .map(item => normalizeIncomingRule(item));

  if (!additions.length) return;

  try {
    await persistRules([...orderedRules.value, ...additions]);
    useAlert(t('CAPTAIN.ASSISTANTS.RULES.API.ADD.SUCCESS'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.RULES.API.ADD.ERROR'));
  }
};

const closeSuggestedRules = () => {
  updateUISettings({ show_assistant_rules_suggestions: false });
};

const handleRuleSelect = id => {
  const selected = new Set(bulkSelectedIds.value);
  selected[selected.has(id) ? 'delete' : 'add'](id);
  bulkSelectedIds.value = selected;
};

const startsGroupAt = (list, index) =>
  index === 0 || list[index - 1]?.group !== list[index]?.group;

const customRulesDraggable = computed({
  get: () => customRules.value,
  set: nextCustomRules => {
    orderedRules.value = [...systemPromptRules.value, ...nextCustomRules];
  },
});

const onDragEnd = async () => {
  await saveRules(orderedRules.value);
};

defineExpose({
  buildPayload,
  saveRules,
});
</script>

<template>
  <div class="flex flex-col gap-4">
    <SettingsHeader
      v-if="showHeader"
      :heading="$t('CAPTAIN.ASSISTANTS.RULES.TITLE')"
      :description="$t('CAPTAIN.ASSISTANTS.RULES.DESCRIPTION')"
    />

    <div v-if="shouldShowSuggestedRules" class="flex flex-col gap-4">
      <SuggestedRules
        :title="$t('CAPTAIN.ASSISTANTS.RULES.ADD.SUGGESTED.TITLE')"
        :items="suggestedItems"
        @close="closeSuggestedRules"
        @add="addAllSuggestedRules"
      >
        <template #default="{ item }">
          <div class="flex flex-col gap-2">
            <div class="flex items-center justify-between gap-3">
              <div class="flex items-center gap-2">
                <span
                  class="inline-flex rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
                  :class="typeBadgeMap[item.type]?.className"
                >
                  {{ typeBadgeMap[item.type]?.label }}
                </span>
                <span class="text-xs text-n-slate-11">
                  {{ displayGroupName(item.group) }}
                </span>
              </div>
              <Button
                :label="$t('CAPTAIN.ASSISTANTS.RULES.ADD.SUGGESTED.ADD_SINGLE')"
                ghost
                xs
                slate
                class="!text-sm !text-n-slate-11 flex-shrink-0"
                @click="addSuggestedRule(item)"
              />
            </div>
            <span class="text-sm text-n-slate-12">
              {{ item.content }}
            </span>
          </div>
        </template>
      </SuggestedRules>
    </div>

    <details
      v-if="systemPromptRules.length"
      data-testid="system-prompts-accordion"
      class="rounded-xl border border-n-weak bg-n-solid-1"
    >
      <summary
        class="cursor-pointer list-none px-4 py-3 text-sm font-medium text-n-slate-12"
      >
        {{
          $t('CAPTAIN.ASSISTANTS.RULES.SYSTEM_PROMPTS_ACCORDION', {
            count: systemPromptRules.length,
          })
        }}
      </summary>
      <div class="flex flex-col gap-3 border-t border-n-weak px-4 py-4">
        <template v-for="(rule, index) in systemPromptRules" :key="rule.id">
          <div v-if="startsGroupAt(systemPromptRules, index)" class="pt-1">
            <h4 class="text-sm font-semibold text-n-slate-12">
              {{ displayGroupName(rule.group) }}
            </h4>
          </div>
          <RuleCard
            :id="rule.id"
            :content="rule.content"
            :group="rule.group"
            :type="rule.type"
            :is-malformed="rule.isMalformed"
            :malformed-message="
              $t('CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULE_HINT')
            "
            :enabled="rule.enabled !== false"
            :editable="false"
            :deletable="false"
            :rule-slot="rule.slot || ''"
            :selectable="false"
            :is-selected="false"
            :type-options="typeOptions"
            :type-badge-map="typeBadgeMap"
            :group-labels="groupLabels"
            :group-label="$t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP')"
            :group-placeholder="
              $t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP_PLACEHOLDER')
            "
            enable-captain-tools
            enable-captain-fields
            enable-captain-skills
            :captain-context-assistant-id="assistantId"
            :captain-context-access="assistant?.config?.context_access || {}"
            :captain-tool-access="assistant?.config?.tool_access || {}"
            @update="updateRuleDraft"
          />
        </template>
      </div>
    </details>

    <BulkSelectBar
      v-model="bulkSelectedIds"
      :all-items="selectableRules"
      :select-all-label="buildSelectedCountLabel"
      :selected-count-label="selectedCountLabel"
      :delete-label="
        $t('CAPTAIN.ASSISTANTS.RULES.BULK_ACTION.BULK_DELETE_BUTTON')
      "
      @bulk-delete="bulkDeleteRules"
    >
      <template #default-actions>
        <div class="flex w-full flex-col gap-3">
          <div class="flex w-full items-center justify-between gap-3">
            <Input
              v-model="searchQuery"
              :placeholder="
                $t('CAPTAIN.ASSISTANTS.RULES.LIST.SEARCH_PLACEHOLDER')
              "
              class="min-w-[18rem]"
            />
            <Button
              v-if="!isCreatingRule"
              sm
              slate
              :label="$t('CAPTAIN.ASSISTANTS.RULES.ADD.NEW.CREATE')"
              @click="openRuleComposer"
            />
          </div>

          <InlineRuleComposer
            v-if="isCreatingRule"
            :confirm-label="$t('CAPTAIN.ASSISTANTS.RULES.ADD.NEW.CONFIRM')"
            :cancel-label="$t('CAPTAIN.ASSISTANTS.RULES.ADD.NEW.CANCEL')"
            :type-label="$t('CAPTAIN.ASSISTANTS.RULES.FORM.TYPE')"
            :group-label="$t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP')"
            :group-placeholder="
              $t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP_PLACEHOLDER')
            "
            :placeholder="$t('CAPTAIN.ASSISTANTS.RULES.ADD.NEW.PLACEHOLDER')"
            :type-options="customRuleTypeOptions"
            :default-groups="defaultGroups"
            :group-labels="groupLabels"
            enable-captain-tools
            enable-captain-fields
            enable-captain-skills
            :captain-context-assistant-id="assistantId"
            :captain-context-access="assistant?.config?.context_access || {}"
            :captain-tool-access="assistant?.config?.tool_access || {}"
            @add="addRule"
            @cancel="closeRuleComposer"
          />
        </div>
      </template>
    </BulkSelectBar>

    <p
      v-if="shouldShowCustomRulesEmptyState"
      class="rounded-xl border border-dashed border-n-strong px-4 py-6 text-sm text-n-slate-11"
    >
      {{ $t('CAPTAIN.ASSISTANTS.RULES.CUSTOM_EMPTY_MESSAGE') }}
    </p>

    <template v-if="!filteredCustomRules.length">
      <p
        v-if="searchQuery"
        class="rounded-xl border border-dashed border-n-strong px-4 py-6 text-sm text-n-slate-11"
      >
        {{ $t('CAPTAIN.ASSISTANTS.RULES.SEARCH_EMPTY_MESSAGE') }}
      </p>
      <p
        v-else-if="!systemPromptRules.length"
        class="rounded-xl border border-dashed border-n-strong px-4 py-6 text-sm text-n-slate-11"
      >
        {{ $t('CAPTAIN.ASSISTANTS.RULES.EMPTY_MESSAGE') }}
      </p>
    </template>

    <div v-else-if="searchQuery" class="flex flex-col gap-3">
      <template v-for="(rule, index) in filteredCustomRules" :key="rule.id">
        <div v-if="startsGroupAt(filteredCustomRules, index)" class="pt-2">
          <h4 class="text-sm font-semibold text-n-slate-12">
            {{ displayGroupName(rule.group) }}
          </h4>
        </div>
        <RuleCard
          :id="rule.id"
          :content="rule.content"
          :group="rule.group"
          :type="rule.type"
          :is-malformed="rule.isMalformed"
          :malformed-message="
            $t('CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULE_HINT')
          "
          :enabled="rule.enabled !== false"
          :editable="rule.editable !== false"
          :deletable="rule.deletable !== false"
          :rule-slot="rule.slot || ''"
          :selectable="rule.deletable !== false"
          :is-selected="bulkSelectedIds.has(rule.id)"
          :type-options="customRuleTypeOptions"
          :type-badge-map="typeBadgeMap"
          :group-labels="groupLabels"
          :group-label="$t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP')"
          :group-placeholder="
            $t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP_PLACEHOLDER')
          "
          enable-captain-tools
          enable-captain-fields
          enable-captain-skills
          :captain-context-assistant-id="assistantId"
          :captain-context-access="assistant?.config?.context_access || {}"
          :captain-tool-access="assistant?.config?.tool_access || {}"
          @select="handleRuleSelect"
          @update="updateRule"
          @delete="deleteRule"
        />
      </template>
    </div>

    <Draggable
      v-else
      v-model="customRulesDraggable"
      item-key="id"
      handle=".captain-rule-handle"
      ghost-class="opacity-60"
      class="flex flex-col gap-3"
      @end="onDragEnd"
    >
      <template #item="{ element, index }">
        <div class="flex flex-col gap-3">
          <div v-if="startsGroupAt(customRulesDraggable, index)" class="pt-2">
            <h4 class="text-sm font-semibold text-n-slate-12">
              {{ displayGroupName(element.group) }}
            </h4>
          </div>
          <RuleCard
            :id="element.id"
            :content="element.content"
            :group="element.group"
            :type="element.type"
            :is-malformed="element.isMalformed"
            :malformed-message="
              $t('CAPTAIN.ASSISTANTS.RULES.MALFORMED_RULE_HINT')
            "
            :enabled="element.enabled !== false"
            :editable="element.editable !== false"
            :deletable="element.deletable !== false"
            :rule-slot="element.slot || ''"
            :selectable="element.deletable !== false"
            :is-selected="bulkSelectedIds.has(element.id)"
            :type-options="customRuleTypeOptions"
            :type-badge-map="typeBadgeMap"
            :group-labels="groupLabels"
            :group-label="$t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP')"
            :group-placeholder="
              $t('CAPTAIN.ASSISTANTS.RULES.FORM.GROUP_PLACEHOLDER')
            "
            enable-captain-tools
            enable-captain-fields
            enable-captain-skills
            :captain-context-assistant-id="assistantId"
            :captain-context-access="assistant?.config?.context_access || {}"
            :captain-tool-access="assistant?.config?.tool_access || {}"
            @select="handleRuleSelect"
            @update="updateRule"
            @delete="deleteRule"
          />
        </div>
      </template>
    </Draggable>
  </div>
</template>
