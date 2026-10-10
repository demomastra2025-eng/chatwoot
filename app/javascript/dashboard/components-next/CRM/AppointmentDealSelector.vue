<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useMapGetter } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  modelValue: { type: Object, default: () => ({}) },
  communicationContactId: { type: [Number, String], default: '' },
  conversationDisplayId: { type: [Number, String], default: '' },
  sourceDealId: { type: [Number, String], default: '' },
  disabled: { type: Boolean, default: false },
});
const emit = defineEmits(['update:modelValue']);
const route = useRoute();
const { t } = useI18n();
const featureEnabled = useMapGetter('accounts/isFeatureEnabledonAccount');
const accountId = computed(() => String(route.params.accountId || ''));
const enabled = computed(() => featureEnabled.value?.(accountId.value, FEATURE_FLAGS.CRM_DEALS));
const data = ref({ deals: [], pipelines: [] });
const error = ref(false);
const loading = ref(false);
let generation = 0;
const emptySelection = () => ({ crm_deal_id: null, crm_pipeline_id: null, crm_deal_selection: null });
const value = computed(() => {
  if (props.modelValue.crm_deal_id) return `deal:${props.modelValue.crm_deal_id}`;
  if (props.modelValue.crm_deal_selection === 'create') return `create:${props.modelValue.crm_pipeline_id}`;
  return '';
});
const options = computed(() => [
  ...data.value.deals.map(deal => ({ label: [deal.title, deal.pipeline_name].filter(Boolean).join(' · '), value: `deal:${deal.id}` })),
  ...data.value.pipelines.map(pipeline => ({ label: t('CRM.APPOINTMENT_DEAL.CREATE_IN', { pipeline: pipeline.name }), value: `create:${pipeline.id}` })),
]);
const visible = computed(() => enabled.value && (data.value.requires_selection || props.modelValue.crm_deal_selection === 'create' || error.value));
const select = selection => {
  const [kind, id] = String(selection || '').split(':');
  const deal = data.value.deals.find(item => String(item.id) === id);
  let next = emptySelection();
  if (kind === 'deal' && deal) {
    next = { crm_deal_id: deal.id, crm_pipeline_id: deal.pipeline_id, crm_deal_selection: null };
  } else if (kind === 'create' && data.value.pipelines.some(item => String(item.id) === id)) {
    next = { crm_deal_id: null, crm_pipeline_id: Number(id), crm_deal_selection: 'create' };
  }
  emit('update:modelValue', next);
};
const load = async () => {
  generation += 1;
  const request = generation;
  const account = accountId.value;
  data.value = { deals: [], pipelines: [] };
  error.value = false;
  loading.value = false;
  emit('update:modelValue', emptySelection());
  if (!enabled.value || !props.communicationContactId) return;
  loading.value = true;
  try {
    const response = await CrmDealsAPI.appointmentOptions({
      contact_id: props.communicationContactId,
      conversation_display_id: props.conversationDisplayId || undefined,
      source_deal_id: props.sourceDealId || undefined,
    });
    if (generation !== request || accountId.value !== account) return;
    data.value = response.data.payload;
    if (data.value.automatic_deal_id) select(`deal:${data.value.automatic_deal_id}`);
  } catch {
    if (generation === request && accountId.value === account) error.value = true;
  } finally {
    if (generation === request) loading.value = false;
  }
};
watch([accountId, enabled, () => props.communicationContactId, () => props.conversationDisplayId, () => props.sourceDealId], load, { immediate: true });
onBeforeUnmount(() => { generation += 1; });
</script>

<template>
  <div v-if="visible" class="grid gap-2" data-testid="appointment-deal-selector">
    <SchedulingSelectField
      v-if="!error"
      :model-value="value"
      :options="options"
      :disabled="disabled || loading"
      :label="$t('CRM.APPOINTMENT_DEAL.LABEL')"
      :placeholder="$t('CRM.APPOINTMENT_DEAL.CHOOSE')"
      @update:model-value="select"
    />
    <p class="m-0 text-xs text-n-slate-10">{{ error ? $t('CRM.APPOINTMENT_DEAL.LOAD_ERROR') : $t('CRM.APPOINTMENT_DEAL.MULTIPLE') }}</p>
    <Button v-if="error" size="xs" variant="ghost" :label="$t('CRM.GENERAL.RETRY')" @click="load" />
  </div>
</template>
