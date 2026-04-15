<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CaptainToolAccessAPI from 'dashboard/api/captain/toolAccess';

const props = defineProps({
  modelValue: {
    type: Object,
    default: () => ({}),
  },
  assistantId: {
    type: Number,
    default: null,
  },
  allowedScopes: {
    type: Array,
    default: () => ['agent', 'assistant'],
  },
  defaultExpanded: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['update:modelValue']);

const { t } = useI18n();

const availableTools = ref([]);
const internalAccess = ref({});
const isLoading = ref(false);
const loadError = ref(false);

const SCOPE_ORDER = Object.freeze(['agent', 'assistant']);
const expandedScopes = ref(
  SCOPE_ORDER.reduce((result, scopeName) => {
    result[scopeName] = props.defaultExpanded;
    return result;
  }, {})
);

const cloneAccess = access => JSON.parse(JSON.stringify(access || {}));
const resolveTranslation = (key, fallback) => {
  const translated = t(key);
  return translated === key ? fallback : translated;
};
const resolveLocalizedValue = (translated, key, fallback) =>
  !translated || translated === key ? fallback : translated;

const defaultScopeSelection = scopeName => {
  const scopeTools = availableTools.value.filter(
    tool => tool.scope_name === scopeName
  );
  const defaultToolIds = scopeTools
    .filter(tool => tool.selected !== false)
    .map(tool => tool.id);

  return {
    enabled: defaultToolIds.length > 0,
    tool_ids: defaultToolIds,
  };
};

const scopeMetadata = computed(() => ({
  agent: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.AGENT.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.AGENT.DESCRIPTION'
    ),
  },
  assistant: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.ASSISTANT.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.SCOPES.ASSISTANT.DESCRIPTION'
    ),
  },
}));

const localizedGroupName = groupName => {
  const groups = {
    Knowledge: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.KNOWLEDGE',
      'Knowledge'
    ),
    Conversations: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.CONVERSATIONS',
      'Conversations'
    ),
    Contacts: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.CONTACTS',
      'Contacts'
    ),
    Companies: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.COMPANIES',
      'Companies'
    ),
    'CRM Deals': resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.CRM_DEALS',
      'CRM Deals'
    ),
    'CRM Tasks': resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.CRM_TASKS',
      'CRM Tasks'
    ),
    Scheduling: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.SCHEDULING',
      'Scheduling'
    ),
    'Help center': resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.HELP_CENTER',
      'Help center'
    ),
    Integrations: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.GROUPS.INTEGRATIONS',
      'Integrations'
    ),
  };

  return groups[groupName] || groupName;
};

const riskBadgeLabel = riskLevel => {
  const level = (riskLevel || 'low').toLowerCase();
  const labels = {
    low: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.LOW',
      'Low risk'
    ),
    medium: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.MEDIUM',
      'Medium risk'
    ),
    high: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.HIGH',
      'High risk'
    ),
    custom: resolveTranslation(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.RISK_LEVELS.CUSTOM',
      'Custom'
    ),
  };

  return labels[level] || labels.low;
};

