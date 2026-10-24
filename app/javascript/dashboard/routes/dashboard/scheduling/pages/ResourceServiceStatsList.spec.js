import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ResourceServiceStatsList from './ResourceServiceStatsList.vue';

const mocks = vi.hoisted(() => ({
  get: vi.fn(),
  update: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      params.count === undefined
        ? key
        : `${key}|${params.count}|${params.minutes}`,
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/api/scheduling/resourceServiceStats', () => ({
  default: { get: mocks.get, update: mocks.update },
}));

const stubs = {
  Spinner: true,
  Switch: {
    props: ['modelValue', 'disabled'],
    emits: ['update:modelValue'],
    template:
      '<button type="button" class="switch" :data-on="modelValue" :disabled="disabled" @click="$emit(\'update:modelValue\', !modelValue)" />',
  },
};

const payload = [
  {
    id: 1,
    resource_id: 7,
    service_id: 11,
    service_name: 'УЗИ малого таза',
    receptions_count: 40,
    median_duration_min: 15,
    status: 'auto',
    counts: true,
  },
  {
    id: 2,
    resource_id: 7,
    service_id: 12,
    service_name: 'Консультация',
    receptions_count: 4,
    median_duration_min: null,
    status: 'stale',
    counts: false,
  },
];

const mountList = async () => {
  const wrapper = mount(ResourceServiceStatsList, {
    props: { resourceId: 7 },
    global: { stubs },
  });
  await flushPromises();
  return wrapper;
};

describe('ResourceServiceStatsList', () => {
  beforeEach(() => {
    mocks.get.mockReset().mockResolvedValue({ data: { payload } });
    mocks.update.mockReset();
    mocks.alert.mockReset();
  });

  it('lists the pairs of the specialist with the history numbers and the status', async () => {
    const wrapper = await mountList();

    expect(mocks.get).toHaveBeenCalledWith(7);
    expect(wrapper.text()).toContain(
      'SCHEDULING.RESOURCES.SERVICE_STATS_TITLE'
    );
    expect(wrapper.get('[data-testid="service-stat-1"]').text()).toContain(
      'УЗИ малого таза'
    );
    expect(wrapper.get('[data-testid="service-stat-1"]').text()).toContain(
      'SCHEDULING.RESOURCES.SERVICE_STATS_NUMBERS|40|15'
    );
    expect(wrapper.get('[data-testid="service-stat-2"]').text()).toContain(
      'SCHEDULING.RESOURCES.SERVICE_STATS_NUMBERS|4|—'
    );
    expect(wrapper.get('[data-testid="service-stat-status-1"]').text()).toBe(
      'SCHEDULING.RESOURCES.SERVICE_STATS_STATUS.AUTO'
    );
    expect(wrapper.get('[data-testid="service-stat-status-2"]').text()).toBe(
      'SCHEDULING.RESOURCES.SERVICE_STATS_STATUS.STALE'
    );
    const switches = wrapper.findAll('.switch');
    expect(switches.map(item => item.attributes('data-on'))).toEqual([
      'true',
      'false',
    ]);
  });

  it('confirms a pair that does not count when its switch is turned on', async () => {
    mocks.update.mockResolvedValue({
      data: { payload: { ...payload[1], status: 'confirmed', counts: true } },
    });
    const wrapper = await mountList();

    await wrapper.findAll('.switch')[1].trigger('click');
    await flushPromises();

    expect(mocks.update).toHaveBeenCalledWith(7, 2, 'confirmed');
    expect(wrapper.get('[data-testid="service-stat-status-2"]').text()).toBe(
      'SCHEDULING.RESOURCES.SERVICE_STATS_STATUS.CONFIRMED'
    );
    expect(wrapper.findAll('.switch')[1].attributes('data-on')).toBe('true');
  });

  it('disables a pair that counts when its switch is turned off', async () => {
    mocks.update.mockResolvedValue({
      data: { payload: { ...payload[0], status: 'disabled', counts: false } },
    });
    const wrapper = await mountList();

    await wrapper.findAll('.switch')[0].trigger('click');
    await flushPromises();

    expect(mocks.update).toHaveBeenCalledWith(7, 1, 'disabled');
    expect(wrapper.findAll('.switch')[0].attributes('data-on')).toBe('false');
  });

  it('keeps the switch where it was and tells the user when saving fails', async () => {
    mocks.update.mockRejectedValue(new Error('boom'));
    const wrapper = await mountList();

    await wrapper.findAll('.switch')[0].trigger('click');
    await flushPromises();

    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.RESOURCES.SERVICE_STATS_ERROR_SAVE'
    );
    expect(wrapper.findAll('.switch')[0].attributes('data-on')).toBe('true');
  });

  it('says so when the history has no services of the specialist yet', async () => {
    mocks.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = await mountList();

    expect(wrapper.find('[data-testid="service-stats-empty"]').exists()).toBe(
      true
    );
    expect(wrapper.find('.switch').exists()).toBe(false);
  });

  it('says so when the list cannot be loaded', async () => {
    mocks.get.mockRejectedValue(new Error('boom'));
    const wrapper = await mountList();

    expect(wrapper.find('[data-testid="service-stats-error"]').exists()).toBe(
      true
    );
  });
});
