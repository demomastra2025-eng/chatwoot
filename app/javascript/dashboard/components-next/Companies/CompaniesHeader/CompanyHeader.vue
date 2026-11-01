<script setup>
import Input from 'dashboard/components-next/input/Input.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CompanySortMenu from './components/CompanySortMenu.vue';

defineProps({
  showSearch: { type: Boolean, default: true },
  searchValue: { type: String, default: '' },
  headerTitle: { type: String, required: true },
  showCreateButton: { type: Boolean, default: true },
  createButtonLabel: { type: String, default: '' },
  activeSort: { type: String, default: 'name' },
  activeOrdering: { type: String, default: '' },
});

const emit = defineEmits(['search', 'update:sort', 'create']);
</script>

<template>
  <header class="sticky top-0 z-10 px-6">
    <div
      class="flex min-w-0 flex-col justify-between w-full py-6 gap-4 mx-auto max-w-5xl lg:flex-row lg:items-center"
    >
      <div class="flex min-w-0 items-center gap-0.5">
        <span class="text-heading-1 truncate text-n-slate-12">
          {{ headerTitle }}
        </span>
      </div>
      <div class="flex min-w-0 w-full flex-wrap items-center gap-2 lg:w-auto">
        <div class="flex items-center">
          <CompanySortMenu
            :active-sort="activeSort"
            :active-ordering="activeOrdering"
            @update:sort="emit('update:sort', $event)"
          />
        </div>
        <Button
          v-if="showCreateButton"
          size="sm"
          class="shrink-0"
          :label="createButtonLabel || $t('COMPANIES.ACTIONS.ADD')"
          @click="emit('create')"
        />
        <div
          v-if="showSearch"
          class="flex min-w-0 w-full items-center gap-2 sm:flex-1 lg:w-64"
        >
          <Input
            :model-value="searchValue"
            type="search"
            :aria-label="$t('COMPANIES.SEARCH_PLACEHOLDER')"
            :placeholder="$t('COMPANIES.SEARCH_PLACEHOLDER')"
            class="w-full"
            @input="emit('search', $event.target.value)"
          >
            <template #suffix>
              <Icon
                icon="i-lucide-search"
                class="absolute -translate-y-1/2 text-n-slate-11 size-4 top-1/2 ltr:right-2 rtl:left-2"
              />
            </template>
          </Input>
        </div>
      </div>
    </div>
  </header>
</template>
