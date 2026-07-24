<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import languages from 'dashboard/components/widgets/conversation/advancedFilterItems/languages.js';
import WhatsAppTemplateCarouselEditor from './WhatsAppTemplateCarouselEditor.vue';
import {
  buildWhatsAppTemplatePayload,
  createEmptyCarouselCard,
  createEmptyTemplateButton,
  createEmptyWhatsAppTemplateForm,
  DEFAULT_TEMPLATE_LANGUAGE,
  extractSequentialTemplateVariables,
  hasDanglingTemplateVariable,
  MAX_CAROUSEL_BUTTONS,
  MAX_CAROUSEL_CARDS,
  MAX_TEMPLATE_BUTTONS,
  MIN_CAROUSEL_CARDS,
  TEMPLATE_BUTTON_TYPE_OPTIONS,
  TEMPLATE_CATEGORY_OPTIONS,
  TEMPLATE_HEADER_TYPE_OPTIONS,
} from 'dashboard/helper/whatsappTemplateLibrary';

const props = defineProps({
  inboxId: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['created']);

const { t } = useI18n();
const store = useStore();
const PHONE_NUMBER_PATTERN = /^\+[1-9]\d{1,14}$/;

const dialogRef = ref(null);
const isSubmitting = ref(false);
const submitError = ref('');
const form = reactive(createEmptyWhatsAppTemplateForm());

function syncExampleMap(currentMap, variables) {
  return Object.fromEntries(
    variables.map(variable => [variable, currentMap?.[variable] || ''])
  );
}

function placeholderToken(variable) {
  return `{{${variable}}}`;
}

const exampleVariables = Object.freeze({
  firstVariable: placeholderToken(1),
  secondVariable: placeholderToken(2),
});

const languageOptions = computed(() =>
  languages.map(({ id, name }) => ({
    value: id,
    label: `${name} (${id})`,
  }))
);

const categoryOptions = computed(() => [
  {
    ...TEMPLATE_CATEGORY_OPTIONS[0],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.CATEGORY_OPTIONS.UTILITY'),
  },
  {
    ...TEMPLATE_CATEGORY_OPTIONS[1],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.CATEGORY_OPTIONS.MARKETING'),
  },
  {
    ...TEMPLATE_CATEGORY_OPTIONS[2],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.CATEGORY_OPTIONS.AUTHENTICATION'),
  },
]);

const headerTypeOptions = computed(() => [
  {
    ...TEMPLATE_HEADER_TYPE_OPTIONS[0],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.NONE'),
  },
  {
    ...TEMPLATE_HEADER_TYPE_OPTIONS[1],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.TEXT'),
  },
  {
    ...TEMPLATE_HEADER_TYPE_OPTIONS[2],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.IMAGE'),
  },
  {
    ...TEMPLATE_HEADER_TYPE_OPTIONS[3],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.VIDEO'),
  },
  {
    ...TEMPLATE_HEADER_TYPE_OPTIONS[4],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.DOCUMENT'),
  },
]);

const buttonTypeOptions = computed(() => [
  {
    ...TEMPLATE_BUTTON_TYPE_OPTIONS[0],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_OPTIONS.QUICK_REPLY'),
  },
  {
    ...TEMPLATE_BUTTON_TYPE_OPTIONS[1],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_OPTIONS.URL'),
  },
  {
    ...TEMPLATE_BUTTON_TYPE_OPTIONS[2],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_OPTIONS.COPY_CODE'),
  },
  {
    ...TEMPLATE_BUTTON_TYPE_OPTIONS[3],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_OPTIONS.PHONE_NUMBER'),
  },
  {
    ...TEMPLATE_BUTTON_TYPE_OPTIONS[4],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_OPTIONS.CATALOG'),
  },
]);

const buttonUsesText = buttonType => buttonType !== 'COPY_CODE';
const buttonUsesUrl = buttonType => buttonType === 'URL';
const buttonUsesCopyCode = buttonType => buttonType === 'COPY_CODE';
const buttonUsesPhoneNumber = buttonType => buttonType === 'PHONE_NUMBER';
const buttonUsesCatalog = buttonType => buttonType === 'CATALOG';

const isAuthentication = computed(() => form.category === 'AUTHENTICATION');
const isStandardTemplate = computed(
  () => !isAuthentication.value && !form.isCarousel
);

const bodyVariableInfo = computed(() =>
  extractSequentialTemplateVariables(form.bodyText)
);
const headerVariableInfo = computed(() =>
  form.headerType === 'text'
    ? extractSequentialTemplateVariables(form.headerText)
    : { variables: [], error: '' }
);

const appendCarouselButtonErrors = (button, index, errors) => {
  if (!button.text.trim()) {
    errors.push(
      t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_TEXT_REQUIRED', {
        index,
      })
    );
  }

  if (buttonUsesUrl(button.type)) {
    const urlVariableInfo = extractSequentialTemplateVariables(button.url);
    if (!button.url.trim()) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_REQUIRED', {
          index,
        })
      );
    }
    if (urlVariableInfo.error) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_INVALID', {
          index,
        })
      );
    }
    if (urlVariableInfo.variables.length > 1) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_SINGLE_VARIABLE', {
          index,
        })
      );
    }
    if (
      urlVariableInfo.variables.length === 1 &&
      !/{{\s*\d+\s*}}$/.test(button.url.trim())
    ) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_SUFFIX', {
          index,
        })
      );
    }
    if (urlVariableInfo.variables.length === 1 && !button.example.trim()) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_EXAMPLE_REQUIRED', {
          index,
        })
      );
    }
  }

  if (buttonUsesPhoneNumber(button.type)) {
    if (!button.phoneNumber.trim()) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_PHONE_NUMBER_REQUIRED', {
          index,
        })
      );
    } else if (!PHONE_NUMBER_PATTERN.test(button.phoneNumber.trim())) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_PHONE_NUMBER_INVALID', {
          index,
        })
      );
    }
  }
};

