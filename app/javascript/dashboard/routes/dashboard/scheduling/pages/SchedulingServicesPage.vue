<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingDurationInput from 'dashboard/components-next/Scheduling/SchedulingDurationInput.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingPercentInput from 'dashboard/components-next/Scheduling/SchedulingPercentInput.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import { COMPENSATION_TYPE_VALUES } from '../constants';
import {
  extractSchedulingError,
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import { formatCurrency } from '../helpers';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t } = useI18n();

const referencesStore = useSchedulingReferencesStore();
const serviceDrawerOpen = ref(false);

const serviceForm = reactive({
  active: true,
  basePrice: 0,
  category: '',
  description: '',
  direction: '',
  durationMin: 30,
  id: null,
  name: '',
  prices: [],
  serviceType: '',
});

const compensationTypeLabels = computed(() => ({
  fixed: t('SCHEDULING.COMPENSATION.fixed'),
  fixed_plus_percent: t('SCHEDULING.COMPENSATION.fixed_plus_percent'),
  percent: t('SCHEDULING.COMPENSATION.percent'),
}));

const compensationPrimaryLabel = type => {
  if (type === 'percent') return t('SCHEDULING.COMPENSATION.percent_value');

  return t('SCHEDULING.COMPENSATION.fixed_value');
};

const compensationTypeOptions = computed(() =>
  COMPENSATION_TYPE_VALUES.map(value => ({
    label: compensationTypeLabels.value[value] || value,
    value,
  }))
);

const serviceCards = computed(() => referencesStore.services);
const resources = computed(() => referencesStore.resources);

const serviceColumns = computed(() => [
  { key: 'name', label: t('SCHEDULING.SERVICES.NAME'), width: '1.6fr' },
  {
    key: 'duration',
    label: t('SCHEDULING.SERVICES.DURATION_TABLE'),
    width: '96px',
  },
  {
    key: 'basePrice',
    label: t('SCHEDULING.SERVICES.BASE_PRICE_TABLE'),
    width: '128px',
  },
  {
    key: 'pricing',
    label: t('SCHEDULING.SERVICES.PRICING_TITLE'),
    width: '1fr',
  },
  { key: 'status', label: t('SCHEDULING.GENERAL.STATUS'), width: '96px' },
  { key: 'actions', label: '', width: '112px', align: 'end' },
]);

const initializePriceRows = prices => {
  return resources.value.map(resource => {
    const matchingPrice = prices.find(
      item => Number(item.resourceId) === Number(resource.id)
    );

    return {
      active: matchingPrice?.active ?? false,
      compensationType:
        matchingPrice?.compensationType ||
        resource.compensationType ||
        'percent',
      compensationPercent:
        matchingPrice?.compensationPercent ?? resource.compensationPercent ?? 0,
      compensationValue:
        matchingPrice?.compensationValue ?? resource.compensationValue ?? 0,
      price: matchingPrice?.price || '',
      resourceId: resource.id,
      resourceName: resource.name,
    };
  });
};

const resetForm = () => {
  Object.assign(serviceForm, {
    active: true,
    basePrice: 0,
    category: '',
    description: '',
    direction: '',
    durationMin: 30,
    id: null,
    name: '',
    prices: initializePriceRows([]),
    serviceType: '',
  });
};

const openCreateService = () => {
  resetForm();
  serviceDrawerOpen.value = true;
};

const openEditService = service => {
  Object.assign(serviceForm, {
    active: service.active,
    basePrice: service.basePrice || 0,
    category: service.category || '',
    description: service.description || '',
    direction: service.direction || '',
    durationMin: service.durationMin || 30,
    id: service.id,
    name: service.name,
    prices: initializePriceRows(service.prices || []),
    serviceType: service.serviceType || '',
  });
  serviceDrawerOpen.value = true;
};

const closeDrawer = () => {
  serviceDrawerOpen.value = false;
  resetForm();
};

