<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { messageStamp } from 'shared/helpers/timeHelper';
import Button from 'dashboard/components-next/button/Button.vue';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import { BaseTableRow, BaseTableCell } from 'dashboard/components-next/table';

const props = defineProps({
  automation: {
    type: Object,
    required: true,
  },
  loading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['toggle', 'edit', 'delete', 'clone']);
const route = useRoute();

const readableDate = date => messageStamp(date, 'LLL d, yyyy');
const readableDateWithTime = date => messageStamp(date, 'LLL d, yyyy hh:mm a');

const automationActive = computed({
  get: () => props.automation.active,
  set: active => {
    const { id, name } = props.automation;
    emit('toggle', {
      id,
      name,
      status: !active,
    });
  },
});
</script>

<template>
  <BaseTableRow :item="automation">
    <template #default>
      <BaseTableCell class="max-w-0 w-full">
        <div class="flex items-center gap-2 min-w-0">
          <span class="text-body-main text-n-slate-12 truncate">
            {{ automation.name }}
          </span>
          <div class="w-px h-3 rounded-lg bg-n-weak flex-shrink-0" />
          <span class="text-body-main text-n-slate-11 truncate">
            {{ automation.description }}
          </span>
        </div>
      </BaseTableCell>

      <BaseTableCell>
        <ToggleSwitch
          v-if="!automation.calendar_managed"
          v-model="automationActive"
        />
        <span v-else>{{
          automation.active
            ? $t('SCHEDULING.NOTIFICATIONS.ENABLED')
            : $t('SCHEDULING.NOTIFICATIONS.DISABLED')
        }}</span>
      </BaseTableCell>

      <BaseTableCell :title="readableDateWithTime(automation.created_on)">
        <span class="text-body-main text-n-slate-12 whitespace-nowrap">
          {{ readableDate(automation.created_on) }}
        </span>
      </BaseTableCell>

      <BaseTableCell align="end">
        <div class="flex gap-3 justify-end flex-shrink-0">
          <router-link
            v-if="automation.calendar_managed"
            :to="{
              name: 'scheduling_notifications',
              params: { accountId: route.params.accountId },
              query: { rule: automation.id },
            }"
            class="text-n-brand text-sm"
          >
            {{ $t('SCHEDULING.NOTIFICATIONS.OPEN_CALENDAR') }}
          </router-link>
          <Button
            v-if="!automation.calendar_managed"
            v-tooltip.top="$t('AUTOMATION.FORM.EDIT')"
            icon="i-woot-edit-pen"
            slate
            sm
            :is-loading="loading"
            @click="$emit('edit', automation)"
          />
          <Button
            v-if="!automation.calendar_managed"
            v-tooltip.top="$t('AUTOMATION.CLONE.TOOLTIP')"
            icon="i-woot-clone"
            sm
            slate
            :is-loading="loading"
            @click="$emit('clone', automation)"
          />
          <Button
            v-if="!automation.calendar_managed"
            v-tooltip.top="$t('AUTOMATION.FORM.DELETE')"
            :is-loading="loading"
            icon="i-woot-bin"
            slate
            sm
            class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
            @click="$emit('delete', automation)"
          />
        </div>
      </BaseTableCell>
    </template>
  </BaseTableRow>
</template>
