<script setup>
import { ref, computed, toRef } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useFunctionGetter, useStore } from 'dashboard/composables/store';
import {
  COMPONENT_TYPES,
  MEDIA_FORMATS,
  findComponentByType,
} from 'dashboard/helper/templateHelper';
import {
  groupWhatsAppTemplates,
  matchesWhatsAppTemplateSearch,
} from 'dashboard/helper/whatsappTemplateLibrary';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  inboxId: {
    type: Number,
    default: undefined,
  },
});

const emit = defineEmits(['onSelect']);

const { t } = useI18n();
const store = useStore();
const query = ref('');
const isRefreshing = ref(false);
const expandedTemplateName = ref('');

const whatsAppTemplateMessages = useFunctionGetter(
  'inboxes/getFilteredWhatsAppTemplates',
  toRef(props, 'inboxId')
);

const groupedTemplateMessages = computed(() =>
  groupWhatsAppTemplates(whatsAppTemplateMessages.value || [])
);

const filteredTemplateGroups = computed(() =>
  groupedTemplateMessages.value.filter(templateGroup =>
    matchesWhatsAppTemplateSearch(templateGroup, query.value)
  )
);

const getTemplateBody = template => {
  return findComponentByType(template, COMPONENT_TYPES.BODY)?.text || '';
};

const getTemplateHeader = template => {
  return findComponentByType(template, COMPONENT_TYPES.HEADER);
};

const getTemplateFooter = template => {
  return findComponentByType(template, COMPONENT_TYPES.FOOTER);
};

const getTemplateButtons = template => {
  return findComponentByType(template, COMPONENT_TYPES.BUTTONS);
};

const hasMediaContent = template => {
  const header = getTemplateHeader(template);
  return header && MEDIA_FORMATS.includes(header.format);
};

const toggleExpandedTemplate = templateName => {
  expandedTemplateName.value =
    expandedTemplateName.value === templateName ? '' : templateName;
};

const selectTemplateGroup = templateGroup => {
  if (templateGroup.variants.length === 1) {
    emit('onSelect', templateGroup.variants[0]);
    return;
  }

  toggleExpandedTemplate(templateGroup.name);
};

const selectVariant = variant => {
  emit('onSelect', variant);
};

const refreshTemplates = async () => {
  isRefreshing.value = true;
  try {
    await store.dispatch('inboxes/syncTemplates', props.inboxId);
    useAlert(t('WHATSAPP_TEMPLATES.PICKER.REFRESH_SUCCESS'));
  } catch (error) {
    useAlert(t('WHATSAPP_TEMPLATES.PICKER.REFRESH_ERROR'));
  } finally {
    isRefreshing.value = false;
  }
};
</script>

