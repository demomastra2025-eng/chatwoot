<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CaptainContextFieldsAPI from 'dashboard/api/captain/contextFields';

const props = defineProps({
  modelValue: {
    type: Object,
    default: () => ({}),
  },
  assistantId: {
    type: Number,
    default: null,
  },
});

const emit = defineEmits(['update:modelValue']);

const { t, locale } = useI18n();

const availableFields = ref([]);
const isLoading = ref(false);

const TABLE_ORDER = Object.freeze([
  'contact',
  'conversation',
  'deal',
  'task',
  'appointment',
]);
const OPTIONAL_TABLES = Object.freeze(['deal', 'task', 'appointment']);
const expandedTables = ref(
  TABLE_ORDER.reduce((result, tableName) => {
    result[tableName] = false;
    return result;
  }, {})
);

const tableMetadata = computed(() => ({
  contact: {
    title: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.DESCRIPTION'
    ),
  },
  conversation: {
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.DESCRIPTION'
    ),
  },
  deal: {
    title: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.DEAL.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.DEAL.DESCRIPTION'
    ),
  },
  task: {
    title: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.TASK.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.TASK.DESCRIPTION'
    ),
  },
  appointment: {
    title: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.APPOINTMENT.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.APPOINTMENT.DESCRIPTION'
    ),
  },
}));

const localizedFieldCatalog = computed(() => {
  if (locale.value !== 'ru') {
    return {};
  }

  return {
    'contact.id': 'ID контакта',
    'contact.name': 'Имя',
    'contact.email': 'Email',
    'contact.phone_number': 'Телефон',
    'contact.identifier': 'Идентификатор',
    'contact.contact_type': 'Тип контакта',
    'conversation.id': 'ID записи диалога',
    'conversation.display_id': 'Номер диалога',
    'conversation.inbox_id': 'ID inbox',
    'conversation.contact_id': 'ID контакта',
    'conversation.status': 'Статус',
    'conversation.priority': 'Приоритет',
    'conversation.label_list': 'Метки',
    'deal.id': 'ID сделки',
    'deal.title': 'Название',
    'deal.description': 'Описание',
    'deal.amount_minor': 'Сумма в минимальных единицах',
    'deal.currency': 'Валюта',
    'deal.expected_close_on': 'Плановая дата закрытия',
    'deal.win_probability': 'Вероятность успеха',
    'deal.closed_at': 'Дата закрытия',
    'deal.external_ref': 'Внешний идентификатор',
    'deal.pipeline_id': 'ID воронки',
    'deal.pipeline_name': 'Воронка',
    'deal.stage_id': 'ID этапа',
    'deal.stage_name': 'Этап',
    'deal.owner_id': 'ID ответственного',
    'deal.owner_name': 'Ответственный',
    'deal.creator_id': 'ID автора',
    'deal.creator_name': 'Автор',
    'deal.team_id': 'ID команды',
    'deal.team_name': 'Команда',
    'deal.company_id': 'ID компании',
    'deal.company_name': 'Компания',
    'deal.originating_conversation_id': 'ID исходного диалога',
    'task.id': 'ID задачи',
    'task.title': 'Название',
    'task.description': 'Описание',
    'task.due_at': 'Срок выполнения',
    'task.start_at': 'Дата начала',
    'task.priority': 'Приоритет',
    'task.completed_at': 'Дата завершения',
    'task.external_ref': 'Внешний идентификатор',
    'task.status_id': 'ID статуса',
    'task.status_name': 'Статус',
    'task.assignee_id': 'ID исполнителя',
    'task.assignee_name': 'Исполнитель',
    'task.creator_id': 'ID автора',
    'task.creator_name': 'Автор',
    'task.team_id': 'ID команды',
    'task.team_name': 'Команда',
    'task.deal_id': 'ID сделки',
    'task.deal_title': 'Название сделки',
    'task.originating_conversation_id': 'ID исходного диалога',
    'appointment.id': 'ID записи',
    'appointment.resource_id': 'ID специалиста',
    'appointment.contact_id': 'ID контакта',
    'appointment.service_id': 'ID услуги',
    'appointment.company_id': 'ID компании',
    'appointment.conversation_id': 'ID диалога',
    'appointment.created_by_id': 'ID автора',
    'appointment.starts_at': 'Начало записи',
    'appointment.ends_at': 'Окончание записи',
    'appointment.duration_min': 'Длительность в минутах',
    'appointment.status': 'Статус',
    'appointment.appointment_type': 'Тип записи',
    'appointment.client_name': 'Имя клиента',
    'appointment.client_phone': 'Телефон клиента',
    'appointment.client_identifier': 'Идентификатор клиента',
    'appointment.client_birth_date': 'Дата рождения клиента',
    'appointment.client_gender': 'Пол клиента',
    'appointment.client_comment': 'Комментарий клиента',
    'appointment.source': 'Источник',
    'appointment.external_ref': 'Внешний идентификатор',
    'appointment.payment_status': 'Статус оплаты',
    'appointment.service_name_snapshot': 'Название услуги',
    'appointment.service_type_snapshot': 'Тип услуги',
    'appointment.service_duration_min_snapshot':
      'Длительность услуги в минутах',
    'appointment.service_amount': 'Стоимость услуги',
    'appointment.compensation_type_snapshot': 'Тип компенсации',
    'appointment.compensation_value_snapshot': 'Значение компенсации',
    'appointment.compensation_percent_snapshot': 'Процент компенсации',
    'appointment.prepaid_amount': 'Сумма предоплаты',
    'appointment.prepaid_payment_method': 'Способ предоплаты',
    'appointment.settlement_amount': 'Сумма расчета',
    'appointment.settlement_payment_method': 'Способ расчета',
  };
});