const localizedToolCatalog = computed(() => ({
  search_documentation: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_documentation.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_documentation.DESCRIPTION'
    ),
  },
  faq_lookup: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.faq_lookup.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.faq_lookup.DESCRIPTION'
    ),
  },
  add_contact_note: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_contact_note.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_contact_note.DESCRIPTION'
    ),
  },
  add_private_note: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_private_note.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_private_note.DESCRIPTION'
    ),
  },
  add_label_to_conversation: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_label_to_conversation.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_label_to_conversation.DESCRIPTION'
    ),
  },
  update_priority: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_priority.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_priority.DESCRIPTION'
    ),
  },
  resolve_conversation: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.resolve_conversation.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.resolve_conversation.DESCRIPTION'
    ),
  },
  handoff: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.handoff.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.handoff.DESCRIPTION'
    ),
  },
  get_conversation: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_conversation.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_conversation.DESCRIPTION'
    ),
  },
  search_conversations: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_conversations.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_conversations.DESCRIPTION'
    ),
  },
  get_contact: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_contact.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_contact.DESCRIPTION'
    ),
  },
  search_contacts: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_contacts.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_contacts.DESCRIPTION'
    ),
  },
  update_contact: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_contact.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_contact.DESCRIPTION'
    ),
  },
  get_company: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_company.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_company.DESCRIPTION'
    ),
  },
  search_companies: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_companies.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_companies.DESCRIPTION'
    ),
  },
  create_company: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_company.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_company.DESCRIPTION'
    ),
  },
  update_company: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_company.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_company.DESCRIPTION'
    ),
  },
  get_deal: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_deal.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_deal.DESCRIPTION'
    ),
  },
  search_deals: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_deals.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_deals.DESCRIPTION'
    ),
  },
  get_deal_timeline: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_deal_timeline.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_deal_timeline.DESCRIPTION'
    ),
  },
  create_deal: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_deal.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_deal.DESCRIPTION'
    ),
  },
  update_deal: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_deal.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_deal.DESCRIPTION'
    ),
  },
  transition_deal_stage: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.transition_deal_stage.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.transition_deal_stage.DESCRIPTION'
    ),
  },
  add_deal_comment: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_deal_comment.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_deal_comment.DESCRIPTION'
    ),
  },
  get_task: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_task.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_task.DESCRIPTION'
    ),
  },
  search_tasks: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_tasks.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_tasks.DESCRIPTION'
    ),
  },
  get_task_timeline: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_task_timeline.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_task_timeline.DESCRIPTION'
    ),
  },
  create_task: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_task.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_task.DESCRIPTION'
    ),
  },
  update_task: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_task.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_task.DESCRIPTION'
    ),
  },
  change_task_status: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.change_task_status.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.change_task_status.DESCRIPTION'
    ),
  },
  add_task_comment: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_task_comment.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_task_comment.DESCRIPTION'
    ),
  },
  get_appointment: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_appointment.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_appointment.DESCRIPTION'
    ),
  },
  search_appointments: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_appointments.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_appointments.DESCRIPTION'
    ),
  },
  search_scheduling_resources: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_scheduling_resources.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_scheduling_resources.DESCRIPTION'
    ),
  },
  search_scheduling_services: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_scheduling_services.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_scheduling_services.DESCRIPTION'
    ),
  },
  search_available_slots: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_available_slots.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_available_slots.DESCRIPTION'
    ),
  },
  create_appointment: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_appointment.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_appointment.DESCRIPTION'
    ),
  },
  update_appointment: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_appointment.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_appointment.DESCRIPTION'
    ),
  },
  cancel_appointment: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.cancel_appointment.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.cancel_appointment.DESCRIPTION'
    ),
  },
  get_article: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_article.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.get_article.DESCRIPTION'
    ),
  },
  search_articles: {
    title: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_articles.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_articles.DESCRIPTION'
    ),
  },
  search_linear_issues: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_linear_issues.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_linear_issues.DESCRIPTION'
    ),
  },
}));

const localizedToolTitle = tool =>
  resolveLocalizedValue(
    localizedToolCatalog.value[tool.id]?.title,
    `CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.${tool.id}.TITLE`,
    tool.title
  );

const localizedToolDescription = tool =>
  resolveLocalizedValue(
    localizedToolCatalog.value[tool.id]?.description,
    `CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.${tool.id}.DESCRIPTION`,
    tool.description
  );

const loadTools = async () => {
  isLoading.value = true;
  loadError.value = false;

  try {
    const response = await CaptainToolAccessAPI.get({
      assistantId: props.assistantId,
    });
    availableTools.value = response.data || [];
  } catch (error) {
    availableTools.value = [];
    loadError.value = true;
  } finally {
    isLoading.value = false;
  }
};

