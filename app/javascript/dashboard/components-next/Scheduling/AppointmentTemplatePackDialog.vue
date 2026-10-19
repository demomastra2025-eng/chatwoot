<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import {
  buildWhatsAppTemplatePayload,
  hasDanglingTemplateVariable,
} from 'dashboard/helper/whatsappTemplateLibrary';
import {
  APPOINTMENT_REMINDER_PRESETS,
  APPOINTMENT_SEMANTIC_VARIABLES,
  buildAppointmentTemplatePackDrafts,
  serializeSemanticTemplateText,
} from 'dashboard/helper/appointmentTemplatePresets';

const props = defineProps({
  inboxId: {
    type: Number,
    default: null,
  },
  existingTemplateNames: {
    type: Array,
    default: () => [],
  },
  defaultCompanyName: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['generated']);

const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const isSubmitting = ref(false);
const submitError = ref('');
const selectedPreviewKey = ref(APPOINTMENT_REMINDER_PRESETS[0].key);

const options = reactive({
  languageMode: 'both',
  includeCompany: true,
  companyNameRu: '',
  companyNameKk: '',
  greetByName: true,
  includeDateTime: true,
  includeSpecialist: true,
  includeService: true,
  confirmationDayBefore: true,
  includeLocationUrl: false,
  locationUrl: '',
});

const customOverrides = reactive({});

const languageModeOptions = computed(() => [
  {
    id: 'both',
    label: t('SCHEDULING.REMINDERS.PACK_MODAL.LANG_BOTH'),
  },
  {
    id: 'ru',
    label: t('SCHEDULING.REMINDERS.PACK_MODAL.LANG_RU'),
  },
  {
    id: 'kk',
    label: t('SCHEDULING.REMINDERS.PACK_MODAL.LANG_KK'),
  },
]);

const existingNameSet = computed(
  () =>
    new Set(
      (props.existingTemplateNames || []).map(name =>
        String(name || '')
          .trim()
          .toLowerCase()
      )
    )
);

const validateDraftFields = ({ name, bodyText, serialized, buttons }) => {
  const trimmedName = String(name || '').trim();
  if (!trimmedName) {
    return t('SCHEDULING.REMINDERS.ERRORS.TEMPLATE_NAME_REQUIRED');
  }
  if (!/^[a-z0-9_]+$/.test(trimmedName)) {
    return t('SCHEDULING.REMINDERS.ERRORS.TEMPLATE_NAME_FORMAT');
  }

  const trimmedBody = String(bodyText || '').trim();
  if (!trimmedBody) {
    return t('SCHEDULING.REMINDERS.ERRORS.TEMPLATE_BODY_REQUIRED');
  }
  if (serialized?.error) {
    return serialized.error;
  }
  if (hasDanglingTemplateVariable(trimmedBody)) {
    return t('SCHEDULING.REMINDERS.ERRORS.TEMPLATE_BODY_DANGLING_VAR');
  }

  const hasEmptyButton = (buttons || []).some(
    btn => !String(btn?.text || '').trim()
  );
  if (hasEmptyButton) {
    return t('SCHEDULING.REMINDERS.ERRORS.TEMPLATE_BUTTON_TEXT_REQUIRED');
  }

  return '';
};

const baseDrafts = computed(() => buildAppointmentTemplatePackDrafts(options));

const drafts = computed(() =>
  baseDrafts.value.map(baseDraft => {
    const override = customOverrides[baseDraft.presetKey] || {};
    const hasNameOverride = override.name !== undefined;
    const hasBodyOverride = override.bodyText !== undefined;
    const hasButtonOverride = override.buttonText !== undefined;

    const name = hasNameOverride ? override.name : baseDraft.name;
    const bodyText = hasBodyOverride ? override.bodyText : baseDraft.bodyText;
    const buttons = baseDraft.buttons.map((btn, idx) =>
      idx === 0 && hasButtonOverride
        ? { ...btn, text: override.buttonText }
        : { ...btn }
    );

    const serialized = serializeSemanticTemplateText(bodyText);
    const semanticKeyMap = Object.fromEntries(
      Object.entries(serialized.semanticMap || {}).map(([idx, item]) => [
        idx,
        item.key,
      ])
    );
    const isCustomized =
      hasNameOverride || hasBodyOverride || hasButtonOverride;
    const validationError = validateDraftFields({
      name,
      bodyText,
      serialized,
      buttons,
    });

    return {
      ...baseDraft,
      name: String(name || '').trim(),
      rawName: String(name || ''),
      bodyText,
      serializedBodyText: serialized.serializedText,
      bodyExamples: serialized.examples,
      variableBindings: serialized.bindings,
      semanticKeyMap,
      buttons,
      isCustomized,
      validationError,
    };
  })
);

const newDraftsToCreate = computed(() =>
  drafts.value.filter(
    draft => !existingNameSet.value.has(draft.name.toLowerCase())
  )
);

const activePreviewDraft = computed(
  () =>
    drafts.value.find(draft => draft.presetKey === selectedPreviewKey.value) ||
    drafts.value[0]
);

const ensureOverrideEntry = presetKey => {
  if (!customOverrides[presetKey]) {
    customOverrides[presetKey] = {};
  }
  return customOverrides[presetKey];
};

const updateActiveDraftName = value => {
  if (!activePreviewDraft.value) return;
  const entry = ensureOverrideEntry(activePreviewDraft.value.presetKey);
  entry.name = String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9_]/g, '_');
  submitError.value = '';
};

