<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMoneyInput from 'dashboard/components-next/Scheduling/SchedulingMoneyInput.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import {
  formatSchedulingErrorMessage,
  toIntegerNumeric,
} from 'dashboard/stores/scheduling/shared';
import { formatCurrency } from '../helpers';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t } = useI18n();
const referencesStore = useSchedulingReferencesStore();

const productDrawerOpen = ref(false);
const searchQuery = ref('');
const selectedCategory = ref('all');
const selectedItemType = ref('all');
const showInactive = ref(false);

const productForm = reactive({
  id: null,
  name: '',
  itemType: 'product',
  code: '',
  article: '',
  category: '',
  uom: 'шт',
  price: 0,
  wholesalePrice: '',
  kaspiPrice: '',
  buyPrice: 0,
  minPrice: 0,
  stock: 0,
  reserve: 0,
  inTransit: 0,
  description: '',
  active: true,
});

const formatErrorMessage = error => formatSchedulingErrorMessage(error, t);

const pageErrorDescription = computed(() =>
  formatErrorMessage(referencesStore.ui.error)
);

const products = computed(() => referencesStore.products || []);

const categories = computed(() => {
  const unique = new Set();
  products.value.forEach(item => {
    if (item.category) unique.add(item.category);
  });
  return Array.from(unique).sort((a, b) => a.localeCompare(b, 'ru'));
});

const filteredProducts = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();

  return products.value.filter(product => {
    if (!showInactive.value && !product.active) return false;
    if (
      selectedCategory.value !== 'all' &&
      product.category !== selectedCategory.value
    ) {
      return false;
    }
    if (
      selectedItemType.value !== 'all' &&
      product.itemType !== selectedItemType.value
    ) {
      return false;
    }
    if (!query) return true;

    const haystack = [
      product.name,
      product.code,
      product.article,
      product.category,
      product.description,
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();

    return haystack.includes(query);
  });
});

const summaryCounts = computed(() => {
  const activeList = products.value.filter(item => item.active);
  const inStock = activeList.filter(
    item => Number(item.availableNow ?? item.stock ?? 0) > 0
  ).length;

  return {
    total: activeList.length,
    inStock,
  };
});

const productColumns = computed(() => [
  { key: 'name', label: t('SCHEDULING.PRODUCTS.TABLE.NAME'), width: '1.8fr' },
  {
    key: 'category',
    label: t('SCHEDULING.PRODUCTS.TABLE.CATEGORY'),
    width: '1fr',
  },
  {
    key: 'price',
    label: t('SCHEDULING.PRODUCTS.TABLE.PRICE'),
    width: '150px',
  },
  {
    key: 'stock',
    label: t('SCHEDULING.PRODUCTS.TABLE.STOCK'),
    width: '170px',
  },
  { key: 'status', label: t('SCHEDULING.GENERAL.STATUS'), width: '100px' },
  { key: 'actions', label: '', width: '112px', align: 'end' },
]);

const itemTypeLabel = itemType => {
  if (itemType === 'variant') return t('SCHEDULING.PRODUCTS.TYPES.VARIANT');
  if (itemType === 'bundle') return t('SCHEDULING.PRODUCTS.TYPES.BUNDLE');
  return t('SCHEDULING.PRODUCTS.TYPES.PRODUCT');
};

const itemTypeBadgeClass = itemType => {
  if (itemType === 'variant') return 'bg-n-violet-3 text-n-violet-11';
  if (itemType === 'bundle') return 'bg-n-amber-3 text-n-amber-11';
  return 'bg-n-slate-3 text-n-slate-11';
};

const formatQuantity = value => {
  const num = Number(value || 0);
  return Number.isInteger(num) ? String(num) : num.toFixed(2);
};

const characteristicsSummary = product => {
  const list = Array.isArray(product.characteristics)
    ? product.characteristics
    : [];
  if (!list.length) return '';

  return list.map(ch => `${ch.name}: ${ch.value}`).join(' · ');
};

const formatCustomAttributeText = (key, val) => {
  if (typeof val === 'boolean') {
    return val ? key : '';
  }
  return `${key}: ${val}`;
};