const riskBadgeClass = riskLevel => {
  if (riskLevel === 'high') {
    return 'bg-n-amber-3 text-n-amber-11';
  }

  if (riskLevel === 'medium') {
    return 'bg-n-blue-3 text-n-blue-11';
  }

  if (riskLevel === 'custom') {
    return 'bg-n-violet-3 text-n-violet-11';
  }

  return 'bg-n-alpha-2 text-n-slate-11';
};

const toolBadges = tool => {
  const badges = [];
  const riskLevel = (tool.risk_level || 'low').toLowerCase();

  if (tool.custom) {
    badges.push({
      key: 'custom',
      label: resolveTranslation(
        'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.CUSTOM',
        'Custom'
      ),
      className: 'bg-n-violet-3 text-n-violet-11',
    });
  }

  if (!(tool.custom && riskLevel === 'custom')) {
    badges.push({
      key: `risk-${riskLevel}`,
      label: riskBadgeLabel(tool.risk_level),
      className: riskBadgeClass(tool.risk_level),
    });
  }

  if (tool.requires_confirmation) {
    badges.push({
      key: 'confirmation',
      label: resolveTranslation(
        'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.BADGES.REQUIRES_CONFIRMATION',
        'Needs confirmation'
      ),
      className: 'bg-n-amber-3 text-n-amber-11',
    });
  }

  return badges;
};

const toolsByScope = computed(() => {
  return SCOPE_ORDER.reduce((result, scopeName) => {
    const groups = new Map();

    availableTools.value
      .filter(tool => tool.scope_name === scopeName)
      .sort((leftTool, rightTool) => {
        const groupComparison = (leftTool.group_name || '').localeCompare(
          rightTool.group_name || ''
        );
        if (groupComparison !== 0) {
          return groupComparison;
        }

        return leftTool.title.localeCompare(rightTool.title);
      })
      .forEach(tool => {
        const groupName = localizedGroupName(
          tool.group_name || scopeMetadata.value[scopeName].title
        );
        if (!groups.has(groupName)) {
          groups.set(groupName, []);
        }

        groups.get(groupName).push(tool);
      });

    result[scopeName] = Array.from(groups.entries()).map(
      ([groupName, tools]) => ({
        groupName,
        tools,
      })
    );

    return result;
  }, {});
});

const scopeToolCounts = computed(() => {
  return SCOPE_ORDER.reduce((result, scopeName) => {
    result[scopeName] = availableTools.value.filter(
      tool => tool.scope_name === scopeName
    ).length;
    return result;
  }, {});
});

const normalizedAccess = computed(() => {
  return SCOPE_ORDER.reduce((result, scopeName) => {
    const rawScope = internalAccess.value?.[scopeName] || {};
    const scopeTools = availableTools.value.filter(
      tool => tool.scope_name === scopeName
    );
    const availableToolIds = scopeTools.map(tool => tool.id);
    const hasToolIds = Object.prototype.hasOwnProperty.call(
      rawScope,
      'tool_ids'
    );
    const defaultToolIds = scopeTools
      .filter(tool => tool.selected !== false)
      .map(tool => tool.id);
    const defaultEnabled = defaultToolIds.length > 0;
    const selectedToolIds = hasToolIds
      ? rawScope.tool_ids || []
      : defaultToolIds;

    result[scopeName] = {
      enabled:
        Object.prototype.hasOwnProperty.call(rawScope, 'enabled') &&
        typeof rawScope.enabled === 'boolean'
          ? rawScope.enabled
          : defaultEnabled,
      toolIds: selectedToolIds.filter(toolId =>
        availableToolIds.includes(toolId)
      ),
    };

    return result;
  }, {});
});

