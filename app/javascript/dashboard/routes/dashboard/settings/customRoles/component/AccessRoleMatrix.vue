<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  roles: {
    type: Array,
    default: () => [],
  },
  resources: {
    type: Object,
    default: () => ({}),
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  hasError: {
    type: Boolean,
    default: false,
  },
  searchQuery: {
    type: String,
    default: '',
  },
  mutationsEnabled: {
    type: Boolean,
    default: false,
  },
  deletingRoles: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['retry', 'clone', 'edit', 'delete']);
const { t } = useI18n();

const scopeClasses = {
  none: 'bg-n-slate-3 text-n-slate-10',
  own: 'bg-n-blue-3 text-n-blue-11',
  team: 'bg-n-violet-3 text-n-violet-11',
  all: 'bg-n-teal-3 text-n-teal-11',
};

const translations = computed(() => ({
  roleKinds: {
    system: t('CUSTOM_ROLE.ACCESS_MATRIX.ROLE_KIND.SYSTEM'),
    custom: t('CUSTOM_ROLE.ACCESS_MATRIX.ROLE_KIND.CUSTOM'),
  },
  systemRoles: {
    administrator: t('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.ADMINISTRATOR'),
    employee: t('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.EMPLOYEE'),
    department_lead: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.DEPARTMENT_LEAD'
    ),
    commercial_director: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.COMMERCIAL_DIRECTOR'
    ),
    observer: t('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.OBSERVER'),
  },
  resources: {
    contacts: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.CONTACTS'),
    conversations: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.CONVERSATIONS'),
    appointments: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.APPOINTMENTS'),
    deals: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.DEALS'),
    tasks: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.TASKS'),
    automation_rules: t('CUSTOM_ROLE.ACCESS_MATRIX.RESOURCES.AUTOMATION_RULES'),
  },
  capabilities: {
    view: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW'),
    create: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.CREATE'),
    update_fields: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.UPDATE_FIELDS'),
    assign: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.ASSIGN'),
    transition: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.TRANSITION'),
    take: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.TAKE'),
    complete_cancel: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.COMPLETE_CANCEL'
    ),
    delete_archive: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.DELETE_ARCHIVE'),
    view_configuration: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW_CONFIGURATION'
    ),
    configure: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.CONFIGURE'),
    export: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.EXPORT'),
    view_reports: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.VIEW_REPORTS'),
    override_schedule: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.OVERRIDE_SCHEDULE'
    ),
    manage: t('CUSTOM_ROLE.ACCESS_MATRIX.CAPABILITIES.MANAGE'),
  },
  scopes: {
    none: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.NONE'),
    own: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.OWN'),
    team: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.TEAM'),
    all: t('CUSTOM_ROLE.ACCESS_MATRIX.SCOPES.ALL'),
  },
}));

const sourceRole = id => props.roles.find(role => role.id === id);
const cloneSourceRole = role => ({
  ...sourceRole(role.id),
  name: role.displayName,
});

const matrixRoles = computed(() => {
  const query = props.searchQuery.trim().toLowerCase();
  return props.roles
    .map(role => ({
      ...role,
      displayName: translations.value.systemRoles[role.system_key] || role.name,
      roleKindLabel:
        translations.value.roleKinds[role.role_kind] ||
        translations.value.roleKinds.custom,
      resourceGroups: Object.entries(props.resources).map(
        ([resource, capabilities]) => ({
          resource,
          label: translations.value.resources[resource] || resource,
          grants: capabilities.map(capability => {
            const grant = role.grants.find(
              item =>
                item.resource === resource && item.capability === capability
            );
            return {
              capability,
              accessScope: grant?.access_scope || 'none',
              capabilityLabel:
                translations.value.capabilities[capability] || capability,
              scopeLabel:
                translations.value.scopes[grant?.access_scope || 'none'],
            };
          }),
        })
      ),
    }))
    .filter(role => {
      if (!query) return true;
      return [role.displayName, role.name, role.description].some(value =>
        value?.toLowerCase().includes(query)
      );
    });
});
</script>

