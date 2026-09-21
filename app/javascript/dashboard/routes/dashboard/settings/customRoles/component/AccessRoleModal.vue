<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

const props = defineProps({
  mode: {
    type: String,
    default: 'add',
    validator: value => ['add', 'clone', 'edit'].includes(value),
  },
  selectedRole: {
    type: Object,
    default: () => ({}),
  },
  resources: {
    type: Object,
    default: () => ({}),
  },
  accessScopes: {
    type: Array,
    default: () => [],
  },
  resourceAccessScopes: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['close', 'stale']);
const store = useStore();
const { t } = useI18n();

const name = ref('');
const description = ref('');
const grantScopes = reactive({});
const isSubmitting = ref(false);
const hasSubmitted = ref(false);

const resourceLabels = computed(() => ({
  contacts: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.CONTACTS'),
  conversations: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.CONVERSATIONS'),
  appointments: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.APPOINTMENTS'),
  deals: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.DEALS'),
  tasks: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.TASKS'),
  automation_rules: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.AUTOMATION_RULES'),
}));

const capabilityLabels = computed(() => ({
  view: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW'),
  create: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.CREATE'),
  update_fields: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.UPDATE_FIELDS'),
  assign: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.ASSIGN'),
  transition: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.TRANSITION'),
  take: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.TAKE'),
  complete_cancel: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.COMPLETE_CANCEL'),
  delete_archive: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.DELETE_ARCHIVE'),
  view_configuration: t(
    'CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW_CONFIGURATION'
  ),
  configure: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.CONFIGURE'),
  export: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.EXPORT'),
  view_reports: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW_REPORTS'),
  view_finance: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW_FINANCE'),
  manage_finance: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.MANAGE_FINANCE'),
  override_schedule: t(
    'CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.OVERRIDE_SCHEDULE'
  ),
  manage: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.MANAGE'),
}));

const scopeLabels = computed(() => ({
  none: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.NONE'),
  own: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.OWN'),
  team: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.TEAM'),
  all: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.ALL'),
}));

const resourceGroups = computed(() =>
  Object.entries(props.resources).map(([resource, capabilities]) => ({
    resource,
    label: resourceLabels.value[resource] || resource,
    capabilities: capabilities.map(capability => ({
      capability,
      key: `${resource}:${capability}`,
      label: capabilityLabels.value[capability] || capability,
    })),
  }))
);

const defaultAvailableScopes = computed(() => {
  const scopes = props.accessScopes.length
    ? props.accessScopes
    : ['none', 'own', 'team', 'all'];
  return scopes.includes('none') ? scopes : ['none', ...scopes];
});

const availableScopesFor = resource => {
  const scopes = props.resourceAccessScopes[resource];
  if (!scopes?.length) return defaultAvailableScopes.value;
  return scopes.includes('none') ? scopes : ['none', ...scopes];
};

const isInvalid = computed(
  () => name.value.trim().length < 2 || !description.value.trim()
);
const modalTitle = computed(() => {
  if (props.mode === 'edit') {
    return t('CUSTOM_ROLE.ACCESS_EDITOR.EDIT_TITLE');
  }
  if (props.mode === 'clone') {
    return t('CUSTOM_ROLE.ACCESS_EDITOR.CLONE_TITLE');
  }
  return t('CUSTOM_ROLE.ACCESS_EDITOR.ADD_TITLE');
});
const submitLabel = computed(() => {
  if (props.mode === 'edit') return t('CUSTOM_ROLE.EDIT.SUBMIT');
  if (props.mode === 'clone') {
    return t('CUSTOM_ROLE.ACCESS_EDITOR.CLONE_SUBMIT');
  }
  return t('CUSTOM_ROLE.ADD.SUBMIT');
});

const hydrateForm = () => {
  const selectedRole = props.selectedRole || {};
  if (props.mode === 'clone') {
    name.value = t('CUSTOM_ROLE.ACCESS_EDITOR.CLONE_NAME', {
      name: selectedRole.name || '',
    });
  } else {
    name.value = props.mode === 'edit' ? selectedRole.name || '' : '';
  }
  if (props.mode === 'add') {
    description.value = '';
  } else if (props.mode === 'clone' && !selectedRole.description) {
    description.value = t('CUSTOM_ROLE.ACCESS_EDITOR.CLONE_DESCRIPTION', {
      name: selectedRole.name || '',
    });
  } else {
    description.value = selectedRole.description || '';
  }

  Object.keys(grantScopes).forEach(key => delete grantScopes[key]);
  resourceGroups.value.forEach(group => {
    group.capabilities.forEach(item => {
      grantScopes[item.key] = 'none';
    });
  });
  (selectedRole.grants || []).forEach(grant => {
    grantScopes[`${grant.resource}:${grant.capability}`] = grant.access_scope;
  });
  hasSubmitted.value = false;
};

watch(
  () => [props.mode, props.selectedRole?.id, props.selectedRole?.lock_version],
  hydrateForm,
  { immediate: true }
);

const resourceSchema = computed(() =>
  Object.entries(props.resources)
    .map(([resource, capabilities]) => `${resource}:${capabilities.join(',')}`)
    .join('|')
);

watch(
  resourceSchema,
  () => {
    resourceGroups.value.forEach(group => {
      group.capabilities.forEach(item => {
        if (!(item.key in grantScopes)) grantScopes[item.key] = 'none';
      });
    });
  },
  { immediate: true }
);

const buildGrants = () =>
  resourceGroups.value.flatMap(group =>
    group.capabilities
      .filter(item => (grantScopes[item.key] || 'none') !== 'none')
      .map(item => ({
        resource: group.resource,
        capability: item.capability,
        access_scope: grantScopes[item.key] || 'none',
      }))
  );

const submit = async () => {
  hasSubmitted.value = true;
  if (isInvalid.value || isSubmitting.value) return;

  isSubmitting.value = true;
  const payload = {
    name: name.value.trim(),
    description: description.value.trim(),
    grants: buildGrants(),
  };

  try {
    if (props.mode === 'edit') {
      await store.dispatch('customRole/updateAccessRole', {
        id: props.selectedRole.id,
        lock_version: props.selectedRole.lock_version,
        ...payload,
      });
      useAlert(t('CUSTOM_ROLE.ACCESS_EDITOR.UPDATE_SUCCESS'));
    } else {
      await store.dispatch('customRole/createAccessRole', payload);
      useAlert(t('CUSTOM_ROLE.ACCESS_EDITOR.CREATE_SUCCESS'));
    }
    emit('close');
  } catch (error) {
    if (error?.code === 'STALE_ACCESS_ROLE') {
      emit('stale', props.selectedRole.id);
    } else if (error?.code === 'ACCESS_ROLE_NOT_FOUND') {
      useAlert(t('CUSTOM_ROLE.ACCESS_EDITOR.NOT_FOUND_ERROR'));
      emit('close');
    } else if (
      [
        'ACCESS_ROLE_MUTATIONS_NOT_ENABLED',
        'ACCESS_CONTROL_NOT_ENFORCED',
      ].includes(error?.code)
    ) {
      useAlert(error?.message || t('CUSTOM_ROLE.ACCESS_EDITOR.SAVE_ERROR'));
      emit('close');
    } else {
      useAlert(error?.message || t('CUSTOM_ROLE.ACCESS_EDITOR.SAVE_ERROR'));
    }
  } finally {
    isSubmitting.value = false;
  }
};
</script>

<template>
  <div class="flex max-h-[85vh] flex-col overflow-auto">
    <woot-modal-header
      :header-title="modalTitle"
      :header-content="$t('CUSTOM_ROLE.ACCESS_EDITOR.DESCRIPTION')"
    />

    <form class="flex w-full flex-col gap-5" @submit.prevent="submit">
      <label class="flex flex-col gap-1 text-label-default text-n-slate-12">
        {{ $t('CUSTOM_ROLE.FORM.NAME.LABEL') }}
        <input
          v-model.trim="name"
          type="text"
          :placeholder="$t('CUSTOM_ROLE.FORM.NAME.PLACEHOLDER')"
          :aria-invalid="hasSubmitted && name.length < 2"
        />
      </label>

      <label class="flex flex-col gap-1 text-label-default text-n-slate-12">
        {{ $t('CUSTOM_ROLE.FORM.DESCRIPTION.LABEL') }}
        <textarea
          v-model="description"
          :rows="3"
          :placeholder="$t('CUSTOM_ROLE.FORM.DESCRIPTION.PLACEHOLDER')"
          :aria-invalid="hasSubmitted && !description.trim()"
        />
      </label>

      <div class="flex flex-col gap-4">
        <div
          v-for="group in resourceGroups"
          :key="group.resource"
          class="rounded-lg border border-n-weak p-4"
        >
          <h3 class="mb-3 text-label-default text-n-slate-12">
            {{ group.label }}
          </h3>
          <div class="grid gap-3 md:grid-cols-2">
            <label
              v-for="item in group.capabilities"
              :key="item.key"
              class="flex items-center justify-between gap-3 text-body-small text-n-slate-11"
            >
              <span>{{ item.label }}</span>
              <select
                v-model="grantScopes[item.key]"
                class="min-w-28 rounded-md border border-n-weak bg-n-solid-1 px-2 py-1"
                :aria-label="`${group.label}: ${item.label}`"
              >
                <option
                  v-for="scope in availableScopesFor(group.resource)"
                  :key="scope"
                  :value="scope"
                >
                  {{ scopeLabels[scope] || scope }}
                </option>
              </select>
            </label>
          </div>
        </div>
      </div>

      <p
        v-if="hasSubmitted && isInvalid"
        class="text-body-small text-n-ruby-11"
        role="alert"
      >
        {{ $t('CUSTOM_ROLE.ACCESS_EDITOR.VALIDATION_ERROR') }}
      </p>

      <div class="flex justify-end gap-2 py-2">
        <Button
          faded
          slate
          type="button"
          :label="$t('CUSTOM_ROLE.FORM.CANCEL_BUTTON_TEXT')"
          @click="emit('close')"
        />
        <Button
          type="submit"
          :label="submitLabel"
          :disabled="isSubmitting"
          :is-loading="isSubmitting"
        />
      </div>
    </form>
  </div>
</template>
