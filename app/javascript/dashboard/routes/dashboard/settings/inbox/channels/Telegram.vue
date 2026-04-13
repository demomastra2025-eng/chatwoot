<script setup>
import { computed } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import ChannelSelector from 'dashboard/components/ChannelSelector.vue';
import TelegramBot from './TelegramBot.vue';
import TelegramPersonal from './TelegramPersonal.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const PROVIDER_TYPES = {
  BOT: 'telegram_bot',
  PERSONAL: 'telegram_personal',
};

const selectedProvider = computed(() => route.query.provider);
const showProviderSelection = computed(() => !selectedProvider.value);

const availableProviders = computed(() => [
  {
    key: PROVIDER_TYPES.BOT,
    title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM_BOT.TITLE'),
    description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM_BOT.DESCRIPTION'),
    icon: 'i-woot-telegram',
  },
  {
    key: PROVIDER_TYPES.PERSONAL,
    title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM_PERSONAL.TITLE'),
    description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM_PERSONAL.DESCRIPTION'),
    icon: 'i-woot-telegram',
  },
]);

const selectedComponent = computed(() => {
  return selectedProvider.value === PROVIDER_TYPES.PERSONAL
    ? TelegramPersonal
    : TelegramBot;
});

const selectProvider = provider => {
  router.push({
    name: route.name,
    params: route.params,
    query: { provider },
  });
};

const resetProvider = () => {
  router.push({
    name: route.name,
    params: route.params,
    query: {},
  });
};
</script>

<template>
  <div class="overflow-auto col-span-6 p-6 w-full h-full">
    <div v-if="showProviderSelection">
      <div class="mb-10 text-left">
        <h1 class="mb-2 text-lg font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.ADD.TELEGRAM.SELECT_PROVIDER.TITLE') }}
        </h1>
        <p class="text-sm leading-relaxed text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.TELEGRAM.SELECT_PROVIDER.DESCRIPTION') }}
        </p>
      </div>

      <div class="flex gap-6 justify-start">
        <ChannelSelector
          v-for="provider in availableProviders"
          :key="provider.key"
          :title="provider.title"
          :description="provider.description"
          :icon="provider.icon"
          @click="selectProvider(provider.key)"
        />
      </div>
    </div>

    <div v-else>
      <div class="mb-4 flex justify-end">
        <Button
          link
          xs
          icon="i-woot-arrow-left"
          :label="$t('INBOX_MGMT.ADD.TELEGRAM.SELECT_PROVIDER.CHANGE_ACTION')"
          @click="resetProvider"
        />
      </div>

      <component :is="selectedComponent" />
    </div>
  </div>
</template>