const saveService = async () => {
  try {
    await referencesStore.saveService({
      active: serviceForm.active,
      base_price: toNumeric(serviceForm.basePrice) || 0,
      category: serviceForm.category,
      description: serviceForm.description,
      direction: serviceForm.direction,
      duration_min: toNumeric(serviceForm.durationMin) || 30,
      id: serviceForm.id,
      name: serviceForm.name,
      prices: serviceForm.prices
        .filter(price => price.active || price.price)
        .map(price => ({
          active: price.active,
          compensation_percent: toNumeric(price.compensationPercent) || 0,
          compensation_type: price.compensationType,
          compensation_value: toNumeric(price.compensationValue) || 0,
          price: toNumeric(price.price) || 0,
          resource_id: price.resourceId,
        })),
      service_type: serviceForm.serviceType,
    });
    useAlert(t('SCHEDULING.SERVICES.SUCCESS_SAVE'));
    closeDrawer();
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const toggleActive = async service => {
  try {
    await referencesStore.saveService({
      active: !service.active,
      base_price: service.basePrice,
      category: service.category,
      description: service.description,
      direction: service.direction,
      duration_min: service.durationMin,
      id: service.id,
      name: service.name,
      service_type: service.serviceType,
    });
    useAlert(t('SCHEDULING.SERVICES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const deleteService = async service => {
  try {
    await referencesStore.deleteService(service.id);
    useAlert(t('SCHEDULING.SERVICES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(extractSchedulingError(error).message);
  }
};

const servicePriceSummary = service => {
  const activePrices = (service.prices || []).filter(price => price.active);
  if (!activePrices.length) return '—';

  return activePrices
    .slice(0, 2)
    .map(price => {
      const resourceName =
        resources.value.find(resource => resource.id === price.resourceId)
          ?.name || `#${price.resourceId}`;
      return `${resourceName}: ${formatCurrency(price.price)}`;
    })
    .join(' · ');
};

onMounted(async () => {
  await Promise.all([
    referencesStore.loadResources({ include_inactive: true }),
    referencesStore.loadServices({ include_inactive: true }),
  ]);
  if (!serviceForm.prices.length) {
    serviceForm.prices = initializePriceRows([]);
  }
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-y-auto bg-n-surface-1">
    <SchedulingPageHeader :title="$t('SCHEDULING.NAV.SERVICES')">
      <template #actions>
        <Button
          size="sm"
          icon="i-lucide-plus"
          :label="$t('SCHEDULING.SERVICES.ADD')"
          @click="openCreateService"
        />
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-5 pb-5 pt-3">
      <div
        v-if="
          referencesStore.ui.isLoadingServices ||
          referencesStore.ui.isLoadingResources
        "
        class="flex justify-center py-16"
      >
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="referencesStore.ui.error"
        :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
        :description="referencesStore.ui.error.message"
        @retry="
          Promise.all([
            referencesStore.loadResources({ include_inactive: true }),
            referencesStore.loadServices({ include_inactive: true }),
          ])
        "
      />

      <SchedulingEmptyState
        v-else-if="serviceCards.length === 0"
        :title="$t('SCHEDULING.SERVICES.EMPTY_TITLE')"
        :description="$t('SCHEDULING.SERVICES.EMPTY_DESCRIPTION')"
        :action-label="$t('SCHEDULING.SERVICES.ADD')"
        @action="openCreateService"
      />

      <SchedulingRecordTable
        v-else
        :columns="serviceColumns"
        :rows="serviceCards"
      >
        <template #cell-name="{ row }">
          <div class="min-w-0">
            <div class="truncate font-medium text-n-slate-12">
              {{ row.name }}
            </div>
            <div class="truncate text-xs text-n-slate-11">
              {{
                [row.serviceType, row.category, row.direction]
                  .filter(Boolean)
                  .join(' · ') || '—'
              }}
            </div>
          </div>
        </template>

        <template #cell-duration="{ row }">
          {{ row.durationMin }} {{ $t('SCHEDULING.GENERAL.MINUTES') }}
        </template>

        <template #cell-basePrice="{ row }">
          {{ formatCurrency(row.basePrice) }}
        </template>

        <template #cell-pricing="{ row }">
          <div class="min-w-0">
            <div class="truncate text-sm">
              {{ servicePriceSummary(row) }}
            </div>
            <div class="truncate text-xs text-n-slate-11">
              {{ (row.prices || []).filter(price => price.active).length }}
              {{ $t('SCHEDULING.SERVICES.ACTIVE_PRICES_COUNT') }}
            </div>
          </div>
        </template>

        <template #cell-status="{ row }">
          <span
            class="px-2 py-1 text-xs rounded-full"
            :class="
              row.active
                ? 'bg-n-teal-4 text-n-teal-11'
                : 'bg-n-slate-4 text-n-slate-11'
            "
          >
            {{
              row.active
                ? $t('SCHEDULING.GENERAL.ACTIVE')
                : $t('SCHEDULING.GENERAL.INACTIVE')
            }}
          </span>
        </template>

        <template #cell-actions="{ row }">
          <div class="flex items-center justify-end gap-1">
            <Button
              size="sm"
              variant="ghost"
              color="slate"
              icon="i-lucide-pencil"
              :aria-label="$t('SCHEDULING.GENERAL.EDIT')"
              :title="$t('SCHEDULING.GENERAL.EDIT')"
              @click="openEditService(row)"
            />
            <Button
              size="sm"
              variant="ghost"
              color="slate"
              icon="i-lucide-power"
              :aria-label="
                row.active
                  ? $t('SCHEDULING.GENERAL.DEACTIVATE')
                  : $t('SCHEDULING.GENERAL.ACTIVATE')
              "
              :title="
                row.active
                  ? $t('SCHEDULING.GENERAL.DEACTIVATE')
                  : $t('SCHEDULING.GENERAL.ACTIVATE')
              "
              @click="toggleActive(row)"
            />
            <Button
              size="sm"
              variant="ghost"
              color="ruby"
              icon="i-lucide-trash-2"
              :aria-label="$t('SCHEDULING.GENERAL.DELETE')"
              :title="$t('SCHEDULING.GENERAL.DELETE')"
              @click="deleteService(row)"
            />
          </div>
        </template>
      </SchedulingRecordTable>
    </div>

    <SchedulingDrawer
      v-model="serviceDrawerOpen"
      width="xl"
      :title="
        serviceForm.id
          ? $t('SCHEDULING.SERVICES.EDIT')
          : $t('SCHEDULING.SERVICES.ADD')
      "
      :confirm-label="$t('SCHEDULING.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!serviceForm.name"
      @close="closeDrawer"
      @confirm="saveService"
    >
      <div class="flex flex-col gap-6">
        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.SERVICES.BASIC')"
          :description="$t('SCHEDULING.SERVICES.BASIC_DESCRIPTION')"
        >
          <template #headerActions>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <Switch v-model="serviceForm.active" />
              <span>{{ $t('SCHEDULING.GENERAL.ACTIVE') }}</span>
            </label>
          </template>

          <div class="grid gap-4 md:grid-cols-2">
            <Input
              v-model="serviceForm.name"
              :label="$t('SCHEDULING.SERVICES.NAME')"
            />
            <SchedulingMoneyInput
              v-model="serviceForm.basePrice"
              min="0"
              :label="$t('SCHEDULING.SERVICES.BASE_PRICE')"
            />
            <SchedulingDurationInput
              v-model="serviceForm.durationMin"
              min="5"
              :label="$t('SCHEDULING.SERVICES.DURATION')"
            />
            <Input
              v-model="serviceForm.category"
              :label="$t('SCHEDULING.SERVICES.CATEGORY')"
            />
            <Input
              v-model="serviceForm.direction"
              :label="$t('SCHEDULING.SERVICES.DIRECTION')"
            />
            <Input
              v-model="serviceForm.serviceType"
              :label="$t('SCHEDULING.SERVICES.TYPE')"
            />
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.SERVICES.PRICING_TITLE')"
          :description="$t('SCHEDULING.SERVICES.PRICING_DESCRIPTION')"
        >
          <div class="flex flex-col gap-4">
            <div
              v-for="price in serviceForm.prices"
              :key="price.resourceId"
              class="grid gap-4 rounded-2xl bg-n-surface-1 p-4 outline outline-1 outline-n-container"
              :class="
                price.compensationType === 'fixed_plus_percent'
                  ? 'lg:grid-cols-[minmax(0,1.2fr)_120px_180px_140px_140px]'
                  : 'lg:grid-cols-[minmax(0,1.2fr)_120px_180px_140px]'
              "
            >
              <div class="flex flex-col gap-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ price.resourceName }}
                </span>
                <label class="flex items-center gap-2 text-xs text-n-slate-11">
                  <Switch v-model="price.active" />
                  <span>{{ $t('SCHEDULING.GENERAL.ACTIVE') }}</span>
                </label>
              </div>
              <SchedulingMoneyInput
                v-model="price.price"
                min="0"
                :label="$t('SCHEDULING.SERVICES.PRICE')"
              />
              <div class="grid gap-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('SCHEDULING.RESOURCES.COMPENSATION') }}
                </span>
                <SchedulingSelectField
                  :model-value="price.compensationType"
                  :options="compensationTypeOptions"
                  :placeholder="$t('SCHEDULING.RESOURCES.COMPENSATION')"
                  @update:model-value="price.compensationType = $event"
                />
              </div>
              <SchedulingPercentInput
                v-if="price.compensationType === 'percent'"
                v-model="price.compensationValue"
                :label="$t('SCHEDULING.COMPENSATION.percent_value')"
              />
              <SchedulingMoneyInput
                v-else
                v-model="price.compensationValue"
                min="0"
                :label="compensationPrimaryLabel(price.compensationType)"
              />
              <SchedulingPercentInput
                v-if="price.compensationType === 'fixed_plus_percent'"
                v-model="price.compensationPercent"
                :label="$t('SCHEDULING.COMPENSATION.percent_value')"
              />
            </div>
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup>
          <TextArea
            v-model="serviceForm.description"
            auto-height
            :label="$t('SCHEDULING.GENERAL.DESCRIPTION')"
          />
        </SchedulingFormFieldGroup>
      </div>
    </SchedulingDrawer>
  </section>
</template>
