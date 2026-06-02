<script setup>
import { reactive, computed, ref, nextTick, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { requiredIf } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    default: null,
  },
});

const emit = defineEmits(['submit', 'cancel']);

const UPLOADABLE_FILE_EXTENSIONS = [
  'pdf',
  'docx',
  'doc',
  'odt',
  'rtf',
  'xlsx',
  'xls',
  'html',
  'htm',
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'heic',
  'heif',
  'tiff',
  'tif',
  'bmp',
];
const DEFAULT_IMPORT_PROFILE = {
  sitemap: 'include',
  includePaths: '',
  excludePaths: '',
  maxPages: 100,
  maxDiscoveryDepth: 4,
  allowSubdomains: false,
  ignoreQueryParameters: true,
  onlyMainContent: true,
};

const { t } = useI18n();
const store = useStore();

const formState = {
  uiFlags: useMapGetter('captainDocuments/getUIFlags'),
};

const initialState = {
  name: '',
  url: '',
  documentType: 'single_page',
  uploadedFile: null,
  importProfile: { ...DEFAULT_IMPORT_PROFILE },
  previewLinks: [],
  selectedUrls: [],
  visibility: 'general',
  faqGenerationEnabled: true,
};

const state = reactive({ ...initialState });
const fileInputRef = ref(null);

const requiresUrl = computed(() => state.documentType !== 'file_upload');
const requiresPreviewSelection = computed(
  () => state.documentType === 'selected_pages'
);
const supportsAdvancedSettings = computed(() =>
  ['site_import', 'selected_pages'].includes(state.documentType)
);

const validationRules = {
  url: {
    required: requiredIf(() => requiresUrl.value),
  },
  uploadedFile: {
    required: requiredIf(() => state.documentType === 'file_upload'),
  },
};

const documentTypeOptions = computed(() => [
  {
    value: 'single_page',
    label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.SINGLE_PAGE'),
  },
  {
    value: 'site_import',
    label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.SITE_IMPORT'),
  },
  {
    value: 'selected_pages',
    label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.SELECTED_PAGES'),
  },
  {
    value: 'pdf_url',
    label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.PDF_URL'),
  },
  {
    value: 'file_url',
    label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.FILE_URL'),
  },
  {
    value: 'file_upload',
    label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.FILE_UPLOAD'),
  },
]);

const visibilityOptions = computed(() => [
  {
    value: 'general',
    label: t('CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.GENERAL'),
  },
  {
    value: 'personal',
    label: t('CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.PERSONAL'),
  },
]);

const v$ = useVuelidate(validationRules, state);

const isLoading = computed(() => formState.uiFlags.value.creatingItem);
const isPreviewing = computed(() => formState.uiFlags.value.previewingItem);

const hasUploadedFileError = computed(() => v$.value.uploadedFile.$error);
const hasSelectedPages = computed(() => state.selectedUrls.length > 0);

const previewSummary = computed(() => {
  if (!state.previewLinks.length) return '';

  return t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.PREVIEW_COUNT', {
    count: state.previewLinks.length,
  });
});

const profileHelpText = computed(() => {
  if (state.documentType === 'site_import') {
    return t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.SITE_IMPORT_HELP');
  }

  if (state.documentType === 'selected_pages') {
    return t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.SELECTED_PAGES_HELP');
  }

  return '';
});

const modeHint = computed(() => {
  if (state.documentType === 'pdf_url') {
    return t('CAPTAIN.DOCUMENTS.FORM.MODE_HINTS.PDF_URL');
  }

  if (state.documentType === 'file_url') {
    return t('CAPTAIN.DOCUMENTS.FORM.MODE_HINTS.FILE_URL');
  }

  if (state.documentType === 'file_upload') {
    return t('CAPTAIN.DOCUMENTS.FORM.MODE_HINTS.FILE_UPLOAD');
  }

  return '';
});

const selectedPagesError = computed(() =>
  requiresPreviewSelection.value && !hasSelectedPages.value
    ? t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.ERROR')
    : ''
);

