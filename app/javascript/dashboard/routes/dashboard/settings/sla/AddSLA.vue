<script>
import { useAlert } from 'dashboard/composables';
import SlaForm from './SlaForm.vue';

export default {
  components: {
    SlaForm,
  },
  props: {
    selectedResponse: {
      type: Object,
      default: () => ({}),
    },
  },
  emits: ['close'],
  computed: {
    isEditMode() {
      return !!this.selectedResponse?.id;
    },
    headerTitle() {
      if (this.isEditMode) return this.$t('SLA.EDIT.TITLE');
      return this.$t('SLA.ADD.TITLE');
    },
    headerDescription() {
      if (this.isEditMode) return this.$t('SLA.EDIT.DESC');
      return this.$t('SLA.ADD.DESC');
    },
    submitLabel() {
      if (this.isEditMode) return this.$t('SLA.FORM.EDIT');
      return this.$t('SLA.FORM.CREATE');
    },
    errorMessage() {
      if (this.isEditMode) return this.$t('SLA.EDIT.API.ERROR_MESSAGE');
      return this.$t('SLA.ADD.API.ERROR_MESSAGE');
    },
  },
  methods: {
    onClose() {
      this.$emit('close');
    },
    async submitSLA(payload) {
      try {
        if (this.isEditMode) {
          await this.$store.dispatch('sla/update', {
            id: this.selectedResponse.id,
            ...payload,
          });
          useAlert(this.$t('SLA.EDIT.API.SUCCESS_MESSAGE'));
        } else {
          await this.$store.dispatch('sla/create', payload);
          useAlert(this.$t('SLA.ADD.API.SUCCESS_MESSAGE'));
        }
        this.onClose();
      } catch (error) {
        const errorMessage = error.message || this.errorMessage;
        useAlert(errorMessage);
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <woot-modal-header
      :header-title="headerTitle"
      :header-content="headerDescription"
    />
    <SlaForm
      :selected-response="selectedResponse"
      :submit-label="submitLabel"
      @submit-sla="submitSLA"
      @close="onClose"
    />
  </div>
</template>
