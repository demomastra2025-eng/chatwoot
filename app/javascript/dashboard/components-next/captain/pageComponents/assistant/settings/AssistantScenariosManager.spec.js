import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { shallowMount } from '@vue/test-utils';

import AssistantScenariosManager from './AssistantScenariosManager.vue';

const dispatchMock = vi.fn();
const updateUISettingsMock = vi.fn();
const useAlertMock = vi.fn();
const useStoreMock = vi.fn();
const useUISettingsMock = vi.fn();
const scenariosRef = ref([]);
const uiFlagsRef = ref({ fetchingList: false });

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: (...args) => useStoreMock(...args),
  useMapGetter: key => {
    if (key === 'captainScenarios/getUIFlags') {
      return uiFlagsRef;
    }

    if (key === 'captainScenarios/getRecords') {
      return scenariosRef;
    }

    return ref([]);
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: (...args) => useUISettingsMock(...args),
}));

vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({
    formatMessage: value => value,
  }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const bulkSelectBarStub = {
  name: 'BulkSelectBar',
  template: `
    <div>
      <slot name="default-actions" />
      <slot />
    </div>
  `,
};

const suggestedScenariosStub = {
  name: 'SuggestedScenarios',
  props: ['showClose', 'items'],
  template: `
    <div
      data-testid="suggested-scenarios"
      :data-show-close="String(showClose)"
    >
      <slot :item="items[0]" />
    </div>
  `,
};

const buildWrapper = props =>
  shallowMount(AssistantScenariosManager, {
    props,
    global: {
      stubs: {
        AddNewScenariosDialog: true,
        BulkSelectBar: bulkSelectBarStub,
        Button: true,
        Input: true,
        ScenariosCard: true,
        SettingsHeader: true,
        SuggestedScenarios: suggestedScenariosStub,
      },
    },
  });

describe('AssistantScenariosManager', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({});
    updateUISettingsMock.mockReset();
    useAlertMock.mockReset();
    scenariosRef.value = [];
    uiFlagsRef.value = { fetchingList: false };

    useStoreMock.mockReturnValue({
      dispatch: dispatchMock,
    });
    useUISettingsMock.mockReturnValue({
      uiSettings: ref({
        show_scenarios_suggestions: false,
      }),
      updateUISettings: updateUISettingsMock,
    });
  });

  it('shows suggested scenarios when the list is empty even after dismissal', () => {
    const wrapper = buildWrapper({ assistantId: 42 });
    const suggestions = wrapper.get('[data-testid="suggested-scenarios"]');

    expect(suggestions.exists()).toBe(true);
    expect(suggestions.attributes('data-show-close')).toBe('false');
  });

  it('respects dismissal when scenarios already exist', () => {
    scenariosRef.value = [
      {
        id: 1,
        title: 'Scenario',
        description: 'Existing scenario',
        instruction: 'Do something',
        tools: [],
        enabled: true,
      },
    ];

    const wrapper = buildWrapper({ assistantId: 42 });

    expect(wrapper.find('[data-testid="suggested-scenarios"]').exists()).toBe(
      false
    );
  });

  it('renders localized tool labels in suggested scenarios', () => {
    const wrapper = buildWrapper({ assistantId: 42 });

    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_private_note.TITLE'
    );
    expect(wrapper.text()).not.toContain('@add_private_note');
  });

  it('renders scenarios in a single-column list layout', () => {
    scenariosRef.value = [
      {
        id: 1,
        title: 'Scenario',
        description: 'Existing scenario',
        instruction: 'Do something',
        tools: [],
        enabled: true,
      },
    ];

    const wrapper = buildWrapper({ assistantId: 42 });
    const list = wrapper.get('[data-testid="scenarios-list"]');

    expect(list.classes()).toContain('flex');
    expect(list.classes()).toContain('flex-col');
    expect(list.classes()).not.toContain('md:grid-cols-2');
  });
});
