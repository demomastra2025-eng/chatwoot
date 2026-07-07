<!-- eslint-disable vue/v-slot-style -->
<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useIntegrationHook } from 'dashboard/composables/useIntegrationHook';
import { FormKit } from '@formkit/vue';
import { useBranding } from 'shared/composables/useBranding';

import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    FormKit,
    NextButton,
  },
  props: {
    integrationId: {
      type: String,
      required: true,
    },
    hook: {
      type: Object,
      default: null,
    },
  },
  emits: ['close'],
  setup(props) {
    const { integration, isHookTypeInbox } = useIntegrationHook(
      props.integrationId
    );
    const { replaceInstallationName } = useBranding();

    return { integration, isHookTypeInbox, replaceInstallationName };
  },
  data() {
    return {
      alertMessage: '',
      values: {},
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'integrations/getUIFlags',
      dialogFlowEnabledInboxes: 'inboxes/dialogFlowEnabledInboxes',
    }),
    inboxes() {
      return this.dialogFlowEnabledInboxes
        .filter(inbox => {
          if (!this.isIntegrationDialogflow) {
            return true;
          }
          return !this.connectedDialogflowInboxIds.includes(inbox.id);
        })
        .map(inbox => ({ label: inbox.name, value: inbox.id }));
    },

    connectedDialogflowInboxIds() {
      if (!this.isIntegrationDialogflow) {
        return [];
      }
      return (this.integration.hooks || []).map(hook => hook.inbox?.id);
    },
    isEditing() {
      return !!this.hook?.id;
    },
    formItems() {
      return (this.integration.settings_form_schema || []).map(item => {
        const normalizedItem = {
          ...item,
          placeholder:
            typeof item.placeholder === 'string'
              ? item.placeholder.replace(/\\n/g, '\n')
              : item.placeholder,
        };

        if (
          this.isEditing &&
          ['access_token', 'secret_settings'].includes(item.store)
        ) {
          return { ...normalizedItem, validation: '' };
        }
        return normalizedItem;
      });
    },
    isIntegrationDialogflow() {
      return this.integration.id === 'dialogflow';
    },
    submitLoading() {
      return this.isEditing
        ? this.uiFlags.isUpdatingHook
        : this.uiFlags.isCreatingHook;
    },
  },
  watch: {
    integration: {
      immediate: true,
      handler() {
        this.setInitialValues();
      },
    },
    hook: {
      immediate: true,
      handler() {
        this.setInitialValues();
      },
    },
  },
  methods: {
    onClose() {
      this.$emit('close');
    },
    defaultValueForItem(item) {
      if (this.isEditing) {
        if (item.store === 'status') {
          return this.hook.status;
        }

        if (item.store === 'access_token' || item.store === 'secret_settings') {
          return '';
        }

        if (
          Object.prototype.hasOwnProperty.call(
            this.hook.settings || {},
            item.name
          )
        ) {
          if (item.validation?.includes('JSON')) {
            return JSON.stringify(this.hook.settings[item.name], null, 2);
          }

          return this.hook.settings[item.name];
        }
      }

      if (Object.prototype.hasOwnProperty.call(item, 'value')) {
        return item.value;
      }

      return item.type === 'checkbox' ? false : '';
    },
    setInitialValues() {
      if (!this.integration?.id) {
        return;
      }

      const values = this.formItems.reduce((acc, item) => {
        acc[item.name] = this.defaultValueForItem(item);
        return acc;
      }, {});

      if (this.isHookTypeInbox && this.isEditing && this.hook?.inbox?.id) {
        values.inbox = this.hook.inbox.id;
      }

      this.values = values;
    },
    buildHookPayload() {
      const hookPayload = {
        app_id: this.integration.id,
        settings: {},
      };

      hookPayload.settings = Object.keys(this.values).reduce((acc, key) => {
        if (key === 'inbox') {
          return acc;
        }

        const formItem = this.formItems.find(item => item.name === key);

        if (formItem?.store === 'access_token') {
          if (this.values[key]) {
            hookPayload.access_token = this.values[key];
          }
          return acc;
        }

        if (formItem?.store === 'secret_settings') {
          if (this.values[key]) {
            hookPayload.secret_settings ||= {};
            hookPayload.secret_settings[key] = this.values[key];
          }
          return acc;
        }

        if (formItem?.store === 'status') {
          hookPayload.status = this.values[key] ? 'enabled' : 'disabled';
          return acc;
        }

        if (formItem?.validation?.includes('JSON') && !this.values[key]) {
          return acc;
        }

        let value = this.values[key];

        if (
          ['integer', 'number'].includes(formItem?.value_type) &&
          value !== ''
        ) {
          value = Number(value);
        }

        if (
          (value === '' || value === null || value === undefined) &&
          !formItem?.validation?.includes('required')
        ) {
          return acc;
        }

        acc[key] = value;
        return acc;
      }, {});

      this.formItems.forEach(item => {
        if (item.store) {
          return;
        }

        if (
          item.validation?.includes('JSON') &&
          hookPayload.settings[item.name]
        ) {
          hookPayload.settings[item.name] =
            typeof hookPayload.settings[item.name] === 'string'
              ? JSON.parse(hookPayload.settings[item.name])
              : hookPayload.settings[item.name];
        }
      });

      if (this.isHookTypeInbox && this.values.inbox) {
        hookPayload.inbox_id = this.values.inbox;
      }

      return hookPayload;
    },
    async submitForm() {
      try {
        const hookPayload = this.buildHookPayload();

        if (this.isEditing) {
          await this.$store.dispatch('integrations/updateHook', {
            hookId: this.hook.id,
            hookData: hookPayload,
          });
        } else {
          await this.$store.dispatch('integrations/createHook', hookPayload);
        }

        this.alertMessage = this.$t('INTEGRATION_APPS.ADD.API.SUCCESS_MESSAGE');
        this.onClose();
      } catch (error) {
        const errorMessage =
          error?.response?.data?.message ||
          error?.response?.data?.error ||
          error?.response?.data?.errors?.[0] ||
          error?.message;
        this.alertMessage =
          errorMessage || this.$t('INTEGRATION_APPS.ADD.API.ERROR_MESSAGE');
      } finally {
        useAlert(this.alertMessage);
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto integration-hooks">
    <woot-modal-header
      :header-title="integration.name"
      :header-content="replaceInstallationName(integration.short_description)"
    />
    <FormKit
      v-model="values"
      type="form"
      form-class="w-full grid gap-4"
      :submit-attrs="{
        inputClass: 'hidden',
        wrapperClass: 'hidden',
      }"
      :incomplete-message="false"
      @submit="submitForm"
    >
      <FormKit v-for="item in formItems" :key="item.name" v-bind="item" />
      <FormKit
        v-if="isHookTypeInbox"
        :options="inboxes"
        type="select"
        name="inbox"
        input-class="reset-base"
        :placeholder="$t('INTEGRATION_APPS.ADD.FORM.INBOX.LABEL')"
        :label="$t('INTEGRATION_APPS.ADD.FORM.INBOX.PLACEHOLDER')"
        validation="required"
        validation-name="Inbox"
      />
      <div class="flex flex-row justify-end w-full gap-2 px-0 py-2">
        <NextButton
          faded
          slate
          type="reset"
          :label="$t('INTEGRATION_APPS.ADD.FORM.CANCEL')"
          @click.prevent="onClose"
        />
        <NextButton
          type="submit"
          :label="$t('INTEGRATION_APPS.ADD.FORM.SUBMIT')"
          :is-loading="submitLoading"
        />
      </div>
    </FormKit>
  </div>
</template>

<style lang="css">
.formkit-outer {
  @apply mt-2;
}

.formkit-form > .formkit-wrapper > ul.formkit-messages {
  @apply hidden;
}

.formkit-form .formkit-help {
  @apply text-n-slate-10 text-sm font-normal mt-2 w-full;
}

/* equivalent of .reset-base */
.formkit-input {
  margin-bottom: 0px !important;
}

[data-invalid] .formkit-message {
  @apply text-n-ruby-9 block text-xs font-normal my-1 w-full;
}

.formkit-outer[data-type='checkbox'] .formkit-wrapper {
  @apply flex items-center gap-2 px-0.5;
}

.formkit-messages {
  @apply list-none m-0 p-0;
}

.formkit-actions {
  @apply hidden;
}
</style>
