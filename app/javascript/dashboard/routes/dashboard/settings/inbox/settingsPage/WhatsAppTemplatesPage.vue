<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CreateWhatsAppTemplateDialog from './components/CreateWhatsAppTemplateDialog.vue';
import {
  groupWhatsAppTemplates,
  getTemplateBodyPreview,
  getTemplateFooterPreview,
  getTemplateHeaderPreview,
  getTemplateParameterDefinitions,
  getTemplateStatusTone,
  matchesWhatsAppTemplateSearch,
} from 'dashboard/helper/whatsappTemplateLibrary';

const props = defineProps({
  embedded: {
    type: Boolean,
    default: false,
  },
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
const updatingVisibility = ref(new Set());
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

// A template is offered in the conversation picker unless an admin hid it;
// the flag is stored on every language variant of the template name.
const isVisibleInConversations = templateGroup =>
  templateGroup.variants.some(
    variant => variant.visible_in_conversation_picker !== false
  );

const updateTemplateVisibility = async (templateGroup, visible) => {
  const templateName = templateGroup.name;
  if (updatingVisibility.value.has(templateName)) return;

  updatingVisibility.value.add(templateName);
  try {
    await store.dispatch('inboxes/updateWhatsAppTemplateVisibility', {
      inboxId: props.inbox.id,
      templateName,
      visible,
    });
  } catch (error) {
    useAlert(
      error.message || t('WHATSAPP_TEMPLATES.MANAGEMENT.VISIBILITY_ERROR')
    );
  } finally {
    updatingVisibility.value.delete(templateName);
  }
};

const sectionComponent = computed(() =>
  props.embedded ? 'div' : SettingsFieldSection
);
const containerClass = computed(() =>
  props.embedded ? 'space-y-3' : 'mx-6 max-w-7xl space-y-3'
);
const getTemplateParameters = template =>
  getTemplateParameterDefinitions(template).map(parameter => parameter.label);
const getTemplateButtons = template =>
  (template?.components || [])
    .filter(component => component.type === 'BUTTONS')
    .flatMap(component => component.buttons || []);
const getTemplateCarouselCards = template => {
  const carouselComponent = template?.components?.find(
    component => component.type === 'CAROUSEL'
  );

  return Array.isArray(template?.carousel_cards)
    ? template.carousel_cards
    : carouselComponent?.cards || [];
};
</script>

<template>
  <div :class="containerClass">
    <component
      :is="sectionComponent"
      v-bind="
        embedded
          ? {}
          : {
              label: t('WHATSAPP_TEMPLATES.MANAGEMENT.PAGE_TITLE'),
              helpText: t('WHATSAPP_TEMPLATES.MANAGEMENT.PAGE_DESCRIPTION'),
            }
      "
    >
      <div class="space-y-3">
        <div
          class="flex flex-col gap-2 rounded-xl border border-n-weak bg-n-surface-1 p-3 md:flex-row md:items-center md:justify-between"
        >
          <div class="min-w-0 space-y-1">
            <p class="mb-0 text-sm font-medium text-n-slate-12">
              {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.SUPPORTED_TITLE') }}
            </p>
            <p class="mb-0 line-clamp-2 text-xs text-n-slate-11">
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
          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <Button
              variant="outline"
              color="slate"
              size="sm"
              icon="i-lucide-refresh-cw"
              :label="
                t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON')
              "
              :is-loading="isSyncingTemplates"
              @click="syncTemplates"
            />
            <Button
              size="sm"
              icon="i-lucide-plus"
              :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_ACTION')"
              @click="openCreateDialog"
            />
          </div>
        </div>

        <Input
          v-model="searchQuery"
          size="sm"
          type="search"
          :placeholder="t('WHATSAPP_TEMPLATES.MANAGEMENT.SEARCH_PLACEHOLDER')"
        />

        <div
          v-if="!templateGroups.length"
          class="rounded-xl border border-dashed border-n-weak bg-n-surface-1 p-6 text-center"
        >
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.EMPTY_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.EMPTY_DESCRIPTION') }}
          </p>
        </div>

        <div
          v-else-if="!filteredTemplates.length"
          class="rounded-xl border border-dashed border-n-weak bg-n-surface-1 p-6 text-center"
        >
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.NO_RESULTS_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.NO_RESULTS_DESCRIPTION') }}
          </p>
        </div>

        <div v-else class="grid grid-cols-1 gap-3 xl:grid-cols-2">
          <div
            v-for="templateGroup in filteredTemplates"
            :key="templateGroup.name"
            class="space-y-2 rounded-xl border border-n-weak bg-n-surface-1 p-3"
            data-test="whatsapp-template-card"
          >
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3">
              <div class="min-w-0">
                <div class="flex min-w-0 flex-wrap items-center gap-1.5">
                  <p
                    class="mb-0 min-w-0 truncate text-sm font-medium text-n-slate-12"
                  >
                    {{ templateGroup.name }}
                  </p>
                  <span
                    class="rounded-full bg-n-alpha-black2 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                  >
                    {{ templateGroup.category || 'UTILITY' }}
                  </span>
                  <span
                    v-if="templateGroup.name === csatTemplateName"
                    class="rounded-full bg-n-brand/10 px-1.5 py-0.5 text-[10px] font-medium text-n-brand"
                  >
                    {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CSAT_BADGE') }}
                  </span>
                </div>

                <div class="mt-1 flex flex-wrap gap-1">
                  <div
                    v-for="variant in templateGroup.variants"
                    :key="`${templateGroup.name}-${variant.language}`"
                    class="inline-flex items-center gap-1 rounded-full bg-n-alpha-black2 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                    data-test="template-variant"
                  >
                    <span>{{ variant.language || 'en' }}</span>
                    <span
                      class="rounded-full px-1.5 py-0.5"
                      :class="getStatusClass(variant.status)"
                    >
                      {{ variant.status || 'PENDING' }}
                    </span>
                  </div>
                </div>

                <p
                  v-if="getTemplateBodyPreview(templateGroup.primaryVariant)"
                  class="mb-0 mt-1 line-clamp-2 whitespace-pre-wrap break-words text-xs leading-4 text-n-slate-11"
                  data-test="template-body-preview"
                >
                  {{ getTemplateBodyPreview(templateGroup.primaryVariant) }}
                </p>

                <p
                  v-if="getRejectedVariants(templateGroup).length"
                  class="mb-0 mt-1 line-clamp-1 text-xs text-n-ruby-11"
                >
                  {{ getRejectedVariants(templateGroup)[0].rejected_reason }}
                </p>
              </div>

              <div class="flex shrink-0 items-center gap-1.5">
                <label
                  class="flex max-w-28 cursor-pointer items-center gap-1.5 text-[11px] font-medium leading-4 text-n-slate-11"
                >
                  <span class="line-clamp-2">
                    {{
                      t('WHATSAPP_TEMPLATES.MANAGEMENT.SHOW_IN_CONVERSATIONS')
                    }}
                  </span>
                  <Switch
                    :model-value="isVisibleInConversations(templateGroup)"
                    :aria-label="
                      t('WHATSAPP_TEMPLATES.MANAGEMENT.SHOW_IN_CONVERSATIONS')
                    "
                    :disabled="updatingVisibility.has(templateGroup.name)"
                    @update:model-value="
                      updateTemplateVisibility(templateGroup, $event)
                    "
                  />
                </label>
                <Button
                  v-if="canDeleteTemplate(templateGroup)"
                  variant="ghost"
                  color="ruby"
                  size="xs"
                  icon="i-lucide-trash-2"
                  :aria-label="
                    `${t('WHATSAPP_TEMPLATES.MANAGEMENT.DELETE_ACTION')}: ${templateGroup.name}`
                  "
                  :title="
                    `${t('WHATSAPP_TEMPLATES.MANAGEMENT.DELETE_ACTION')}: ${templateGroup.name}`
                  "
                  @click="openDeleteDialog(templateGroup)"
                />
              </div>
            </div>

            <details
              class="border-t border-n-weak pt-2"
              data-test="full-template-details"
            >
              <summary
                class="flex cursor-pointer list-none items-center justify-between gap-2 text-xs font-medium text-n-brand"
              >
                <span>{{
                  t('WHATSAPP_TEMPLATES.MANAGEMENT.VIEW_FULL_TEMPLATE')
                }}</span>
                <span class="i-lucide-chevron-down size-3.5 shrink-0" />
              </summary>
              <div class="mt-2 space-y-2">
                <section
                  v-for="variant in templateGroup.variants"
                  :key="`${templateGroup.name}-${variant.language}-details`"
                  class="space-y-1.5 rounded-lg bg-n-alpha-1 p-2"
                  data-test="template-variant-details"
                >
                  <div class="flex flex-wrap items-center gap-1.5">
                    <span class="text-xs font-medium text-n-slate-12">
                      {{ variant.language || 'en' }}
                    </span>
                    <span
                      class="rounded-full px-1.5 py-0.5 text-[10px] font-medium"
                      :class="getStatusClass(variant.status)"
                    >
                      {{ variant.status || 'PENDING' }}
                    </span>
                  </div>
                  <p
                    v-if="getTemplateHeaderPreview(variant)"
                    class="mb-0 whitespace-pre-wrap break-words text-xs text-n-slate-11"
                  >
                    <span class="font-medium text-n-slate-12">
                      {{ t('WHATSAPP_TEMPLATES.PICKER.HEADER') }}:
                    </span>
                    {{ getTemplateHeaderPreview(variant) }}
                  </p>
                  <p
                    v-if="getTemplateBodyPreview(variant)"
                    class="mb-0 whitespace-pre-wrap break-words text-xs text-n-slate-11"
                  >
                    <span class="font-medium text-n-slate-12">
                      {{ t('WHATSAPP_TEMPLATES.PICKER.BODY') }}:
                    </span>
                    {{ getTemplateBodyPreview(variant) }}
                  </p>
                  <p
                    v-if="getTemplateFooterPreview(variant)"
                    class="mb-0 whitespace-pre-wrap break-words text-xs text-n-slate-11"
                  >
                    <span class="font-medium text-n-slate-12">
                      {{ t('WHATSAPP_TEMPLATES.PICKER.FOOTER') }}:
                    </span>
                    {{ getTemplateFooterPreview(variant) }}
                  </p>
                  <div v-if="getTemplateButtons(variant).length">
                    <p class="mb-0 text-xs font-medium text-n-slate-12">
                      {{ t('WHATSAPP_TEMPLATES.PICKER.BUTTONS') }}
                    </p>
                    <ul
                      class="mb-0 list-inside list-disc text-xs text-n-slate-11"
                    >
                      <li
                        v-for="(button, index) in getTemplateButtons(variant)"
                        :key="`${button.type}-${button.text}-${index}`"
                      >
                        {{ button.text || button.type }}
                        <span v-if="button.url"> · {{ button.url }}</span>
                        <span v-if="button.phone_number">
                          · {{ button.phone_number }}
                        </span>
                      </li>
                    </ul>
                  </div>
                  <div v-if="getTemplateCarouselCards(variant).length">
                    <p class="mb-0 text-xs font-medium text-n-slate-12">
                      {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.TITLE') }}
                    </p>
                    <div
                      v-for="(card, index) in getTemplateCarouselCards(variant)"
                      :key="`${variant.language}-carousel-${index}`"
                      class="mt-1 rounded-md border border-n-weak p-2"
                    >
                      <p class="mb-1 text-xs font-medium text-n-slate-12">
                        {{
                          t(
                            'WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.CARD_TITLE',
                            { index: index + 1 }
                          )
                        }}
                      </p>
                      <p
                        v-if="card.body_text"
                        class="mb-0 whitespace-pre-wrap break-words text-xs text-n-slate-11"
                      >
                        {{ card.body_text }}
                      </p>
                      <p
                        v-if="card.header_type"
                        class="mb-0 text-xs text-n-slate-10"
                      >
                        {{ card.header_type }}
                      </p>
                      <ul
                        v-if="card.buttons?.length"
                        class="mb-0 list-inside list-disc text-xs text-n-slate-11"
                      >
                        <li
                          v-for="(button, buttonIndex) in card.buttons"
                          :key="buttonIndex"
                        >
                          {{ button.text || button.type }}
                          <span v-if="button.url"> · {{ button.url }}</span>
                          <span v-if="button.phone_number">
                            · {{ button.phone_number }}
                          </span>
                        </li>
                      </ul>
                    </div>
                  </div>
                  <div
                    v-if="getTemplateParameters(variant).length"
                    class="flex flex-wrap gap-1"
                  >
                    <span
                      v-for="parameter in getTemplateParameters(variant)"
                      :key="`${templateGroup.name}-${variant.language}-${parameter}`"
                      class="rounded-full bg-n-slate-3 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                    >
                      {{ parameter }}
                    </span>
                  </div>
                  <div
                    v-if="
                      variant.rejected_reason &&
                      variant.rejected_reason !== 'NONE'
                    "
                    class="rounded-md bg-n-ruby-9/10 px-2 py-1"
                  >
                    <p class="mb-0 text-[10px] font-medium text-n-ruby-11">
                      {{
                        t('WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASON', {
                          language: variant.language || 'en',
                        })
                      }}
                    </p>
                    <p
                      class="mb-0 whitespace-pre-wrap break-words text-xs text-n-ruby-11"
                    >
                      {{ variant.rejected_reason }}
                    </p>
                  </div>
                </section>
              </div>
            </details>

          </div>
        </div>
      </div>
    </component>

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
