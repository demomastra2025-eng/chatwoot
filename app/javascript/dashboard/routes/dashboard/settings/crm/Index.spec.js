import { flushPromises, mount } from '@vue/test-utils';
import { h, nextTick, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import Index from './Index.vue';

const testState = vi.hoisted(() => ({
  batchUpdateStages: vi.fn(() => Promise.resolve()),
  checkStageDeletion: vi.fn(() => Promise.resolve({ deletable: true })),
  useAlert: vi.fn(),
  translate: vi.fn(key =>
    key === 'CRM.SETTINGS.STAGES.NEW_NAME' ? 'New stage' : key
  ),
  deleteStage: vi.fn(() => Promise.resolve()),
  loadPipelines: vi.fn(() => Promise.resolve()),
  loadFieldDefinitions: vi.fn(() => Promise.resolve()),
  reorderStages: vi.fn(() => Promise.resolve()),
  savePipeline: vi.fn(payload => Promise.resolve(payload)),
  saveStage: vi.fn(() =>
    Promise.resolve({ id: 12, name: 'New stage', pipelineId: 1 })
  ),
  route: { query: { pipelineId: '1' } },
  pipelineList: [],
  routeLeaveGuard: null,
  routeUpdateGuard: null,
  selectedMenuOption: null,
  router: {
    push: vi.fn(() => Promise.resolve()),
    replace: vi.fn(() => Promise.resolve()),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (...args) => testState.translate(...args),
  }),
}));

vi.mock('vue-router', () => ({
  onBeforeRouteLeave: vi.fn(guard => {
    testState.routeLeaveGuard = guard;
  }),
  onBeforeRouteUpdate: vi.fn(guard => {
    testState.routeUpdateGuard = guard;
  }),
  useRoute: () => testState.route,
  useRouter: () => testState.router,
}));

vi.mock('dashboard/composables', () => ({
  useAlert: testState.useAlert,
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => {
    if (key === 'getCurrentAccountId') return ref(1);
    if (key === 'accounts/isFeatureEnabledonAccount') {
      return ref(() => true);
    }
    return ref(null);
  },
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));

const pipeline = {
  active: true,
  autoCreateDealOnChannelContact: true,
  default: true,
  id: 1,
  name: 'Sales',
  stages: [
    {
      active: true,
      code: 'new',
      color: '#2563EB',
      id: 10,
      name: 'Unsorted',
      outcome: 'open',
      pipelineId: 1,
      position: 0,
    },
    {
      active: true,
      code: 'qualified',
      color: '#16A34A',
      default: true,
      id: 11,
      name: 'Qualified',
      outcome: 'open',
      pipelineId: 1,
      position: 1,
    },
    {
      active: true,
      code: 'proposal',
      color: '#2563EB',
      id: 13,
      name: 'Proposal',
      outcome: 'open',
      pipelineId: 1,
      position: 2,
    },
  ],
};

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    dealFieldDefinitions: [],
    pipelines: testState.pipelineList,
    ui: {
      error: null,
      isLoadingPipelines: false,
      isSaving: false,
    },
    loadPipelines: testState.loadPipelines,
    loadFieldDefinitions: testState.loadFieldDefinitions,
    batchUpdateStages: testState.batchUpdateStages,
    checkStageDeletion: testState.checkStageDeletion,
    deleteStage: testState.deleteStage,
    reorderStages: testState.reorderStages,
    savePipeline: testState.savePipeline,
    saveStage: testState.saveStage,
  }),
}));

const ButtonStub = {
  props: {
    label: { type: String, default: '' },
  },
  emits: ['click', 'pointerdown'],
  template: `
    <button
      type="button"
      @pointerdown="$emit('pointerdown', $event)"
      @click="$emit('click', $event)"
    >
      {{ label }}
    </button>
  `,
};

const DialogStub = {
  name: 'Dialog',
  props: {
    title: { type: String, default: '' },
  },
  emits: ['close', 'confirm'],
  setup(_, { expose }) {
    expose({ close: vi.fn(), open: vi.fn() });
  },
  template: '<aside><slot /><slot name="footer" /></aside>',
};

const SchedulingDrawerStub = {
  props: {
    modelValue: { type: Boolean, default: false },
    title: { type: String, default: '' },
  },
  emits: ['confirm', 'update:modelValue'],
  template: `
    <aside v-if="modelValue" data-testid="scheduling-drawer">
      <h2>{{ title }}</h2>
      <slot />
      <slot name="footer" />
    </aside>
  `,
};

