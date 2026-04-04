<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import CreateWhatsAppTemplateDialog from './components/CreateWhatsAppTemplateDialog.vue';
import {
  groupWhatsAppTemplates,
  getTemplateBodyPreview,
  getTemplateFooterPreview,
  getTemplateHeaderPreview,
  getTemplateStatusTone,
  matchesWhatsAppTemplateSearch,
} from 'dashboard/helper/whatsappTemplateLibrary';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
});

const { t } = useI18n();
const store = useStore();

const searchQuery = ref('');
const isSyncingTemplates = ref(false);
const isDeletingTemplate = ref(false);
const templatePendingDelete = ref(null);
const createDialogRef = ref(null);
const deleteDialogRef = ref(null);

const templateGroups = computed(() =>
  groupWhatsAppTemplates(
    Array.isArray(props.inbox?.message_templates)
      ? props.inbox.message_templates
      : []
  )
);

const filteredTemplates = computed(() =>
  templateGroups.value.filter(templateGroup =>
    matchesWhatsAppTemplateSearch(templateGroup, searchQuery.value)
  )
);

const csatTemplateName = computed(
  () => props.inbox?.csat_config?.template?.name || ''
);

const lastUpdatedText = computed(() => {
  if (!props.inbox?.message_templates_last_updated) {
    return t('WHATSAPP_TEMPLATES.MANAGEMENT.NOT_SYNCED_YET');
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(props.inbox.message_templates_last_updated));
});

