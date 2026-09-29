import { flushPromises, mount } from '@vue/test-utils';
import { reactive } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingExceptionsPage from './SchedulingExceptionsPage.vue';

// The calendar grid draws time-offs on the clinic clock (Asia/Almaty, UTC+5
// all year). The exceptions page must list, edit and save them on the same
// clock in any browser timezone; run this spec with TZ=UTC, TZ=Europe/Berlin
// and TZ=America/Los_Angeles.
const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  store: null,
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'ru' },
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/stores/scheduling/references', () => ({
  useSchedulingReferencesStore: () => mocks.store,
}));

// 10:00-12:00 on 1 October 2026 in Almaty.
const clinicTimeOff = {
  endsAt: '2026-10-01T07:00:00.000Z',
  id: 11,
  kind: 'vacation',
  notes: '',
  resourceId: 7,
  startsAt: '2026-10-01T05:00:00.000Z',
  title: 'Отпуск',
};

const buildStore = () =>
  reactive({
    deleteHoliday: vi.fn(() => Promise.resolve()),
    deleteTimeOff: vi.fn(() => Promise.resolve()),
    deleteWorkdayOverride: vi.fn(() => Promise.resolve()),
    holidays: [
      {
        date: '2026-10-01',
        id: 3,
        recurringYearly: false,
        title: 'Праздник',
        workingDayOverride: false,
      },
    ],
    loadExceptions: vi.fn(() => Promise.resolve()),
    loadResources: vi.fn(() => Promise.resolve()),
    resources: [{ customAttributes: {}, id: 7, name: 'Дина' }],
    saveHoliday: vi.fn(() => Promise.resolve()),
    saveTimeOff: vi.fn(() => Promise.resolve()),
    saveWorkdayOverride: vi.fn(() => Promise.resolve()),
    timeOffs: [{ ...clinicTimeOff }],
    ui: {
      error: null,
      isLoadingExceptions: false,
      isLoadingResources: false,
      isSaving: false,
    },
    workdayOverrides: [],
  });

const stubs = {
  Button: {
    props: ['icon', 'label'],
    emits: ['click'],
    template:
      '<button type="button" :data-icon="icon" @click="$emit(\'click\')">{{ label }}</button>',
  },
  Checkbox: true,
  Input: true,
  SchedulingDateTimeField: {
    name: 'SchedulingDateTimeField',
    props: ['modelValue', 'type', 'label'],
    emits: ['update:modelValue'],
    template:
      '<input class="date-time-field" :data-label="label" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
  },
  SchedulingDrawer: {
    props: ['modelValue'],
    emits: ['close', 'confirm', 'update:modelValue'],
    template:
      '<div><slot /><button type="button" class="drawer-confirm" @click="$emit(\'confirm\')" /></div>',
  },
  SchedulingEmptyState: true,
  SchedulingErrorState: true,
  SchedulingFormFieldGroup: { template: '<div><slot /></div>' },
  SchedulingPageHeader: { template: '<div><slot name="actions" /></div>' },
  SchedulingRecordTable: {
    props: ['columns', 'rows'],
    template: `
      <div>
        <div v-for="row in rows" :key="row.id" class="record-row">
          <div
            v-for="column in columns"
            :key="column.key"
            :class="'cell-' + column.key"
          >
            <slot :name="'cell-' + column.key" :row="row" />
          </div>
        </div>
      </div>
    `,
  },
  SchedulingSelectField: true,
  Spinner: true,
  TabBar: {
    props: ['tabs'],
    emits: ['tabChanged'],
    template:
      '<div><button v-for="tab in tabs" :key="tab.value" type="button" :data-tab="tab.value" @click="$emit(\'tabChanged\', tab)" /></div>',
  },
  TextArea: true,
};

const mountPage = async () => {
  const wrapper = mount(SchedulingExceptionsPage, {
    global: {
      mocks: { $t: key => key },
      stubs,
    },
  });
  await flushPromises();
  return wrapper;
};

const openTab = async (wrapper, tab) => {
  await wrapper.find(`[data-tab="${tab}"]`).trigger('click');
};

const editFirstRow = wrapper =>
  wrapper.find('.record-row [data-icon="i-lucide-pencil"]').trigger('click');

const dateTimeFields = wrapper =>
  wrapper.findAllComponents({ name: 'SchedulingDateTimeField' });

describe(`SchedulingExceptionsPage time-offs (process TZ=${process.env.TZ})`, () => {
  beforeEach(() => {
    mocks.alert.mockReset();
    mocks.store = buildStore();
  });

  it('lists a time-off on the clinic clock, like the calendar grid', async () => {
    const wrapper = await mountPage();
    await openTab(wrapper, 'time_offs');

    const period = wrapper.find('.record-row .cell-period').text();
    expect(period).toContain('10:00');
    expect(period).toContain('12:00');
  });

  it('opens a time-off for editing on the clinic clock', async () => {
    const wrapper = await mountPage();
    await openTab(wrapper, 'time_offs');
    await editFirstRow(wrapper);

    const [startsAt, endsAt] = dateTimeFields(wrapper);
    expect(startsAt.props('modelValue')).toBe('2026-10-01T10:00');
    expect(endsAt.props('modelValue')).toBe('2026-10-01T12:00');
  });

  it('saves an unchanged time-off back to the same instants', async () => {
    const wrapper = await mountPage();
    await openTab(wrapper, 'time_offs');
    await editFirstRow(wrapper);
    await wrapper.find('.drawer-confirm').trigger('click');
    await flushPromises();

    expect(mocks.store.saveTimeOff).toHaveBeenCalledWith(
      expect.objectContaining({
        ends_at: '2026-10-01T07:00:00.000Z',
        id: 11,
        starts_at: '2026-10-01T05:00:00.000Z',
      })
    );
  });

  it('saves times typed on the page as clinic time', async () => {
    const wrapper = await mountPage();
    await openTab(wrapper, 'time_offs');
    await wrapper.find('[data-icon="i-lucide-plus"]').trigger('click');

    const [startsAt, endsAt] = dateTimeFields(wrapper);
    await startsAt.find('input').setValue('2026-10-01T10:00');
    await endsAt.find('input').setValue('2026-10-01T12:00');
    await wrapper.find('.drawer-confirm').trigger('click');
    await flushPromises();

    expect(mocks.store.saveTimeOff).toHaveBeenCalledWith(
      expect.objectContaining({
        ends_at: '2026-10-01T07:00:00.000Z',
        id: null,
        starts_at: '2026-10-01T05:00:00.000Z',
      })
    );
  });

  it('keeps an empty time-off period empty in the payload', async () => {
    const wrapper = await mountPage();
    await openTab(wrapper, 'time_offs');
    await wrapper.find('[data-icon="i-lucide-plus"]').trigger('click');
    await wrapper.find('.drawer-confirm').trigger('click');
    await flushPromises();

    expect(mocks.store.saveTimeOff).toHaveBeenCalledWith(
      expect.objectContaining({ ends_at: '', starts_at: '' })
    );
  });

  it('shows a holiday on its stored calendar day', async () => {
    const wrapper = await mountPage();
    await openTab(wrapper, 'holidays');

    // "2026-10-01" must not become 30 September in a browser west of UTC.
    expect(wrapper.find('.record-row .cell-date').text()).toContain(
      '1 октября 2026'
    );
  });
});