const updateActiveDraftBody = value => {
  if (!activePreviewDraft.value) return;
  const entry = ensureOverrideEntry(activePreviewDraft.value.presetKey);
  entry.bodyText = String(value ?? '');
  submitError.value = '';
};

const updateActiveDraftButtonText = value => {
  if (!activePreviewDraft.value) return;
  const entry = ensureOverrideEntry(activePreviewDraft.value.presetKey);
  entry.buttonText = String(value ?? '');
  submitError.value = '';
};

const insertVariableIntoActiveDraft = token => {
  if (!activePreviewDraft.value) return;
  const current = String(activePreviewDraft.value.bodyText || '');
  const separator =
    current && !current.endsWith(' ') && !current.endsWith('\n') ? ' ' : '';
  updateActiveDraftBody(`${current}${separator}${token}`);
};

const resetDraftOverride = presetKey => {
  if (!presetKey) return;
  delete customOverrides[presetKey];
  submitError.value = '';
};

const suggestNextAvailableName = rawName => {
  const cleanBase =
    String(rawName || 'booking_template')
      .trim()
      .toLowerCase()
      .replace(/_v\d+$/, '') || 'booking_template';
  let version = 2;
  while (existingNameSet.value.has(`${cleanBase}_v${version}`)) {
    version += 1;
  }
  return `${cleanBase}_v${version}`;
};

const suggestedActiveNewName = computed(() =>
  activePreviewDraft.value
    ? suggestNextAvailableName(activePreviewDraft.value.name)
    : ''
);

const bumpActiveDraftName = () => {
  if (!activePreviewDraft.value) return;
  updateActiveDraftName(suggestedActiveNewName.value);
};

const renderExamplePreview = draft => {
  if (!draft) return '';
  let text = String(draft.serializedBodyText || '');
  Object.entries(draft.bodyExamples || {}).forEach(([key, exampleVal]) => {
    text = text.replaceAll(`{{${key}}}`, exampleVal);
  });
  return text;
};

const open = () => {
  submitError.value = '';
  if (!options.companyNameRu && props.defaultCompanyName) {
    options.companyNameRu = props.defaultCompanyName;
    options.companyNameKk = props.defaultCompanyName;
  }
  dialogRef.value?.open();
};

const close = () => {
  dialogRef.value?.close();
};

