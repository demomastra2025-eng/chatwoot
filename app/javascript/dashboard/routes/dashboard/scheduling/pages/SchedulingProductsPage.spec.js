import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingProductsPage from './SchedulingProductsPage.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  store: {
    products: [],
    moyskladStatus: {
      connected: false,
      status: 'disabled',
      priceTypeName: 'Цена продажи',
      maskedToken: null,
      syncedProductsCount: 0,
    },
    ui: {
      isLoadingProducts: false,
      isSaving: false,
      isSyncingMoysklad: false,
      error: null,
    },
    loadProducts: vi.fn(() => Promise.resolve()),
    saveProduct: vi.fn(() => Promise.resolve()),
    deleteProduct: vi.fn(() => Promise.resolve()),
    saveMoyskladConfig: vi.fn(() => Promise.resolve()),
    syncMoysklad: vi.fn(() =>
      Promise.resolve({ syncSummary: { totalSynced: 5 }, products: [] })
    ),
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/stores/scheduling/references', () => ({
  useSchedulingReferencesStore: () => mocks.store,
}));

const mountPage = async () => {
  const wrapper = mount(SchedulingProductsPage, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        Button: {
          props: ['label'],
          emits: ['click'],
          template: '<button @click="$emit(\'click\')">{{ label }}</button>',
        },
        Input: {
          props: ['modelValue', 'label'],
          emits: ['update:modelValue'],
          template:
            '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
        },
        TextArea: true,
        Switch: true,
        Spinner: true,
        SchedulingDrawer: {
          props: ['modelValue', 'title', 'description'],
          template:
            '<div v-if="modelValue" data-test="drawer"><slot /><slot name="footer" /></div>',
        },
        SchedulingEmptyState: {
          props: ['title'],
          template: '<div data-test="empty-state">{{ title }}</div>',
        },
        SchedulingErrorState: true,
        SchedulingFormFieldGroup: {
          template: '<div><slot /></div>',
        },
        SchedulingMoneyInput: true,
        SchedulingPageHeader: {
          props: ['title'],
          template:
            '<header><h1>{{ title }}</h1><slot name="actions" /></header>',
        },
        SchedulingRecordTable: {
          props: ['rows'],
          template:
            '<div data-test="products-table"><div v-for="row in rows" :key="row.id" data-test="product-row"><slot name="cell-name" :row="row" /><slot name="cell-price" :row="row" /><slot name="cell-stock" :row="row" /></div></div>',
        },
      },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('SchedulingProductsPage', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    mocks.alert.mockReset();
    mocks.store.loadProducts.mockClear();
    mocks.store.syncMoysklad.mockClear();
    mocks.store.products = [
      {
        id: 1,
        name: 'Смартфон Apple iPhone 16 Pro',
        itemType: 'product',
        code: 'IP16PRO-BASE',
        article: 'A3293',
        category: 'Электроника/Смартфоны и гаджеты',
        uom: 'шт',
        price: 649990,
        wholesalePrice: 595000,
        kaspiPrice: 679990,
        stock: 14,
        reserve: 2,
        inTransit: 6,
        availableNow: 12,
        active: true,
        externalSource: 'moysklad',
        characteristics: [],
        customAttributes: { Бренд: 'Apple' },
      },
      {
        id: 2,
        name: 'Чехол Apple Silicone Case',
        itemType: 'product',
        code: 'ACC-CASE-16P',
        category: 'Электроника/Аксессуары',
        uom: 'шт',
        price: 24990,
        stock: 40,
        reserve: 3,
        inTransit: 0,
        availableNow: 37,
        active: true,
        externalSource: 'local',
        characteristics: [],
        customAttributes: {},
      },
    ];
    mocks.store.moyskladStatus = {
      connected: true,
      status: 'enabled',
      priceTypeName: 'Цена продажи',
      maskedToken: '8d66••••3bfb',
      syncedProductsCount: 1,
    };
  });

  it('loads products on mount and renders product rows with MoySklad badge and stock', async () => {
    const wrapper = await mountPage();

    expect(mocks.store.loadProducts).toHaveBeenCalledWith({
      include_inactive: true,
    });
    expect(wrapper.findAll('[data-test="product-row"]')).toHaveLength(2);
    expect(wrapper.text()).toContain('Смартфон Apple iPhone 16 Pro');
    expect(wrapper.text()).toContain('SCHEDULING.PRODUCTS.SOURCE_MOYSKLAD');
    expect(wrapper.text()).toContain('Бренд: Apple');
  });

  it('filters products by search query and source', async () => {
    const wrapper = await mountPage();

    await wrapper
      .find('[data-test="products-source-filter"]')
      .setValue('moysklad');
    expect(wrapper.findAll('[data-test="product-row"]')).toHaveLength(1);

    await wrapper.find('[data-test="products-source-filter"]').setValue('all');
    await wrapper.find('[data-test="products-search-input"]').setValue('Чехол');
    expect(wrapper.findAll('[data-test="product-row"]')).toHaveLength(1);
    expect(wrapper.text()).toContain('Чехол Apple Silicone Case');
  });

  it('triggers quick MoySklad sync when connected', async () => {
    const wrapper = await mountPage();

    await wrapper
      .find('[data-test="moysklad-quick-sync-button"]')
      .trigger('click');
    await flushPromises();

    expect(mocks.store.syncMoysklad).toHaveBeenCalledWith({});
    expect(mocks.alert).toHaveBeenCalled();
  });

  it('opens MoySklad drawer and Product drawer via v-model when buttons are clicked', async () => {
    const wrapper = await mountPage();

    expect(wrapper.findAll('[data-test="drawer"]')).toHaveLength(0);

    await wrapper
      .get('[data-test="moysklad-open-drawer-button"]')
      .trigger('click');
    expect(wrapper.findAll('[data-test="drawer"]')).toHaveLength(1);
    expect(wrapper.get('[data-test="drawer"]').text()).toContain(
      'SCHEDULING.PRODUCTS.MOYSKLAD.SAVE_AND_SYNC'
    );

    await wrapper.get('[data-test="add-product-button"]').trigger('click');
    expect(wrapper.findAll('[data-test="drawer"]')).toHaveLength(2);
  });
});