const syncTemplates = async () => {
  try {
    isSyncingTemplates.value = true;
    await store.dispatch('inboxes/syncTemplates', props.inbox.id);
    useAlert(t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  } finally {
    isSyncingTemplates.value = false;
  }
};

const openCreateDialog = () => {
  createDialogRef.value?.open();
};

const openDeleteDialog = template => {
  templatePendingDelete.value = template;
  deleteDialogRef.value?.open();
};

const deleteTemplate = async () => {
  if (!templatePendingDelete.value) {
    return;
  }

  try {
    isDeletingTemplate.value = true;
    await store.dispatch('inboxes/deleteWhatsAppTemplate', {
      inboxId: props.inbox.id,
      templateName: templatePendingDelete.value.name,
    });
    useAlert(t('WHATSAPP_TEMPLATES.MANAGEMENT.DELETE_SUCCESS'));
    deleteDialogRef.value?.close();
    templatePendingDelete.value = null;
  } catch (error) {
    useAlert(error.message);
  } finally {
    isDeletingTemplate.value = false;
  }
};

const getRejectedVariants = templateGroup =>
  templateGroup.variants.filter(
    variant => variant.rejected_reason && variant.rejected_reason !== 'NONE'
  );

const formatLanguages = templateGroup => templateGroup.languages.join(', ');

const getStatusClass = templateStatus => {
  const tone = getTemplateStatusTone(templateStatus);

  return {
    teal: 'bg-n-teal-9/10 text-n-teal-11',
    amber: 'bg-n-amber-9/10 text-n-amber-11',
    ruby: 'bg-n-ruby-9/10 text-n-ruby-11',
  }[tone];
};

const canDeleteTemplate = templateGroup =>
  templateGroup?.name && templateGroup.name !== csatTemplateName.value;
</script>

<template>
  <div class="mx-6 max-w-7xl space-y-6">
    <SettingsFieldSection
      :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.PAGE_TITLE')"
      :help-text="t('WHATSAPP_TEMPLATES.MANAGEMENT.PAGE_DESCRIPTION')"
    >
      <div class="space-y-5">
        <div
          class="flex flex-col gap-3 rounded-2xl border border-n-weak bg-n-surface-1 p-4 md:flex-row md:items-center md:justify-between"
        >
          <div class="space-y-1">
            <p class="mb-0 text-sm font-medium text-n-slate-12">
              {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.SUPPORTED_TITLE') }}
            </p>
            <p class="mb-0 text-sm text-n-slate-11">
              {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.SUPPORTED_DESCRIPTION') }}
            </p>
            <p class="mb-0 text-xs text-n-slate-10">
              {{
                t('WHATSAPP_TEMPLATES.MANAGEMENT.LAST_SYNC', {
                  timestamp: lastUpdatedText,
                })
              }}
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <Button
              variant="outline"
              color="slate"
              icon="i-lucide-refresh-cw"
              :label="
                t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON')
              "
              :is-loading="isSyncingTemplates"
              @click="syncTemplates"
            />
            <Button
              icon="i-lucide-plus"
              :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_ACTION')"
              @click="openCreateDialog"
            />
          </div>
        </div>

        <Input
          v-model="searchQuery"
          type="search"
          :placeholder="t('WHATSAPP_TEMPLATES.MANAGEMENT.SEARCH_PLACEHOLDER')"
        />

        <div
          v-if="!templateGroups.length"
          class="rounded-2xl border border-dashed border-n-weak bg-n-surface-1 p-8 text-center"
        >
          <p class="mb-1 text-base font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.EMPTY_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.EMPTY_DESCRIPTION') }}
          </p>
        </div>

        <div
          v-else-if="!filteredTemplates.length"
          class="rounded-2xl border border-dashed border-n-weak bg-n-surface-1 p-8 text-center"
        >
          <p class="mb-1 text-base font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.NO_RESULTS_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.NO_RESULTS_DESCRIPTION') }}
          </p>
        </div>

        <div v-else class="grid grid-cols-1 gap-4 xl:grid-cols-2">
          <div
            v-for="templateGroup in filteredTemplates"
            :key="templateGroup.name"
            class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0 space-y-2">
                <div class="flex flex-wrap items-center gap-2">
                  <p
                    class="mb-0 truncate text-base font-medium text-n-slate-12"
                  >
                    {{ templateGroup.name }}
                  </p>
                  <span
                    class="rounded-full bg-n-alpha-black2 px-2.5 py-1 text-xs font-medium text-n-slate-11"
                  >
                    {{ templateGroup.category || 'UTILITY' }}
                  </span>
                  <span
                    v-if="templateGroup.name === csatTemplateName"
                    class="rounded-full bg-n-brand/10 px-2.5 py-1 text-xs font-medium text-n-brand"
                  >
                    {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CSAT_BADGE') }}
                  </span>
                </div>

                <p class="mb-0 text-xs text-n-slate-10">
                  {{
                    t('WHATSAPP_TEMPLATES.MANAGEMENT.LANGUAGES', {
                      languages: formatLanguages(templateGroup),
                    })
                  }}
                </p>

                <div class="flex flex-wrap gap-2">
                  <div
                    v-for="variant in templateGroup.variants"
                    :key="`${templateGroup.name}-${variant.language}`"
                    class="inline-flex items-center gap-2 rounded-full bg-n-alpha-black2 px-2.5 py-1 text-xs font-medium text-n-slate-11"
                  >
                    <span>{{ variant.language || 'en' }}</span>
                    <span
                      class="rounded-full px-2 py-0.5"
                      :class="getStatusClass(variant.status)"
                    >
                      {{ variant.status || 'PENDING' }}
                    </span>
                  </div>
                </div>

                <p
                  v-if="getTemplateHeaderPreview(templateGroup.primaryVariant)"
                  class="mb-0 text-sm font-medium text-n-slate-12"
                >
                  {{ getTemplateHeaderPreview(templateGroup.primaryVariant) }}
                </p>

                <p class="mb-0 text-sm whitespace-pre-wrap text-n-slate-11">
                  {{ getTemplateBodyPreview(templateGroup.primaryVariant) }}
                </p>

                <p
                  v-if="getTemplateFooterPreview(templateGroup.primaryVariant)"
                  class="mb-0 text-xs text-n-slate-10"
                >
                  {{ getTemplateFooterPreview(templateGroup.primaryVariant) }}
                </p>
              </div>

              <Button
                v-if="canDeleteTemplate(templateGroup)"
                variant="ghost"
                color="ruby"
                icon="i-lucide-trash-2"
                @click="openDeleteDialog(templateGroup)"
              />
            </div>

            <div
              v-if="getRejectedVariants(templateGroup).length"
              class="space-y-2"
            >
              <div
                v-for="variant in getRejectedVariants(templateGroup)"
                :key="`${templateGroup.name}-${variant.language}-rejected`"
                class="rounded-xl bg-n-ruby-9/10 p-3"
              >
                <p class="mb-1 text-xs font-medium text-n-ruby-11">
                  {{
                    t('WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASON', {
                      language: variant.language || 'en',
                    })
                  }}
                </p>
                <p class="mb-0 text-xs text-n-ruby-11">
                  {{ variant.rejected_reason }}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </SettingsFieldSection>

    <CreateWhatsAppTemplateDialog ref="createDialogRef" :inbox-id="inbox.id" />

    <Dialog
      ref="deleteDialogRef"
      type="alert"
      :title="t('WHATSAPP_TEMPLATES.MANAGEMENT.DELETE_TITLE')"
      :description="
        t('WHATSAPP_TEMPLATES.MANAGEMENT.DELETE_DESCRIPTION', {
          templateName: templatePendingDelete?.name || '',
        })
      "
      :confirm-button-label="t('WHATSAPP_TEMPLATES.MANAGEMENT.DELETE_ACTION')"
      :cancel-button-label="t('DIALOG.BUTTONS.CANCEL')"
      :is-loading="isDeletingTemplate"
      @confirm="deleteTemplate"
      @close="templatePendingDelete = null"
    />
  </div>
</template>
