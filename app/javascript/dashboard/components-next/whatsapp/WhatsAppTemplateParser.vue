<script setup>
/**
 * This component handles parsing and sending WhatsApp message templates.
 * It works as follows:
 * 1. Displays the template text with variable placeholders.
 * 2. Generates input fields for each variable in the template.
 * 3. Validates that all variables are filled before sending.
 * 4. Replaces placeholders with user-provided values.
 * 5. Emits events to send the processed message or reset the template.
 */
import { ref, computed, onBeforeUnmount, onMounted, watch } from 'vue';
import { useVuelidate } from '@vuelidate/core';
import { requiredIf } from '@vuelidate/validators';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TemplateParamInput from './TemplateParamInput.vue';
import TemplatePreview from 'dashboard/components-next/template-preview/TemplatePreview.vue';
import { PLATFORMS } from 'dashboard/services/TemplateConstants';
import { uploadWhatsAppTemplateMedia } from 'dashboard/helper/uploadHelper';
import {
  buildTemplateParameters,
  allKeysRequired,
  replaceTemplateVariables,
  extractTemplateVariables,
  DEFAULT_LANGUAGE,
  DEFAULT_CATEGORY,
  COMPONENT_TYPES,
  MEDIA_FORMATS,
  findComponentByType,
} from 'dashboard/helper/templateHelper';

const props = defineProps({
  initialProcessedParams: {
    type: Object,
    default: () => ({}),
  },
  template: {
    type: Object,
    default: () => ({}),
    validator: value => {
      if (!value || typeof value !== 'object') return false;
      if (!value.components || !Array.isArray(value.components)) return false;
      return true;
    },
  },
});

const emit = defineEmits(['sendMessage', 'resetTemplate', 'back']);

const { t } = useI18n();

const processedParams = ref({});
const mediaFileInputRef = ref(null);
const isUploadingMedia = ref(false);
const selectedMediaFileName = ref('');

const cloneProcessedParams = value => JSON.parse(JSON.stringify(value || {}));

const mergeProcessedParams = (baseParams, initialParams) => {
  const mergedParams = cloneProcessedParams(baseParams);

  Object.entries(cloneProcessedParams(initialParams)).forEach(
    ([section, value]) => {
      if (Array.isArray(value)) {
        mergedParams[section] = value.map((entry, index) => ({
          ...(mergedParams[section]?.[index] || {}),
          ...(entry || {}),
        }));
        return;
      }

      if (value && typeof value === 'object') {
        mergedParams[section] = {
          ...(mergedParams[section] || {}),
          ...value,
        };
      }
    }
  );

  return mergedParams;
};

const languageLabel = computed(() => {
  return `${t('WHATSAPP_TEMPLATES.PARSER.LANGUAGE')}: ${props.template.language || DEFAULT_LANGUAGE}`;
});

const categoryLabel = computed(() => {
  return `${t('WHATSAPP_TEMPLATES.PARSER.CATEGORY')}: ${props.template.category || DEFAULT_CATEGORY}`;
});

const headerComponent = computed(() => {
  return findComponentByType(props.template, COMPONENT_TYPES.HEADER);
});

const bodyComponent = computed(() => {
  return findComponentByType(props.template, COMPONENT_TYPES.BODY);
});

const textHeader = computed(() => {
  if (headerComponent.value?.format !== 'TEXT') return '';
  return headerComponent.value?.text || '';
});

const bodyText = computed(() => {
  return bodyComponent.value?.text || '';
});

const hasMediaHeader = computed(() =>
  MEDIA_FORMATS.includes(headerComponent.value?.format)
);

const textHeaderVariables = computed(() =>
  extractTemplateVariables(textHeader.value)
);

const hasTextHeaderVariables = computed(
  () => textHeaderVariables.value.length > 0
);

const formatType = computed(() => {
  const format = headerComponent.value?.format;
  return format ? format.charAt(0) + format.slice(1).toLowerCase() : '';
});

const isDocumentTemplate = computed(() => {
  return headerComponent.value?.format?.toLowerCase() === 'document';
});

const mediaFileAccept = computed(
  () =>
    ({
      image: 'image/jpeg,image/png',
      video: 'video/mp4',
      document: 'application/pdf',
    })[headerComponent.value?.format?.toLowerCase()] || ''
);