const handleGenerate = async () => {
  if (!props.inboxId) {
    submitError.value = t('SCHEDULING.REMINDERS.ERRORS.INBOX_REQUIRED');
    return;
  }

  if (
    options.includeLocationUrl &&
    !/^https?:\/\/\S+/i.test(String(options.locationUrl || '').trim())
  ) {
    submitError.value = t('SCHEDULING.REMINDERS.ERRORS.INVALID_LOCATION_URL');
    return;
  }

  const targets = newDraftsToCreate.value;
  const invalidDraft = targets.find(draft => Boolean(draft.validationError));
  if (invalidDraft) {
    selectedPreviewKey.value = invalidDraft.presetKey;
    submitError.value = invalidDraft.validationError;
    return;
  }

  submitError.value = '';
  isSubmitting.value = true;

  try {
    await targets.reduce(async (previousPromise, draft) => {
      await previousPromise;
      const payload = buildWhatsAppTemplatePayload(draft);
      await store.dispatch('inboxes/createWhatsAppTemplate', {
        inboxId: props.inboxId,
        template: payload,
      });
    }, Promise.resolve());
    const createdCount = targets.length;

    useAlert(
      createdCount > 0
        ? t('SCHEDULING.REMINDERS.PACK_MODAL.SUCCESS', { count: createdCount })
        : t('SCHEDULING.REMINDERS.PACK_MODAL.ALREADY_EXISTS_NOTICE')
    );

    emit('generated', {
      drafts: drafts.value,
      createdCount,
    });
    close();
  } catch (error) {
    submitError.value =
      error?.response?.data?.error ||
      error?.message ||
      t('SCHEDULING.REMINDERS.PACK_MODAL.ERROR');
  } finally {
    isSubmitting.value = false;
  }
};