const validationErrors = computed(() => {
  const errors = [];

  if (!form.name.trim()) {
    errors.push(t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.NAME_REQUIRED'));
  } else if (!/^[a-z0-9_]+$/.test(form.name.trim())) {
    errors.push(t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.NAME_FORMAT'));
  }

  if (isAuthentication.value) {
    const expirationMinutes = Number(form.codeExpirationMinutes);
    if (
      !Number.isInteger(expirationMinutes) ||
      expirationMinutes < 1 ||
      expirationMinutes > 90
    ) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.AUTH_EXPIRATION_RANGE')
      );
    }

    return [...new Set(errors)];
  }

  if (!form.bodyText.trim()) {
    errors.push(t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BODY_REQUIRED'));
  }

  if (bodyVariableInfo.value.error) {
    errors.push(bodyVariableInfo.value.error);
  }

  if (hasDanglingTemplateVariable(form.bodyText)) {
    errors.push(
      t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BODY_VARIABLE_POSITION')
    );
  }

  bodyVariableInfo.value.variables.forEach(variable => {
    if (!String(form.bodyExamples?.[variable] || '').trim()) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BODY_EXAMPLE_REQUIRED', {
          variable: placeholderToken(variable),
        })
      );
    }
  });

  if (form.isCarousel) {
    if (form.category !== 'MARKETING') {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_MARKETING_ONLY')
      );
    }
    if (
      form.carouselCards.length < MIN_CAROUSEL_CARDS ||
      form.carouselCards.length > MAX_CAROUSEL_CARDS
    ) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_CARD_LIMIT')
      );
    }

    const cardSignatures = form.carouselCards.map(card =>
      [
        card.bodyText.trim() ? 'BODY' : '',
        ...card.buttons.map(button => button.type),
      ].join('|')
    );
    if (new Set(cardSignatures).size > 1) {
      errors.push(t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_STRUCTURE'));
    }

    form.carouselCards.forEach((card, cardIndex) => {
      const visibleCardIndex = cardIndex + 1;

      if (!['image', 'video'].includes(card.headerType)) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_HEADER_TYPE', {
            index: visibleCardIndex,
          })
        );
      }
      if (!card.sampleMediaUrl.trim()) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_MEDIA_REQUIRED', {
            index: visibleCardIndex,
          })
        );
      }
      if (card.bodyText.trim().length > 160) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_BODY_LENGTH', {
            index: visibleCardIndex,
          })
        );
      }

      const cardVariableInfo = extractSequentialTemplateVariables(
        card.bodyText
      );
      if (cardVariableInfo.error) errors.push(cardVariableInfo.error);
      if (hasDanglingTemplateVariable(card.bodyText)) {
        errors.push(
          t(
            'WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_BODY_VARIABLE_POSITION',
            { index: visibleCardIndex }
          )
        );
      }
      cardVariableInfo.variables.forEach(variable => {
        if (!String(card.bodyExamples?.[variable] || '').trim()) {
          errors.push(
            t(
              'WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_BODY_EXAMPLE_REQUIRED',
              {
                index: visibleCardIndex,
                variable: placeholderToken(variable),
              }
            )
          );
        }
      });

      if (card.buttons.length > MAX_CAROUSEL_BUTTONS) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_BUTTON_LIMIT', {
            index: visibleCardIndex,
          })
        );
      }
      card.buttons.forEach((button, buttonIndex) => {
        if (!['QUICK_REPLY', 'URL', 'PHONE_NUMBER'].includes(button.type)) {
          errors.push(
            t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CAROUSEL_BUTTON_TYPE', {
              index: visibleCardIndex,
            })
          );
        }
        appendCarouselButtonErrors(
          button,
          `${visibleCardIndex}.${buttonIndex + 1}`,
          errors
        );
      });
    });

    return [...new Set(errors)];
  }

  if (form.headerType === 'text') {
    if (!form.headerText.trim()) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.HEADER_TEXT_REQUIRED')
      );
    }

    if (headerVariableInfo.value.error) {
      errors.push(headerVariableInfo.value.error);
    }

    if (hasDanglingTemplateVariable(form.headerText)) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.HEADER_VARIABLE_POSITION')
      );
    }

    headerVariableInfo.value.variables.forEach(variable => {
      if (!String(form.headerExamples?.[variable] || '').trim()) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.HEADER_EXAMPLE_REQUIRED', {
            variable: placeholderToken(variable),
          })
        );
      }
    });
  }

  if (
    ['image', 'video', 'document'].includes(form.headerType) &&
    !form.sampleMediaUrl.trim()
  ) {
    errors.push(t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.MEDIA_URL_REQUIRED'));
  }

  if (form.buttons.length > MAX_TEMPLATE_BUTTONS) {
    errors.push(
      t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_LIMIT', {
        count: MAX_TEMPLATE_BUTTONS,
      })
    );
  }

  form.buttons.forEach((button, index) => {
    const buttonIndex = index + 1;

    if (buttonUsesText(button.type) && !button.text.trim()) {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_TEXT_REQUIRED', {
          index: buttonIndex,
        })
      );
    }

    if (buttonUsesCatalog(button.type) && form.category !== 'MARKETING') {
      errors.push(
        t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.CATALOG_MARKETING_ONLY')
      );
    }

    if (buttonUsesUrl(button.type)) {
      const urlVariableInfo = extractSequentialTemplateVariables(button.url);

      if (!button.url.trim()) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_REQUIRED', {
            index: buttonIndex,
          })
        );
      }

      if (urlVariableInfo.error) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_INVALID', {
            index: buttonIndex,
          })
        );
      }

      if (urlVariableInfo.variables.length > 1) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_SINGLE_VARIABLE', {
            index: buttonIndex,
          })
        );
      }

      if (
        urlVariableInfo.variables.length === 1 &&
        !/{{\s*\d+\s*}}$/.test(button.url.trim())
      ) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_URL_SUFFIX', {
            index: buttonIndex,
          })
        );
      }

      if (urlVariableInfo.variables.length === 1 && !button.example.trim()) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_EXAMPLE_REQUIRED', {
            index: buttonIndex,
          })
        );
      }
    }

    if (buttonUsesCopyCode(button.type)) {
      if (!button.example.trim()) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_COPY_CODE_REQUIRED', {
            index: buttonIndex,
          })
        );
      } else if (button.example.trim().length > 15) {
        errors.push(
          t('WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_COPY_CODE_LENGTH', {
            index: buttonIndex,
          })
        );
      }
    }

    if (buttonUsesPhoneNumber(button.type)) {
      if (!button.phoneNumber.trim()) {
        errors.push(
          t(
            'WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_PHONE_NUMBER_REQUIRED',
            {
              index: buttonIndex,
            }
          )
        );
      } else if (!PHONE_NUMBER_PATTERN.test(button.phoneNumber.trim())) {
        errors.push(
          t(
            'WHATSAPP_TEMPLATES.MANAGEMENT.ERRORS.BUTTON_PHONE_NUMBER_INVALID',
            {
              index: buttonIndex,
            }
          )
        );
      }
    }
  });

  return [...new Set(errors)];
});