const formErrors = computed(() => ({
  url:
    v$.value.url.$error && requiresUrl.value
      ? t('CAPTAIN.DOCUMENTS.FORM.URL.ERROR')
      : '',
  uploadedFile:
    v$.value.uploadedFile.$error && state.documentType === 'file_upload'
      ? t('CAPTAIN.DOCUMENTS.FORM.UPLOAD_FILE.ERROR')
      : '',
  selectedPages: selectedPagesError.value,
}));

const urlPlaceholder = computed(() => {
  if (state.documentType === 'pdf_url') {
    return t('CAPTAIN.DOCUMENTS.FORM.URL.PDF_PLACEHOLDER');
  }

  if (state.documentType === 'file_url') {
    return t('CAPTAIN.DOCUMENTS.FORM.URL.FILE_PLACEHOLDER');
  }

  return t('CAPTAIN.DOCUMENTS.FORM.URL.PLACEHOLDER');
});

const urlInputMessage = computed(() => {
  if (formErrors.value.url) return formErrors.value.url;
  if (state.documentType === 'file_url') {
    return t('CAPTAIN.DOCUMENTS.FORM.URL.FILE_HELP');
  }

  return '';
});

watch(
  () => state.documentType,
  nextMode => {
    state.previewLinks = [];
    state.selectedUrls = [];
    if (nextMode !== 'file_upload') {
      state.uploadedFile = null;
      if (fileInputRef.value) fileInputRef.value.value = '';
    }
  }
);

watch(
  () => state.url,
  () => {
    if (requiresPreviewSelection.value) {
      state.previewLinks = [];
      state.selectedUrls = [];
    }
  }
);

const handleCancel = () => emit('cancel');

const handleFileChange = event => {
  const file = event.target.files[0];
  if (!file) return;

  const extension = file.name.split('.').pop()?.toLowerCase() || '';

  if (!UPLOADABLE_FILE_EXTENSIONS.includes(extension)) {
    useAlert(t('CAPTAIN.DOCUMENTS.FORM.UPLOAD_FILE.INVALID_TYPE'));
    event.target.value = '';
    return;
  }

  state.uploadedFile = file;
  state.name = file.name.replace(/\.[^.]+$/i, '');
};

const openFileDialog = () => {
  nextTick(() => {
    fileInputRef.value?.click();
  });
};

const splitCommaValues = value =>
  value
    .split(',')
    .map(item => item.trim())
    .filter(Boolean);

const buildImportProfile = () => ({
  sitemap: state.importProfile.sitemap || 'include',
  include_paths: splitCommaValues(state.importProfile.includePaths),
  exclude_paths: splitCommaValues(state.importProfile.excludePaths),
  max_pages: Number(state.importProfile.maxPages) || 100,
  max_discovery_depth: Number(state.importProfile.maxDiscoveryDepth) || 4,
  allow_subdomains: state.importProfile.allowSubdomains,
  ignore_query_parameters: state.importProfile.ignoreQueryParameters,
  only_main_content: state.importProfile.onlyMainContent,
});

const normalizePreviewLinks = payload =>
  payload.map(item => ({
    url: item.url,
    title: item.title || '',
    description: item.description || '',
  }));

const toggleUrlSelection = url => {
  if (state.selectedUrls.includes(url)) {
    state.selectedUrls = state.selectedUrls.filter(item => item !== url);
  } else {
    state.selectedUrls = [...state.selectedUrls, url];
  }
};

const selectAllPreviewLinks = checked => {
  state.selectedUrls = checked ? state.previewLinks.map(item => item.url) : [];
};

