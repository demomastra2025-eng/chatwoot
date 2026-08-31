import { flushPromises, mount } from '@vue/test-utils';
import { h, nextTick, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import Index from './Index.vue';

const testState = vi.hoisted(() => ({
  batchUpdateStages: vi.fn(() => Promise.resolve()),
  checkStageDeletion: vi.fn(() => Promise.resolve({ deletable: true })),
  deleteStage: vi.fn(() => Promise.resolve()),
  loadPipelines: vi.fn(() => Promise.resolve()),
  reorderStages: vi.fn(() => Promise.resolve()),
  savePipeline: vi.fn(payload => Promise.resolve(payload)),
  saveStage: vi.fn(() =>
    Promise.resolve({ id: 12, name: 'New stage', pipelineId: 1 })
  ),
  route: { query: { pipelineId: '1' } },
  routeLeaveGuard: null,
  routeUpdateGuard: null,
  router: {
    push: vi.fn(() => Promise.resolve()),
    replace: vi.fn(() => Promise.resolve()),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => (key === 'CRM.SETTINGS.STAGES.NEW_NAME' ? 'New stage' : key),
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
  useAlert: vi.fn(),
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
    pipelines: [pipeline],
    ui: {
      error: null,
      isLoadingPipelines: false,
      isSaving: false,
    },
    loadPipelines: testState.loadPipelines,
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
    label: { type: String, default: '' },
    modelValue: { type: String, default: '' },
    options: { type: Array, default: () => [] },
    subMenuPosition: { type: String, default: 'right' },
  },
  emits: ['update:modelValue'],
  template: `
    <button
      type="button"
      :data-position="subMenuPosition"
      @click="$emit('update:modelValue', options[1]?.value)"
    >
      {{ label }}
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
        SchedulingPageHeader: {
          template:
            '<header><slot name="title" /><slot name="actions" /></header>',
        },
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
    pipeline.stages.find(stage => stage.id === 13).active = true;
    testState.checkStageDeletion.mockReset();
    testState.checkStageDeletion.mockResolvedValue({ deletable: true });
    testState.batchUpdateStages.mockReset();
    testState.batchUpdateStages.mockResolvedValue(pipeline);
    testState.deleteStage.mockClear();
    testState.loadPipelines.mockClear();
    testState.reorderStages.mockClear();
    testState.savePipeline.mockClear();
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
    ).toEqual(['11', expect.stringMatching(/^draft-stage-/), '13']);
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
    const wrapper = mountComponent();
    await flushPromises();

    const selector = wrapper.get('[data-testid="auto-create-stage-select"]');
    expect(selector.text()).toBe('Qualified');
    expect(selector.attributes('data-position')).toBe('bottom');
    expect(selector.element.parentElement.classList).not.toContain(
      'rounded-xl'
    );

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
});