const InputStub = {
  props: {
    modelValue: { type: [String, Number], default: '' },
  },
  emits: ['update:modelValue'],
  template: `
    <input
      data-testid="stage-name-input"
      :value="modelValue"
      @input="$emit('update:modelValue', $event.target.value)"
    />
  `,
};

const DraggableStub = {
  props: {
    modelValue: { type: Array, default: () => [] },
  },
  setup(props, { slots }) {
    return () =>
      h(
        'div',
        props.modelValue.map((element, index) =>
          slots.item?.({ element, index })
        )
      );
  },
};

const SelectMenuStub = {
  props: {
    actionLabel: { type: String, default: '' },
    label: { type: String, default: '' },
    modelValue: { type: String, default: '' },
    options: { type: Array, default: () => [] },
    subMenuPosition: { type: String, default: 'right' },
  },
  emits: ['action', 'update:modelValue'],
  setup: () => ({ testState }),
  template: `
    <button
      type="button"
      :data-position="subMenuPosition"
      :data-options="options.map(option => option.value).join(',')"
      @click="$emit('update:modelValue', testState.selectedMenuOption || options[1]?.value)"
    >
      {{ label }}
      <span
        v-if="actionLabel"
        data-testid="select-menu-action"
        role="button"
        @click.stop="$emit('action')"
      >
        {{ actionLabel }}
      </span>
    </button>
  `,
};

const mountComponent = () =>
  mount(Index, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: ButtonStub,
        Dialog: DialogStub,
        Draggable: DraggableStub,
        Input: InputStub,
        SchedulingColorPicker: true,
        SchedulingDrawer: SchedulingDrawerStub,
        SchedulingErrorState: true,
        SelectMenu: SelectMenuStub,
        SettingsLayout: {
          template:
            '<main><slot name="loading" /><slot name="body" /><slot /></main>',
        },
        Spinner: true,
        Switch: true,
        TagInput: true,
      },
    },
  });