const localizedGroupCatalog = computed(() => ({
  Contact: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.TITLE'),
  Conversation: t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.TITLE'
  ),
  Deal: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.DEAL.TITLE'),
  Task: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.TASK.TITLE'),
  Appointment: t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.APPOINTMENT.TITLE'
  ),
  'Contact Attributes': t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.CONTACT_ATTRIBUTES'
  ),
  'Conversation Attributes': t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.CONVERSATION_ATTRIBUTES'
  ),
  'Deal Attributes': t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.DEAL_ATTRIBUTES'
  ),
  'Task Attributes': t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.TASK_ATTRIBUTES'
  ),
  'Appointment Attributes': t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.GROUPS.APPOINTMENT_ATTRIBUTES'
  ),
}));

const scopeLabels = computed(() => ({
  contact: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.ENTITIES.CONTACT'),
  conversation: t(
    'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.ENTITIES.CONVERSATION'
  ),
  deal: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.ENTITIES.DEAL'),
  task: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.ENTITIES.TASK'),
  appointment: t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.ENTITIES.APPOINTMENT'),
}));

const resolveGroupName = groupName =>
  localizedGroupCatalog.value[groupName] || groupName;

const resolveFieldTitle = field => {
  if (field.field_type === 'custom_attribute') {
    return field.title;
  }

  return localizedFieldCatalog.value[field.id] || field.title;
};

const resolveFieldDescription = field => {
  if (field.field_type === 'custom_attribute') {
    return t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELD_TYPES.CUSTOM', {
      entity: scopeLabels.value[field.table_name] || field.table_name,
    });
  }

  return t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.FIELD_TYPES.DEFAULT', {
    entity: scopeLabels.value[field.table_name] || field.table_name,
  });
};

const resolveFieldVariable = field => field.description || field.id;

const loadFields = async () => {
  isLoading.value = true;

  try {
    const response = await CaptainContextFieldsAPI.get({
      assistantId: props.assistantId,
    });
    availableFields.value = response.data || [];
  } catch (error) {
    availableFields.value = [];
  } finally {
    isLoading.value = false;
  }
};