watch(
  bodyVariableInfo,
  variableInfo => {
    form.bodyExamples = syncExampleMap(
      form.bodyExamples,
      variableInfo.variables
    );
  },
  { immediate: true }
);

watch(
  headerVariableInfo,
  variableInfo => {
    form.headerExamples = syncExampleMap(
      form.headerExamples,
      variableInfo.variables
    );
  },
  { immediate: true }
);

watch(
  () => form.category,
  category => {
    if (category === 'AUTHENTICATION') form.isCarousel = false;
  }
);

const resetForm = () => {
  Object.assign(form, createEmptyWhatsAppTemplateForm());
  submitError.value = '';
};

const addButton = () => {
  if (form.buttons.length >= MAX_TEMPLATE_BUTTONS) {
    return;
  }

  form.buttons.push(createEmptyTemplateButton());
};

const removeButton = index => {
  form.buttons.splice(index, 1);
};

const updateButtonType = (index, type) => {
  const currentButton = form.buttons[index];
  form.buttons[index] = {
    ...currentButton,
    type,
    text: buttonUsesText(type) ? currentButton.text : '',
    url: buttonUsesUrl(type) ? currentButton.url : '',
    example:
      buttonUsesUrl(type) || buttonUsesCopyCode(type)
        ? currentButton.example
        : '',
    phoneNumber: buttonUsesPhoneNumber(type) ? currentButton.phoneNumber : '',
  };
};

