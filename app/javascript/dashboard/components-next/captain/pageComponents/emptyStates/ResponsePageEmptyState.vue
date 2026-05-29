<script setup>
import { useAccount } from 'dashboard/composables/useAccount';
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import FeatureSpotlight from 'dashboard/components-next/feature-spotlight/FeatureSpotlight.vue';

import { computed } from 'vue';

const props = defineProps({
  variant: {
    type: String,
    default: 'approved',
    validator: value => ['approved', 'pending'].includes(value),
  },
  hasActiveFilters: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['click', 'clearFilters']);

const isApproved = computed(() => props.variant === 'approved');
const isPending = computed(() => props.variant === 'pending');

const { isOnChatwootCloud } = useAccount();
const onClick = () => {
  emit('click');
};

const onClearFilters = () => {
  emit('clearFilters');
};
</script>

<template>
  <FeatureSpotlight
    v-if="isApproved"
    :title="$t('CAPTAIN.RESPONSES.EMPTY_STATE.FEATURE_SPOTLIGHT.TITLE')"
    :note="$t('CAPTAIN.RESPONSES.EMPTY_STATE.FEATURE_SPOTLIGHT.NOTE')"
    fallback-thumbnail="/assets/images/dashboard/captain/faqs-light.svg"
    fallback-thumbnail-dark="/assets/images/dashboard/captain/faqs-dark.svg"
    :hide-actions="!isOnChatwootCloud"
    class="mb-8"
  />
  <EmptyStateLayout
    :title="
      isPending
        ? $t('CAPTAIN.RESPONSES.EMPTY_STATE.NO_PENDING_TITLE')
        : $t('CAPTAIN.RESPONSES.EMPTY_STATE.TITLE')
    "
    :subtitle="isApproved ? $t('CAPTAIN.RESPONSES.EMPTY_STATE.SUBTITLE') : ''"
    :action-perms="['administrator']"
    :show-backdrop="false"
  >
    <template #actions>
      <div class="flex flex-col items-center gap-3">
        <Button
          v-if="isApproved"
          :label="$t('CAPTAIN.RESPONSES.ADD_NEW')"
          icon="i-lucide-plus"
          @click="onClick"
        />
        <Button
          v-else-if="isPending && hasActiveFilters"
          :label="$t('CAPTAIN.RESPONSES.EMPTY_STATE.CLEAR_SEARCH')"
          variant="link"
          size="sm"
          @click="onClearFilters"
        />
      </div>
    </template>
  </EmptyStateLayout>
</template>
