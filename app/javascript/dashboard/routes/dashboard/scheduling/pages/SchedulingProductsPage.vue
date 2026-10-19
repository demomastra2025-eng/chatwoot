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
  toNumeric,
} from 'dashboard/stores/scheduling/shared';
import { formatCurrency } from '../helpers';
import { useSchedulingReferencesStore } from 'dashboard/stores/scheduling/references';

const { t } = useI18n();

const referencesStore = useSchedulingReferencesStore();
const productDrawerOpen = ref(false);
const moyskladDrawerOpen = ref(false);

const searchQuery = ref('');
const selectedType = ref('all');
const selectedSource = ref('all');

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

const moyskladForm = reactive({
  authMode: 'token',
  accessToken: '',
  login: '',
  password: '',
  priceTypeName: 'Цена продажи',
  enabled: true,
});

const formatErrorMessage = error => formatSchedulingErrorMessage(error, t);

const pageErrorDescription = computed(() =>
  formatErrorMessage(referencesStore.ui.error)
);

const allProducts = computed(() => referencesStore.products || []);
const moyskladStatus = computed(() => referencesStore.moyskladStatus || {});

const filteredProducts = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();

  return allProducts.value.filter(product => {
    if (
      selectedType.value !== 'all' &&
      product.itemType !== selectedType.value
    ) {
      return false;
    }

    if (
      selectedSource.value === 'moysklad' &&
      product.externalSource !== 'moysklad'
    ) {
      return false;
    }
    if (
      selectedSource.value === 'local' &&
      product.externalSource === 'moysklad'
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

const summaryStats = computed(() => {
  const rows = allProducts.value;
  const inStockCount = rows.filter(
    item => Number(item.availableNow ?? item.stock ?? 0) > 0
  ).length;
  const moyskladCount = rows.filter(
    item => item.externalSource === 'moysklad'
  ).length;
  const totalAvailableUnits = rows.reduce(
    (sum, item) => sum + Math.max(Number(item.availableNow ?? 0), 0),
    0
  );

  return {
    total: rows.length,
    inStockCount,
    moyskladCount,
    totalAvailableUnits,
  };
});

const productColumns = computed(() => [
  { key: 'name', label: t('SCHEDULING.PRODUCTS.NAME_COLUMN'), width: '1.8fr' },
  {
    key: 'category',
    label: t('SCHEDULING.PRODUCTS.CATEGORY_COLUMN'),
    width: '1fr',
  },
  {
    key: 'price',
    label: t('SCHEDULING.PRODUCTS.PRICE_COLUMN'),
    width: '150px',
  },
  {
    key: 'stock',
    label: t('SCHEDULING.PRODUCTS.STOCK_COLUMN'),
    width: '180px',
  },
  { key: 'status', label: t('SCHEDULING.GENERAL.STATUS'), width: '104px' },
  { key: 'actions', label: t('SCHEDULING.GENERAL.ACTIONS'), width: '216px' },
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
    price: product.price || 0,
    wholesalePrice: product.wholesalePrice ?? '',
    kaspiPrice: product.kaspiPrice ?? '',
    buyPrice: product.buyPrice || 0,
    minPrice: product.minPrice || 0,
    stock: product.stock ?? 0,
    reserve: product.reserve ?? 0,
    inTransit: product.inTransit ?? 0,
    description: product.description || '',
    active: product.active ?? true,
  });
  productDrawerOpen.value = true;
};

const closeProductDrawer = () => {
  productDrawerOpen.value = false;
  resetProductForm();
};

const openMoyskladDrawer = () => {
  moyskladForm.priceTypeName =
    moyskladStatus.value.priceTypeName || 'Цена продажи';
  moyskladForm.enabled = moyskladStatus.value.status !== 'disabled';
  moyskladForm.accessToken = '';
  moyskladForm.login = '';
  moyskladForm.password = '';
  moyskladDrawerOpen.value = true;
};

const closeMoyskladDrawer = () => {
  moyskladDrawerOpen.value = false;
};

const saveProduct = async () => {
  try {
    await referencesStore.saveProduct({
      id: productForm.id,
      name: productForm.name,
      item_type: productForm.itemType,
      code: productForm.code,
      article: productForm.article,
      category: productForm.category,
      uom: productForm.uom || 'шт',
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
      stock: toNumeric(productForm.stock) ?? 0,
      reserve: toNumeric(productForm.reserve) ?? 0,
      in_transit: toNumeric(productForm.inTransit) ?? 0,
      description: productForm.description,
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
      price: product.price,
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

const buildMoyskladPayload = () => {
  const payload = {
    price_type_name: moyskladForm.priceTypeName || 'Цена продажи',
    enabled: moyskladForm.enabled,
  };
  if (moyskladForm.authMode === 'credentials') {
    if (moyskladForm.login.trim()) payload.login = moyskladForm.login.trim();
    if (moyskladForm.password) payload.password = moyskladForm.password;
  } else if (moyskladForm.accessToken.trim()) {
    payload.access_token = moyskladForm.accessToken.trim();
  }
  return payload;
};

const handleSaveMoyskladConfig = async () => {
  try {
    await referencesStore.saveMoyskladConfig(buildMoyskladPayload());
    useAlert(t('SCHEDULING.PRODUCTS.MOYSKLAD.CONFIG_SAVED'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handleSyncMoysklad = async (inline = false) => {
  try {
    const payload = inline ? {} : buildMoyskladPayload();
    const result = await referencesStore.syncMoysklad(payload);
    const total =
      result.syncSummary?.totalSynced ?? result.products?.length ?? 0;
    useAlert(t('SCHEDULING.PRODUCTS.MOYSKLAD.SYNC_SUCCESS', { count: total }));
    if (!inline) {
      closeMoyskladDrawer();
    }
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
        <div class="flex items-center gap-2">
          <Button
            v-if="moyskladStatus.connected"
            size="sm"
            variant="faded"
            color="teal"
            icon="i-lucide-refresh-cw"
            :is-loading="referencesStore.ui.isSyncingMoysklad"
            :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.SYNC_NOW')"
            data-test="moysklad-quick-sync-button"
            @click="handleSyncMoysklad(true)"
          />
          <Button
            size="sm"
            variant="faded"
            color="slate"
            icon="i-lucide-boxes"
            :label="
              moyskladStatus.connected
                ? $t('SCHEDULING.PRODUCTS.MOYSKLAD.SETTINGS_CONNECTED')
                : $t('SCHEDULING.PRODUCTS.MOYSKLAD.CONNECT_BUTTON')
            "
            data-test="moysklad-open-drawer-button"
            @click="openMoyskladDrawer"
          />
          <Button
            size="sm"
            icon="i-lucide-plus"
            :label="$t('SCHEDULING.PRODUCTS.ADD')"
            data-test="add-product-button"
            @click="openCreateProduct"
          />
        </div>
      </template>
    </SchedulingPageHeader>

    <div class="flex flex-col gap-4 px-6 pb-8 pt-3">
      <!-- KPI & Filter Bar -->
      <div
        v-if="allProducts.length > 0 || moyskladStatus.connected"
        class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-3"
      >
        <div class="flex flex-wrap items-center gap-4 text-xs text-n-slate-11">
          <div>
            {{ $t('SCHEDULING.PRODUCTS.SUMMARY.TOTAL') }}:
            <span class="font-semibold text-n-slate-12">{{
              summaryStats.total
            }}</span>
          </div>
          <div>
            {{ $t('SCHEDULING.PRODUCTS.SUMMARY.IN_STOCK') }}:
            <span class="font-semibold text-n-teal-11">{{
              summaryStats.inStockCount
            }}</span>
          </div>
          <div>
            {{ $t('SCHEDULING.PRODUCTS.SUMMARY.MOYSKLAD') }}:
            <span class="font-semibold text-n-blue-11">{{
              summaryStats.moyskladCount
            }}</span>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <input
            v-model="searchQuery"
            type="search"
            :placeholder="$t('SCHEDULING.PRODUCTS.SEARCH_PLACEHOLDER')"
            data-test="products-search-input"
            class="h-8 w-64 rounded-lg border border-n-weak bg-n-surface-1 px-3 text-xs text-n-slate-12 placeholder:text-n-slate-10 focus:border-n-brand focus:outline-none"
          />
          <select
            v-model="selectedType"
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
            v-model="selectedSource"
            data-test="products-source-filter"
            class="h-8 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 text-xs text-n-slate-12 focus:border-n-brand focus:outline-none"
          >
            <option value="all">
              {{ $t('SCHEDULING.PRODUCTS.FILTERS.ALL_SOURCES') }}
            </option>
            <option value="moysklad">
              {{ $t('SCHEDULING.PRODUCTS.FILTERS.MOYSKLAD_ONLY') }}
            </option>
            <option value="local">
              {{ $t('SCHEDULING.PRODUCTS.FILTERS.LOCAL_ONLY') }}
            </option>
          </select>
        </div>
      </div>

      <div
        v-if="referencesStore.ui.isLoadingProducts"
        class="flex justify-center py-16"
      >
        <Spinner class="!w-8 !h-8" />
      </div>

      <SchedulingErrorState
        v-else-if="referencesStore.ui.error && allProducts.length === 0"
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
            <div class="flex flex-wrap items-center gap-1.5">
              <span class="truncate font-medium text-n-slate-12">
                {{ row.name }}
              </span>
              <span
                class="inline-flex items-center rounded-md px-1.5 py-0.5 text-[10px] font-medium"
                :class="itemTypeBadgeClass(row.itemType)"
              >
                {{ itemTypeLabel(row.itemType) }}
              </span>
              <span
                v-if="row.externalSource === 'moysklad'"
                class="inline-flex items-center rounded-md bg-n-blue-3 px-1.5 py-0.5 text-[10px] font-medium text-n-blue-11"
              >
                {{ $t('SCHEDULING.PRODUCTS.SOURCE_MOYSKLAD') }}
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
          <div class="grid gap-3 md:grid-cols-2">
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
            :rows="3"
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
          <div class="flex items-center justify-between pt-1">
            <span class="text-sm text-n-slate-12">
              {{ $t('SCHEDULING.GENERAL.ACTIVE') }}
            </span>
            <Switch v-model="productForm.active" />
          </div>
        </SchedulingFormFieldGroup>
      </div>

      <template #footer>
        <div class="flex justify-end gap-2">
          <Button
            variant="faded"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.CANCEL')"
            @click="closeProductDrawer"
          />
          <Button
            :label="$t('SCHEDULING.GENERAL.SAVE')"
            :is-loading="referencesStore.ui.isSaving"
            @click="saveProduct"
          />
        </div>
      </template>
    </SchedulingDrawer>

    <!-- MoySklad Integration Drawer -->
    <SchedulingDrawer
      v-model="moyskladDrawerOpen"
      :title="$t('SCHEDULING.PRODUCTS.MOYSKLAD.DRAWER_TITLE')"
      :description="$t('SCHEDULING.PRODUCTS.MOYSKLAD.DRAWER_SUBTITLE')"
      @close="closeMoyskladDrawer"
    >
      <div class="flex flex-col gap-5">
        <div
          v-if="moyskladStatus.connected"
          class="rounded-xl border border-n-teal-6 bg-n-teal-2 p-3.5 text-xs text-n-slate-12"
        >
          <div
            class="flex items-center justify-between font-semibold text-n-teal-11"
          >
            <span>{{
              $t('SCHEDULING.PRODUCTS.MOYSKLAD.CONNECTED_BADGE')
            }}</span>
            <span v-if="moyskladStatus.maskedToken" class="font-mono">
              {{ moyskladStatus.maskedToken }}
            </span>
          </div>
          <div class="mt-1.5 text-n-slate-11">
            {{ $t('SCHEDULING.PRODUCTS.MOYSKLAD.SYNCED_COUNT_LABEL') }}:
            <strong class="text-n-slate-12">
              {{ moyskladStatus.syncedProductsCount || 0 }}
            </strong>
          </div>
        </div>

        <SchedulingFormFieldGroup
          :title="$t('SCHEDULING.PRODUCTS.MOYSKLAD.AUTH_GROUP')"
        >
          <div class="flex gap-2">
            <Button
              size="xs"
              :variant="moyskladForm.authMode === 'token' ? 'solid' : 'faded'"
              color="slate"
              :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.BY_TOKEN')"
              @click="moyskladForm.authMode = 'token'"
            />
            <Button
              size="xs"
              :variant="
                moyskladForm.authMode === 'credentials' ? 'solid' : 'faded'
              "
              color="slate"
              :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.BY_CREDENTIALS')"
              @click="moyskladForm.authMode = 'credentials'"
            />
          </div>

          <Input
            v-if="moyskladForm.authMode === 'token'"
            v-model="moyskladForm.accessToken"
            type="password"
            :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.TOKEN_LABEL')"
            :placeholder="
              moyskladStatus.maskedToken ||
              $t('SCHEDULING.PRODUCTS.MOYSKLAD.TOKEN_PLACEHOLDER')
            "
          />

          <div v-else class="grid gap-3 md:grid-cols-2">
            <Input
              v-model="moyskladForm.login"
              :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.LOGIN_LABEL')"
              placeholder="admin@company"
            />
            <Input
              v-model="moyskladForm.password"
              type="password"
              :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.PASSWORD_LABEL')"
            />
          </div>

          <Input
            v-model="moyskladForm.priceTypeName"
            :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.PRICE_TYPE_LABEL')"
            placeholder="Цена продажи"
          />
        </SchedulingFormFieldGroup>
      </div>

      <template #footer>
        <div class="flex justify-end gap-2">
          <Button
            variant="faded"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.CANCEL')"
            @click="closeMoyskladDrawer"
          />
          <Button
            variant="faded"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.SAVE')"
            :is-loading="referencesStore.ui.isSaving"
            @click="handleSaveMoyskladConfig"
          />
          <Button
            icon="i-lucide-refresh-cw"
            :label="$t('SCHEDULING.PRODUCTS.MOYSKLAD.SAVE_AND_SYNC')"
            :is-loading="referencesStore.ui.isSyncingMoysklad"
            data-test="moysklad-drawer-sync-button"
            @click="handleSyncMoysklad(false)"
          />
        </div>
      </template>
    </SchedulingDrawer>
  </section>
</template>
