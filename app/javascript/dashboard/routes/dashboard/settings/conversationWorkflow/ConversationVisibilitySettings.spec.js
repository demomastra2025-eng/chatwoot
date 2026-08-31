import { shallowMount } from '@vue/test-utils';
import { reactive, ref } from 'vue';

import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';
import ConversationVisibilitySettings from './ConversationVisibilitySettings.vue';

const currentAccount = ref({ settings: {} });
const accountId = ref(1);
const updateAccount = vi.fn();
const useAlert = vi.fn();
const enabledFeatures = new Set();
const isFeatureEnabled = vi.fn((_, featureFlag) =>
  enabledFeatures.has(featureFlag)
);
const crmReferencesStore = reactive({
  pipelines: [],
  ui: { isLoadingPipelines: false },
  loadPipelines: vi.fn(),
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${JSON.stringify(params)}` : key),
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: message => useAlert(message),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref(isFeatureEnabled),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId,
    currentAccount,
    updateAccount,
  }),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => crmReferencesStore,
}));

const mountComponent = () =>
  shallowMount(ConversationVisibilitySettings, {
    global: {
      stubs: {
        BaseSettingsHeader: true,
        SettingsLayout: {
          template:
            '<section><slot name="header" /><slot name="body" /></section>',
        },
        SectionLayout: {
          props: ['title', 'description', 'hideContent'],
          template:
            '<section><h2>{{ title }}</h2><p>{{ description }}</p><slot name="headerActions" /><slot /></section>',
        },
        Switch: {
          props: ['id', 'modelValue', 'disabled'],
          emits: ['update:modelValue'],
          template:
            '<input :id="id" type="checkbox" :checked="modelValue" :disabled="disabled" @change="$emit(\'update:modelValue\', $event.target.checked)" />',
        },
        NextSelect: {
          props: ['id', 'modelValue', 'options'],
          emits: ['update:modelValue'],
          template:
            '<select :id="id" :value="modelValue" @change="$emit(\'update:modelValue\', Number($event.target.value))"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
        },
        Button: true,
      },
    },
  });

describe('ConversationVisibilitySettings', () => {
  beforeEach(() => {
    currentAccount.value = { settings: {} };
    enabledFeatures.clear();
    enabledFeatures.add(FEATURE_FLAGS.CRM_DEALS);
    enabledFeatures.add(FEATURE_FLAGS.SCHEDULING);
    crmReferencesStore.pipelines = [
      {
        id: 1,
        name: 'Main pipeline',
        active: true,
        default: true,
        position: 1,
        stages: [
          { id: 11, name: 'New', active: true, position: 1 },
          { id: 12, name: 'Qualified', active: true, position: 2 },
        ],
      },
      {
        id: 2,
        name: 'Second pipeline',
        active: true,
        default: false,
        position: 2,
        stages: [{ id: 21, name: 'Incoming', active: true, position: 1 }],
      },
    ];
    crmReferencesStore.ui.isLoadingPipelines = false;
    crmReferencesStore.loadPipelines.mockReset();
    crmReferencesStore.loadPipelines.mockResolvedValue(
      crmReferencesStore.pipelines
    );
    updateAccount.mockReset();
    updateAccount.mockResolvedValue();
    useAlert.mockReset();
    isFeatureEnabled.mockClear();
  });

  it('shows supported conversation navigation groups', () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.groupedVisibilityItems.map(group => group.key)).toEqual([
      'pipeline',
      'appointments',
    ]);
    expect(wrapper.vm.PRIMARY_NAVIGATION_ITEMS.map(item => item.key)).toEqual([
      'assignee',
      'folders',
      'teams',
      'labels',
    ]);
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ASSIGNEE'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.APPOINTMENTS'
    );
    expect(wrapper.text()).toContain('SIDEBAR.CUSTOM_VIEWS_FOLDER');
    expect(wrapper.text()).toContain('SIDEBAR.TEAMS');
    expect(wrapper.text()).toContain('SIDEBAR.LABELS');
    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ORGANIZATION'
    );
    const primaryNavigation = wrapper.get(
      '[data-testid="conversation-primary-navigation"]'
    );
    expect(primaryNavigation.classes()).toContain('divide-y');
    expect(primaryNavigation.classes()).not.toContain('rounded-xl');
    expect(primaryNavigation.classes()).not.toContain('border');
    expect(primaryNavigation.findAll('label')).toHaveLength(4);
    expect(wrapper.vm.visibilityDraft['Conversation:Folders']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Teams']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Labels']).toBe(true);
    expect(
      wrapper
        .find('#conversation-visibility-conversation-organization')
        .exists()
    ).toBe(false);
    expect(
      wrapper.find('#conversation-visibility-conversation-folders').exists()
    ).toBe(true);
    expect(
      wrapper.find('#conversation-visibility-conversation-teams').exists()
    ).toBe(true);
    expect(
      wrapper.find('#conversation-visibility-conversation-labels').exists()
    ).toBe(true);
    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.STATUSES'
    );
  });

  it('toggles folders independently from teams and tags', () => {
    const wrapper = mountComponent();
    const foldersItem = wrapper.vm.PRIMARY_NAVIGATION_ITEMS.find(
      item => item.key === 'folders'
    );

    wrapper.vm.togglePrimaryNavigationItem(foldersItem);

    expect(wrapper.vm.visibilityDraft['Conversation:Folders']).toBe(false);
    expect(wrapper.vm.visibilityDraft['Conversation:Teams']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Labels']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee']).toBe(true);
  });

  it('does not overwrite a dirty navigation draft during an account refresh', async () => {
    const wrapper = mountComponent();
    const foldersItem = wrapper.vm.PRIMARY_NAVIGATION_ITEMS.find(
      item => item.key === 'folders'
    );

    wrapper.vm.togglePrimaryNavigationItem(foldersItem);
    currentAccount.value = {
      settings: {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:Teams'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      },
    };
    await wrapper.vm.$nextTick();

    expect(wrapper.vm.visibilityDraft['Conversation:Folders']).toBe(false);
    expect(wrapper.vm.visibilityDraft['Conversation:Teams']).toBe(true);
  });

  it('hides unavailable business sections', () => {
    enabledFeatures.delete(FEATURE_FLAGS.CRM_DEALS);
    enabledFeatures.delete(FEATURE_FLAGS.SCHEDULING);

    const wrapper = mountComponent();

    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
    );
    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.APPOINTMENTS'
    );
  });

  it('hides record statuses when Records are hidden', async () => {
    const wrapper = mountComponent();
    const appointmentsGroup = wrapper.vm.groupedVisibilityItems.find(
      group => group.key === 'appointments'
    );

    wrapper.vm.toggleGroupExpansion(appointmentsGroup);
    await wrapper.vm.$nextTick();
    expect(
      wrapper
        .find(
          '#conversation-visibility-conversation-appointmentstatus-scheduled'
        )
        .exists()
    ).toBe(true);

    wrapper.vm.toggleGroup(appointmentsGroup);
    await wrapper.vm.$nextTick();

    expect(wrapper.vm.isGroupExpanded(appointmentsGroup)).toBe(false);
    expect(
      wrapper
        .find(
          '#conversation-visibility-conversation-appointmentstatus-scheduled'
        )
        .exists()
    ).toBe(false);
  });

  it('keeps primary lists atomic inside main navigation', async () => {
    const wrapper = mountComponent();

    const assigneeItem = wrapper.vm.PRIMARY_NAVIGATION_ITEMS.find(
      item => item.key === 'assignee'
    );
    wrapper.vm.togglePrimaryNavigationItem(assigneeItem);
    await wrapper.vm.$nextTick();

    const allSwitch = wrapper.find(
      '#conversation-visibility-conversation-assignee-all'
    );
    const mineSwitch = wrapper.find(
      '#conversation-visibility-conversation-assignee-me'
    );
    const unassignedSwitch = wrapper.find(
      '#conversation-visibility-conversation-assignee-unassigned'
    );

    expect(allSwitch.exists()).toBe(false);
    expect(mineSwitch.exists()).toBe(false);
    expect(unassignedSwitch.exists()).toBe(false);
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee:all']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee:me']).toBe(false);
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee:unassigned']).toBe(
      false
    );

    await wrapper.vm.saveVisibility();
    expect(updateAccount).toHaveBeenCalledWith(
      expect.objectContaining({
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Conversation:Assignee',
          'Conversation:Assignee:me',
          'Conversation:Assignee:unassigned',
        ],
      })
    );

    wrapper.vm.togglePrimaryNavigationItem(assigneeItem);
    await wrapper.vm.$nextTick();
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee:all']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee:me']).toBe(true);
    expect(wrapper.vm.visibilityDraft['Conversation:Assignee:unassigned']).toBe(
      true
    );
    expect(
      wrapper
        .find('#conversation-visibility-conversation-assignee-all')
        .exists()
    ).toBe(false);
  });

  it('selects a pipeline before exposing its stages', async () => {
    const wrapper = mountComponent();
    const pipelineGroup = wrapper.vm.groupedVisibilityItems.find(
      group => group.key === 'pipeline'
    );

    expect(wrapper.text()).not.toContain('New');
    wrapper.vm.toggleGroupExpansion(pipelineGroup);
    await wrapper.vm.$nextTick();

    expect(wrapper.text()).toContain('Main pipeline');
    expect(wrapper.text()).toContain('New');
    expect(wrapper.text()).not.toContain('Incoming');
    expect(
      wrapper.find('#conversation-visibility-primary-pipeline').element.value
    ).toBe('1');

    wrapper.vm.setSelectedPipeline(2);
    await wrapper.vm.$nextTick();

    expect(wrapper.text()).toContain('Incoming');
    expect(wrapper.text()).not.toContain('New');
    expect(wrapper.vm.pipelineVisibilityDraft['1'].enabled).toBe(false);
    expect(wrapper.vm.pipelineVisibilityDraft['2'].enabled).toBe(true);
  });

  it('preserves navigation edits when delayed pipelines finish loading', async () => {
    const pipelines = crmReferencesStore.pipelines;
    crmReferencesStore.pipelines = [];
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft['Conversation:Folders'] = false;
    crmReferencesStore.pipelines = pipelines;
    await wrapper.vm.$nextTick();

    expect(wrapper.vm.visibilityDraft['Conversation:Folders']).toBe(false);
    expect(wrapper.vm.pipelineVisibilityDraft['1'].enabled).toBe(true);
  });

  it('preserves stage edits when pipeline references refresh', async () => {
    const wrapper = mountComponent();

    wrapper.vm.pipelineVisibilityDraft['1'].stages['12'] = false;
    crmReferencesStore.pipelines = crmReferencesStore.pipelines.map(
      pipeline => ({
        ...pipeline,
        stages: pipeline.stages.map(stage => ({ ...stage })),
      })
    );
    await wrapper.vm.$nextTick();

    expect(wrapper.vm.pipelineVisibilityDraft['1'].stages['12']).toBe(false);
    expect(wrapper.vm.pipelineVisibilityDraft['1'].enabled).toBe(true);
  });

  it('shows compact summaries and expands only one business section', async () => {
    const wrapper = mountComponent();
    const pipelineGroup = wrapper.vm.groupedVisibilityItems.find(
      group => group.key === 'pipeline'
    );
    const appointmentsGroup = wrapper.vm.groupedVisibilityItems.find(
      group => group.key === 'appointments'
    );

    expect(wrapper.vm.groupSummary(pipelineGroup)).toContain('Main pipeline');
    expect(wrapper.vm.groupSummary(appointmentsGroup)).toContain('"visible":5');
    const pipelineSection = wrapper.get(
      '[data-testid="conversation-navigation-group-pipeline"]'
    );
    expect(pipelineSection.find('button-stub').exists()).toBe(false);
    expect(pipelineSection.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.CONFIGURE'
    );

    wrapper.vm.toggleGroupExpansion(pipelineGroup);
    await wrapper.vm.$nextTick();
    expect(wrapper.vm.isGroupExpanded(pipelineGroup)).toBe(true);
    expect(wrapper.text()).toContain('New');
    expect(pipelineSection.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.COLLAPSE'
    );

    wrapper.vm.toggleGroupExpansion(appointmentsGroup);
    await wrapper.vm.$nextTick();
    expect(wrapper.vm.isGroupExpanded(pipelineGroup)).toBe(false);
    expect(wrapper.vm.isGroupExpanded(appointmentsGroup)).toBe(true);
    expect(wrapper.text()).not.toContain('New');
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.SCHEDULED'
    );
  });

  it('saves conversation navigation without changing top-level visibility', async () => {
    currentAccount.value = {
      settings: {
        locale: 'ru',
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
          'Reports',
          'Conversation:Pipelines',
        ],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      },
    };
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft['Conversation:Pipelines'] = true;
    wrapper.vm.visibilityDraft['Conversation:Folders'] = false;
    await wrapper.vm.saveVisibility();

    expect(updateAccount).toHaveBeenCalledWith({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Reports', 'Conversation:Folders'],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
      dashboard_conversation_sidebar_pipeline_visibility: {
        configured: true,
        pipelines: [
          { id: 1, enabled: true, hidden_stage_ids: [] },
          { id: 2, enabled: false, hidden_stage_ids: [] },
        ],
      },
    });
    expect(useAlert).toHaveBeenCalledWith(
      'CONVERSATION_WORKFLOW.VISIBILITY.SAVE.SUCCESS'
    );
  });

  it('does not overwrite pipeline selection when pipelines failed to load', async () => {
    currentAccount.value = {
      settings: {
        dashboard_conversation_sidebar_pipeline_visibility: {
          configured: true,
          pipelines: [{ id: 1, enabled: true, hidden_stage_ids: [12] }],
        },
      },
    };
    crmReferencesStore.pipelines = [];
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft['Conversation:Folders'] = false;
    await wrapper.vm.saveVisibility();

    expect(updateAccount).toHaveBeenCalledWith({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:Folders'],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });
  });
});