<template>
  <section
    class="flex flex-col gap-4 rounded-xl border border-n-weak bg-n-solid-1 p-5"
    aria-labelledby="access-role-matrix-title"
  >
    <div class="flex flex-col gap-1">
      <h2 id="access-role-matrix-title" class="text-heading-3 text-n-slate-12">
        {{ $t('CUSTOM_ROLE.ACCESS_MATRIX.TITLE') }}
      </h2>
      <p class="text-body-main text-n-slate-11">
        {{ $t('CUSTOM_ROLE.ACCESS_MATRIX.DESCRIPTION') }}
      </p>
    </div>

    <div
      v-if="isLoading"
      class="rounded-lg bg-n-slate-2 px-4 py-8 text-center text-body-main text-n-slate-11"
      aria-live="polite"
      data-testid="access-role-matrix-loading"
    >
      {{ $t('CUSTOM_ROLE.ACCESS_MATRIX.LOADING') }}
    </div>

    <div
      v-else-if="hasError"
      class="flex flex-col items-center gap-3 rounded-lg border border-n-ruby-5 bg-n-ruby-2 px-4 py-8 text-center"
      role="alert"
      data-testid="access-role-matrix-error"
    >
      <p class="text-body-main text-n-ruby-11">
        {{ $t('CUSTOM_ROLE.ACCESS_MATRIX.ERROR') }}
      </p>
      <Button
        :label="$t('CUSTOM_ROLE.ACCESS_MATRIX.RETRY')"
        size="sm"
        slate
        @click="emit('retry')"
      />
    </div>

    <p
      v-else-if="!matrixRoles.length"
      class="rounded-lg bg-n-slate-2 px-4 py-8 text-center text-body-main text-n-slate-11"
      data-testid="access-role-matrix-empty"
    >
      {{ $t('CUSTOM_ROLE.ACCESS_MATRIX.EMPTY') }}
    </p>

    <div v-else class="flex flex-col gap-3">
      <details
        v-for="(role, index) in matrixRoles"
        :key="role.id"
        :open="index === 0"
        class="group rounded-lg border border-n-weak bg-n-alpha-1"
        data-testid="access-role-card"
      >
        <summary
          class="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 marker:hidden"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="truncate text-heading-4 text-n-slate-12">
                {{ role.displayName }}
              </span>
              <span
                class="rounded-full bg-n-slate-3 px-2 py-0.5 text-label-mini text-n-slate-11"
              >
                {{ role.roleKindLabel }}
              </span>
            </div>
            <p
              v-if="role.description"
              class="truncate text-body-small text-n-slate-10"
            >
              {{ role.description }}
            </p>
          </div>
          <div class="flex flex-shrink-0 items-center gap-3">
            <div v-if="mutationsEnabled" class="flex items-center gap-2">
              <Button
                :label="$t('CUSTOM_ROLE.ACCESS_EDITOR.CLONE_BUTTON')"
                size="sm"
                faded
                slate
                type="button"
                @click.stop="emit('clone', cloneSourceRole(role))"
              />
              <Button
                v-if="role.role_kind === 'custom'"
                :label="$t('CUSTOM_ROLE.EDIT.BUTTON_TEXT')"
                size="sm"
                faded
                slate
                type="button"
                @click.stop="emit('edit', sourceRole(role.id))"
              />
              <Button
                v-if="role.role_kind === 'custom'"
                :label="$t('CUSTOM_ROLE.DELETE.BUTTON_TEXT')"
                size="sm"
                ruby
                type="button"
                :is-loading="Boolean(deletingRoles[role.id])"
                :disabled="
                  Boolean(deletingRoles[role.id]) ||
                  role.assigned_users_count > 0
                "
                @click.stop="emit('delete', sourceRole(role.id))"
              />
            </div>
            <span class="text-body-small text-n-slate-10">
              {{
                $t('CUSTOM_ROLE.ACCESS_MATRIX.ASSIGNED_USERS', {
                  n: role.assigned_users_count || 0,
                })
              }}
            </span>
            <span
              class="i-lucide-chevron-down size-4 text-n-slate-10 transition-transform group-open:rotate-180"
              aria-hidden="true"
            />
          </div>
        </summary>

        <div class="border-t border-n-weak px-4 py-4">
          <div class="grid gap-4 xl:grid-cols-2">
            <section
              v-for="resourceGroup in role.resourceGroups"
              :key="resourceGroup.resource"
              class="flex flex-col gap-2"
              :data-testid="`access-role-resource-${resourceGroup.resource}`"
            >
              <h3 class="text-label-default text-n-slate-12">
                {{ resourceGroup.label }}
              </h3>
              <ul class="flex flex-wrap gap-2">
                <li
                  v-for="grant in resourceGroup.grants"
                  :key="grant.capability"
                  class="flex items-center overflow-hidden rounded-md border border-n-weak bg-n-solid-1 text-label-mini"
                  :data-scope="grant.accessScope"
                >
                  <span class="px-2 py-1 text-n-slate-11">
                    {{ grant.capabilityLabel }}
                  </span>
                  <span
                    class="self-stretch px-2 py-1"
                    :class="
                      scopeClasses[grant.accessScope] || scopeClasses.none
                    "
                  >
                    {{ grant.scopeLabel }}
                  </span>
                </li>
              </ul>
            </section>
          </div>
        </div>
      </details>
    </div>
  </section>
</template>