describe('CRM pipeline settings', () => {
  beforeEach(() => {
    testState.pipelineList = [pipeline];
    pipeline.stages.find(stage => stage.id === 13).active = true;
    testState.checkStageDeletion.mockReset();
    testState.checkStageDeletion.mockResolvedValue({ deletable: true });
    testState.useAlert.mockReset();
    testState.translate.mockClear();
    testState.batchUpdateStages.mockReset();
    testState.batchUpdateStages.mockResolvedValue(pipeline);
    testState.deleteStage.mockClear();
    testState.loadPipelines.mockClear();
    testState.reorderStages.mockClear();
    testState.savePipeline.mockClear();
    testState.selectedMenuOption = null;
    testState.saveStage.mockReset();
    testState.saveStage.mockResolvedValue({
      color: '#16A34A',
      id: 12,
      name: 'New stage',
      outcome: 'open',
      pipelineId: 1,
      position: 3,
    });
    testState.router.replace.mockClear();
  });

  it('shows unsorted as the fixed first stage with its own switch', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const stages = wrapper.findAll('[data-stage-id]');
    expect(stages[0].attributes('data-stage-id')).toBe('10');
    expect(stages[0].find('.stage-drag-handle').exists()).toBe(false);
    expect(stages[0].find('switch-stub').exists()).toBe(true);
    expect(stages[0].text()).toContain(
      'CRM.SETTINGS.STAGES.SYSTEM.POSITION_LOCKED'
    );
    expect(stages[1].text()).toContain(
      'CRM.SETTINGS.STAGE_RULES.REQUIRED_FIELDS'
    );
  });

  it('keeps a new stage frontend-only until the global save', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const saveButton = wrapper.get('[data-testid="save-settings-button"]');

    expect(saveButton.attributes()).toHaveProperty('disabled');

    await wrapper.get('[data-testid="create-stage-at-1"]').trigger('click');
    await nextTick();

    const draftStage = wrapper.get('[data-draft-stage="true"]');
    expect(draftStage.find('input').element.value).toBe('New stage');
    expect(
      wrapper
        .findAll('[data-stage-id]')
        .map(card => card.attributes('data-stage-id'))
    ).toEqual(['10', '11', expect.stringMatching(/^draft-stage-/), '13']);
    expect(testState.saveStage).not.toHaveBeenCalled();
    expect(testState.reorderStages).not.toHaveBeenCalled();
    expect(saveButton.attributes()).not.toHaveProperty('disabled');

    await saveButton.trigger('click');
    await flushPromises();

    expect(testState.batchUpdateStages).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        stages: expect.arrayContaining([
          expect.objectContaining({
            id: undefined,
            color: expect.stringMatching(/^#[A-F0-9]{6}$/),
            name: 'New stage',
          }),
        ]),
      })
    );
    expect(wrapper.find('[data-draft-stage="true"]').exists()).toBe(false);
    expect(saveButton.attributes()).toHaveProperty('disabled');
    expect(wrapper.find('[data-testid="scheduling-drawer"]').exists()).toBe(
      false
    );
  });

  it('does not save an existing stage name on blur', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const saveButton = wrapper.get('[data-testid="save-settings-button"]');
    const nameInput = wrapper.get('[data-stage-name-id="13"]');
    await nameInput.setValue('Proposal draft');
    await nameInput.trigger('blur');

    expect(testState.saveStage).not.toHaveBeenCalled();
    expect(saveButton.attributes()).not.toHaveProperty('disabled');

    await saveButton.trigger('click');
    await flushPromises();

    expect(testState.batchUpdateStages).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        stages: expect.arrayContaining([
          expect.objectContaining({ id: 13, name: 'Proposal draft' }),
        ]),
      })
    );
    expect(testState.reorderStages).not.toHaveBeenCalled();
  });

  it('validates blank stage names before sending the batch request', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const nameInput = wrapper.get('[data-stage-name-id="13"]');
    await nameInput.setValue('   ');
    await wrapper.get('[data-testid="save-settings-button"]').trigger('click');
    await flushPromises();

    expect(testState.batchUpdateStages).not.toHaveBeenCalled();
    expect(nameInput.element.value).toBe('   ');
  });

  it('preserves the complete local draft when the atomic batch is rejected', async () => {
    testState.batchUpdateStages.mockRejectedValueOnce({
      response: { data: { code: 'STAGE_HAS_DEALS' } },
    });
    const wrapper = mountComponent();
    await flushPromises();

    const nameInput = wrapper.get('[data-stage-name-id="13"]');
    await nameInput.setValue('Proposal draft');
    await wrapper.get('[data-testid="create-stage-at-1"]').trigger('click');
    await wrapper.get('[data-testid="save-settings-button"]').trigger('click');
    await flushPromises();

    expect(wrapper.get('[data-stage-name-id="13"]').element.value).toBe(
      'Proposal draft'
    );
    expect(wrapper.find('[data-draft-stage="true"]').exists()).toBe(true);
    expect(testState.loadPipelines).toHaveBeenCalledTimes(1);
  });

  it('keeps a stage color frontend-only until the global save', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const stageCard = wrapper.get('[data-stage-id="13"]');
    const colorPicker = stageCard.findComponent({
      name: 'SchedulingColorPicker',
    });
    colorPicker.vm.$emit('update:modelValue', '#A855F7');
    await nextTick();

    expect(testState.saveStage).not.toHaveBeenCalled();
    expect(
      wrapper.get('[data-testid="save-settings-button"]').attributes()
    ).not.toHaveProperty('disabled');

    await wrapper.get('[data-testid="save-settings-button"]').trigger('click');
    await flushPromises();

    expect(testState.batchUpdateStages).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        stages: expect.arrayContaining([
          expect.objectContaining({ color: '#A855F7', id: 13 }),
        ]),
      })
    );
    expect(testState.reorderStages).not.toHaveBeenCalled();
  });

  it('keeps a stage deletion frontend-only until the global save', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const stageCard = wrapper.get('[data-stage-id="13"]');
    await stageCard.findAll('button').at(-1).trigger('click');
    await flushPromises();
    wrapper
      .findAllComponents({ name: 'Dialog' })
      .find(
        dialog => dialog.props('title') === 'CRM.SETTINGS.STAGES.DELETE_TITLE'
      )
      .vm.$emit('confirm');
    await nextTick();

    expect(wrapper.find('[data-stage-id="13"]').exists()).toBe(false);
    expect(testState.checkStageDeletion).toHaveBeenCalledWith(13);
    expect(testState.deleteStage).not.toHaveBeenCalled();
    expect(
      wrapper.get('[data-testid="save-settings-button"]').attributes()
    ).not.toHaveProperty('disabled');

    await wrapper.get('[data-testid="save-settings-button"]').trigger('click');
    await flushPromises();

    expect(testState.batchUpdateStages).toHaveBeenCalledWith(
      1,
      expect.objectContaining({ deleted_stage_ids: [13] })
    );
  });

  it('keeps a stage and explains a successful preflight blocker response', async () => {
    // The references store camelCases the preflight payload before it reaches the page.
    testState.checkStageDeletion.mockResolvedValueOnce({
      canDelete: false,
      blockReason: 'STAGE_HAS_DEALS',
      dealCount: 2,
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .get('[data-stage-id="13"]')
      .findAll('button')
      .at(-1)
      .trigger('click');
    await flushPromises();

    expect(wrapper.find('[data-stage-id="13"]').exists()).toBe(true);
    expect(testState.translate).toHaveBeenCalledWith(
      'CRM.ERRORS.STAGE_HAS_DEALS',
      { count: 2 }
    );
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CRM.ERRORS.STAGE_HAS_DEALS'
    );
    expect(testState.batchUpdateStages).not.toHaveBeenCalled();
  });

  it('keeps a stage that deals have passed through and says to deactivate it', async () => {
    testState.checkStageDeletion.mockResolvedValueOnce({
      canDelete: false,
      blockReason: 'STAGE_HAS_HISTORY',
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .get('[data-stage-id="13"]')
      .findAll('button')
      .at(-1)
      .trigger('click');
    await flushPromises();

    expect(wrapper.find('[data-stage-id="13"]').exists()).toBe(true);
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CRM.ERRORS.STAGE_HAS_HISTORY'
    );
    expect(testState.batchUpdateStages).not.toHaveBeenCalled();
  });

  it('keeps a stage when the deletion preflight rejects it', async () => {
    testState.checkStageDeletion.mockRejectedValueOnce({
      response: { data: { code: 'STAGE_HAS_DEALS' } },
    });
    const wrapper = mountComponent();
    await flushPromises();

    const stageCard = wrapper.get('[data-stage-id="13"]');
    await stageCard.findAll('button').at(-1).trigger('click');
    await flushPromises();

    expect(testState.checkStageDeletion).toHaveBeenCalledWith(13);
    expect(wrapper.find('[data-stage-id="13"]').exists()).toBe(true);
    expect(testState.deleteStage).not.toHaveBeenCalled();
  });

  it('offers stay, discard, or save before leaving with a dirty draft', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.get('[data-stage-name-id="13"]').setValue('Proposal draft');

    const stayDecision = testState.routeLeaveGuard();
    await nextTick();
    await wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CRM.SETTINGS.STAGES.UNSAVED.STAY')
      )
      .trigger('click');
    await expect(stayDecision).resolves.toBe(false);

    const discardDecision = testState.routeUpdateGuard(
      { query: { pipelineId: '2' } },
      { query: { pipelineId: '1' } }
    );
    await nextTick();
    await wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CRM.SETTINGS.STAGES.UNSAVED.DISCARD')
      )
      .trigger('click');
    await expect(discardDecision).resolves.toBe(true);
    expect(testState.saveStage).not.toHaveBeenCalled();

    await wrapper.get('[data-stage-name-id="13"]').setValue('Proposal saved');
    const saveDecision = testState.routeLeaveGuard();
    await nextTick();
    await wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CRM.SETTINGS.STAGES.UNSAVED.SAVE')
      )
      .trigger('click');
    await expect(saveDecision).resolves.toBe(true);
    expect(testState.batchUpdateStages).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        stages: expect.arrayContaining([
          expect.objectContaining({ id: 13, name: 'Proposal saved' }),
        ]),
      })
    );
  });

  it('keeps the default stage selector inside auto-create settings', async () => {
    const inactiveStage = {
      active: false,
      code: 'inactive_open',
      id: 14,
      name: 'Inactive open',
      outcome: 'open',
      pipelineId: 1,
      position: 3,
    };
    const closedStage = {
      active: true,
      code: 'won',
      id: 15,
      name: 'Won',
      outcome: 'won',
      pipelineId: 1,
      position: 4,
    };
    testState.pipelineList = [
      { ...pipeline, stages: [...pipeline.stages, inactiveStage, closedStage] },
    ];
    const wrapper = mountComponent();
    await flushPromises();

    const selector = wrapper.get('[data-testid="auto-create-stage-select"]');
    expect(selector.text()).toBe('Qualified');
    expect(selector.attributes('data-position')).toBe('bottom');
    expect(selector.attributes('data-options').split(',')).toContain('10');
    expect(selector.attributes('data-options').split(',')).not.toContain('14');
    expect(selector.attributes('data-options').split(',')).not.toContain('15');
    expect(selector.element.parentElement.classList).not.toContain(
      'rounded-xl'
    );
    testState.selectedMenuOption = '13';
    await selector.trigger('click');
    await flushPromises();
    expect(testState.savePipeline).toHaveBeenCalledWith(
      expect.objectContaining({
        auto_create_deal_on_channel_contact: true,
        auto_create_stage_id: '13',
        id: 1,
      })
    );
  });

  it('saves the Unsorted stage database id for automatic deal creation', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const selector = wrapper.get('[data-testid="auto-create-stage-select"]');
    expect(selector.attributes('data-options').split(',')).toContain('10');
    testState.selectedMenuOption = '10';
    await selector.trigger('click');
    await flushPromises();

    expect(testState.savePipeline).toHaveBeenCalledWith(
      expect.objectContaining({
        auto_create_deal_on_channel_contact: true,
        auto_create_stage_id: '10',
        id: 1,
      })
    );
  });

  it('does not persist a closed, inactive, or other-pipeline stage selection', async () => {
    testState.pipelineList = [
      {
        ...pipeline,
        stages: [
          ...pipeline.stages,
          {
            active: false,
            code: 'inactive_open',
            id: 14,
            name: 'Inactive open',
            outcome: 'open',
            pipelineId: 1,
          },
          {
            active: true,
            code: 'won',
            id: 15,
            name: 'Won',
            outcome: 'won',
            pipelineId: 1,
          },
        ],
      },
      {
        active: true,
        id: 2,
        name: 'Other pipeline',
        stages: [
          {
            active: true,
            code: 'other',
            id: 22,
            name: 'Other stage',
            outcome: 'open',
            pipelineId: 2,
          },
        ],
      },
    ];
    const wrapper = mountComponent();
    await flushPromises();

    const selector = wrapper.get('[data-testid="auto-create-stage-select"]');
    await Promise.all(
      ['14', '15', '22'].map(stageId => {
        testState.selectedMenuOption = stageId;
        return selector.trigger('click');
      })
    );
    await flushPromises();

    expect(testState.savePipeline).not.toHaveBeenCalled();
  });

  it('does not offer stages from an inactive pipeline for automatic deals', async () => {
    testState.pipelineList = [{ ...pipeline, active: false }];
    const wrapper = mountComponent();
    await flushPromises();

    const selector = wrapper.get('[data-testid="auto-create-stage-select"]');
    expect(selector.attributes('data-options')).toBe('');
    testState.selectedMenuOption = '11';
    await selector.trigger('click');
    await flushPromises();

    expect(testState.savePipeline).not.toHaveBeenCalled();
  });

  it('renders settings directly on stage cards without legacy fields', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const existingStage = pipeline.stages.find(stage => stage.id === 13);
    existingStage.active = false;
    await nextTick();

    expect(wrapper.find('scheduling-color-picker-stub[compact]').exists()).toBe(
      true
    );
    expect(wrapper.find('[data-stage-id="13"]').exists()).toBe(true);
    expect(wrapper.text()).not.toContain('CRM.SETTINGS.STAGES.DEFAULT_BADGE');
    expect(wrapper.text()).not.toContain(
      'CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS'
    );
    expect(wrapper.get('header').text()).not.toContain(
      'CRM.SETTINGS.STAGES.CREATE_TITLE'
    );
    expect(
      wrapper.get('[data-stage-id="11"]').find('switch-stub').exists()
    ).toBe(false);
    existingStage.active = true;
  });

  it('edits the pipeline name directly in the page header', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const input = wrapper.get('[data-testid="pipeline-name-input"]');
    expect(input.element.value).toBe('Sales');
    await input.setValue('Direct Sales');
    await input.trigger('blur');
    await flushPromises();

    expect(testState.savePipeline).toHaveBeenCalledWith({
      id: 1,
      name: 'Direct Sales',
    });
  });

  it('renders the pipeline name editor through the real header title slot', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const header = wrapper.get('header');
    expect(header.find('h1').exists()).toBe(false);
    expect(header.find('[data-testid="pipeline-name-input"]').exists()).toBe(
      true
    );
    expect(header.find('[data-testid="select-menu-action"]').text()).toBe(
      'CRM.SETTINGS.PIPELINES.ADD'
    );
  });

  it('switches the pipeline from the header selector', async () => {
    testState.pipelineList = [
      pipeline,
      { active: true, default: false, id: 2, name: 'Support', stages: [] },
    ];
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.get('header [data-position="bottom"]').trigger('click');

    expect(testState.router.replace).toHaveBeenCalledWith({
      query: { pipelineId: '2' },
    });
  });

  it('opens the create pipeline drawer from the header selector action', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    expect(wrapper.find('[data-testid="scheduling-drawer"]').exists()).toBe(
      false
    );

    await wrapper
      .get('header [data-testid="select-menu-action"]')
      .trigger('click');
    await nextTick();

    expect(wrapper.find('[data-testid="scheduling-drawer"]').exists()).toBe(
      true
    );
  });
});
