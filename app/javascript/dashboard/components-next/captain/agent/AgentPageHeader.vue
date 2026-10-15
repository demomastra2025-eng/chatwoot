<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import AgentDeleteDialog from './AgentDeleteDialog.vue';
import { useAgentActiveToggle } from './useAgentActiveToggle';
import { AGENT_DESCRIPTION_MAX_LENGTH } from './agentDraft';

// Agent page header: breadcrumb, avatar (changed at once), inline name and
// one-line description (part of the page draft), «активен» switch,
// «Проверить», the single «Сохранить» and the kebab menu. Read-only for
// non-admins.
const props = defineProps({
  assistant: { type: Object, required: true },
  draft: { type: Object, required: true },
  errors: { type: Object, default: () => ({}) },
  showErrors: { type: Boolean, default: false },
  canEdit: { type: Boolean, default: false },
  isDirty: { type: Boolean, default: false },
  isValid: { type: Boolean, default: true },
  isSaving: { type: Boolean, default: false },
});

const emit = defineEmits(['update:draft', 'save', 'check', 'deleted']);

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const { setActive, isToggling } = useAgentActiveToggle();

const deleteDialogRef = ref(null);
const showMenu = ref(false);
const avatarPreview = ref('');
const isAvatarBusy = ref(false);
const pendingActive = ref(null);

const accountId = computed(() => route.params.accountId);

const updateDraft = patch => emit('update:draft', { ...props.draft, ...patch });

const name = computed({
  get: () => props.draft.name || '',
  set: value => updateDraft({ name: value ?? '' }),
});
const routingDescription = computed({
  get: () => props.draft.routingDescription || '',
  set: value => updateDraft({ routingDescription: value ?? '' }),
});

const displayName = computed(
  () =>
    props.draft.name ||
    props.assistant?.name ||
    t('CAPTAIN.AGENT_PAGE.NAME_PLACEHOLDER')
);

const descriptionLength = computed(() => routingDescription.value.length);

const nameError = computed(() =>
  props.showErrors && props.errors?.name === 'required'
    ? t('CAPTAIN.AGENT_PAGE.NAME_REQUIRED')
    : ''
);

const descriptionError = computed(() => {
  if (!props.showErrors) return '';
  if (props.errors?.routingDescription === 'required') {
    return t('CAPTAIN.AGENT_PAGE.DESCRIPTION_REQUIRED');
  }
  if (props.errors?.routingDescription === 'max') {
    return t('CAPTAIN.AGENT_PAGE.DESCRIPTION_MAX', {
      max: AGENT_DESCRIPTION_MAX_LENGTH,
    });
  }
  return '';
});

// Borderless until hovered or focused, so the name reads as the page title.
const inlineInputClass = hasError =>
  hasError
    ? '!bg-transparent'
    : '!bg-transparent !outline-transparent hover:!outline-n-weak focus:!outline-n-brand';

const breadcrumbRoute = computed(() => ({
  name: 'captain_agents_index',
  params: { accountId: accountId.value },
}));

// Active switch: shows the requested value while the request runs and falls
// back to the stored value when it is refused.
const isActive = computed(() =>
  pendingActive.value === null
    ? props.assistant?.active !== false
    : pendingActive.value
);
const isActiveToggling = computed(() => isToggling(props.assistant?.id));

const handleActiveChange = async value => {
  if (!props.canEdit) return;
  pendingActive.value = Boolean(value);
  try {
    await setActive(props.assistant, Boolean(value));
  } finally {
    pendingActive.value = null;
  }
};

const refreshAssistant = () =>
  store.dispatch('captainAssistants/show', props.assistant.id);

const handleAvatarUpload = async ({ file, url }) => {
  if (!props.canEdit || !file || isAvatarBusy.value) return;
  isAvatarBusy.value = true;
  avatarPreview.value = url || '';
  try {
    await CaptainAssistantAPI.updateAvatar(props.assistant.id, file);
    await refreshAssistant();
  } catch {
    useAlert(t('CAPTAIN.AGENT_PAGE.AVATAR_UPLOAD_ERROR'));
  } finally {
    avatarPreview.value = '';
    isAvatarBusy.value = false;
  }
};

const handleAvatarDelete = async () => {
  if (!props.canEdit || isAvatarBusy.value) return;
  isAvatarBusy.value = true;
  try {
    await CaptainAssistantAPI.deleteAvatar(props.assistant.id);
    await refreshAssistant();
  } catch {
    useAlert(t('CAPTAIN.AGENT_PAGE.AVATAR_DELETE_ERROR'));
  } finally {
    isAvatarBusy.value = false;
  }
};

const avatarSrc = computed(
  () => avatarPreview.value || props.assistant?.avatar_url || ''
);

