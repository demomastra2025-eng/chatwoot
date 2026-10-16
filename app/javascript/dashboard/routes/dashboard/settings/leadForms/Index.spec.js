import { flushPromises, mount } from '@vue/test-utils';
import { reactive } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mockRoute = reactive({
  params: { accountId: '74' },
  query: { pipelineId: '47' },
});
const mockRouter = {
  push: vi.fn(),
};
const mockAlert = vi.fn();
const mockStoreDispatch = vi.fn(() => Promise.resolve());
const mockInboxes = [
  {
    id: 11,
    name: 'WhatsApp Клиника',
    channel_type: 'Channel::Whatsapp',
  },
  {
    id: 12,
    name: 'Instagram Клиника',
    channel_type: 'Channel::Instagram',
  },
  {
    id: 13,
    name: 'Виджет сайта',
    channel_type: 'Channel::WebWidget',
  },
];

const mockReferencesStore = reactive({
  pipelines: [
    {
      id: 47,
      name: 'Запись',
      active: true,
      default: true,
      stages: [
        { id: 314, name: 'Неразобранное', active: true, outcome: 'open', default: true },
        { id: 315, name: 'Пациент записан', active: true, outcome: 'open', default: false },
      ],
    },
  ],
  loadPipelines: vi.fn(() => Promise.resolve()),
});

const mockLeadFormsGet = vi.fn(() =>
  Promise.resolve({
    data: {
      payload: [
        {
          id: 901,
          name: 'Тильда Имплантация',
          source_kind: 'api',
          status: 'active',
          inbox_id: 12,
          inbox_name: 'WhatsApp Клиника',
          pipeline_id: 47,
          pipeline_name: 'Запись',
          stage_id: 314,
          stage_name: 'Неразобранное',
          public_token: 'tok-901',
          field_schema: [
            { name: 'phoneNumber', label: 'Телефон', type: 'tel', required: true },
          ],
        },
      ],
    },
  })
);
const mockLeadFormsCreate = vi.fn(() => Promise.resolve({ data: {} }));
const mockLeadFormsUpdate = vi.fn(() => Promise.resolve({ data: {} }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mockRoute,
  useRouter: () => mockRouter,
}));

vi.mock('vuex', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    useStore: () => ({
      dispatch: mockStoreDispatch,
    }),
  };
});

vi.mock('../components/BaseSettingsHeader.vue', () => ({
  default: {
    name: 'BaseSettingsHeader',
    props: ['title', 'description', 'backButtonLabel', 'backButtonUrl'],
    template: '<div data-testid="header">{{ title }}</div>',
  },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    value: mockInboxes,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockAlert(...args),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mockReferencesStore,
}));

vi.mock('dashboard/api/leadForms', () => ({
  default: {
    get: (...args) => mockLeadFormsGet(...args),
    create: (...args) => mockLeadFormsCreate(...args),
    update: (...args) => mockLeadFormsUpdate(...args),
  },
}));

import LeadFormsIndex from './Index.vue';

const ComboBoxStub = {
  name: 'ComboBox',
  props: ['modelValue', 'options', 'placeholder', 'disabled'],
  emits: ['update:modelValue'],
  template: `
    <select
      :value="modelValue"
      :disabled="disabled"
      @change="$emit('update:modelValue', $event.target.value)"
    >
      <option
        v-for="option in options"
        :key="option.value"
        :value="option.value"
      >
        {{ option.label }}
      </option>
    </select>
  `,
};

const InputStub = {
  name: 'Input',
  props: ['modelValue', 'placeholder'],
  emits: ['update:modelValue'],
  template: `<input :value="modelValue" :placeholder="placeholder" @input="$emit('update:modelValue', $event.target.value)" />`,
};

const ButtonStub = {
  name: 'Button',
  props: ['label', 'type', 'disabled'],
  emits: ['click'],
  template: `<button :type="type || 'button'" :disabled="disabled" @click="$emit('click')">{{ label }}</button>`,
};

const TabBarStub = {
  name: 'TabBar',
  props: ['tabs', 'initialActiveTab'],
  emits: ['tabChanged'],
  template: `
    <div data-testid="lead-forms-tabs">
      <button
        v-for="tab in tabs"
        :key="tab.id"
        type="button"
        :data-testid="'tab-' + tab.id"
        @click="$emit('tabChanged', tab)"
      >
        {{ tab.label }}
      </button>
    </div>
  `,
};

const BaseSettingsHeaderStub = {
  name: 'BaseSettingsHeader',
  props: ['title', 'description', 'backButtonLabel', 'backButtonUrl'],
  template: `<div data-testid="header">{{ title }}</div>`,
};

describe('settings/leadForms/Index.vue', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockRoute.query = { pipelineId: '47' };
  });

  const mountComponent = () =>
    mount(LeadFormsIndex, {
      global: {
        mocks: {
          $t: key => key,
        },
        stubs: {
          ComboBox: ComboBoxStub,
          Input: InputStub,
          Button: ButtonStub,
          TabBar: TabBarStub,
          BaseSettingsHeader: BaseSettingsHeaderStub,
          ApiFieldBuilder: {
            template: '<div data-testid="api-field-builder" />',
          },
        },
      },
    });

  it('renders only Meta and API tabs without the duplicate website widget tab', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.find('[data-testid="tab-meta"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="tab-api"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="tab-widget"]').exists()).toBe(false);
  });

  it('preselects the pipeline from route query and sends pipeline_id and stage_id when creating an API form', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.get('[data-testid="tab-api"]').trigger('click');
    await flushPromises();

    const pipelineSelect = wrapper.get('[data-testid="api-form-pipeline-select"] select');
    const stageSelect = wrapper.get('[data-testid="api-form-stage-select"] select');

    expect(pipelineSelect.element.value).toBe('47');
    expect(stageSelect.element.value).toBe('314');

    const nameInput = wrapper.find('input');
    await nameInput.setValue('Лендинг Чекап');
    await stageSelect.setValue('315');
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(mockLeadFormsCreate).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'Лендинг Чекап',
        inbox_id: 12,
        pipeline_id: 47,
        stage_id: 315,
        source_kind: 'api',
      })
    );
  });
});
