<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import ScenarioCustomFields from './ScenarioCustomFields.vue';

const props = defineProps({
  modelValue: { type: Object, required: true },
  disabled: { type: Boolean, default: false },
});
const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const jsonError = ref(false);
const advancedKeys = [
  'resources',
  'services',
  'pipelines',
  'stages',
  'companies',
  'staff',
  'teams',
  'labels',
  'channel_templates',
  'touch_plans',
  'touch_plan_enrollments',
  'tasks',
  'task_statuses',
  'task_types',
  'task_outcomes',
  'messages',
  'touches',
  'timelines',
  'notifications',
  'selection',
  'inbox',
  'knowledge_documents',
  'knowledge_chunks',
  'faq_responses',
  'articles',
  'categories',
  'canned_responses',
];
const advancedJSON = computed(() =>
  JSON.stringify(
    Object.fromEntries(
      advancedKeys
        .filter(key => props.modelValue[key])
        .map(key => [key, props.modelValue[key]])
    ),
    null,
    2
  )
);
const updateAdvanced = value => {
  try {
    const attributes = JSON.parse(value);
    if (
      !attributes ||
      typeof attributes !== 'object' ||
      Array.isArray(attributes)
    )
      throw new Error('object');
    emit('update:modelValue', {
      ...props.modelValue,
      ...Object.fromEntries(
        advancedKeys
          .filter(key => attributes[key])
          .map(key => [key, attributes[key]])
      ),
    });
    jsonError.value = false;
  } catch {
    jsonError.value = true;
  }
};
const draft = computed(() => props.modelValue);
const inputClass =
  'mb-0 w-full rounded-lg border border-n-weak bg-n-background px-2 py-1.5 text-sm text-n-slate-12';
const contacts = computed(() => [
  { record: draft.value.contact || {}, group: 'contact', index: null },
  ...(draft.value.patients || []).map((record, index) => ({
    record,
    group: 'patients',
    index,
  })),
]);
const allContacts = computed(() =>
  [draft.value.contact, ...(draft.value.patients || [])].filter(
    record => record?.id
  )
);
const fields = kind =>
  (draft.value.custom_fields || []).filter(
    field => field.entity_kind === kind && field.active !== false
  );
const update = (group, index, field, value) => {
  if (index === null)
    emit('update:modelValue', {
      ...draft.value,
      [group]: { ...draft.value[group], [field]: value },
    });
  else
    emit('update:modelValue', {
      ...draft.value,
      [group]: draft.value[group].map((record, position) =>
        position === index ? { ...record, [field]: value } : record
      ),
    });
};
const updateAttribute = (item, field, value) =>
  update(item.group, item.index, 'custom_attributes', {
    ...item.record.custom_attributes,
    [field]: value,
  });