const fieldsByTable = computed(() => {
  return TABLE_ORDER.reduce((result, tableName) => {
    const groups = new Map();

    availableFields.value
      .filter(field => field.table_name === tableName)
      .sort((leftField, rightField) => {
        const groupComparison = (leftField.group_name || '').localeCompare(
          rightField.group_name || ''
        );
        if (groupComparison !== 0) {
          return groupComparison;
        }

        return leftField.title.localeCompare(rightField.title);
      })
      .forEach(field => {
        const groupName =
          field.group_name || tableMetadata.value[tableName].title;
        if (!groups.has(groupName)) {
          groups.set(groupName, []);
        }

        groups.get(groupName).push(field);
      });

    result[tableName] = Array.from(groups.entries()).map(
      ([groupName, fields]) => ({
        groupName,
        fields,
      })
    );

    return result;
  }, {});
});

const tableFieldCounts = computed(() => {
  return TABLE_ORDER.reduce((result, tableName) => {
    result[tableName] = availableFields.value.filter(
      field => field.table_name === tableName
    ).length;

    return result;
  }, {});
});

const visibleTables = computed(() => {
  return TABLE_ORDER.filter(tableName => {
    if (!OPTIONAL_TABLES.includes(tableName)) {
      return true;
    }

    return (
      tableFieldCounts.value[tableName] > 0 ||
      Object.prototype.hasOwnProperty.call(props.modelValue || {}, tableName)
    );
  });
});

const normalizedAccess = computed(() => {
  return TABLE_ORDER.reduce((result, tableName) => {
    const rawScope = props.modelValue?.[tableName] || {};
    const tableFields = availableFields.value.filter(
      field => field.table_name === tableName
    );
    const availableFieldIds = tableFields.map(field => field.id);
    const hasFieldIds = Object.prototype.hasOwnProperty.call(
      rawScope,
      'field_ids'
    );
    const defaultEnabled = tableFields.some(field => field.selected !== false);
    const defaultFieldIds = availableFieldIds;

    result[tableName] = {
      enabled:
        Object.prototype.hasOwnProperty.call(rawScope, 'enabled') &&
        typeof rawScope.enabled === 'boolean'
          ? rawScope.enabled
          : defaultEnabled,
      fieldIds: (hasFieldIds ? rawScope.field_ids : defaultFieldIds).filter(
        fieldId => availableFieldIds.includes(fieldId)
      ),
    };

    return result;
  }, {});
});

const serializedAccess = computed(() => {
  return visibleTables.value.reduce((result, tableName) => {
    result[tableName] = {
      enabled: normalizedAccess.value[tableName].enabled,
      field_ids: normalizedAccess.value[tableName].fieldIds,
    };

    return result;
  }, {});
});

const updateAccess = nextAccess => {
  emit('update:modelValue', nextAccess);
};

const selectionCountLabel = (tableName, selectedCount, totalCount) =>
  `${normalizedAccess.value[tableName].enabled ? selectedCount : 0} / ${totalCount}`;

const toggleTableExpanded = tableName => {
  expandedTables.value = {
    ...expandedTables.value,
    [tableName]: !expandedTables.value[tableName],
  };
};

const updateTableEnabled = (tableName, enabled) => {
  updateAccess({
    ...serializedAccess.value,
    [tableName]: {
      ...serializedAccess.value[tableName],
      enabled,
    },
  });
};

const toggleFieldSelection = (tableName, fieldId, checked) => {
  const selectedIds = new Set(serializedAccess.value[tableName].field_ids);

  if (checked) {
    selectedIds.add(fieldId);
  } else {
    selectedIds.delete(fieldId);
  }

  updateAccess({
    ...serializedAccess.value,
    [tableName]: {
      ...serializedAccess.value[tableName],
      field_ids: Array.from(selectedIds),
    },
  });
};

watch(
  () => props.assistantId,
  () => {
    loadFields();
  },
  { immediate: true }
);

watch(
  [availableFields, serializedAccess],
  () => {
    if (!availableFields.value.length) return;

    const currentValue = JSON.stringify(props.modelValue || {});
    const nextValue = JSON.stringify(serializedAccess.value);
    if (currentValue !== nextValue) {
      emit('update:modelValue', serializedAccess.value);
    }
  },
  { deep: true, immediate: true }
);
</script>