const handlePreviewSelectedPages = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid || !state.url) return;

  try {
    const response = await store.dispatch('captainDocuments/preview', {
      document: {
        ...(props.assistantId ? { assistant_id: props.assistantId } : {}),
        external_link: state.url,
        source_mode: state.documentType,
        import_profile: buildImportProfile(),
      },
    });

    state.previewLinks = normalizePreviewLinks(response.payload || []);
    state.selectedUrls = state.previewLinks.map(item => item.url);
  } catch (error) {
    useAlert(
      error?.response?.data?.message ||
        t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.PREVIEW_ERROR')
    );
  }
};

const prepareDocumentDetails = () => {
  if (state.documentType === 'file_upload') {
    const formData = new FormData();
    const extension =
      state.uploadedFile?.name.split('.').pop()?.toLowerCase() || '';
    if (props.assistantId) {
      formData.append('document[assistant_id]', props.assistantId);
    }
    if (extension === 'pdf') {
      formData.append('document[pdf_file]', state.uploadedFile);
    } else {
      formData.append('document[source_file]', state.uploadedFile);
      formData.append('document[source_mode]', 'file_upload');
    }
    formData.append(
      'document[name]',
      state.name || state.uploadedFile.name.replace(/\.[^.]+$/i, '')
    );
    formData.append(
      'document[faq_generation_enabled]',
      state.faqGenerationEnabled
    );
    formData.append('document[visibility]', state.visibility);
    return formData;
  }

  return {
    document: {
      ...(props.assistantId ? { assistant_id: props.assistantId } : {}),
      name: state.name || state.url,
      external_link: state.url,
      source_mode: state.documentType,
      import_profile: buildImportProfile(),
      faq_generation_enabled: state.faqGenerationEnabled,
      visibility: state.visibility,
      ...(state.documentType === 'selected_pages'
        ? { selected_urls: state.selectedUrls }
        : {}),
    },
  };
};

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) {
    return;
  }

  if (
    requiresUrl.value &&
    (() => {
      try {
        // eslint-disable-next-line no-new
        new URL(state.url);
        return false;
      } catch {
        return true;
      }
    })()
  ) {
    useAlert(t('CAPTAIN.DOCUMENTS.FORM.URL.ERROR'));
    return;
  }

  if (requiresPreviewSelection.value && !hasSelectedPages.value) {
    useAlert(t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.ERROR'));
    return;
  }

  emit('submit', prepareDocumentDetails());
};
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
    <div class="flex flex-col gap-1">
      <label
        for="documentType"
        class="mb-0.5 text-sm font-medium text-n-slate-12"
      >
        {{ t('CAPTAIN.DOCUMENTS.FORM.TYPE.LABEL') }}
      </label>
      <ComboBox
        id="documentType"
        v-model="state.documentType"
        :options="documentTypeOptions"
        class="[&>div>button]:bg-n-alpha-black2"
      />
    </div>

    <p class="m-0 text-sm text-n-slate-11">
      {{
        t(
          `CAPTAIN.DOCUMENTS.FORM.TYPE_DESCRIPTIONS.${state.documentType.toUpperCase()}`
        )
      }}
    </p>

    <div
      v-if="modeHint"
      class="rounded-xl border border-n-brand/20 bg-n-brand/5 px-4 py-3"
    >
      <p class="m-0 text-sm text-n-slate-12">
        {{ modeHint }}
      </p>
    </div>

    <Input
      v-if="requiresUrl"
      v-model="state.url"
      :label="t('CAPTAIN.DOCUMENTS.FORM.URL.LABEL')"
      :placeholder="urlPlaceholder"
      :message="urlInputMessage"
      :message-type="formErrors.url ? 'error' : 'info'"
    />

    <div v-if="supportsAdvancedSettings" class="rounded-xl bg-n-alpha-2 p-4">
      <div class="mb-3">
        <p class="m-0 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.TITLE') }}
        </p>
        <p class="mt-1 mb-0 text-xs text-n-slate-11">
          {{ profileHelpText }}
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
        <Input
          v-model="state.importProfile.includePaths"
          :label="t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.INCLUDE_PATHS')"
          :placeholder="t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.PATHS_PLACEHOLDER')"
        />
        <Input
          v-model="state.importProfile.excludePaths"
          :label="t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.EXCLUDE_PATHS')"
          :placeholder="t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.PATHS_PLACEHOLDER')"
        />
        <Input
          v-model="state.importProfile.maxPages"
          type="number"
          min="1"
          :label="t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.MAX_PAGES')"
        />
        <Input
          v-model="state.importProfile.maxDiscoveryDepth"
          type="number"
          min="1"
          :label="t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.MAX_DEPTH')"
        />
      </div>

      <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-2">
        <div
          class="flex items-center justify-between rounded-lg bg-n-alpha-2 p-3"
        >
          <div>
            <p class="m-0 text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.ALLOW_SUBDOMAINS') }}
            </p>
          </div>
          <Switch v-model="state.importProfile.allowSubdomains" />
        </div>
        <div
          class="flex items-center justify-between rounded-lg bg-n-alpha-2 p-3"
        >
          <div>
            <p class="m-0 text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.IGNORE_QUERY_PARAMETERS') }}
            </p>
          </div>
          <Switch v-model="state.importProfile.ignoreQueryParameters" />
        </div>
        <div
          class="flex items-center justify-between rounded-lg bg-n-alpha-2 p-3"
        >
          <div>
            <p class="m-0 text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.DOCUMENTS.FORM.ADVANCED.ONLY_MAIN_CONTENT') }}
            </p>
          </div>
          <Switch v-model="state.importProfile.onlyMainContent" />
        </div>
      </div>
    </div>

    <div v-if="state.documentType === 'selected_pages'" class="space-y-3">
      <Button
        type="button"
        color="slate"
        variant="outline"
        class="w-full"
        :label="t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.PREVIEW_ACTION')"
        :is-loading="isPreviewing"
        :disabled="isPreviewing"
        @click="handlePreviewSelectedPages"
      />

      <div
        v-if="state.previewLinks.length"
        class="rounded-xl border border-n-weak bg-n-background p-4"
      >
        <div class="mb-3 flex items-center justify-between gap-2">
          <div>
            <p class="m-0 text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.PREVIEW_TITLE') }}
            </p>
            <p class="mt-1 mb-0 text-xs text-n-slate-11">
              {{ previewSummary }}
            </p>
          </div>
          <Button
            type="button"
            color="slate"
            variant="ghost"
            size="sm"
            :label="
              hasSelectedPages
                ? t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.CLEAR_SELECTION')
                : t('CAPTAIN.DOCUMENTS.FORM.SELECTED_PAGES.SELECT_ALL')
            "
            @click="selectAllPreviewLinks(!hasSelectedPages)"
          />
        </div>

        <div class="max-h-72 space-y-2 overflow-y-auto pr-1">
          <label
            v-for="item in state.previewLinks"
            :key="item.url"
            class="flex cursor-pointer items-start gap-3 rounded-lg border border-transparent bg-n-alpha-2 p-3 transition-all hover:border-n-brand/20 hover:bg-n-brand/5"
          >
            <input
              class="mt-1 size-4 rounded border-n-weak text-n-brand focus:ring-n-brand"
              type="checkbox"
              :checked="state.selectedUrls.includes(item.url)"
              @change="toggleUrlSelection(item.url)"
            />
            <div class="min-w-0 flex-1">
              <p class="m-0 text-sm font-medium text-n-slate-12">
                {{ item.title || item.url }}
              </p>
              <p class="mt-1 mb-0 truncate text-xs text-n-slate-11">
                {{ item.url }}
              </p>
              <p
                v-if="item.description"
                class="mt-1 mb-0 line-clamp-2 text-xs text-n-slate-11"
              >
                {{ item.description }}
              </p>
            </div>
          </label>
        </div>

        <p
          v-if="formErrors.selectedPages"
          class="mt-3 mb-0 text-xs text-n-ruby-9"
        >
          {{ formErrors.selectedPages }}
        </p>
      </div>
    </div>

    <div
      v-if="state.documentType === 'file_upload'"
      class="flex flex-col gap-2"
    >
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.DOCUMENTS.FORM.UPLOAD_FILE.LABEL') }}
      </label>
      <div class="relative">
        <input
          ref="fileInputRef"
          type="file"
          accept=".pdf,.docx,.doc,.odt,.rtf,.xlsx,.xls,.html,.htm,.jpg,.jpeg,.png,.webp,.gif,.heic,.heif,.tiff,.tif,.bmp"
          class="hidden"
          @change="handleFileChange"
        />
        <Button
          type="button"
          :color="hasUploadedFileError ? 'ruby' : 'slate'"
          :variant="hasUploadedFileError ? 'outline' : 'solid'"
          class="!h-auto !w-full !justify-between !py-4"
          @click="openFileDialog"
        >
          <template #default>
            <div class="flex items-center gap-2">
              <div
                class="flex h-10 w-10 items-center justify-center rounded-lg bg-n-slate-3"
              >
                <i class="i-ph-file text-xl text-n-slate-11" />
              </div>
              <div class="flex flex-1 flex-col items-start gap-1">
                <p class="m-0 text-sm font-medium text-n-slate-12">
                  {{
                    state.uploadedFile
                      ? state.uploadedFile.name
                      : t('CAPTAIN.DOCUMENTS.FORM.UPLOAD_FILE.CHOOSE_FILE')
                  }}
                </p>
                <p class="m-0 text-xs text-n-slate-11">
                  {{
                    state.uploadedFile
                      ? `${(state.uploadedFile.size / 1024 / 1024).toFixed(2)} MB`
                      : t('CAPTAIN.DOCUMENTS.FORM.UPLOAD_FILE.HELP_TEXT')
                  }}
                </p>
              </div>
            </div>
            <i class="i-lucide-upload text-n-slate-11" />
          </template>
        </Button>
      </div>
      <p v-if="formErrors.uploadedFile" class="text-xs text-n-ruby-9">
        {{ formErrors.uploadedFile }}
      </p>
    </div>

    <Input
      v-model="state.name"
      :label="t('CAPTAIN.DOCUMENTS.FORM.NAME.LABEL')"
      :placeholder="t('CAPTAIN.DOCUMENTS.FORM.NAME.PLACEHOLDER')"
    />

    <div class="flex flex-col gap-1">
      <label
        for="documentVisibility"
        class="mb-0.5 text-sm font-medium text-n-slate-12"
      >
        {{ t('CAPTAIN.KNOWLEDGE_VISIBILITY.LABEL') }}
      </label>
      <ComboBox
        id="documentVisibility"
        v-model="state.visibility"
        :options="visibilityOptions"
        class="[&>div>button]:bg-n-alpha-black2"
      />
      <p class="m-0 text-xs text-n-slate-11">
        {{ t('CAPTAIN.KNOWLEDGE_VISIBILITY.HELP_TEXT') }}
      </p>
    </div>

    <div
      class="flex items-start justify-between gap-3 rounded-xl bg-n-alpha-2 p-4"
    >
      <div class="min-w-0">
        <p class="m-0 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.DOCUMENTS.FORM.FAQ_GENERATION.LABEL') }}
        </p>
        <p class="mt-1 mb-0 text-xs text-n-slate-11">
          {{ t('CAPTAIN.DOCUMENTS.FORM.FAQ_GENERATION.HELP_TEXT') }}
        </p>
      </div>
      <Switch v-model="state.faqGenerationEnabled" />
    </div>

    <div class="flex w-full items-center justify-between gap-3">
      <Button
        type="button"
        variant="faded"
        color="slate"
        :label="t('CAPTAIN.FORM.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        type="submit"
        :label="t('CAPTAIN.FORM.CREATE')"
        class="w-full"
        :is-loading="isLoading"
        :disabled="isLoading || (requiresPreviewSelection && !hasSelectedPages)"
      />
    </div>
  </form>
</template>