const customAttributesBadges = product => {
  const attrs = product.customAttributes || {};
  return Object.entries(attrs)
    .filter(([, val]) => val !== null && val !== undefined && val !== '')
    .slice(0, 3)
    .map(([key, val]) => ({
      key,
      text: formatCustomAttributeText(key, val),
    }))
    .filter(item => item.text);
};

const resetProductForm = () => {
  Object.assign(productForm, {
    id: null,
    name: '',
    itemType: 'product',
    code: '',
    article: '',
    category: '',
    uom: 'шт',
    price: 0,
    wholesalePrice: '',
    kaspiPrice: '',
    buyPrice: 0,
    minPrice: 0,
    stock: 0,
    reserve: 0,
    inTransit: 0,
    description: '',
    active: true,
  });
};

const openCreateProduct = () => {
  resetProductForm();
  productDrawerOpen.value = true;
};

const openEditProduct = product => {
  Object.assign(productForm, {
    id: product.id,
    name: product.name || '',
    itemType: product.itemType || 'product',
    code: product.code || '',
    article: product.article || '',
    category: product.category || '',
    uom: product.uom || 'шт',
    price: product.price ?? 0,
    wholesalePrice: product.wholesalePrice ?? '',
    kaspiPrice: product.kaspiPrice ?? '',
    buyPrice: product.buyPrice ?? 0,
    minPrice: product.minPrice ?? 0,
    stock: Number(product.stock ?? 0),
    reserve: Number(product.reserve ?? 0),
    inTransit: Number(product.inTransit ?? 0),
    description: product.description || '',
    active: product.active ?? true,
  });
  productDrawerOpen.value = true;
};

const closeProductDrawer = () => {
  productDrawerOpen.value = false;
  resetProductForm();
};