defineExpose({
  open,
  close,
});
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="4xl"
    :title="t('SCHEDULING.REMINDERS.PACK_MODAL.TITLE')"
    :description="t('SCHEDULING.REMINDERS.PACK_MODAL.DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
  >
    <div class="space-y-6">
      <div class="space-y-2">
        <label class="block text-sm font-medium text-n-slate-12">
          {{ t('SCHEDULING.REMINDERS.PACK_MODAL.LANGUAGE_LABEL') }}
        </label>
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-3">
          <button
            v-for="mode in languageModeOptions"
            :key="mode.id"
            type="button"
            :data-testid="`lang-mode-${mode.id}`"
            class="flex items-center justify-center rounded-xl border px-3 py-2.5 text-sm font-medium transition-colors"
            :class="
              options.languageMode === mode.id
                ? 'border-n-brand bg-n-brand/10 text-n-brand'
                : 'border-n-weak bg-n-alpha-black2 text-n-slate-12 hover:border-n-slate-6'
            "
            @click="options.languageMode = mode.id"
          >
            {{ mode.label }}
          </button>
        </div>
      </div>

      <div
        class="rounded-xl border border-n-weak bg-n-alpha-black2 p-4 space-y-4"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <p class="mb-0 text-sm font-medium text-n-slate-12">
              {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INCLUDE_COMPANY') }}
            </p>
            <p class="mb-0 text-xs text-n-slate-11">
              {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INCLUDE_COMPANY_HINT') }}
            </p>
          </div>
          <Switch v-model="options.includeCompany" />
        </div>

        <div
          v-if="options.includeCompany"
          class="grid grid-cols-1 gap-3 sm:grid-cols-2"
        >
          <Input
            v-if="options.languageMode !== 'kk'"
            v-model="options.companyNameRu"
            :label="t('SCHEDULING.REMINDERS.PACK_MODAL.COMPANY_NAME_RU')"
            :placeholder="
              t('SCHEDULING.REMINDERS.PACK_MODAL.COMPANY_NAME_PLACEHOLDER')
            "
          />
          <Input
            v-if="options.languageMode !== 'ru'"
            v-model="options.companyNameKk"
            :label="t('SCHEDULING.REMINDERS.PACK_MODAL.COMPANY_NAME_KK')"
            :placeholder="
              t('SCHEDULING.REMINDERS.PACK_MODAL.COMPANY_NAME_PLACEHOLDER')
            "
          />
        </div>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak px-3.5 py-2.5"
        >
          <span class="text-sm text-n-slate-12">
            {{ t('SCHEDULING.REMINDERS.PACK_MODAL.GREET_BY_NAME') }}
          </span>
          <Switch v-model="options.greetByName" />
        </div>

        <div
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak px-3.5 py-2.5"
        >
          <span class="text-sm text-n-slate-12">
            {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INCLUDE_DATETIME') }}
          </span>
          <Switch v-model="options.includeDateTime" />
        </div>

        <div
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak px-3.5 py-2.5"
        >
          <span class="text-sm text-n-slate-12">
            {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INCLUDE_SPECIALIST') }}
          </span>
          <Switch v-model="options.includeSpecialist" />
        </div>

        <div
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak px-3.5 py-2.5"
        >
          <span class="text-sm text-n-slate-12">
            {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INCLUDE_SERVICE') }}
          </span>
          <Switch v-model="options.includeService" />
        </div>

        <div
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak px-3.5 py-2.5 sm:col-span-2"
        >
          <div>
            <p class="mb-0 text-sm font-medium text-n-slate-12">
              {{ t('SCHEDULING.REMINDERS.PACK_MODAL.CONFIRMATION_BUTTON') }}
            </p>
            <p class="mb-0 text-xs text-n-slate-11">
              {{
                t('SCHEDULING.REMINDERS.PACK_MODAL.CONFIRMATION_BUTTON_HINT')
              }}
            </p>
          </div>
          <Switch v-model="options.confirmationDayBefore" />
        </div>

        <div
          class="flex flex-col gap-3 rounded-xl border border-n-weak px-3.5 py-2.5 sm:col-span-2"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-sm text-n-slate-12">
              {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INCLUDE_LOCATION_URL') }}
            </span>
            <Switch v-model="options.includeLocationUrl" />
          </div>
          <Input
            v-if="options.includeLocationUrl"
            v-model="options.locationUrl"
            type="url"
            :label="t('SCHEDULING.REMINDERS.PACK_MODAL.LOCATION_URL_LABEL')"
            :placeholder="
              t('SCHEDULING.REMINDERS.PACK_MODAL.LOCATION_URL_LABEL')
            "
          />
        </div>
      </div>

      <div class="space-y-3 border-t border-n-weak pt-4">
        <div class="flex items-center justify-between gap-2">
          <p class="mb-0 text-sm font-medium text-n-slate-12">
            {{ t('SCHEDULING.REMINDERS.PACK_MODAL.PREVIEW_SECTION') }}
          </p>
          <span class="text-xs text-n-slate-11">
            {{
              t('SCHEDULING.REMINDERS.PACK_MODAL.READY_COUNT', {
                count: newDraftsToCreate.length,
                total: drafts.length,
              })
            }}
          </span>
        </div>

        <div class="flex flex-wrap gap-1.5">
          <button
            v-for="draft in drafts"
            :key="draft.presetKey"
            type="button"
            :data-testid="`pack-tab-${draft.presetKey}`"
            class="inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 text-xs font-medium transition-colors"
            :class="
              selectedPreviewKey === draft.presetKey
                ? 'border-n-brand bg-n-brand/10 text-n-brand'
                : 'border-n-weak bg-n-alpha-black2 text-n-slate-11 hover:text-n-slate-12'
            "
            @click="selectedPreviewKey = draft.presetKey"
          >
            <span>{{
              t(`SCHEDULING.REMINDERS.PRESETS.${draft.presetKey}.TITLE`)
            }}</span>
            <span
              v-if="draft.isCustomized"
              class="rounded bg-n-brand/15 px-1.5 py-0.5 text-[10px] text-n-brand"
            >
              {{ t('SCHEDULING.REMINDERS.PACK_MODAL.CUSTOMIZED_BADGE') }}
            </span>
            <span
              v-if="existingNameSet.has(draft.name.toLowerCase())"
              class="rounded bg-n-teal-9/15 px-1.5 py-0.5 text-[10px] text-n-teal-11"
            >
              {{ t('SCHEDULING.REMINDERS.PACK_MODAL.EXISTS_BADGE') }}
            </span>
            <span
              v-if="draft.validationError"
              class="size-2 rounded-full bg-n-ruby-9"
            />
          </button>
        </div>

        <div
          v-if="activePreviewDraft"
          class="grid grid-cols-1 gap-4 rounded-2xl border border-n-weak bg-n-alpha-black2 p-4 lg:grid-cols-12"
        >
          <div class="space-y-3 lg:col-span-7">
            <div class="flex items-center justify-between gap-2">
              <p class="mb-0 text-xs font-semibold uppercase tracking-wide text-n-slate-11">
                {{ t('SCHEDULING.REMINDERS.PACK_MODAL.EDIT_TEMPLATE_TITLE') }}
              </p>
              <button
                v-if="activePreviewDraft.isCustomized"
                type="button"
                data-testid="reset-active-template-btn"
                class="inline-flex items-center gap-1 text-xs font-medium text-n-brand hover:underline"
                @click="resetDraftOverride(activePreviewDraft.presetKey)"
              >
                <span class="i-lucide-rotate-ccw size-3" />
                <span>{{
                  t('SCHEDULING.REMINDERS.PACK_MODAL.RESET_TEMPLATE')
                }}</span>
              </button>
            </div>

            <Input
              data-testid="pack-template-name-input"
              :model-value="activePreviewDraft.rawName"
              :label="t('SCHEDULING.REMINDERS.PACK_MODAL.TEMPLATE_NAME_LABEL')"
              @update:model-value="updateActiveDraftName"
            />

            <div
              v-if="existingNameSet.has(activePreviewDraft.name.toLowerCase())"
              class="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-n-amber-9/30 bg-n-amber-9/10 px-3 py-2 text-xs text-n-amber-11"
            >
              <span>{{
                t('SCHEDULING.REMINDERS.PACK_MODAL.EXISTS_EDIT_HINT')
              }}</span>
              <button
                type="button"
                data-testid="bump-template-name-btn"
                class="shrink-0 rounded-lg bg-n-amber-9/20 px-2.5 py-1 font-medium text-n-amber-11 hover:bg-n-amber-9/30"
                @click="bumpActiveDraftName"
              >
                {{
                  t('SCHEDULING.REMINDERS.PACK_MODAL.BUMP_TEMPLATE_NAME', {
                    name: suggestedActiveNewName,
                  })
                }}
              </button>
            </div>

            <div class="space-y-1.5">
              <span class="block text-xs font-medium text-n-slate-11">
                {{ t('SCHEDULING.REMINDERS.PACK_MODAL.INSERT_VARIABLE_LABEL') }}
              </span>
              <div class="flex flex-wrap items-center gap-1.5">
                <button
                  v-for="semVar in APPOINTMENT_SEMANTIC_VARIABLES"
                  :key="semVar.key"
                  type="button"
                  data-testid="pack-variable-chip"
                  class="inline-flex items-center gap-1 rounded-lg border border-n-weak bg-n-solid-2 px-2 py-1 text-xs font-medium text-n-slate-12 transition-colors hover:border-n-brand/60 hover:bg-n-brand/10 hover:text-n-brand"
                  @click="insertVariableIntoActiveDraft(semVar.token)"
                >
                  <span class="i-lucide-plus size-3" />
                  <span>{{ t(semVar.labelKey, semVar.defaultLabel) }}</span>
                  <span class="font-mono text-[10px] opacity-70">{{ semVar.token }}</span>
                </button>
              </div>
            </div>

            <div class="space-y-1">
              <TextArea
                data-testid="pack-template-body-input"
                :model-value="activePreviewDraft.bodyText"
                :label="t('SCHEDULING.REMINDERS.PACK_MODAL.TEMPLATE_BODY_LABEL')"
                auto-height
                @update:model-value="updateActiveDraftBody"
              />
              <p class="mb-0 text-[11px] text-n-slate-11">
                {{ t('SCHEDULING.REMINDERS.PACK_MODAL.TEMPLATE_BODY_HINT') }}
              </p>
            </div>

            <Input
              v-if="activePreviewDraft.buttons.length"
              data-testid="pack-template-button-text-input"
              :model-value="activePreviewDraft.buttons[0].text"
              :label="t('SCHEDULING.REMINDERS.PACK_MODAL.BUTTON_TEXT_LABEL')"
              @update:model-value="updateActiveDraftButtonText"
            />

            <div
              v-if="activePreviewDraft.validationError"
              data-testid="pack-template-validation-error"
              class="rounded-xl bg-n-ruby-9/10 px-3 py-2 text-xs text-n-ruby-11"
            >
              {{ activePreviewDraft.validationError }}
            </div>
          </div>

          <div
            class="flex flex-col justify-between rounded-2xl border border-n-weak bg-[#efeae2] dark:bg-n-solid-3 p-4 lg:col-span-5"
          >
            <div>
              <div
                class="mb-2.5 flex items-center justify-between text-xs text-n-slate-11"
              >
                <span class="font-medium">{{
                  t('SCHEDULING.REMINDERS.PACK_MODAL.LIVE_PREVIEW_LABEL')
                }}</span>
                <span class="font-mono">{{
                  `${activePreviewDraft.category} · ${activePreviewDraft.language.toUpperCase()}`
                }}</span>
              </div>
              <div
                class="rounded-2xl rounded-tl-sm bg-white dark:bg-n-solid-2 p-3.5 shadow-sm"
              >
                <p
                  data-testid="pack-template-live-preview"
                  class="mb-0 whitespace-pre-line text-sm leading-relaxed text-n-slate-12"
                >
                  {{ renderExamplePreview(activePreviewDraft) }}
                </p>
                <div
                  v-if="activePreviewDraft.buttons.length"
                  class="mt-3 border-t border-n-weak pt-2 flex flex-col gap-1.5"
                >
                  <div
                    v-for="(btn, idx) in activePreviewDraft.buttons"
                    :key="idx"
                    class="flex items-center justify-center gap-1.5 rounded-lg bg-n-alpha-black2 py-1.5 text-xs font-medium text-n-brand"
                  >
                    <span
                      :class="
                        btn.type === 'URL'
                          ? 'i-lucide-external-link size-3.5'
                          : 'i-lucide-reply size-3.5'
                      "
                    />
                    <span>{{ btn.text }}</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="mt-3 flex items-center justify-between text-[11px] text-n-slate-11">
              <span class="font-mono truncate">{{ activePreviewDraft.name }}</span>
            </div>
          </div>
        </div>
      </div>

      <div v-if="submitError" class="rounded-xl bg-n-ruby-9/10 p-3">
        <p class="mb-0 text-sm text-n-ruby-11">
          {{ submitError }}
        </p>
      </div>
    </div>

    <template #footer>
      <div class="flex items-center justify-end gap-3">
        <Button
          variant="faded"
          color="slate"
          :label="t('DIALOG.BUTTONS.CANCEL')"
          :disabled="isSubmitting"
          @click="close"
        />
        <Button
          data-testid="submit-template-pack-btn"
          :label="
            newDraftsToCreate.length
              ? t('SCHEDULING.REMINDERS.PACK_MODAL.SUBMIT', {
                  count: newDraftsToCreate.length,
                })
              : t('SCHEDULING.REMINDERS.PACK_MODAL.APPLY_EXISTING')
          "
          :is-loading="isSubmitting"
          @click="handleGenerate"
        />
      </div>
    </template>
  </Dialog>
</template>
