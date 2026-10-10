<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  modelValue: { type: Object, required: true },
  mode: { type: String, required: true },
  disabled: { type: Boolean, default: false },
});
const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const inputClass = 'mb-0 w-full rounded-lg border border-n-weak bg-n-background px-2 py-1.5 text-sm text-n-slate-12';
const draft = computed(() => props.modelValue);
const appointmentServices = computed(() => {
  const resource = draft.value.resources?.find(item => item.id === draft.value.appointment?.resource_id);
  return (draft.value.services || []).filter(service => !resource || resource.service_ids.includes(service.id));
});

const update = (group, field, value) => {
  emit('update:modelValue', {
    ...draft.value,
    [group]: { ...draft.value[group], [field]: value },
  });
};

const updatePatientAttribute = (group, field, value) => {
  const record = draft.value[group] || {};
  update(group, 'custom_attributes', { ...record.custom_attributes, [field]: value });
};

const localDatetime = value => (value ? value.slice(0, 16) : '');
const updateDatetime = value => {
  if (!value) return;
  const oldValue = draft.value.appointment?.starts_at || '';
  const offset = oldValue.match(/(?:Z|[+-]\d{2}:\d{2})$/)?.[0] || 'Z';
  const startsAt = `${value}:00${offset}`;
  emit('update:modelValue', {
    ...draft.value,
    appointment: {
      ...draft.value.appointment,
      starts_at: startsAt,
      ends_at: new Date(Date.parse(startsAt) + (draft.value.appointment?.duration_min || 30) * 60000).toISOString(),
    },
  });
};

const updateIin = (group, value) => {
  const record = draft.value[group] || {};
  emit('update:modelValue', {
    ...draft.value,
    [group]: {
      ...record,
      ...(props.mode === 'trial' ? { identifier: value } : {}),
      custom_attributes: { ...record.custom_attributes, iin: value },
    },
  });
};

const updateResource = resourceId => {
  const resource = draft.value.resources?.find(item => item.id === resourceId);
  const serviceId = resource?.service_ids.includes(draft.value.appointment?.service_id)
    ? draft.value.appointment.service_id
    : resource?.service_ids[0];
  emit('update:modelValue', {
    ...draft.value,
    appointment: { ...draft.value.appointment, resource_id: resourceId, service_id: serviceId },
  });
};

defineExpose({ update, updateDatetime });
</script>

<template>
  <div class="grid gap-4 md:grid-cols-2" data-test="playground-scenario-editor">
    <fieldset
      v-for="group in mode === 'trial' ? ['contact', 'patient'] : ['contact']"
      :key="group"
      class="m-0 min-w-0 rounded-lg border border-n-weak p-3"
      :disabled="disabled"
    >
      <legend class="px-1 text-xs font-medium text-n-slate-12">
        {{ t(`CAPTAIN.PLAYGROUND.SCENARIO_${group.toUpperCase()}`) }}
      </legend>
      <div class="grid gap-3 sm:grid-cols-2">
        <label class="flex flex-col gap-1 text-xs text-n-slate-11 sm:col-span-2">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_NAME') }}
          <input
            :value="draft[group]?.name"
            :class="inputClass"
            :data-test="`scenario-${group}-name`"
            @input="update(group, 'name', $event.target.value)"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_PHONE') }}
          <input
            :value="draft[group]?.phone_number"
            :class="inputClass"
            :data-test="`scenario-${group}-phone`"
            @input="update(group, 'phone_number', $event.target.value)"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_IIN') }}
          <input
            :value="draft[group]?.custom_attributes?.iin || (mode === 'trial' ? draft[group]?.identifier : '')"
            :class="inputClass"
            :data-test="`scenario-${group}-iin`"
            @input="updateIin(group, $event.target.value)"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_BIRTH_DATE') }}
          <input
            type="date"
            :value="draft[group]?.custom_attributes?.birth_date"
            :class="inputClass"
            @input="updatePatientAttribute(group, 'birth_date', $event.target.value)"
          />
        </label>
      </div>
    </fieldset>

    <fieldset v-if="mode === 'trial' && draft.deal" class="m-0 min-w-0 rounded-lg border border-n-weak p-3" :disabled="disabled">
      <legend class="px-1 text-xs font-medium text-n-slate-12">
        {{ t('CAPTAIN.PLAYGROUND.SCENARIO_DEAL') }}
      </legend>
      <div class="grid gap-3 sm:grid-cols-2">
        <label class="flex flex-col gap-1 text-xs text-n-slate-11 sm:col-span-2">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_TITLE') }}
          <input :value="draft.deal.title" :class="inputClass" @input="update('deal', 'title', $event.target.value)" />
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_AMOUNT') }}
          <input type="number" min="0" :value="draft.deal.amount" :class="inputClass" @input="update('deal', 'amount', Number($event.target.value))" />
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_STAGE') }}
          <select :value="draft.deal.stage_id" :class="inputClass" @change="update('deal', 'stage_id', Number($event.target.value))">
            <option v-for="stage in draft.stages || []" :key="stage.id" :value="stage.id">{{ stage.name }}</option>
          </select>
        </label>
      </div>
    </fieldset>

    <fieldset v-if="mode === 'trial' && draft.appointment" class="m-0 min-w-0 rounded-lg border border-n-weak p-3" :disabled="disabled">
      <legend class="px-1 text-xs font-medium text-n-slate-12">
        {{ t('CAPTAIN.PLAYGROUND.SCENARIO_APPOINTMENT') }}
      </legend>
      <div class="grid gap-3 sm:grid-cols-2">
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_DOCTOR') }}
          <select :value="draft.appointment.resource_id" :class="inputClass" data-test="scenario-appointment-resource" @change="updateResource(Number($event.target.value))">
            <option v-for="resource in draft.resources || []" :key="resource.id" :value="resource.id">{{ resource.name }}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_SERVICE') }}
          <select :value="draft.appointment.service_id" :class="inputClass" @change="update('appointment', 'service_id', Number($event.target.value))">
            <option v-for="service in appointmentServices" :key="service.id" :value="service.id">{{ service.name }}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-xs text-n-slate-11 sm:col-span-2">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_DATETIME') }}
          <input type="datetime-local" :value="localDatetime(draft.appointment.starts_at)" :class="inputClass" @input="updateDatetime($event.target.value)" />
        </label>
      </div>
    </fieldset>
  </div>
</template>