<template>
  <div class="flex min-w-0 flex-col gap-4">
    <div class="flex flex-col gap-1">
      <h4 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TITLE') }}
      </h4>
      <p class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.DESCRIPTION') }}
      </p>
      <p class="text-xs text-n-slate-10">
        {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.HINT') }}
      </p>
    </div>

    <div
      v-for="tableName in visibleTables"
      :key="tableName"
      class="flex min-w-0 flex-col gap-4 rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <div class="flex items-start justify-between gap-4">
        <button
          type="button"
          class="flex min-w-0 flex-1 items-start gap-3 text-left"
          :aria-expanded="expandedTables[tableName]"
          @click="toggleTableExpanded(tableName)"
        >
          <span
            class="mt-0.5 size-4 shrink-0 text-n-slate-10 i-lucide-chevron-down transition-transform duration-200"
            :class="{ 'rotate-180': expandedTables[tableName] }"
          />

          <span class="min-w-0 flex-1">
            <span class="flex flex-wrap items-center gap-2">
              <span class="break-words text-sm font-medium text-n-slate-12">
                {{ tableMetadata[tableName].title }}
              </span>
              <span
                class="inline-flex items-center rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
              >
                {{
                  selectionCountLabel(
                    tableName,
                    normalizedAccess[tableName].fieldIds.length,
                    tableFieldCounts[tableName]
                  )
                }}
              </span>
            </span>
            <span class="mt-1 block break-words text-sm text-n-slate-11">
              {{ tableMetadata[tableName].description }}
            </span>
          </span>
        </button>

        <div class="shrink-0" @click.stop>
          <Switch
            :model-value="normalizedAccess[tableName].enabled"
            class="data-[state=checked]:!bg-n-violet-9"
            @update:model-value="value => updateTableEnabled(tableName, value)"
          />
        </div>
      </div>

      <div v-show="expandedTables[tableName]" class="flex flex-col gap-4">
        <div
          v-if="!normalizedAccess[tableName].enabled"
          class="text-xs text-n-slate-10"
        >
          {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.DISABLED_MESSAGE') }}
        </div>

        <div v-if="isLoading" class="text-sm text-n-slate-11">
          {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.LOADING') }}
        </div>

        <div
          v-else-if="normalizedAccess[tableName].enabled"
          class="grid grid-cols-1 gap-4 xl:grid-cols-2"
        >
          <div
            v-for="group in fieldsByTable[tableName]"
            :key="group.groupName"
            class="flex min-w-0 flex-col gap-3 rounded-lg border border-n-weak bg-n-alpha-2 p-3"
          >
            <div class="flex min-w-0 items-center gap-2">
              <div
                class="min-w-0 break-words text-sm font-medium text-n-slate-12"
              >
                {{ resolveGroupName(group.groupName) }}
              </div>
            </div>

            <div class="flex flex-col gap-2">
              <label
                v-for="field in group.fields"
                :key="field.id"
                class="flex min-w-0 items-start gap-2.5 rounded-md px-1 py-0.5 transition-colors hover:bg-n-alpha-3"
              >
                <span class="mt-0.5 shrink-0">
                  <Checkbox
                    :model-value="
                      normalizedAccess[tableName].fieldIds.includes(field.id)
                    "
                    @update:model-value="
                      value => toggleFieldSelection(tableName, field.id, value)
                    "
                  />
                </span>
                <span class="flex min-w-0 flex-col gap-0.5">
                  <span
                    class="break-words text-sm font-medium leading-5 text-n-slate-12"
                  >
                    {{ resolveFieldTitle(field) }}
                  </span>
                  <span class="break-words text-xs leading-4 text-n-slate-10">
                    {{ resolveFieldDescription(field) }}
                  </span>
                  <span
                    class="break-all font-mono text-[11px] leading-4 text-n-slate-9"
                  >
                    {{ resolveFieldVariable(field) }}
                  </span>
                </span>
              </label>
            </div>
          </div>

          <p
            v-if="!fieldsByTable[tableName]?.length"
            class="text-sm text-n-slate-11"
          >
            {{ t('CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.EMPTY') }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