<template>
  <div class="w-full">
    <div class="flex gap-2 mb-2.5">
      <div
        class="flex flex-1 gap-1 items-center px-2.5 py-0 rounded-lg bg-n-alpha-black2 outline outline-1 outline-n-weak hover:outline-n-slate-6 dark:hover:outline-n-slate-6 focus-within:outline-n-brand dark:focus-within:outline-n-brand"
      >
        <input
          v-model="query"
          type="search"
          :placeholder="t('WHATSAPP_TEMPLATES.PICKER.SEARCH_PLACEHOLDER')"
          class="reset-base w-full h-9 bg-transparent text-n-slate-12 !text-sm !outline-0"
        />
        <fluent-icon
          icon="search"
          class="text-n-slate-12 flex-shrink-0"
          size="16"
        />
      </div>
      <button
        :disabled="isRefreshing"
        class="flex justify-center items-center w-9 h-9 rounded-lg bg-n-alpha-black2 outline outline-1 outline-n-weak hover:outline-n-slate-6 dark:hover:outline-n-slate-6 hover:bg-n-alpha-2 dark:hover:bg-n-solid-2 disabled:opacity-50 disabled:cursor-not-allowed"
        :title="t('WHATSAPP_TEMPLATES.PICKER.REFRESH_BUTTON')"
        @click="refreshTemplates"
      >
        <Icon
          icon="i-lucide-refresh-ccw"
          class="text-n-slate-12 size-4"
          :class="{ 'animate-spin': isRefreshing }"
        />
      </button>
    </div>
    <div
      class="bg-n-background outline-n-container outline outline-1 rounded-lg max-h-[18.75rem] overflow-y-auto p-2.5"
    >
      <div
        v-for="(templateGroup, i) in filteredTemplateGroups"
        :key="templateGroup.name"
      >
        <button
          class="block p-2.5 w-full text-left rounded-lg cursor-pointer hover:bg-n-alpha-2 dark:hover:bg-n-solid-2"
          @click="selectTemplateGroup(templateGroup)"
        >
          <div>
            <div class="flex justify-between items-center mb-2.5">
              <p class="text-sm">
                {{ templateGroup.name }}
              </p>
              <div class="flex items-center gap-2">
                <span
                  class="inline-block px-2 py-1 text-xs leading-none rounded-lg cursor-default bg-n-slate-3 text-n-slate-12"
                >
                  {{
                    `${t('WHATSAPP_TEMPLATES.PICKER.LABELS.LANGUAGE')}: ${templateGroup.languages.join(', ')}`
                  }}
                </span>
                <span
                  v-if="templateGroup.variants.length > 1"
                  class="inline-flex size-6 items-center justify-center rounded-full bg-n-alpha-2 text-n-slate-11"
                >
                  <span
                    class="size-4"
                    :class="
                      expandedTemplateName === templateGroup.name
                        ? 'i-lucide-chevron-up'
                        : 'i-lucide-chevron-down'
                    "
                  />
                </span>
              </div>
            </div>
            <p
              v-if="templateGroup.variants.length > 1"
              class="mb-3 text-xs text-n-slate-11"
            >
              {{ t('WHATSAPP_TEMPLATES.PICKER.SELECT_LANGUAGE') }}
            </p>
            <!-- Header -->
            <div
              v-if="getTemplateHeader(templateGroup.primaryVariant)"
              class="mb-3"
            >
              <p class="text-xs font-medium text-n-slate-11">
                {{ t('WHATSAPP_TEMPLATES.PICKER.HEADER') || 'HEADER' }}
              </p>
              <div
                v-if="
                  getTemplateHeader(templateGroup.primaryVariant).format ===
                  'TEXT'
                "
                class="text-sm label-body"
              >
                {{ getTemplateHeader(templateGroup.primaryVariant).text }}
              </div>
              <div
                v-else-if="hasMediaContent(templateGroup.primaryVariant)"
                class="text-sm italic text-n-slate-11"
              >
                {{
                  t('WHATSAPP_TEMPLATES.PICKER.MEDIA_CONTENT', {
                    format: getTemplateHeader(templateGroup.primaryVariant)
                      .format,
                  }) ||
                  `${getTemplateHeader(templateGroup.primaryVariant).format} ${t('WHATSAPP_TEMPLATES.PICKER.MEDIA_CONTENT_FALLBACK')}`
                }}
              </div>
            </div>

            <!-- Body -->
            <div>
              <p class="text-xs font-medium text-n-slate-11">
                {{ t('WHATSAPP_TEMPLATES.PICKER.BODY') || 'BODY' }}
              </p>
              <p class="text-sm label-body">
                {{ getTemplateBody(templateGroup.primaryVariant) }}
              </p>
            </div>

            <!-- Footer -->
            <div
              v-if="getTemplateFooter(templateGroup.primaryVariant)"
              class="mt-3"
            >
              <p class="text-xs font-medium text-n-slate-11">
                {{ t('WHATSAPP_TEMPLATES.PICKER.FOOTER') || 'FOOTER' }}
              </p>
              <p class="text-sm label-body">
                {{ getTemplateFooter(templateGroup.primaryVariant).text }}
              </p>
            </div>

            <!-- Buttons -->
            <div
              v-if="getTemplateButtons(templateGroup.primaryVariant)"
              class="mt-3"
            >
              <p class="text-xs font-medium text-n-slate-11">
                {{ t('WHATSAPP_TEMPLATES.PICKER.BUTTONS') || 'BUTTONS' }}
              </p>
              <div class="flex flex-wrap gap-1 mt-1">
                <span
                  v-for="button in getTemplateButtons(
                    templateGroup.primaryVariant
                  ).buttons"
                  :key="button.text"
                  class="px-2 py-1 text-xs rounded bg-n-slate-3 text-n-slate-12"
                >
                  {{ button.text }}
                </span>
              </div>
            </div>

            <div class="mt-3">
              <p class="text-xs font-medium text-n-slate-11">
                {{ t('WHATSAPP_TEMPLATES.PICKER.CATEGORY') || 'CATEGORY' }}
              </p>
              <p class="text-sm">{{ templateGroup.category }}</p>
            </div>
          </div>
        </button>
        <div
          v-if="
            templateGroup.variants.length > 1 &&
            expandedTemplateName === templateGroup.name
          "
          class="mt-2 flex flex-wrap gap-2 px-2.5 pb-2.5"
        >
          <button
            v-for="variant in templateGroup.variants"
            :key="`${templateGroup.name}-${variant.language}`"
            type="button"
            class="inline-flex items-center rounded-full border border-n-weak bg-n-alpha-black2 px-3 py-1.5 text-xs font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-2"
            @click.stop="selectVariant(variant)"
          >
            {{
              `${t('WHATSAPP_TEMPLATES.PICKER.LABELS.LANGUAGE')}: ${variant.language}`
            }}
          </button>
        </div>
        <hr
          v-if="i != filteredTemplateGroups.length - 1"
          :key="`hr-${i}`"
          class="border-b border-solid border-n-weak my-2.5 mx-auto max-w-[95%]"
        />
      </div>
      <div v-if="!filteredTemplateGroups.length" class="py-8 text-center">
        <div v-if="query && groupedTemplateMessages.length">
          <p>
            {{ t('WHATSAPP_TEMPLATES.PICKER.NO_TEMPLATES_FOUND') }}
            <strong>{{ query }}</strong>
          </p>
        </div>
        <div v-else-if="!groupedTemplateMessages.length" class="space-y-4">
          <p class="text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.PICKER.NO_TEMPLATES_AVAILABLE') }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.label-body {
  font-family: monospace;
}
</style>
