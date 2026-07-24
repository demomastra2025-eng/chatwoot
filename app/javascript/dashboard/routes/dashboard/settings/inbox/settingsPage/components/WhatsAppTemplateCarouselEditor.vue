<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import {
  createEmptyCarouselCard,
  createEmptyTemplateButton,
  extractSequentialTemplateVariables,
  MAX_CAROUSEL_BUTTONS,
  MAX_CAROUSEL_CARDS,
  TEMPLATE_BUTTON_TYPE_OPTIONS,
} from 'dashboard/helper/whatsappTemplateLibrary';

const cards = defineModel({
  type: Array,
  required: true,
});

const { t } = useI18n();

const headerTypeOptions = computed(() => [
  {
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.IMAGE'),
    value: 'image',
  },
  {
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.HEADER_OPTIONS.VIDEO'),
    value: 'video',
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
    ...TEMPLATE_BUTTON_TYPE_OPTIONS[3],
    label: t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTON_OPTIONS.PHONE_NUMBER'),
  },
]);

const cardVariables = card =>
  extractSequentialTemplateVariables(card.bodyText).variables;

const updateCard = (index, patch) => {
  cards.value = cards.value.map((card, cardIndex) =>
    cardIndex === index ? { ...card, ...patch } : card
  );
};

const updateCardBody = (index, bodyText) => {
  const card = cards.value[index];
  const variables = extractSequentialTemplateVariables(bodyText).variables;
  const bodyExamples = Object.fromEntries(
    variables.map(variable => [variable, card.bodyExamples?.[variable] || ''])
  );
  updateCard(index, { bodyText, bodyExamples });
};

const addCard = () => {
  if (cards.value.length >= MAX_CAROUSEL_CARDS) return;

  cards.value = [...cards.value, createEmptyCarouselCard()];
};

const removeCard = index => {
  cards.value = cards.value.filter((_, cardIndex) => cardIndex !== index);
};

const addCardButton = cardIndex => {
  const card = cards.value[cardIndex];
  if (card.buttons.length >= MAX_CAROUSEL_BUTTONS) return;

  updateCard(cardIndex, {
    buttons: [...card.buttons, createEmptyTemplateButton()],
  });
};

const removeCardButton = (cardIndex, buttonIndex) => {
  const card = cards.value[cardIndex];
  updateCard(cardIndex, {
    buttons: card.buttons.filter((_, index) => index !== buttonIndex),
  });
};

const updateCardButton = (cardIndex, buttonIndex, patch) => {
  const card = cards.value[cardIndex];
  updateCard(cardIndex, {
    buttons: card.buttons.map((button, index) =>
      index === buttonIndex ? { ...button, ...patch } : button
    ),
  });
};

const updateCardButtonType = (cardIndex, buttonIndex, type) => {
  const currentButton = cards.value[cardIndex].buttons[buttonIndex];
  updateCardButton(cardIndex, buttonIndex, {
    type,
    text: currentButton.text,
    url: type === 'URL' ? currentButton.url : '',
    example: type === 'URL' ? currentButton.example : '',
    phoneNumber: type === 'PHONE_NUMBER' ? currentButton.phoneNumber : '',
  });
};
</script>

