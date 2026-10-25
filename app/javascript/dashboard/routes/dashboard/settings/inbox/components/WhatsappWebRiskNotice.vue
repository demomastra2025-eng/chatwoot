<script setup>
import Banner from 'dashboard/components-next/banner/Banner.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

// WhatsApp Web links a phone through an unofficial client. A business may use
// it at its own risk, so the risk is said plainly wherever the number is
// connected or managed. Nothing to accept: the notice only informs.
</script>

<template>
  <Banner color="amber" role="note" data-testid="whatsapp-web-risk-notice">
    <div class="flex items-start gap-2">
      <Icon icon="i-lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
      <div class="flex flex-col gap-0.5">
        <p class="mb-0 font-medium text-n-amber-12">
          {{ $t('INBOX_MGMT.WHATSAPP_WEB_RISK.TITLE') }}
        </p>
        <p class="mb-0">
          {{ $t('INBOX_MGMT.WHATSAPP_WEB_RISK.DESCRIPTION') }}
        </p>
      </div>
    </div>
  </Banner>
</template>
