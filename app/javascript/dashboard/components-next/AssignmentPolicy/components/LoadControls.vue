<script setup>
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();

const normalizeOptionalPositiveNumber = value => {
  const numberValue = Number(value);
  return numberValue > 0 ? numberValue : null;
};

const assignmentDelayMinutes = defineModel('assignmentDelayMinutes', {
  type: Number,
  default: 0,
  set(value) {
    const numberValue = Number(value);
    return numberValue > 0 ? numberValue : 0;
  },
});

const maxOpenConversations = defineModel('maxOpenConversations', {
  type: Number,
  default: null,
  set: normalizeOptionalPositiveNumber,
});

const monthlyNewClientQuota = defineModel('monthlyNewClientQuota', {
  type: Number,
  default: null,
  set: normalizeOptionalPositiveNumber,
});

const stickyOwnerEnabled = defineModel('stickyOwnerEnabled', {
  type: Boolean,
  default: false,
});

const stickyOwnerDurationDays = defineModel('stickyOwnerDurationDays', {
  type: Number,
  default: 30,
  set(value) {
    const numberValue = Number(value);
    return numberValue > 0 ? numberValue : 30;
  },
});
</script>

<template>
  <div class="grid grid-cols-1 gap-3">
    <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
      <label
        class="flex flex-col gap-1 rounded-xl border border-n-weak bg-n-solid-1 p-3"
      >
        <span class="text-sm font-medium text-n-slate-12">
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.DELAY.LABEL'
            )
          }}
        </span>
        <span class="text-xs text-n-slate-11 min-h-8">
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.DELAY.DESCRIPTION'
            )
          }}
        </span>
        <Input
          v-model="assignmentDelayMinutes"
          type="number"
          min="0"
          max="10080"
          placeholder="0"
        />
      </label>

      <label
        class="flex flex-col gap-1 rounded-xl border border-n-weak bg-n-solid-1 p-3"
      >
        <span class="text-sm font-medium text-n-slate-12">
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.MAX_OPEN.LABEL'
            )
          }}
        </span>
        <span class="text-xs text-n-slate-11 min-h-8">
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.MAX_OPEN.DESCRIPTION'
            )
          }}
        </span>
        <Input
          v-model="maxOpenConversations"
          type="number"
          min="1"
          max="100000"
          :placeholder="
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.UNLIMITED_PLACEHOLDER'
            )
          "
        />
      </label>

      <label
        class="flex flex-col gap-1 rounded-xl border border-n-weak bg-n-solid-1 p-3"
      >
        <span class="text-sm font-medium text-n-slate-12">
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.MONTHLY_QUOTA.LABEL'
            )
          }}
        </span>
        <span class="text-xs text-n-slate-11 min-h-8">
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.MONTHLY_QUOTA.DESCRIPTION'
            )
          }}
        </span>
        <Input
          v-model="monthlyNewClientQuota"
          type="number"
          min="1"
          max="1000000"
          :placeholder="
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.UNLIMITED_PLACEHOLDER'
            )
          "
        />
      </label>
    </div>

    <div
      class="flex flex-col md:flex-row md:items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-3"
    >
      <label class="flex items-start gap-3">
        <Switch v-model="stickyOwnerEnabled" class="mt-0.5" />
        <span class="flex flex-col gap-1">
          <span class="text-sm font-medium text-n-slate-12">
            {{
              t(
                'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.STICKY_OWNER.LABEL'
              )
            }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{
              t(
                'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.STICKY_OWNER.DESCRIPTION'
              )
            }}
          </span>
        </span>
      </label>

      <label
        v-if="stickyOwnerEnabled"
        class="flex items-center gap-2 text-sm text-n-slate-12"
      >
        <span>
          {{
            t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.STICKY_OWNER.DURATION_LABEL'
            )
          }}
        </span>
        <Input
          v-model="stickyOwnerDurationDays"
          type="number"
          min="1"
          max="3650"
          class="w-24"
        />
      </label>
    </div>
  </div>
</template>
