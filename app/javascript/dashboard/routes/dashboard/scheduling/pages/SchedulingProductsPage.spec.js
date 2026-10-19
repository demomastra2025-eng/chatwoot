import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingProductsPage from './SchedulingProductsPage.vue';
import SchedulingProductsAPI from 'dashboard/api/scheduling/products';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/api/scheduling/products', () => ({
  default: {
    get: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
  },
}));

const sampleProducts = [
  {
    id: 101,
    name: 'Смартфон Apple iPhone 16 Pro',
    item_type: 'product',
    code: 'IP16PRO-BASE',
    article: 'A3293',
    category: 'Электроника/Смартфоны',
    uom: 'шт',
    price: 649990,
    wholesale_price: 595000,
    kaspi_price: 679990,
    stock: 14,
    reserve: 2,
    in_transit: 6,
    available_now: 12,
    active: true,
    custom_attributes: { Бренд: 'Apple' },
  },
  {
    id: 102,
    name: 'Чехол Apple Silicone Case',
    item_type: 'variant',
    code: 'ACC-CASE-16P',
    category: 'Аксессуары',
    uom: 'шт',
    price: 24990,
    stock: 40,
    reserve: 3,
    in_transit: 0,
    available_now: 37,
    active: true,
    custom_attributes: {},
  },
];

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
          template:
            '<button type="button" @click="$emit(\'click\')">{{ label }}</button>',
        },
        Input: true,
        Spinner: true,
        Switch: true,
        TextArea: true,
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
    vi.clearAllMocks();
    SchedulingProductsAPI.get.mockResolvedValue({
      data: {
        payload: sampleProducts,
        meta: { count: 2 },
      },
    });
  });

  it('loads products on mount and renders product rows with stock and custom attributes without provider branding', async () => {
    const wrapper = await mountPage();

    expect(SchedulingProductsAPI.get).toHaveBeenCalledWith({
      include_inactive: true,
    });
    expect(wrapper.findAll('[data-test="product-row"]')).toHaveLength(2);
    expect(wrapper.text()).toContain('Смартфон Apple iPhone 16 Pro');
    expect(wrapper.text()).toContain('Бренд: Apple');
    expect(wrapper.text()).not.toContain('MOYSKLAD');
  });

  it('filters products by search query and item type', async () => {
    const wrapper = await mountPage();

    await wrapper.get('[data-test="products-search-input"]').setValue('Чехол');
    expect(wrapper.findAll('[data-test="product-row"]')).toHaveLength(1);
    expect(wrapper.text()).toContain('Чехол Apple Silicone Case');

    await wrapper.get('[data-test="products-search-input"]').setValue('');
    await wrapper.get('[data-test="products-type-filter"]').setValue('variant');
    expect(wrapper.findAll('[data-test="product-row"]')).toHaveLength(1);
    expect(wrapper.text()).toContain('Чехол Apple Silicone Case');
  });

  it('opens Product drawer via v-model when Add Product button is clicked', async () => {
    const wrapper = await mountPage();

    expect(wrapper.findAll('[data-test="drawer"]')).toHaveLength(0);

    await wrapper.get('[data-test="add-product-button"]').trigger('click');
    expect(wrapper.findAll('[data-test="drawer"]')).toHaveLength(1);
  });
});
