<script setup>
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';

defineProps({
  form: { type: Object, required: true },
  activityTypeOptions: { type: Array, default: () => [] },
  assigneeOptions: { type: Array, default: () => [] },
  taskPriorityOptions: { type: Array, default: () => [] },
  taskStatusOptions: { type: Array, default: () => [] },
  taskContextOptions: { type: Array, default: () => [] },
  dealOptions: { type: Array, default: () => [] },
  applicableTaskFieldDefinitions: { type: Array, default: () => [] },
  isEditing: { type: Boolean, default: false },
  updateFormActivityType: { type: Function, required: true },
  updateAllDay: { type: Function, required: true },
});
const emit = defineEmits(['update:field']);
</script>

<template>
  <div class="grid gap-4">
    <div v-if="form.originatingConversationId" class="flex flex-col gap-1">
      <p class="mb-0 text-heading-3 text-n-slate-12">
        {{ $t('CRM.GENERAL.LINKED_CONVERSATION') }}
      </p>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{
          [
            $t('CRM.TIMELINE.CONVERSATION', {
              id:
                form.originatingConversationDisplayId ||
                form.originatingConversationId,
            }),
            $t('CRM.GENERAL.CONVERSATION_SOURCE'),
          ].join(' · ')
        }}
      </p>
    </div>

    <SchedulingFormFieldGroup :framed="false">
      <div class="grid gap-4 md:grid-cols-2">
        <Input
          :label="$t('CRM.TASKS.FORM.TITLE')"
          :model-value="form.title"
          @update:model-value="emit('update:field', 'title', $event)"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.ACTIVITY_TYPE')"
          :model-value="form.activityType"
          :options="activityTypeOptions"
          @update:model-value="updateFormActivityType"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
          :model-value="form.assigneeId"
          :options="assigneeOptions"
          @update:model-value="emit('update:field', 'assigneeId', $event)"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.PRIORITY')"
          :model-value="form.priority"
          :options="taskPriorityOptions"
          @update:model-value="emit('update:field', 'priority', $event)"
        />

        <SchedulingSelectField
          v-if="!isEditing"
          :label="$t('CRM.TASKS.FORM.STATUS')"
          :model-value="form.statusId"
          :options="taskStatusOptions"
          @update:model-value="emit('update:field', 'statusId', $event)"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.CONTEXT_KIND')"
          :model-value="form.contextKind"
          :options="taskContextOptions"
          @update:model-value="emit('update:field', 'contextKind', $event)"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.DEAL')"
          :model-value="form.dealId"
          :options="dealOptions"
          @update:model-value="emit('update:field', 'dealId', $event)"
        />

        <p
          v-if="form.contextKind === 'sales' && !form.dealId"
          class="mb-0 text-xs text-n-ruby-11 md:col-span-2"
        >
          {{ $t('CRM.TASKS.FORM.SALES_DEAL_REQUIRED') }}
        </p>

        <div class="flex items-center gap-2 md:col-span-2">
          <Switch
            :model-value="form.allDay"
            @update:model-value="updateAllDay"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.TASKS.FORM.ALL_DAY') }}
          </span>
        </div>

        <SchedulingDateTimeField
          v-if="!form.allDay"
          :label="$t('CRM.TASKS.FORM.START_AT')"
          :model-value="form.startAt"
          type="datetime"
          @update:model-value="emit('update:field', 'startAt', $event)"
        />
        <SchedulingDateTimeField
          :label="$t('CRM.TASKS.FORM.DUE_AT')"
          :model-value="form.dueAt"
          :type="form.allDay ? 'date' : 'datetime'"
          @update:model-value="emit('update:field', 'dueAt', $event)"
        />
        <TextArea
          class="md:col-span-2"
          :label="$t('CRM.TASKS.FORM.DESCRIPTION')"
          :model-value="form.description"
          auto-height
          @update:model-value="emit('update:field', 'description', $event)"
        />
      </div>
    </SchedulingFormFieldGroup>

    <CrmCustomFieldsSection
      :definitions="applicableTaskFieldDefinitions"
      :framed="false"
      :model-value="form.customAttributes"
      @update:model-value="emit('update:field', 'customAttributes', $event)"
    />
  </div>
</template>