const add = group => {
  const template = JSON.parse(JSON.stringify(draft.value[group]?.[0] || {}));
  delete template.id;
  if (group === 'patients') {
    template.name = '';
    template.identifier = '';
    template.phone_number = '';
    template.custom_attributes = {};
  }
  if (group === 'deals') template.title = '';
  emit('update:modelValue', {
    ...draft.value,
    [group]: [...(draft.value[group] || []), template],
  });
};
const appointmentServices = record => {
  const resource = draft.value.resources?.find(
    item => item.id === record.resource_id
  );
  return (draft.value.services || []).filter(
    service => !resource || resource.service_ids.includes(service.id)
  );
};
const updateResource = (index, resourceId) => {
  const resource = draft.value.resources.find(item => item.id === resourceId);
  const appointment = draft.value.appointments[index];
  const serviceId = resource.service_ids.includes(appointment.service_id)
    ? appointment.service_id
    : resource.service_ids[0];
  emit('update:modelValue', {
    ...draft.value,
    appointments: draft.value.appointments.map((record, position) =>
      position === index
        ? { ...record, resource_id: resourceId, service_id: serviceId }
        : record
    ),
  });
};
const updateDatetime = (index, value) => {
  if (!value) return;
  const record = draft.value.appointments[index];
  const offset = record.starts_at?.match(/(?:Z|[+-]\d{2}:\d{2})$/)?.[0] || 'Z';
  const startsAt = `${value}:00${offset}`;
  emit('update:modelValue', {
    ...draft.value,
    appointments: draft.value.appointments.map((item, position) =>
      position === index
        ? {
            ...item,
            starts_at: startsAt,
            ends_at: new Date(
              Date.parse(startsAt) + (record.duration_min || 30) * 60000
            ).toISOString(),
          }
        : item
    ),
  });
};
const updateDuration = (index, value) => {
  const record = draft.value.appointments[index];
  const duration = Number(value);
  if (
    !Number.isInteger(duration) ||
    duration < 5 ||
    duration > 1440 ||
    !Number.isFinite(Date.parse(record.starts_at))
  )
    return;
  emit('update:modelValue', {
    ...draft.value,
    appointments: draft.value.appointments.map((item, position) =>
      position === index
        ? {
            ...item,
            duration_min: duration,
            ends_at: new Date(
              Date.parse(record.starts_at) + duration * 60000
            ).toISOString(),
          }
        : item
    ),
  });
};
const minute = value => {
  const [hours, minutes] = value.split(':').map(Number);
  return hours * 60 + minutes;
};
const clock = value =>
  `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;
const updateRule = (resourceIndex, ruleIndex, field, value) => {
  const resource = draft.value.resources[resourceIndex];
  update(
    'resources',
    resourceIndex,
    'work_rules',
    resource.work_rules.map((rule, index) =>
      index === ruleIndex ? { ...rule, [field]: value } : rule
    )
  );
};
defineExpose({ update, add, updateDatetime });
</script>

<template>
  <div class="space-y-4" data-test="playground-scenario-editor">
    <p class="mb-0 text-xs text-n-slate-11">
      {{ t('CAPTAIN.PLAYGROUND.SCENARIO_ISOLATION') }}
    </p>
    <div class="grid gap-4 md:grid-cols-2">
      <fieldset
        v-for="item in contacts"
        :key="item.record.id || `patient-${item.index}`"
        class="m-0 min-w-0 rounded-lg border border-n-weak p-3"
        :disabled="disabled"
      >
        <legend class="px-1 text-xs font-medium">
          {{
            t(
              item.group === 'contact'
                ? 'CAPTAIN.PLAYGROUND.SCENARIO_CONTACT'
                : 'CAPTAIN.PLAYGROUND.SCENARIO_PATIENT'
            )
          }}
        </legend>
        <div class="grid gap-3 sm:grid-cols-2">
          <label
            class="flex flex-col gap-1 text-xs text-n-slate-11 sm:col-span-2"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_NAME') }}
            <input
              :value="item.record.name"
              :class="inputClass"
              @input="
                update(item.group, item.index, 'name', $event.target.value)
              "
          /></label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_PHONE') }}
            <input
              :value="item.record.phone_number"
              :class="inputClass"
              @input="
                update(
                  item.group,
                  item.index,
                  'phone_number',
                  $event.target.value
                )
              "
          /></label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_IIN') }}
            <input
              :value="item.record.identifier"
              :class="inputClass"
              @input="
                update(
                  item.group,
                  item.index,
                  'identifier',
                  $event.target.value
                )
              "
          /></label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_BIRTH_DATE') }}
            <input
              type="date"
              :value="item.record.custom_attributes?.birth_date"
              :class="inputClass"
              @input="updateAttribute(item, 'birth_date', $event.target.value)"
          /></label>
        </div>
      </fieldset>
      <fieldset
        v-for="(record, index) in draft.deals || []"
        :key="record.id || `deal-${index}`"
        class="m-0 min-w-0 space-y-3 rounded-lg border border-n-weak p-3"
        :disabled="disabled"
      >
        <legend class="px-1 text-xs font-medium">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_DEAL') }}
        </legend>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11"
          >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_TITLE') }}
          <input
            :value="record.title"
            :class="inputClass"
            @input="update('deals', index, 'title', $event.target.value)"
        /></label>
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_AMOUNT') }}
            <input
              type="number"
              min="0"
              :value="record.amount"
              :class="inputClass"
              @input="
                update('deals', index, 'amount', Number($event.target.value))
              "
          /></label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_STAGE') }}
            <select
              :value="record.stage_id"
              :class="inputClass"
              @change="
                update('deals', index, 'stage_id', Number($event.target.value))
              "
            >
              <option
                v-for="stage in (draft.stages || []).filter(
                  stage => stage.pipeline_id === record.pipeline_id
                )"
                :key="stage.id"
                :value="stage.id"
              >
                {{ stage.name }}
              </option>
            </select></label
          >
        </div>
        <ScenarioCustomFields
          :model-value="record.custom_attributes"
          :fields="fields('deal')"
          :disabled="disabled"
          @update:model-value="
            update('deals', index, 'custom_attributes', $event)
          "
        />
      </fieldset>
      <fieldset
        v-for="(record, index) in draft.appointments || []"
        :key="record.id || `appointment-${index}`"
        class="m-0 min-w-0 space-y-3 rounded-lg border border-n-weak p-3"
        :disabled="disabled"
      >
        <legend class="px-1 text-xs font-medium">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_APPOINTMENT') }}
        </legend>
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_PATIENT') }}
            <select
              :value="record.patient_contact_id"
              :class="inputClass"
              @change="
                update(
                  'appointments',
                  index,
                  'patient_contact_id',
                  Number($event.target.value)
                )
              "
            >
              <option
                v-for="contact in allContacts"
                :key="contact.id"
                :value="contact.id"
              >
                {{ contact.name }}
              </option>
            </select></label
          >
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_DOCTOR') }}
            <select
              :value="record.resource_id"
              :class="inputClass"
              @change="updateResource(index, Number($event.target.value))"
            >
              <option
                v-for="resource in draft.resources || []"
                :key="resource.id"
                :value="resource.id"
              >
                {{ resource.name }}
              </option>
            </select></label
          >
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_SERVICE') }}
            <select
              :value="record.service_id"
              :class="inputClass"
              @change="
                update(
                  'appointments',
                  index,
                  'service_id',
                  Number($event.target.value)
                )
              "
            >
              <option
                v-for="service in appointmentServices(record)"
                :key="service.id"
                :value="service.id"
              >
                {{ service.name }}
              </option>
            </select></label
          >
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_DATETIME') }}
            <input
              type="datetime-local"
              :value="record.starts_at?.slice(0, 16)"
              :class="inputClass"
              @input="updateDatetime(index, $event.target.value)"
          /></label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_DURATION') }}
            <input
              type="number"
              min="5"
              max="1440"
              :value="record.duration_min"
              :class="inputClass"
              @change="updateDuration(index, $event.target.value)"
          /></label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11"
            >{{ t('CAPTAIN.PLAYGROUND.SCENARIO_STATUS') }}
            <select
              :value="record.status"
              :class="inputClass"
              @change="
                update('appointments', index, 'status', $event.target.value)
              "
            >
              <option
                v-for="status in [
                  'scheduled',
                  'completed',
                  'cancelled',
                  'no_show',
                ]"
                :key="status"
                :value="status"
              >
                {{ t(`CAPTAIN.PLAYGROUND.STATUSES.${status.toUpperCase()}`) }}
              </option>
            </select></label
          >
        </div>
        <ScenarioCustomFields
          :model-value="record.custom_attributes"
          :fields="fields('appointment')"
          :disabled="disabled"
          @update:model-value="
            update('appointments', index, 'custom_attributes', $event)
          "
        />
      </fieldset>
    </div>
    <div class="flex flex-wrap gap-2">
      <Button
        v-for="group in ['patients', 'deals', 'appointments']"
        :key="group"
        variant="outline"
        color="slate"
        size="sm"
        icon="i-lucide-plus"
        :label="t(`CAPTAIN.PLAYGROUND.ADD_${group.toUpperCase()}`)"
        :disabled="disabled || (draft[group]?.length || 0) >= 30"
        :data-test="`scenario-add-${group}`"
        @click="add(group)"
      />
    </div>
    <details class="rounded-lg border border-n-weak p-3">
      <summary class="cursor-pointer text-xs font-medium">
        {{ t('CAPTAIN.PLAYGROUND.SCENARIO_CALENDAR') }}
      </summary>
      <div
        v-for="(resource, index) in draft.resources || []"
        :key="resource.id"
        class="mt-3"
      >
        <p class="mb-2 text-sm">{{ resource.name }}</p>
        <div
          v-for="(rule, ruleIndex) in resource.work_rules || []"
          :key="ruleIndex"
          class="mb-2 flex items-center gap-2"
        >
          <label class="flex flex-1 items-center gap-2 text-xs">
            <input
              type="checkbox"
              :checked="rule.active !== false"
              :disabled="disabled"
              @change="
                updateRule(index, ruleIndex, 'active', $event.target.checked)
              "
            />
            {{ t(`CAPTAIN.PLAYGROUND.WEEKDAY_${rule.weekday}`) }}
          </label>
          <input
            type="time"
            :value="clock(rule.start_minute)"
            :class="inputClass"
            class="max-w-28"
            :disabled="disabled"
            :aria-label="t('CAPTAIN.PLAYGROUND.CALENDAR_START')"
            @input="
              updateRule(
                index,
                ruleIndex,
                'start_minute',
                minute($event.target.value)
              )
            "
          />
          <input
            type="time"
            :value="clock(rule.end_minute)"
            :class="inputClass"
            class="max-w-28"
            :disabled="disabled"
            :aria-label="t('CAPTAIN.PLAYGROUND.CALENDAR_END')"
            @input="
              updateRule(
                index,
                ruleIndex,
                'end_minute',
                minute($event.target.value)
              )
            "
          />
        </div>
      </div>
    </details>
    <details class="rounded-lg border border-n-weak p-3">
      <summary class="cursor-pointer text-xs font-medium">
        {{ t('CAPTAIN.PLAYGROUND.SCENARIO_ADVANCED') }}
      </summary>
      <textarea
        :value="advancedJSON"
        :class="inputClass"
        class="mt-3 min-h-40 font-mono text-xs"
        :disabled="disabled"
        :aria-label="t('CAPTAIN.PLAYGROUND.SCENARIO_ADVANCED')"
        @change="updateAdvanced($event.target.value)"
      />
      <p v-if="jsonError" class="mb-0 mt-1 text-xs text-n-ruby-11" role="alert">
        {{ t('CAPTAIN.PLAYGROUND.SCENARIO_INVALID_JSON') }}
      </p>
    </details>
  </div>
</template>