const toggleCarousel = event => {
  form.isCarousel = event.target.checked;
  if (!form.isCarousel) return;

  form.category = 'MARKETING';
  form.headerType = 'none';
  form.headerText = '';
  form.footerText = '';
  form.sampleMediaUrl = '';
  form.headerExamples = {};
  form.buttons = [];
  if (form.carouselCards.length < MIN_CAROUSEL_CARDS) {
    form.carouselCards = Array.from(
      { length: MIN_CAROUSEL_CARDS },
      createEmptyCarouselCard
    );
  }
};

const open = () => {
  resetForm();
  dialogRef.value?.open();
};

const close = () => {
  dialogRef.value?.close();
};

const handleSubmit = async () => {
  submitError.value = validationErrors.value[0] || '';
  if (submitError.value) {
    return;
  }

  try {
    isSubmitting.value = true;
    const response = await store.dispatch('inboxes/createWhatsAppTemplate', {
      inboxId: props.inboxId,
      template: buildWhatsAppTemplatePayload(form),
    });

    useAlert(t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_SUCCESS'));
    emit('created', response);
    close();
  } catch (error) {
    submitError.value = error.message;
  } finally {
    isSubmitting.value = false;
  }
};

defineExpose({
  dialogRef,
  open,
  close,
});
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="3xl"
    :title="t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_TITLE')"
    :description="t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
  >
    <div class="space-y-6">
      <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
        <Input
          v-model="form.name"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.NAME.LABEL')"
          :placeholder="
            t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.NAME.PLACEHOLDER')
          "
        />
        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-heading-3 text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.LANGUAGE') }}
          </label>
          <ComboBox
            v-model="form.language"
            :placeholder="DEFAULT_TEMPLATE_LANGUAGE"
            :options="languageOptions"
            input-like
          />
        </div>
        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-heading-3 text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.CATEGORY') }}
          </label>
          <ComboBox
            v-model="form.category"
            :options="categoryOptions"
            input-like
          />
        </div>
      </div>

      <div
        v-if="isAuthentication"
        class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
      >
        <div class="space-y-1">
          <p class="mb-0 text-sm font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.AUTHENTICATION.TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.AUTHENTICATION.HINT') }}
          </p>
        </div>
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <input
            v-model="form.addSecurityRecommendation"
            type="checkbox"
            class="h-4 w-4 rounded border-n-weak"
          />
          {{
            t(
              'WHATSAPP_TEMPLATES.MANAGEMENT.AUTHENTICATION.SECURITY_RECOMMENDATION'
            )
          }}
        </label>
        <Input
          v-model="form.codeExpirationMinutes"
          type="number"
          min="1"
          max="90"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.AUTHENTICATION.EXPIRATION')"
        />
      </div>

      <label
        v-if="!isAuthentication"
        class="flex items-start gap-3 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
      >
        <input
          :checked="form.isCarousel"
          type="checkbox"
          class="mt-0.5 h-4 w-4 rounded border-n-weak"
          @change="toggleCarousel"
        />
        <span class="space-y-1">
          <span class="block text-sm font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.ENABLE') }}
          </span>
          <span class="block text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.ENABLE_HINT') }}
          </span>
        </span>
      </label>

      <div
        v-if="!isAuthentication"
        class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
      >
        <div class="space-y-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.BODY_SECTION') }}
          </p>
          <p class="text-sm text-n-slate-11">
            {{
              t('WHATSAPP_TEMPLATES.MANAGEMENT.VARIABLE_HINT', exampleVariables)
            }}
          </p>
        </div>

        <TextArea
          v-model="form.bodyText"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BODY_TEXT')"
          auto-height
          max-height="18rem"
          :placeholder="
            t(
              'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BODY_PLACEHOLDER',
              exampleVariables
            )
          "
        />

        <div
          v-if="bodyVariableInfo.variables.length"
          class="grid grid-cols-1 gap-3 md:grid-cols-2"
        >
          <Input
            v-for="variable in bodyVariableInfo.variables"
            :key="`body-${variable}`"
            v-model="form.bodyExamples[variable]"
            :label="
              t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BODY_EXAMPLE', {
                variable: placeholderToken(variable),
              })
            "
            :placeholder="
              t(
                'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BODY_EXAMPLE_PLACEHOLDER',
                {
                  variable: placeholderToken(variable),
                }
              )
            "
          />
        </div>
      </div>

      <WhatsAppTemplateCarouselEditor
        v-if="form.isCarousel"
        v-model="form.carouselCards"
      />

      <div
        v-if="isStandardTemplate"
        class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
      >
        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-heading-3 text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.HEADER_TYPE') }}
          </label>
          <ComboBox
            v-model="form.headerType"
            :options="headerTypeOptions"
            input-like
          />
        </div>

        <TextArea
          v-if="form.headerType === 'text'"
          v-model="form.headerText"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.HEADER_TEXT')"
          auto-height
          :placeholder="
            t(
              'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.HEADER_PLACEHOLDER',
              exampleVariables
            )
          "
        />

        <div
          v-if="
            form.headerType === 'text' && headerVariableInfo.variables.length
          "
          class="grid grid-cols-1 gap-3 md:grid-cols-2"
        >
          <Input
            v-for="variable in headerVariableInfo.variables"
            :key="`header-${variable}`"
            v-model="form.headerExamples[variable]"
            :label="
              t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.HEADER_EXAMPLE', {
                variable: placeholderToken(variable),
              })
            "
            :placeholder="
              t(
                'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.HEADER_EXAMPLE_PLACEHOLDER',
                {
                  variable: placeholderToken(variable),
                }
              )
            "
          />
        </div>

        <Input
          v-if="['image', 'video', 'document'].includes(form.headerType)"
          v-model="form.sampleMediaUrl"
          type="url"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_URL')"
          :placeholder="
            t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_URL_PLACEHOLDER')
          "
        />
      </div>

      <TextArea
        v-if="isStandardTemplate"
        v-model="form.footerText"
        :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.FOOTER_TEXT')"
        auto-height
        :placeholder="
          t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.FOOTER_PLACEHOLDER')
        "
      />

      <div
        v-if="isStandardTemplate"
        class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="space-y-1">
            <p class="text-sm font-medium text-n-slate-12">
              {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTONS_SECTION') }}
            </p>
            <p class="text-sm text-n-slate-11">
              {{
                t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTONS_HINT', {
                  count: MAX_TEMPLATE_BUTTONS,
                })
              }}
            </p>
          </div>
          <Button
            variant="outline"
            color="slate"
            size="sm"
            icon="i-lucide-plus"
            :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.ADD_BUTTON')"
            :disabled="form.buttons.length >= MAX_TEMPLATE_BUTTONS"
            @click="addButton"
          />
        </div>

        <div
          v-if="!form.buttons.length"
          class="rounded-xl bg-n-alpha-black2 p-4"
        >
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.NO_BUTTONS') }}
          </p>
        </div>

        <div
          v-for="(button, index) in form.buttons"
          :key="`button-${index}`"
          class="space-y-4 rounded-xl border border-n-weak bg-n-alpha-black2 p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <p class="mb-0 text-sm font-medium text-n-slate-12">
              {{
                t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_TITLE', {
                  index: index + 1,
                })
              }}
            </p>
            <Button
              variant="ghost"
              color="ruby"
              size="sm"
              icon="i-lucide-trash-2"
              @click="removeButton(index)"
            />
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <div class="flex flex-col gap-1">
              <label class="mb-0.5 text-heading-3 text-n-slate-12">
                {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_TYPE') }}
              </label>
              <ComboBox
                :model-value="button.type"
                :options="buttonTypeOptions"
                input-like
                @update:model-value="value => updateButtonType(index, value)"
              />
            </div>
            <Input
              v-if="buttonUsesText(button.type)"
              v-model="button.text"
              :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_TEXT')"
              :placeholder="
                t(
                  'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_TEXT_PLACEHOLDER'
                )
              "
            />
          </div>

          <div
            v-if="buttonUsesUrl(button.type)"
            class="grid grid-cols-1 gap-4 md:grid-cols-2"
          >
            <Input
              v-model="button.url"
              type="url"
              :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_URL')"
              :placeholder="
                t(
                  'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_URL_PLACEHOLDER',
                  exampleVariables
                )
              "
            />
            <Input
              v-if="
                extractSequentialTemplateVariables(button.url).variables.length
              "
              v-model="button.example"
              :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_EXAMPLE')"
              :placeholder="
                t(
                  'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_EXAMPLE_PLACEHOLDER'
                )
              "
            />
          </div>

          <Input
            v-if="buttonUsesCopyCode(button.type)"
            v-model="button.example"
            :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_COPY_CODE')"
            :placeholder="
              t(
                'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_COPY_CODE_PLACEHOLDER'
              )
            "
          />

          <Input
            v-if="buttonUsesPhoneNumber(button.type)"
            v-model="button.phoneNumber"
            :label="
              t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_PHONE_NUMBER')
            "
            :placeholder="
              t(
                'WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_PHONE_NUMBER_PLACEHOLDER'
              )
            "
          />
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
          @click="close"
        />
        <Button
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_ACTION')"
          :is-loading="isSubmitting"
          @click="handleSubmit"
        />
      </div>
    </template>
  </Dialog>
</template>
