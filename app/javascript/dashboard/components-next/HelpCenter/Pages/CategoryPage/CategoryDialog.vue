<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { useRoute } from 'vue-router';
import { PORTALS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import CategoryForm from 'dashboard/components-next/HelpCenter/Pages/CategoryPage/CategoryForm.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'edit',
    validator: value => ['edit', 'create'].includes(value),
  },
  selectedCategory: {
    type: Object,
    default: () => ({}),
  },
  portalName: {
    type: String,
    default: '',
  },
  activeLocaleName: {
    type: String,
    default: '',
  },
  activeLocaleCode: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['close']);

const store = useStore();
const { t } = useI18n();
const route = useRoute();
const dialogRef = ref(null);
const categoryFormRef = ref(null);
const isSaving = ref(false);
const isSubmitDisabled = computed(
  () => categoryFormRef.value?.isSubmitDisabled ?? true
);
onMounted(() => dialogRef.value?.open());

const handleCategory = async formData => {
  if (isSaving.value) return;
  isSaving.value = true;
  const { id, name, slug, icon, description, locale } = formData;
  const categoryData = { name, icon, slug, description };

  if (props.mode === 'create') {
    categoryData.locale = locale;
  } else {
    categoryData.id = id;
  }

  try {
    const action = props.mode === 'edit' ? 'update' : 'create';
    const payload = {
      portalSlug: route.params.portalSlug,
      categoryObj: categoryData,
    };

    if (action === 'update') {
      payload.categoryId = id;
    }

    await store.dispatch(`categories/${action}`, payload);

    const successMessage = t(
      `HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.${props.mode.toUpperCase()}.API.SUCCESS_MESSAGE`
    );
    useAlert(successMessage);

    const trackEvent =
      props.mode === 'edit'
        ? PORTALS_EVENTS.EDIT_CATEGORY
        : PORTALS_EVENTS.CREATE_CATEGORY;
    useTrack(
      trackEvent,
      props.mode === 'create'
        ? { hasDescription: Boolean(description) }
        : undefined
    );

    dialogRef.value?.close();
  } catch (error) {
    const errorMessage =
      error?.message ||
      t(
        `HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.${props.mode.toUpperCase()}.API.ERROR_MESSAGE`
      );
    useAlert(errorMessage);
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    width="md"
    overflow-y-auto
    :title="
      t(
        `HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.HEADER.${mode.toUpperCase()}`
      )
    "
    :confirm-button-label="
      t(
        `HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.BUTTONS.${mode.toUpperCase()}`
      )
    "
    :cancel-button-label="
      t('HELP_CENTER.CATEGORY_PAGE.CATEGORY_DIALOG.BUTTONS.CANCEL')
    "
    :is-loading="isSaving"
    :disable-confirm-button="isSaving || isSubmitDisabled"
    @confirm="categoryFormRef?.submit()"
    @close="emit('close')"
  >
    <CategoryForm
      ref="categoryFormRef"
      :mode="mode"
      :selected-category="selectedCategory"
      :active-locale-code="activeLocaleCode"
      :portal-name="portalName"
      :active-locale-name="activeLocaleName"
      :show-action-buttons="false"
      @submit="handleCategory"
    />
  </Dialog>
</template>