const serializedAccess = computed(() => {
  const preservedAccess = cloneAccess(internalAccess.value);

  return props.allowedScopes.reduce((result, scopeName) => {
    result[scopeName] = {
      enabled: normalizedAccess.value[scopeName].enabled,
      tool_ids: normalizedAccess.value[scopeName].toolIds,
    };

    return result;
  }, preservedAccess);
});

const updateAccess = nextAccess => {
  const clonedAccess = cloneAccess(nextAccess);
  internalAccess.value = clonedAccess;
  emit('update:modelValue', clonedAccess);
};

const hydrateMissingDefaults = () => {
  if (!availableTools.value.length) return;

  const nextAccess = cloneAccess(internalAccess.value);
  let changed = false;

  props.allowedScopes.forEach(scopeName => {
    const rawScope = nextAccess[scopeName];
    const defaults = defaultScopeSelection(scopeName);

    if (!rawScope || typeof rawScope !== 'object') {
      nextAccess[scopeName] = defaults;
      changed = true;
      return;
    }

    if (!Object.prototype.hasOwnProperty.call(rawScope, 'enabled')) {
      nextAccess[scopeName] = {
        ...nextAccess[scopeName],
        enabled: defaults.enabled,
      };
      changed = true;
    }

    if (!Object.prototype.hasOwnProperty.call(rawScope, 'tool_ids')) {
      nextAccess[scopeName] = {
        ...nextAccess[scopeName],
        tool_ids: defaults.tool_ids,
      };
      changed = true;
    }
  });

  if (changed) {
    updateAccess(nextAccess);
  }
};

const selectionCountLabel = (scopeName, selectedCount, totalCount) =>
  `${normalizedAccess.value[scopeName].enabled ? selectedCount : 0} / ${totalCount}`;

const toggleScopeExpanded = scopeName => {
  expandedScopes.value = {
    ...expandedScopes.value,
    [scopeName]: !expandedScopes.value[scopeName],
  };
};

const updateScopeEnabled = (scopeName, enabled) => {
  updateAccess({
    ...serializedAccess.value,
    [scopeName]: {
      ...serializedAccess.value[scopeName],
      enabled,
    },
  });
};

const toggleToolSelection = (scopeName, toolId, checked) => {
  const selectedIds = new Set(serializedAccess.value[scopeName].tool_ids);

  if (checked) {
    selectedIds.add(toolId);
  } else {
    selectedIds.delete(toolId);
  }

  updateAccess({
    ...serializedAccess.value,
    [scopeName]: {
      ...serializedAccess.value[scopeName],
      tool_ids: Array.from(selectedIds),
    },
  });
};

watch(
  () => props.assistantId,
  () => {
    loadTools();
  },
  { immediate: true }
);

watch(
  () => props.modelValue,
  newValue => {
    internalAccess.value = cloneAccess(newValue);
  },
  { deep: true, immediate: true }
);

watch(
  () => [availableTools.value, props.allowedScopes],
  () => {
    expandedScopes.value = props.allowedScopes.reduce(
      (result, scopeName) => {
        result[scopeName] = props.defaultExpanded;
        return result;
      },
      { ...expandedScopes.value }
    );
    hydrateMissingDefaults();
  },
  { deep: true, immediate: true }
);
</script>

