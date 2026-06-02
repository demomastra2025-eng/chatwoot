<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import CaptainSkillsAPI from 'dashboard/api/captain/skills';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { useKeyboardNavigableList } from 'dashboard/composables/useKeyboardNavigableList';
import {
  filterAndSortCatalogItems,
  matchesCatalogSearch,
} from 'dashboard/helper/captainCatalog';

const props = defineProps({
  searchKey: {
    type: String,
    default: '',
  },
  assistantId: {
    type: Number,
    default: null,
  },
  usedItemIds: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['close', 'selectSkill']);

const { t } = useI18n();

const selectedIndex = ref(0);
const skills = ref([]);
const searchQuery = ref(props.searchKey || '');
const showWorkspaceOnly = ref(false);
const skillFormMode = ref(null);
const isSavingSkill = ref(false);
const skillForm = ref({
  name: '',
  description: '',
  groupName: '',
  content: '',
  sourceUrl: '',
});

const loadSkills = async () => {
  try {
    const response = await CaptainSkillsAPI.get({
      assistantId: props.assistantId,
    });
    skills.value = response.data || [];
  } catch {
    skills.value = [];
  }
};

const usedItemIdSet = computed(() => new Set(props.usedItemIds || []));

const normalizedSkills = computed(() =>
  skills.value.map(skill => ({
    ...skill,
    group_label: skill.group_name,
    isUsed: usedItemIdSet.value.has(skill.id),
    isWorkspace: skill.source_type === 'workspace',
  }))
);

const workspaceSkills = computed(() =>
  normalizedSkills.value.filter(skill => skill.isWorkspace)
);

const filteredSkills = computed(() =>
  filterAndSortCatalogItems(
    normalizedSkills.value.filter(skill => {
      if (showWorkspaceOnly.value && !skill.isWorkspace) return false;
      if (matchesCatalogSearch(skill, searchQuery.value)) return true;
      return (skill.tree || []).some(file =>
        String(file.path || '')
          .toLowerCase()
          .includes(searchQuery.value.trim().toLowerCase())
      );
    }),
    { search: '' }
  )
);

const selectedSkill = computed(() => filteredSkills.value[selectedIndex.value]);

const skillTree = computed(() => [
  {
    path: 'SKILL.md',
    type: 'file',
    size: selectedSkill.value?.content?.length,
  },
  ...(selectedSkill.value?.tree || []),
]);

const visibleTree = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return skillTree.value;

  return skillTree.value.filter(entry =>
    String(entry.path || '')
      .toLowerCase()
      .includes(query)
  );
});

const displayPath = path =>
  String(path || '')
    .split('/')
    .pop();
const depthFor = path => Math.max(String(path || '').split('/').length - 1, 0);

const onSelect = idx => {
  if (idx !== undefined) selectedIndex.value = idx;
  if (!selectedSkill.value) return;

  emit('selectSkill', selectedSkill.value);
  emit('close');
};

const selectSkill = skill => {
  const idx = filteredSkills.value.findIndex(item => item.id === skill.id);
  onSelect(idx >= 0 ? idx : selectedIndex.value);
};

const resetSkillForm = () => {
  skillForm.value = {
    name: '',
    description: '',
    groupName: '',
    content: '',
    sourceUrl: '',
  };
};

const openCreateSkillForm = () => {
  resetSkillForm();
  skillFormMode.value = 'create';
};

const openImportSkillForm = () => {
  resetSkillForm();
  skillFormMode.value = 'import';
};

const openEditSkillForm = skill => {
  if (!skill?.editable) return;
  skillForm.value = {
    id: skill.workspace_skill_id,
    name: skill.name || skill.title || '',
    description: skill.description || '',
    groupName: skill.group_name || '',
    content: skill.content || '',
    sourceUrl: skill.source_url || '',
  };
  skillFormMode.value = 'edit';
};

const closeSkillForm = () => {
  skillFormMode.value = null;
  resetSkillForm();
};

const skillPayload = () => ({
  name: skillForm.value.name,
  description: skillForm.value.description,
  group_name: skillForm.value.groupName,
  content: skillForm.value.content,
  source_url: skillForm.value.sourceUrl,
});

const saveSkill = async () => {
  try {
    isSavingSkill.value = true;
    if (skillFormMode.value === 'import') {
      await CaptainSkillsAPI.importWorkspace(skillForm.value.sourceUrl);
    } else if (skillFormMode.value === 'edit') {
      await CaptainSkillsAPI.updateWorkspace(
        skillForm.value.id,
        skillPayload()
      );
    } else {
      await CaptainSkillsAPI.createWorkspace(skillPayload());
    }
    useAlert(t('CAPTAIN.ASSISTANTS.SKILLS.SAVED'));
    closeSkillForm();
    await loadSkills();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('CAPTAIN.ASSISTANTS.SKILLS.SAVE_ERROR')
    );
  } finally {
    isSavingSkill.value = false;
  }
};

