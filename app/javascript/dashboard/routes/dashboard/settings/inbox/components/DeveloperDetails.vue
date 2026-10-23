<script setup>
import Accordion from 'dashboard/components-next/Accordion/Accordion.vue';

// A collapsed block at the bottom of a channel settings tab. Everything a
// manager does not need day to day (ids, webhook URLs and tokens, raw provider
// errors, sync counters) lives here so the top of the tab stays readable.
</script>

<template>
  <div data-testid="developer-details" class="mt-6">
    <Accordion :title="$t('INBOX_MGMT.EDIT.DEVELOPER_DETAILS.TITLE')">
      <div class="space-y-4 pt-1">
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('INBOX_MGMT.EDIT.DEVELOPER_DETAILS.HINT') }}
        </p>
        <slot />
      </div>
    </Accordion>
  </div>
</template>