const hasVariables = computed(() => {
  return (
    bodyText.value?.match(/{{([^}]+)}}/g) !== null ||
    hasTextHeaderVariables.value
  );
});

const headerParamEntries = computed(() => {
  if (!hasTextHeaderVariables.value || !processedParams.value.header) {
    return [];
  }

  return textHeaderVariables.value.map(variable => ({
    key: variable,
    value: processedParams.value.header?.[variable] || '',
  }));
});

const bodyParamEntries = computed(() =>
  Object.entries(processedParams.value.body || {}).map(([key, value]) => ({
    key,
    value,
  }))
);

const hasInteractiveParams = computed(() =>
  Boolean(processedParams.value.catalog || processedParams.value.carousel)
);

const renderedTemplate = computed(() => {
  return replaceTemplateVariables(bodyText.value, processedParams.value);
});

const previewVariables = computed(() => ({
  ...(processedParams.value.body || {}),
  ...(processedParams.value.header || {}),
}));

const rawRenderedTemplate = computed(() => {
  return replaceTemplateVariables(bodyText.value, processedParams.value, {
    previewMode: false,
  });
});

const isFormInvalid = computed(() => {
  if (isUploadingMedia.value) return true;

  if (
    !hasVariables.value &&
    !hasMediaHeader.value &&
    !hasInteractiveParams.value
  ) {
    return false;
  }

  if (hasMediaHeader.value && !processedParams.value.header?.media_url) {
    return true;
  }

  if (hasVariables.value && processedParams.value.body) {
    const hasEmptyBodyVariable = Object.values(processedParams.value.body).some(
      value => !value
    );
    if (hasEmptyBodyVariable) return true;
  }

  if (hasTextHeaderVariables.value && processedParams.value.header) {
    const hasEmptyHeaderVariable = textHeaderVariables.value.some(
      variable => !processedParams.value.header?.[variable]
    );
    if (hasEmptyHeaderVariable) return true;
  }

  if (processedParams.value.buttons) {
    const hasEmptyButtonParameter = processedParams.value.buttons.some(
      button => !button.parameter
    );
    if (hasEmptyButtonParameter) return true;
  }

  const carouselCards = processedParams.value.carousel?.cards || [];
  const hasInvalidCarouselCard = carouselCards.some(card => {
    if (!card.header?.media_id) return true;
    if (Object.values(card.body || {}).some(value => !value)) return true;

    return (card.buttons || []).some(
      button => button.type === 'url' && !button.parameter
    );
  });
  if (hasInvalidCarouselCard) return true;

  return false;
});

const v$ = useVuelidate(
  {
    processedParams: {
      requiredIfKeysPresent: requiredIf(hasVariables),
      allKeysRequired,
    },
  },
  { processedParams }
);

const initializeTemplateParameters = () => {
  selectedMediaFileName.value = '';
  const baseProcessedParams = buildTemplateParameters(
    props.template,
    hasMediaHeader.value
  );
  processedParams.value = mergeProcessedParams(
    baseProcessedParams,
    props.initialProcessedParams
  );
};

const updateMediaUrl = value => {
  processedParams.value.header ??= {};
  processedParams.value.header.media_url = value;
};

const updateMediaName = value => {
  processedParams.value.header ??= {};
  processedParams.value.header.media_name = value;
};

let mediaUploadGeneration = 0;

const invalidateMediaUpload = () => {
  mediaUploadGeneration += 1;
  isUploadingMedia.value = false;
};

const removeMediaFile = () => {
  invalidateMediaUpload();
  updateMediaUrl('');
  updateMediaName('');
  selectedMediaFileName.value = '';
};

const handleMediaFileChange = async event => {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;

  mediaUploadGeneration += 1;
  const uploadGeneration = mediaUploadGeneration;
  try {
    isUploadingMedia.value = true;
    const { fileUrl } = await uploadWhatsAppTemplateMedia(
      file,
      headerComponent.value?.format?.toLowerCase()
    );
    if (uploadGeneration !== mediaUploadGeneration) return;

    updateMediaUrl(fileUrl);
    updateMediaName(file.name);
    selectedMediaFileName.value = file.name;
  } catch (error) {
    if (uploadGeneration !== mediaUploadGeneration) return;

    useAlert(
      error?.response?.data?.error ||
        error?.message ||
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.MEDIA_UPLOAD_FAILED')
    );
  } finally {
    if (uploadGeneration === mediaUploadGeneration) {
      isUploadingMedia.value = false;
    }
  }
};