useKeyboardNavigableList({
  items: filteredSkills,
  onSelect,
  adjustScroll: () => {},
  selectedIndex,
});

watch(
  () => props.assistantId,
  () => loadSkills(),
  { immediate: true }
);

watch(
  () => props.searchKey,
  newValue => {
    searchQuery.value = newValue || '';
  }
);

watch([searchQuery, showWorkspaceOnly], () => {
  selectedIndex.value = 0;
});

watch(filteredSkills, newList => {
  if (newList.length < selectedIndex.value + 1) {
    selectedIndex.value = 0;
  }
});
</script>

<template>
  <div
    class="absolute z-50 mt-1 grid w-[44rem] max-w-[calc(100vw-3rem)] grid-cols-[minmax(14rem,18rem)_minmax(0,1fr)] overflow-hidden rounded-xl border border-n-weak bg-n-solid-1 shadow-lg"
  >
    <div class="border-r border-n-weak p-3">
      <Input
        v-model="searchQuery"
        autofocus
        :placeholder="t('CAPTAIN.ASSISTANTS.SKILLS.SEARCH_PLACEHOLDER')"
      />
      <div class="mt-3 flex flex-wrap gap-2">
        <Button
          xs
          slate
          :label="t('CAPTAIN.ASSISTANTS.SKILLS.ADD_OWN')"
          @click="openCreateSkillForm"
        />
        <Button
          xs
          slate
          variant="faded"
          :label="t('CAPTAIN.ASSISTANTS.SKILLS.IMPORT')"
          @click="openImportSkillForm"
        />
        <Button
          xs
          slate
          variant="faded"
          :label="
            showWorkspaceOnly
              ? t('CAPTAIN.ASSISTANTS.SKILLS.SHOW_ALL')
              : t('CAPTAIN.ASSISTANTS.SKILLS.SHOW_OWN', {
                  count: workspaceSkills.length,
                })
          "
          @click="showWorkspaceOnly = !showWorkspaceOnly"
        />
      </div>
      <div class="mt-3 max-h-80 overflow-y-auto">
        <button
          v-for="(skill, index) in filteredSkills"
          :key="skill.id"
          type="button"
          class="flex w-full min-w-0 flex-col gap-1 rounded-lg px-3 py-2 text-left hover:bg-n-slate-3"
          :class="{ 'bg-n-slate-4': index === selectedIndex }"
          @mousemove="selectedIndex = index"
          @click="selectSkill(skill)"
        >
          <span class="flex min-w-0 items-center gap-2">
            <Icon icon="i-lucide-badge-check" class="size-4 text-n-iris-10" />
            <span class="truncate text-sm font-medium text-n-slate-12">
              {{ skill.title }}
            </span>
            <span
              v-if="skill.isWorkspace"
              class="rounded bg-n-iris-3 px-1.5 py-0.5 text-[0.625rem] font-medium text-n-iris-11"
            >
              {{ t('CAPTAIN.ASSISTANTS.SKILLS.OWN_BADGE') }}
            </span>
            <span
              v-if="skill.isUsed"
              class="rounded bg-n-teal-3 px-1.5 py-0.5 text-[0.625rem] font-medium text-n-teal-11"
            >
              {{ t('CAPTAIN.ASSISTANTS.SKILLS.USED') }}
            </span>
          </span>
          <span class="line-clamp-2 text-xs text-n-slate-11">
            {{ skill.description }}
          </span>
        </button>
        <p
          v-if="!filteredSkills.length"
          class="px-3 py-6 text-sm text-n-slate-11"
        >
          {{ t('CAPTAIN.ASSISTANTS.SKILLS.EMPTY') }}
        </p>
      </div>
    </div>

    <div class="flex min-w-0 flex-col p-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="truncate text-sm font-semibold text-n-slate-12">
            {{ selectedSkill?.title || t('CAPTAIN.ASSISTANTS.SKILLS.TITLE') }}
          </h3>
          <p class="mt-1 line-clamp-2 text-xs text-n-slate-11">
            {{ selectedSkill?.description }}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <Button
            v-if="selectedSkill?.editable"
            xs
            slate
            variant="faded"
            :label="t('CAPTAIN.ASSISTANTS.SKILLS.EDIT')"
            @click="openEditSkillForm(selectedSkill)"
          />
          <Button
            v-if="selectedSkill"
            xs
            slate
            :label="t('CAPTAIN.ASSISTANTS.SKILLS.INSERT')"
            @click="selectSkill(selectedSkill)"
          />
        </div>
      </div>

      <form
        v-if="skillFormMode"
        class="mt-3 flex flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-2 p-3"
        @submit.prevent="saveSkill"
      >
        <p class="mb-0 text-sm font-semibold text-n-slate-12">
          {{
            skillFormMode === 'import'
              ? t('CAPTAIN.ASSISTANTS.SKILLS.IMPORT_TITLE')
              : skillFormMode === 'edit'
                ? t('CAPTAIN.ASSISTANTS.SKILLS.EDIT_TITLE')
                : t('CAPTAIN.ASSISTANTS.SKILLS.CREATE_TITLE')
          }}
        </p>
        <Input
          v-if="skillFormMode === 'import'"
          v-model="skillForm.sourceUrl"
          :label="t('CAPTAIN.ASSISTANTS.SKILLS.SOURCE_URL')"
          placeholder="https://raw.githubusercontent.com/org/repo/main/skill/SKILL.md"
        />
        <template v-else>
          <Input
            v-model="skillForm.name"
            :label="t('CAPTAIN.ASSISTANTS.SKILLS.NAME')"
          />
          <Input
            v-model="skillForm.description"
            :label="t('CAPTAIN.ASSISTANTS.SKILLS.DESCRIPTION')"
          />
          <Input
            v-model="skillForm.groupName"
            :label="t('CAPTAIN.ASSISTANTS.SKILLS.GROUP')"
          />
          <textarea
            v-model="skillForm.content"
            class="min-h-40 rounded-lg border border-n-weak bg-n-alpha-black2 p-3 text-sm text-n-slate-12 outline-none focus:border-n-brand"
            :placeholder="t('CAPTAIN.ASSISTANTS.SKILLS.CONTENT_PLACEHOLDER')"
          />
        </template>
        <div class="flex justify-end gap-2">
          <Button
            type="button"
            xs
            slate
            variant="faded"
            :label="t('CAPTAIN.FORM.CANCEL')"
            @click="closeSkillForm"
          />
          <Button
            type="submit"
            xs
            slate
            :is-loading="isSavingSkill"
            :disabled="isSavingSkill"
            :label="t('CAPTAIN.ASSISTANTS.SKILLS.SAVE')"
          />
        </div>
      </form>
      <div
        v-if="!skillFormMode && selectedSkill?.scripts?.length"
        class="mt-3 rounded-lg border border-n-weak bg-n-solid-2 p-2"
      >
        <p class="mb-1 text-xs font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.SKILLS.SCRIPTS') }}
        </p>
        <div
          v-for="script in selectedSkill.scripts"
          :key="script.id"
          class="flex min-w-0 items-start justify-between gap-2 py-1 text-xs text-n-slate-11"
        >
          <div class="min-w-0">
            <p class="truncate font-medium text-n-slate-12">
              {{ script.title }}
            </p>
            <p class="truncate font-mono text-[0.6875rem]">
              {{ script.tool_id }}
            </p>
          </div>
          <span class="shrink-0 rounded bg-n-slate-3 px-1.5 py-0.5">
            {{ script.risk_level }}
          </span>
        </div>
      </div>

      <div
        v-if="!skillFormMode && selectedSkill"
        class="mt-3 grid min-h-0 flex-1 grid-cols-[minmax(11rem,14rem)_minmax(0,1fr)] gap-3"
      >
        <div
          class="max-h-72 overflow-y-auto rounded-lg border border-n-weak p-2"
        >
          <div
            v-for="entry in visibleTree"
            :key="entry.path"
            class="flex min-w-0 items-center gap-1 rounded px-1.5 py-1 text-xs text-n-slate-11"
            :style="{
              paddingLeft: `${depthFor(entry.path) * 0.75 + 0.375}rem`,
            }"
          >
            <Icon
              :icon="
                entry.type === 'directory'
                  ? 'i-lucide-folder'
                  : 'i-lucide-file-text'
              "
              class="size-3.5 flex-shrink-0 text-n-slate-10"
            />
            <span class="truncate">{{ displayPath(entry.path) }}</span>
          </div>
        </div>

        <div
          class="max-h-72 overflow-auto rounded-lg border border-n-weak bg-n-alpha-black2 p-3 text-xs leading-5 text-n-slate-12 whitespace-pre-wrap"
        >
          <code>{{ selectedSkill.content }}</code>
        </div>
      </div>
    </div>
  </div>
</template>
