<script setup>
import Modal from 'dashboard/components/Modal.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  BaseTable,
  BaseTableCell,
  BaseTableRow,
} from 'dashboard/components-next/table';

defineProps({
  modelValue: {
    type: Boolean,
    default: false,
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  plans: {
    type: Array,
    default: () => [],
  },
  mutatingPlanId: {
    type: [Number, String, null],
    default: null,
  },
  hasEntityContext: {
    type: Boolean,
    default: false,
  },
  emptyMessage: {
    type: String,
    default: '',
  },
  loadingMessage: {
    type: String,
    default: '',
  },
  noDescriptionLabel: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  createLabel: {
    type: String,
    default: '',
  },
  refreshLabel: {
    type: String,
    default: '',
  },
  editLabel: {
    type: String,
    default: '',
  },
  applyLabel: {
    type: String,
    default: '',
  },
  archiveLabel: {
    type: String,
    default: '',
  },
  activeLabel: {
    type: String,
    default: '',
  },
  archivedLabel: {
    type: String,
    default: '',
  },
  headers: {
    type: Array,
    default: () => [],
  },
  formatEntityKinds: {
    type: Function,
    required: true,
  },
  previewPlan: {
    type: Function,
    required: true,
  },
});

const emit = defineEmits([
  'archive',
  'apply',
  'close',
  'create',
  'edit',
  'refresh',
  'update:modelValue',
]);
</script>

<template>
  <Modal
    :show="modelValue"
    size="medium"
    @update:show="emit('update:modelValue', $event)"
    @close="
      emit('update:modelValue', false);
      emit('close');
    "
  >
    <div class="flex max-h-[80vh] flex-col overflow-hidden">
      <div class="border-b border-n-weak px-8 pb-5 pt-8">
        <div
          class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between"
        >
          <div class="min-w-0">
            <h3 class="mb-1 text-xl font-semibold text-n-slate-12">
              {{ title }}
            </h3>
            <p class="mb-0 text-sm leading-6 text-n-slate-11">
              {{ description }}
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              slate
              :label="refreshLabel"
              @click="emit('refresh')"
            />
            <Button size="sm" :label="createLabel" @click="emit('create')" />
          </div>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto px-8 pb-8 pt-5">
        <div
          v-if="isLoading"
          class="rounded-3xl bg-n-surface-2 px-6 py-12 text-center outline outline-1 outline-n-container shadow-sm"
        >
          <p class="mb-0 text-sm text-n-slate-11">
            {{ loadingMessage }}
          </p>
        </div>

        <BaseTable
          v-else
          :headers="headers"
          :items="plans"
          :no-data-message="emptyMessage"
        >
          <template #row="{ items }">
            <BaseTableRow
              v-for="touchPlan in items"
              :key="touchPlan.id"
              :item="touchPlan"
            >
              <template #default>
                <BaseTableCell class="max-w-0">
                  <div class="grid gap-1.5 min-w-0">
                    <span class="text-heading-3 text-n-slate-12 truncate">
                      {{ touchPlan.name }}
                    </span>
                    <p class="mb-0 text-body-main text-n-slate-11 line-clamp-2">
                      {{ touchPlan.description || noDescriptionLabel }}
                    </p>
                  </div>
                </BaseTableCell>

                <BaseTableCell class="text-n-slate-11">
                  <div class="grid gap-1">
                    <span class="text-sm text-n-slate-12">
                      {{ formatEntityKinds(touchPlan.entity_kinds) || '—' }}
                    </span>
                    <span class="text-xs text-n-slate-10">
                      {{ previewPlan(touchPlan) }}
                    </span>
                  </div>
                </BaseTableCell>

                <BaseTableCell>
                  <span
                    class="inline-flex rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="
                      touchPlan.active
                        ? 'bg-n-teal-9/10 text-n-teal-11'
                        : 'bg-n-alpha-2 text-n-slate-11'
                    "
                  >
                    {{ touchPlan.active ? activeLabel : archivedLabel }}
                  </span>
                </BaseTableCell>

                <BaseTableCell align="end" class="w-56">
                  <div class="flex flex-wrap justify-end gap-2">
                    <Button
                      v-if="touchPlan.active"
                      size="sm"
                      slate
                      :label="editLabel"
                      @click="emit('edit', touchPlan)"
                    />
                    <Button
                      v-if="touchPlan.active && hasEntityContext"
                      size="sm"
                      slate
                      :label="applyLabel"
                      :is-loading="mutatingPlanId === touchPlan.id"
                      @click="emit('apply', touchPlan)"
                    />
                    <Button
                      v-if="touchPlan.active"
                      size="sm"
                      ruby
                      faded
                      :label="archiveLabel"
                      :is-loading="mutatingPlanId === touchPlan.id"
                      @click="emit('archive', touchPlan)"
                    />
                  </div>
                </BaseTableCell>
              </template>
            </BaseTableRow>
          </template>
        </BaseTable>
      </div>
    </div>
  </Modal>
</template>