const menuItems = computed(() => [
  {
    label: t('CAPTAIN.AGENT_PAGE.MENU.LOGS'),
    value: 'logs',
    action: 'logs',
    icon: 'i-lucide-scroll-text',
  },
  {
    label: t('CAPTAIN.AGENT_PAGE.MENU.DELETE'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const logsRoute = computed(() => ({
  name: 'captain_observability_index',
  params: { accountId: accountId.value },
  query: { assistant_id: props.assistant?.id },
}));

const handleMenuAction = ({ action }) => {
  showMenu.value = false;
  if (action === 'logs') {
    router.push(logsRoute.value);
    return;
  }
  if (action === 'delete') deleteDialogRef.value?.open();
};
</script>

<template>
  <div class="flex flex-col gap-3 pt-3 pb-1" data-test="agent-page-header">
    <router-link
      :to="breadcrumbRoute"
      :aria-label="t('CAPTAIN.AGENT_PAGE.BREADCRUMB_ARIA')"
      class="w-fit text-heading-3 text-n-slate-11 hover:text-n-slate-12"
      data-test="agent-breadcrumb"
    >
      {{ `${t('CAPTAIN.NAV.GROUP')} ›` }}
    </router-link>

    <div
      class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
    >
      <div class="flex min-w-0 flex-1 items-start gap-3">
        <Avatar
          :src="avatarSrc"
          :name="displayName"
          :size="48"
          icon-name="i-woot-captain"
          rounded-full
          :allow-upload="canEdit && !isAvatarBusy"
          @upload="handleAvatarUpload"
          @delete="handleAvatarDelete"
        />
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <template v-if="canEdit">
            <Input
              v-model="name"
              :placeholder="t('CAPTAIN.AGENT_PAGE.NAME_PLACEHOLDER')"
              :message="nameError"
              :message-type="nameError ? 'error' : 'info'"
              :custom-input-class="[
                'text-heading-1 !text-lg',
                inlineInputClass(Boolean(nameError)),
              ]"
              data-test="agent-name-input"
            />
            <Input
              v-model="routingDescription"
              size="sm"
              :placeholder="t('CAPTAIN.AGENT_PAGE.DESCRIPTION_PLACEHOLDER')"
              :message-type="descriptionError ? 'error' : 'info'"
              :custom-input-class="[
                'text-body-main !text-n-slate-11',
                inlineInputClass(Boolean(descriptionError)),
              ]"
              data-test="agent-description-input"
            />
            <div class="flex items-start justify-between gap-3 px-3">
              <p
                class="mb-0 min-w-0 text-label-small text-n-ruby-9"
                data-test="agent-description-error"
              >
                {{ descriptionError }}
              </p>
              <span
                class="shrink-0 text-label-small tabular-nums"
                :class="
                  descriptionLength > AGENT_DESCRIPTION_MAX_LENGTH
                    ? 'text-n-ruby-9'
                    : 'text-n-slate-10'
                "
                data-test="agent-description-counter"
              >
                {{ `${descriptionLength} / ${AGENT_DESCRIPTION_MAX_LENGTH}` }}
              </span>
            </div>
          </template>
          <template v-else>
            <h1 class="mb-0 truncate text-heading-1 text-n-slate-12">
              {{ displayName }}
            </h1>
            <p
              class="mb-0 text-body-main"
              :class="
                assistant.routing_description
                  ? 'text-n-slate-11'
                  : 'text-n-slate-10'
              "
            >
              {{
                assistant.routing_description ||
                t('CAPTAIN.AGENT_PAGE.DESCRIPTION_EMPTY')
              }}
            </p>
          </template>
        </div>
      </div>

      <div class="flex shrink-0 flex-wrap items-center gap-2 lg:pt-1">
        <label
          v-if="canEdit"
          class="mb-0 flex items-center gap-2 px-1 text-body-main font-normal text-n-slate-12"
          data-test="agent-active"
        >
          <Switch
            :model-value="isActive"
            :disabled="isActiveToggling"
            @update:model-value="handleActiveChange"
          />
          {{ t('CAPTAIN.AGENT_PAGE.ACTIVE') }}
        </label>
        <span
          v-else
          class="px-1 text-body-main text-n-slate-11"
          data-test="agent-active-status"
        >
          {{
            isActive
              ? t('CAPTAIN.ASSISTANTS.ROUTING.ACTIVE_STATUS')
              : t('CAPTAIN.ASSISTANTS.ROUTING.INACTIVE_STATUS')
          }}
        </span>
        <Button
          :label="t('CAPTAIN.AGENT_PAGE.CHECK')"
          icon="i-lucide-message-circle"
          color="slate"
          variant="faded"
          size="sm"
          data-test="agent-check"
          @click="emit('check')"
        />
        <Button
          v-if="canEdit"
          :label="t('CAPTAIN.AGENT_PAGE.SAVE')"
          size="sm"
          :disabled="!isDirty || !isValid || isSaving"
          :is-loading="isSaving"
          data-test="agent-save"
          @click="emit('save')"
        />
        <div
          v-if="canEdit"
          v-on-clickaway="() => (showMenu = false)"
          class="relative"
        >
          <Button
            icon="i-lucide-ellipsis-vertical"
            color="slate"
            variant="ghost"
            size="sm"
            :aria-label="t('CAPTAIN.AGENT_PAGE.MENU.ACTIONS_ARIA')"
            data-test="agent-menu"
            @click="showMenu = !showMenu"
          />
          <DropdownMenu
            v-if="showMenu"
            :menu-items="menuItems"
            class="top-full mt-1 ltr:right-0 rtl:left-0"
            @action="handleMenuAction"
          />
        </div>
      </div>
    </div>

    <AgentDeleteDialog
      v-if="canEdit"
      ref="deleteDialogRef"
      :assistant="assistant"
      @deleted="emit('deleted', $event)"
    />
  </div>
</template>