<template>
  <div class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4">
    <div class="flex items-center justify-between gap-3">
      <div class="space-y-1">
        <p class="mb-0 text-sm font-medium text-n-slate-12">
          {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.TITLE') }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.HINT') }}
        </p>
      </div>
      <Button
        variant="outline"
        color="slate"
        size="sm"
        icon="i-lucide-plus"
        :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.ADD_CARD')"
        :disabled="cards.length >= MAX_CAROUSEL_CARDS"
        @click="addCard"
      />
    </div>

    <div
      v-for="(card, cardIndex) in cards"
      :key="`carousel-card-${cardIndex}`"
      class="space-y-4 rounded-xl border border-n-weak bg-n-alpha-black2 p-4"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="mb-0 text-sm font-medium text-n-slate-12">
          {{
            t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.CARD_TITLE', {
              index: cardIndex + 1,
            })
          }}
        </p>
        <Button
          variant="ghost"
          color="ruby"
          size="sm"
          icon="i-lucide-trash-2"
          @click="removeCard(cardIndex)"
        />
      </div>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-heading-3 text-n-slate-12">
            {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.HEADER_TYPE') }}
          </label>
          <ComboBox
            :model-value="card.headerType"
            :options="headerTypeOptions"
            input-like
            @update:model-value="
              value => updateCard(cardIndex, { headerType: value })
            "
          />
        </div>
        <Input
          :model-value="card.sampleMediaUrl"
          type="url"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_URL')"
          :placeholder="
            t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.MEDIA_URL_PLACEHOLDER')
          "
          @update:model-value="
            value => updateCard(cardIndex, { sampleMediaUrl: value })
          "
        />
      </div>

      <TextArea
        :model-value="card.bodyText"
        :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.CAROUSEL.CARD_BODY')"
        auto-height
        max-height="10rem"
        @update:model-value="value => updateCardBody(cardIndex, value)"
      />

      <div
        v-if="cardVariables(card).length"
        class="grid grid-cols-1 gap-3 md:grid-cols-2"
      >
        <Input
          v-for="variable in cardVariables(card)"
          :key="`card-${cardIndex}-body-${variable}`"
          :model-value="card.bodyExamples[variable]"
          :label="
            t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BODY_EXAMPLE', {
              variable: `{{${variable}}}`,
            })
          "
          @update:model-value="
            value =>
              updateCard(cardIndex, {
                bodyExamples: { ...card.bodyExamples, [variable]: value },
              })
          "
        />
      </div>

      <div class="flex items-center justify-between gap-3">
        <p class="mb-0 text-sm font-medium text-n-slate-12">
          {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.BUTTONS_SECTION') }}
        </p>
        <Button
          variant="outline"
          color="slate"
          size="sm"
          icon="i-lucide-plus"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.ADD_BUTTON')"
          :disabled="card.buttons.length >= MAX_CAROUSEL_BUTTONS"
          @click="addCardButton(cardIndex)"
        />
      </div>

      <div
        v-for="(button, buttonIndex) in card.buttons"
        :key="`card-${cardIndex}-button-${buttonIndex}`"
        class="space-y-3 rounded-xl border border-n-weak bg-n-surface-1 p-3"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex flex-1 flex-col gap-1">
            <label class="mb-0.5 text-heading-3 text-n-slate-12">
              {{ t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_TYPE') }}
            </label>
            <ComboBox
              :model-value="button.type"
              :options="buttonTypeOptions"
              input-like
              @update:model-value="
                value => updateCardButtonType(cardIndex, buttonIndex, value)
              "
            />
          </div>
          <Button
            variant="ghost"
            color="ruby"
            size="sm"
            icon="i-lucide-trash-2"
            @click="removeCardButton(cardIndex, buttonIndex)"
          />
        </div>

        <Input
          :model-value="button.text"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_TEXT')"
          @update:model-value="
            value => updateCardButton(cardIndex, buttonIndex, { text: value })
          "
        />
        <Input
          v-if="button.type === 'URL'"
          :model-value="button.url"
          type="url"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_URL')"
          @update:model-value="
            value => updateCardButton(cardIndex, buttonIndex, { url: value })
          "
        />
        <Input
          v-if="button.type === 'URL' && button.url.includes('{{')"
          :model-value="button.example"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_EXAMPLE')"
          @update:model-value="
            value =>
              updateCardButton(cardIndex, buttonIndex, { example: value })
          "
        />
        <Input
          v-if="button.type === 'PHONE_NUMBER'"
          :model-value="button.phoneNumber"
          :label="t('WHATSAPP_TEMPLATES.MANAGEMENT.FIELDS.BUTTON_PHONE_NUMBER')"
          @update:model-value="
            value =>
              updateCardButton(cardIndex, buttonIndex, { phoneNumber: value })
          "
        />
      </div>
    </div>
  </div>
</template>