const sendMessage = () => {
  v$.value.$touch();
  if (v$.value.$invalid || isFormInvalid.value || isUploadingMedia.value) {
    return;
  }

  const { name, category, language, namespace } = props.template;

  const payload = {
    message: rawRenderedTemplate.value,
    templateParams: {
      name,
      category,
      language,
      namespace,
      processed_params: processedParams.value,
    },
  };
  emit('sendMessage', payload);
};

const resetTemplate = () => {
  invalidateMediaUpload();
  emit('resetTemplate');
};

const goBack = () => {
  emit('back');
};

onMounted(initializeTemplateParameters);
onBeforeUnmount(invalidateMediaUpload);

watch(
  () => props.template,
  () => {
    invalidateMediaUpload();
    initializeTemplateParameters();
    v$.value.$reset();
  },
  { deep: true }
);

defineExpose({
  processedParams,
  hasVariables,
  hasMediaHeader,
  hasInteractiveParams,
  isDocumentTemplate,
  headerComponent,
  renderedTemplate,
  rawRenderedTemplate,
  isFormInvalid,
  v$,
  updateMediaUrl,
  updateMediaName,
  sendMessage,
  resetTemplate,
  goBack,
});
</script>

<template>
  <div>
    <div class="flex flex-col gap-4 p-4 mb-4 rounded-lg bg-n-alpha-black2">
      <div class="flex justify-between items-center">
        <h3 class="text-sm font-medium text-n-slate-12">
          {{ template.name }}
        </h3>
        <span class="text-xs text-n-slate-11">
          {{ languageLabel }}
        </span>
      </div>

      <TemplatePreview
        :template="template"
        :variables="previewVariables"
        :platform="PLATFORMS.WHATSAPP"
      />

      <div class="text-xs text-n-slate-11">
        {{ categoryLabel }}
      </div>
    </div>

    <div v-if="hasVariables || hasMediaHeader || hasInteractiveParams">
      <div v-if="headerParamEntries.length" class="mb-4">
        <p class="mb-2.5 text-sm font-semibold">
          {{ t('WHATSAPP_TEMPLATES.PARSER.HEADER_VARIABLES_LABEL') }}
        </p>
        <div
          v-for="variable in headerParamEntries"
          :key="`header-${variable.key}`"
          class="flex items-center mb-2.5"
        >
          <TemplateParamInput
            v-model="processedParams.header[variable.key]"
            type="text"
            class="flex-1"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.VARIABLE_PLACEHOLDER', {
                variable: variable.key,
              })
            "
          />
        </div>
      </div>

      <div v-if="hasMediaHeader" class="mb-4">
        <p class="mb-2.5 text-sm font-semibold">
          {{
            $t('WHATSAPP_TEMPLATES.PARSER.MEDIA_HEADER_LABEL', {
              type: formatType,
            }) || `${formatType} Header`
          }}
        </p>
        <input
          ref="mediaFileInputRef"
          type="file"
          class="hidden"
          :accept="mediaFileAccept"
          @change="handleMediaFileChange"
        />
        <div class="flex flex-wrap items-center gap-2 mb-2.5">
          <Button
            type="button"
            variant="outline"
            color="slate"
            size="sm"
            icon="i-lucide-upload"
            :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_FILE')"
            :is-loading="isUploadingMedia"
            :disabled="isUploadingMedia"
            @click="mediaFileInputRef?.click()"
          />
          <span
            v-if="selectedMediaFileName"
            class="min-w-0 truncate text-sm text-n-slate-11"
          >
            {{ selectedMediaFileName }}
          </span>
          <Button
            v-if="selectedMediaFileName"
            type="button"
            variant="ghost"
            color="ruby"
            size="sm"
            icon="i-lucide-x"
            :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_REMOVE')"
            @click="removeMediaFile"
          />
        </div>
        <p class="mb-2.5 text-xs text-n-slate-10">
          {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_SOURCE_HINT') }}
        </p>
        <div class="flex items-center mb-2.5">
          <Input
            :model-value="processedParams.header?.media_url || ''"
            type="url"
            class="flex-1"
            :disabled="Boolean(selectedMediaFileName) || isUploadingMedia"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.MEDIA_URL_LABEL', {
                type: formatType,
              })
            "
            @update:model-value="updateMediaUrl"
          />
        </div>
        <div v-if="isDocumentTemplate" class="flex items-center mb-2.5">
          <Input
            :model-value="processedParams.header?.media_name || ''"
            type="text"
            class="flex-1"
            :disabled="isUploadingMedia"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.DOCUMENT_NAME_PLACEHOLDER')
            "
            @update:model-value="updateMediaName"
          />
        </div>
      </div>

      <!-- Body Variables Section -->
      <div v-if="processedParams.body">
        <p class="mb-2.5 text-sm font-semibold">
          {{ $t('WHATSAPP_TEMPLATES.PARSER.VARIABLES_LABEL') }}
        </p>
        <div
          v-for="variable in bodyParamEntries"
          :key="`body-${variable.key}`"
          class="flex items-center mb-2.5"
        >
          <TemplateParamInput
            v-model="processedParams.body[variable.key]"
            type="text"
            class="flex-1"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.VARIABLE_PLACEHOLDER', {
                variable: variable.key,
              })
            "
          />
        </div>
      </div>

      <!-- Button Variables Section -->
      <div v-if="processedParams.buttons">
        <p class="mb-2.5 text-sm font-semibold">
          {{ t('WHATSAPP_TEMPLATES.PARSER.BUTTON_PARAMETERS') }}
        </p>
        <div
          v-for="(button, index) in processedParams.buttons"
          :key="`button-${index}`"
          class="flex items-center mb-2.5"
        >
          <TemplateParamInput
            v-model="processedParams.buttons[index].parameter"
            type="text"
            class="flex-1"
            :placeholder="t('WHATSAPP_TEMPLATES.PARSER.BUTTON_PARAMETER')"
          />
        </div>
      </div>
      <div v-if="processedParams.catalog" class="mb-4">
        <p class="mb-2.5 text-sm font-semibold">
          {{ t('WHATSAPP_TEMPLATES.PARSER.CATALOG_THUMBNAIL_LABEL') }}
        </p>
        <TemplateParamInput
          v-model="processedParams.catalog.thumbnail_product_retailer_id"
          type="text"
          class="w-full"
          :placeholder="
            t('WHATSAPP_TEMPLATES.PARSER.CATALOG_THUMBNAIL_PLACEHOLDER')
          "
        />
      </div>

      <div v-if="processedParams.carousel" class="flex flex-col gap-4 mb-4">
        <div
          v-for="(card, cardIndex) in processedParams.carousel.cards"
          :key="`carousel-card-${card.card_index}`"
          class="p-3 border rounded-lg border-n-weak"
        >
          <p class="mb-2.5 text-sm font-semibold">
            {{
              t('WHATSAPP_TEMPLATES.PARSER.CAROUSEL_CARD_LABEL', {
                index: cardIndex + 1,
              })
            }}
          </p>
          <TemplateParamInput
            v-model="card.header.media_id"
            type="text"
            class="w-full mb-2.5"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.CAROUSEL_MEDIA_ID_PLACEHOLDER')
            "
          />
          <TemplateParamInput
            v-for="(_, variable) in card.body"
            :key="`carousel-${card.card_index}-body-${variable}`"
            v-model="card.body[variable]"
            type="text"
            class="w-full mb-2.5"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.VARIABLE_PLACEHOLDER', {
                variable,
              })
            "
          />
          <TemplateParamInput
            v-for="button in card.buttons"
            :key="`carousel-${card.card_index}-button-${button.index}`"
            v-model="button.parameter"
            type="text"
            class="w-full mb-2.5"
            :placeholder="
              t('WHATSAPP_TEMPLATES.PARSER.CAROUSEL_BUTTON_PLACEHOLDER', {
                index: button.index + 1,
              })
            "
          />
        </div>
      </div>

      <p
        v-if="v$.$dirty && v$.$invalid"
        class="p-2.5 text-center rounded-md bg-n-ruby-9/20 text-n-ruby-9"
      >
        {{ $t('WHATSAPP_TEMPLATES.PARSER.FORM_ERROR_MESSAGE') }}
      </p>
    </div>

    <slot
      name="actions"
      :send-message="sendMessage"
      :reset-template="resetTemplate"
      :go-back="goBack"
      :is-valid="!v$.$invalid && !isUploadingMedia"
      :disabled="isFormInvalid || isUploadingMedia"
    />
  </div>
</template>