const saveProduct = async () => {
  try {
    const stock = Number(productForm.stock || 0);
    const reserve = Number(productForm.reserve || 0);
    const inTransit = Number(productForm.inTransit || 0);

    await referencesStore.saveProduct({
      id: productForm.id,
      name: productForm.name.trim(),
      item_type: productForm.itemType,
      code: productForm.code.trim() || null,
      article: productForm.article.trim() || null,
      category: productForm.category.trim() || null,
      uom: productForm.uom.trim() || 'шт',
      price: toIntegerNumeric(productForm.price, 'price') || 0,
      wholesale_price:
        productForm.wholesalePrice !== ''
          ? toIntegerNumeric(productForm.wholesalePrice, 'wholesale_price')
          : null,
      kaspi_price:
        productForm.kaspiPrice !== ''
          ? toIntegerNumeric(productForm.kaspiPrice, 'kaspi_price')
          : null,
      buy_price: toIntegerNumeric(productForm.buyPrice, 'buy_price') || 0,
      min_price: toIntegerNumeric(productForm.minPrice, 'min_price') || 0,
      stock,
      reserve,
      in_transit: inTransit,
      quantity: stock - reserve + inTransit,
      description: productForm.description.trim() || null,
      active: productForm.active,
    });

    useAlert(t('SCHEDULING.PRODUCTS.SUCCESS_SAVE'));
    closeProductDrawer();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const toggleProductActive = async product => {
  try {
    await referencesStore.saveProduct({
      id: product.id,
      name: product.name,
      active: !product.active,
    });
    useAlert(t('SCHEDULING.PRODUCTS.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const deleteProduct = async product => {
  try {
    await referencesStore.deleteProduct(product.id);
    useAlert(t('SCHEDULING.PRODUCTS.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

onMounted(async () => {
  await referencesStore.loadProducts({ include_inactive: true });
});
</script>

<template>
  <section class="flex flex-col flex-1 min-h-0 overflow-y-auto bg-n-surface-1">
    <SchedulingPageHeader :title="$t('SCHEDULING.PRODUCTS.TITLE')">
      <template #actions>
        <Button
          size="sm"
          icon="i-lucide-plus"
          :label="$t('SCHEDULING.PRODUCTS.ADD')"
          data-test="add-product-button"
          @click="openCreateProduct"
        />
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-6 pb-8 pt-3">
      <!-- Summary & Filters -->
      <div
        class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-3"
      >
        <div class="flex flex-wrap items-center gap-2 text-xs">
          <span
            class="inline-flex items-center gap-1.5 rounded-lg bg-n-alpha-2 px-2.5 py-1 font-medium text-n-slate-12"
          >
            {{ $t('SCHEDULING.PRODUCTS.SUMMARY.TOTAL') }}:
            <strong>{{ summaryCounts.total }}</strong>
          </span>
          <span
            class="inline-flex items-center gap-1.5 rounded-lg bg-n-teal-3 px-2.5 py-1 font-medium text-n-teal-11"
          >
            {{ $t('SCHEDULING.PRODUCTS.SUMMARY.IN_STOCK') }}:
            <strong>{{ summaryCounts.inStock }}</strong>
          </span>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <input
            v-model="searchQuery"
            type="search"
            :placeholder="$t('SCHEDULING.PRODUCTS.SEARCH_PLACEHOLDER')"
            data-test="products-search-input"
            class="h-8 w-56 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-xs text-n-slate-12 placeholder:text-n-slate-10 focus:border-n-brand focus:outline-none"
          />

          <select
            v-model="selectedItemType"
            data-test="products-type-filter"
            class="h-8 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-xs text-n-slate-12 focus:border-n-brand focus:outline-none"
          >
            <option value="all">
              {{ $t('SCHEDULING.PRODUCTS.FILTERS.ALL_TYPES') }}
            </option>
            <option value="product">
              {{ $t('SCHEDULING.PRODUCTS.TYPES.PRODUCT') }}
            </option>
            <option value="variant">
              {{ $t('SCHEDULING.PRODUCTS.TYPES.VARIANT') }}
            </option>
            <option value="bundle">
              {{ $t('SCHEDULING.PRODUCTS.TYPES.BUNDLE') }}
            </option>
          </select>

          <select
            v-if="categories.length"
            v-model="selectedCategory"
            data-test="products-category-filter"
            class="h-8 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-xs text-n-slate-12 focus:border-n-brand focus:outline-none"
          >
            <option value="all">
              {{ $t('SCHEDULING.PRODUCTS.FILTERS.ALL_CATEGORIES') }}
            </option>
            <option v-for="cat in categories" :key="cat" :value="cat">
              {{ cat }}
            </option>
          </select>

          <label
            class="inline-flex items-center gap-1.5 text-xs text-n-slate-11 cursor-pointer select-none"
          >
            <input
              v-model="showInactive"
              type="checkbox"
              class="rounded border-n-weak"
            />
            {{ $t('SCHEDULING.PRODUCTS.FILTERS.SHOW_INACTIVE') }}
          </label>
        </div>
      </div>

      <div
        v-if="referencesStore.ui.isLoadingProducts"
        class="flex justify-center py-16"
      >
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="referencesStore.ui.error"
        :title="$t('SCHEDULING.GENERAL.ERROR_TITLE')"
        :description="pageErrorDescription"
        @retry="referencesStore.loadProducts({ include_inactive: true })"
      />

      <SchedulingEmptyState
        v-else-if="filteredProducts.length === 0"
        :title="$t('SCHEDULING.PRODUCTS.EMPTY_TITLE')"
        :description="$t('SCHEDULING.PRODUCTS.EMPTY_DESCRIPTION')"
        :action-label="$t('SCHEDULING.PRODUCTS.ADD')"
        @action="openCreateProduct"
      />

      <SchedulingRecordTable
        v-else
        :columns="productColumns"
        :rows="filteredProducts"
      >
        <template #cell-name="{ row }">
          <div class="min-w-0">
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="truncate font-medium text-n-slate-12">
                {{ row.name }}
              </span>
              <span
                class="inline-flex items-center rounded-md px-1.5 py-0.5 text-[10px] font-medium"
                :class="itemTypeBadgeClass(row.itemType)"
              >
                {{ itemTypeLabel(row.itemType) }}
              </span>
            </div>

            <div
              class="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-n-slate-11"
            >
              <span v-if="row.code">
                {{ $t('SCHEDULING.PRODUCTS.CODE') }}: {{ row.code }}
              </span>
              <span v-if="row.article">
                {{ $t('SCHEDULING.PRODUCTS.ARTICLE') }}: {{ row.article }}
              </span>
              <span v-if="characteristicsSummary(row)" class="text-n-violet-11">
                {{ characteristicsSummary(row) }}
              </span>
            </div>

            <div
              v-if="customAttributesBadges(row).length"
              class="mt-1 flex flex-wrap gap-1"
            >
              <span
                v-for="badge in customAttributesBadges(row)"
                :key="badge.key"
                class="inline-flex items-center rounded bg-n-alpha-2 px-1.5 py-0.5 text-[10px] text-n-slate-11"
              >
                {{ badge.text }}
              </span>
            </div>
          </div>
        </template>

        <template #cell-category="{ row }">
          <span class="text-xs text-n-slate-11">
            {{ row.category || '—' }}
          </span>
        </template>

        <template #cell-price="{ row }">
          <div class="flex flex-col">
            <span class="font-medium text-n-slate-12">
              {{ formatCurrency(row.price) }}
            </span>
            <span v-if="row.wholesalePrice" class="text-[11px] text-n-slate-11">
              {{ $t('SCHEDULING.PRODUCTS.WHOLESALE_PRICE') }}:
              {{ formatCurrency(row.wholesalePrice) }}
            </span>
            <span v-if="row.kaspiPrice" class="text-[11px] text-n-slate-11">
              {{ $t('SCHEDULING.PRODUCTS.KASPI_PRICE') }}:
              {{ formatCurrency(row.kaspiPrice) }}
            </span>
          </div>
        </template>

        <template #cell-stock="{ row }">
          <div class="flex flex-col text-xs">
            <span
              class="font-medium"
              :class="
                Number(row.availableNow ?? row.stock ?? 0) > 0
                  ? 'text-n-teal-11'
                  : 'text-n-slate-10'
              "
            >
              {{ $t('SCHEDULING.PRODUCTS.AVAILABLE_NOW') }}:
              {{ formatQuantity(row.availableNow ?? row.stock) }}
              {{ row.uom || 'шт' }}
            </span>
            <span class="text-[11px] text-n-slate-11">
              {{ $t('SCHEDULING.PRODUCTS.STOCK_SHORT') }}:
              {{ formatQuantity(row.stock) }}
              <template v-if="Number(row.reserve) > 0">
                · {{ $t('SCHEDULING.PRODUCTS.RESERVE_SHORT') }}:
                {{ formatQuantity(row.reserve) }}
              </template>
              <template v-if="Number(row.inTransit) > 0">
                · {{ $t('SCHEDULING.PRODUCTS.IN_TRANSIT_SHORT') }}:
                {{ formatQuantity(row.inTransit) }}
              </template>
            </span>
          </div>
        </template>

        <template #cell-status="{ row }">
          <span
            class="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium"
            :class="
              row.active
                ? 'bg-n-teal-3 text-n-teal-11'
                : 'bg-n-slate-3 text-n-slate-11'
            "
          >
            {{
              row.active
                ? $t('SCHEDULING.GENERAL.ACTIVE')
                : $t('SCHEDULING.GENERAL.INACTIVE')
            }}
          </span>
        </template>

        <template #cell-actions="{ row }">
          <div class="flex items-center justify-end gap-1 whitespace-nowrap">
            <Button
              size="xs"
              variant="ghost"
              color="slate"
              :label="$t('SCHEDULING.GENERAL.EDIT')"
              @click="openEditProduct(row)"
            />
            <Button
              size="xs"
              variant="ghost"
              color="slate"
              :label="
                row.active
                  ? $t('SCHEDULING.GENERAL.DEACTIVATE')
                  : $t('SCHEDULING.GENERAL.ACTIVATE')
              "
              @click="toggleProductActive(row)"
            />
            <Button
              size="xs"
              variant="ghost"
              color="ruby"
              :label="$t('SCHEDULING.GENERAL.DELETE')"
              @click="deleteProduct(row)"
            />
          </div>
        </template>
      </SchedulingRecordTable>
    </div>

    <!-- Product Create / Edit Drawer -->
    <SchedulingDrawer
      v-model="productDrawerOpen"
      :title="
        productForm.id
          ? $t('SCHEDULING.PRODUCTS.EDIT')
          : $t('SCHEDULING.PRODUCTS.ADD')
      "
      :description="$t('SCHEDULING.PRODUCTS.DRAWER_SUBTITLE')"
      @close="closeProductDrawer"
    >
      <div class="flex flex-col gap-5">
        <SchedulingFormFieldGroup :title="$t('SCHEDULING.PRODUCTS.MAIN_GROUP')">
          <Input
            v-model="productForm.name"
            :label="$t('SCHEDULING.PRODUCTS.NAME')"
          />
          <div class="grid gap-3 md:grid-cols-2">
            <Input
              v-model="productForm.code"
              :label="$t('SCHEDULING.PRODUCTS.CODE')"
            />
            <Input
              v-model="productForm.article"
              :label="$t('SCHEDULING.PRODUCTS.ARTICLE')"
            />
          </div>
          <div class="grid gap-3 md:grid-cols-3">
            <div class="flex flex-col gap-1">
              <label class="text-xs font-medium text-n-slate-11">
                {{ $t('SCHEDULING.PRODUCTS.ITEM_TYPE') }}
              </label>
              <select
                v-model="productForm.itemType"
                class="h-9 rounded-lg border border-n-weak bg-n-surface-1 px-3 text-sm text-n-slate-12"
              >
                <option value="product">
                  {{ $t('SCHEDULING.PRODUCTS.TYPES.PRODUCT') }}
                </option>
                <option value="variant">
                  {{ $t('SCHEDULING.PRODUCTS.TYPES.VARIANT') }}
                </option>
                <option value="bundle">
                  {{ $t('SCHEDULING.PRODUCTS.TYPES.BUNDLE') }}
                </option>
              </select>
            </div>
            <Input
              v-model="productForm.category"
              :label="$t('SCHEDULING.PRODUCTS.CATEGORY')"
            />
            <Input
              v-model="productForm.uom"
              :label="$t('SCHEDULING.PRODUCTS.UOM')"
            />
          </div>
          <TextArea
            v-model="productForm.description"
            :label="$t('SCHEDULING.PRODUCTS.DESCRIPTION')"
          />
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.PRODUCTS.PRICES_GROUP')"
        >
          <div class="grid gap-3 md:grid-cols-3">
            <SchedulingMoneyInput
              v-model="productForm.price"
              :label="$t('SCHEDULING.PRODUCTS.PRICE')"
            />
            <SchedulingMoneyInput
              v-model="productForm.wholesalePrice"
              :label="$t('SCHEDULING.PRODUCTS.WHOLESALE_PRICE')"
            />
            <SchedulingMoneyInput
              v-model="productForm.kaspiPrice"
              :label="$t('SCHEDULING.PRODUCTS.KASPI_PRICE')"
            />
          </div>
          <div class="grid gap-3 md:grid-cols-2">
            <SchedulingMoneyInput
              v-model="productForm.buyPrice"
              :label="$t('SCHEDULING.PRODUCTS.BUY_PRICE')"
            />
            <SchedulingMoneyInput
              v-model="productForm.minPrice"
              :label="$t('SCHEDULING.PRODUCTS.MIN_PRICE')"
            />
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.PRODUCTS.STOCK_GROUP')"
        >
          <div class="grid gap-3 md:grid-cols-3">
            <Input
              v-model="productForm.stock"
              type="number"
              :label="$t('SCHEDULING.PRODUCTS.STOCK')"
            />
            <Input
              v-model="productForm.reserve"
              type="number"
              :label="$t('SCHEDULING.PRODUCTS.RESERVE')"
            />
            <Input
              v-model="productForm.inTransit"
              type="number"
              :label="$t('SCHEDULING.PRODUCTS.IN_TRANSIT')"
            />
          </div>
          <div class="flex items-center justify-between pt-2">
            <span class="text-sm text-n-slate-12">
              {{ $t('SCHEDULING.PRODUCTS.ACTIVE_LABEL') }}
            </span>
            <Switch v-model="productForm.active" />
          </div>
        </SchedulingFormFieldGroup>
      </div>

      <template #footer>
        <div class="flex items-center justify-end gap-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.CANCEL')"
            @click="closeProductDrawer"
          />
          <Button
            size="sm"
            :label="$t('SCHEDULING.GENERAL.SAVE')"
            :is-loading="referencesStore.ui.isSaving"
            @click="saveProduct"
          />
        </div>
      </template>
    </SchedulingDrawer>
  </section>
</template>
