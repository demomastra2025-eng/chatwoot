<script setup>
import { computed, onMounted } from 'vue';
import { storeToRefs } from 'pinia';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

import Switch from 'dashboard/components-next/switch/Switch.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';

const { t } = useI18n();
const configStore = useCaptainConfigStore();
const { features, uiFlags } = storeToRefs(configStore);

const isEditorEnabled = computed(() => features.value.editor?.enabled === true);

const updateTextImprovement = async enabled => {
  try {
    await configStore.updatePreferences({
      captain_features: {
        editor: enabled,
      },
    });
    useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.UPDATE_SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.UPDATE_ERROR'));
  }
};

onMounted(() => configStore.fetch());
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :no-records-found="false"
    class="gap-8"
  >
    <template #header>
      <BaseSettingsHeader
        :title="t('GENERAL_SETTINGS.CONVERSATIONS.TITLE')"
        :description="t('GENERAL_SETTINGS.CONVERSATIONS.DESCRIPTION')"
        feature-name="conversation-settings"
      />
    </template>

    <template #body>
      <div class="mt-4 rounded-xl border border-n-weak bg-n-solid-2 px-4">
        <div class="flex items-center justify-between gap-4 py-4">
          <div>
            <div class="text-sm font-medium text-n-slate-12">
              {{ t('GENERAL_SETTINGS.CONVERSATIONS.TEXT_IMPROVEMENT') }}
            </div>
            <div class="text-xs text-n-slate-11">
              {{
                t('GENERAL_SETTINGS.CONVERSATIONS.TEXT_IMPROVEMENT_DESCRIPTION')
              }}
            </div>
          </div>
          <Switch
            :model-value="isEditorEnabled"
            @change="updateTextImprovement"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