<template>
  <div class="flex min-w-0 flex-col gap-4">
    <div class="flex flex-col gap-1">
      <h4 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TITLE') }}
      </h4>
      <p class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.DESCRIPTION') }}
      </p>
      <p class="text-xs text-n-slate-10">
        {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.HINT') }}
      </p>
    </div>

    <div
      v-if="loadError"
      class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-n-amber-6/30 bg-n-amber-3/40 p-4"
    >
      <p class="text-sm text-n-amber-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.ERROR') }}
      </p>
      <button
        type="button"
        class="inline-flex items-center rounded-lg border border-n-amber-7/40 px-3 py-1.5 text-sm font-medium text-n-amber-11 transition-colors hover:bg-n-amber-4/60"
        @click="loadTools"
      >
        {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.RETRY') }}
      </button>
    </div>

    <div
      v-for="scopeName in props.allowedScopes"
      :key="scopeName"
      class="flex min-w-0 flex-col gap-4 rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <div class="flex items-start justify-between gap-4">
        <button
          type="button"
          class="flex min-w-0 flex-1 items-start gap-3 text-left"
          :aria-expanded="expandedScopes[scopeName]"
          @click="toggleScopeExpanded(scopeName)"
        >
          <span
            class="mt-0.5 size-4 shrink-0 text-n-slate-10 i-lucide-chevron-down transition-transform duration-200"
            :class="{ 'rotate-180': expandedScopes[scopeName] }"
          />

          <span class="min-w-0 flex-1">
            <span class="flex flex-wrap items-center gap-2">
              <span class="break-words text-sm font-medium text-n-slate-12">
                {{ scopeMetadata[scopeName].title }}
              </span>
              <span
                class="inline-flex items-center rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
              >
                {{
                  selectionCountLabel(
                    scopeName,
                    normalizedAccess[scopeName].toolIds.length,
                    scopeToolCounts[scopeName]
                  )
                }}
              </span>
            </span>
            <span class="mt-1 block break-words text-sm text-n-slate-11">
              {{ scopeMetadata[scopeName].description }}
            </span>
          </span>
        </button>

        <div class="shrink-0" @click.stop>
          <Switch
            :model-value="normalizedAccess[scopeName].enabled"
            class="data-[state=checked]:!bg-n-violet-9"
            @update:model-value="value => updateScopeEnabled(scopeName, value)"
          />
        </div>
      </div>

      <div v-show="expandedScopes[scopeName]" class="flex flex-col gap-4">
        <div
          v-if="!normalizedAccess[scopeName].enabled"
          class="text-xs text-n-slate-10"
        >
          {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.DISABLED_MESSAGE') }}
        </div>

        <div v-if="isLoading" class="text-sm text-n-slate-11">
          {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.LOADING') }}
        </div>

        <div
          v-else-if="normalizedAccess[scopeName].enabled"
          class="grid grid-cols-1 gap-4 xl:grid-cols-2"
        >
          <div
            v-for="group in toolsByScope[scopeName]"
            :key="group.groupName"
            class="flex min-w-0 flex-col gap-3 rounded-lg border border-n-weak bg-n-alpha-2 p-3"
          >
            <div class="flex min-w-0 items-center gap-2">
              <div
                class="min-w-0 break-words text-sm font-medium text-n-slate-12"
              >
                {{ group.groupName }}
              </div>
            </div>

            <div class="flex flex-col gap-2">
              <label
                v-for="tool in group.tools"
                :key="tool.id"
                class="flex min-w-0 items-start gap-3 rounded-md px-1 py-1 transition-colors hover:bg-n-alpha-3"
              >
                <span class="mt-0.5 shrink-0">
                  <Checkbox
                    :model-value="
                      normalizedAccess[scopeName].toolIds.includes(tool.id)
                    "
                    @update:model-value="
                      value => toggleToolSelection(scopeName, tool.id, value)
                    "
                  />
                </span>
                <span class="min-w-0">
                  <span
                    class="block break-words text-sm font-medium text-n-slate-12"
                  >
                    {{ localizedToolTitle(tool) }}
                  </span>
                  <span class="mt-1 flex flex-wrap gap-1">
                    <span
                      v-for="badge in toolBadges(tool)"
                      :key="badge.key"
                      class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium"
                      :class="badge.className"
                    >
                      {{ badge.label }}
                    </span>
                  </span>
                  <span class="block break-words text-xs text-n-slate-10">
                    {{ localizedToolDescription(tool) }}
                  </span>
                </span>
              </label>
            </div>
          </div>

          <p
            v-if="!toolsByScope[scopeName]?.length"
            class="text-sm text-n-slate-11"
          >
            {{ t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.EMPTY') }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
