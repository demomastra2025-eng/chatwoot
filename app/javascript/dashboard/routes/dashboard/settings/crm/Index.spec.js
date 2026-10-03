import { flushPromises, shallowMount } from '@vue/test-utils';
import { defineComponent, h, nextTick, reactive, ref } from 'vue';

import CrmSettings from './Index.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  router: { go: vi.fn(), push: vi.fn(), replace: vi.fn() },
  route: { query: {} },
  referencesStore: null,
}));

vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key =>
    key === 'getCurrentAccountId' ? { value: 7 } : { value: () => true },
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: ref({ settings: {} }),
    updateAccount: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));
vi.mock('dashboard/composables/useTouchPlans', () => ({
  useTouchPlans: () => ({
    isLoadingTouchPlans: ref(false),
    loadTouchPlans: vi.fn(() => Promise.resolve()),
    touchPlanOptionsForEntityKind: () => [],
  }),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mocks.referencesStore,
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => mocks.route,
  useRouter: () => mocks.router,
}));

const ButtonStub = defineComponent({
  name: 'ButtonStub',
  inheritAttrs: false,
  setup(_props, { attrs, slots }) {
    return () => {
      const { disabled, isLoading, label, ...buttonAttrs } = attrs;
      return h(
        'button',
        { ...buttonAttrs, disabled: Boolean(disabled || isLoading) },
        [label, slots.default?.()]
      );
    };
  },
});

const InputStub = defineComponent({
  name: 'InputStub',
  inheritAttrs: false,
  setup(_props, { attrs }) {
    return () => {
      const inputAttrs = { ...attrs };
      delete inputAttrs.label;
      delete inputAttrs.modelValue;
      delete inputAttrs['onUpdate:modelValue'];
      return h('label', {}, [
        h('span', {}, attrs.label),
        h('input', {
          ...inputAttrs,
          'aria-label': attrs.label,
          placeholder: attrs.placeholder,
          value: attrs.modelValue,
          onInput: event => attrs['onUpdate:modelValue']?.(event.target.value),
        }),
      ]);
    };
  },
});

const SchedulingDrawerStub = defineComponent({
  name: 'SchedulingDrawerStub',
  inheritAttrs: false,
  setup(_props, { attrs, slots }) {
    const sectionAttrs = Object.fromEntries(
      Object.entries(attrs).filter(
        ([key]) =>
          ['class', 'id', 'role'].includes(key) ||
          key.startsWith('aria-') ||
          key.startsWith('data-')
      )
    );

    return () =>
      attrs.modelValue
        ? h('section', sectionAttrs, [slots.default?.(), slots.footer?.()])
        : null;
  },
});

const DialogStub = defineComponent({
  name: 'DialogStub',
  inheritAttrs: false,
  setup(_props, { attrs, expose }) {
    expose({ open: vi.fn(), close: vi.fn() });
    return () =>
      h('section', { ...attrs }, [
        h(
          'button',
          {
            type: 'button',
            'data-test': 'confirm-delete-stage',
            disabled: attrs.disableConfirmButton,
            onClick: () => attrs.onConfirm?.(),
          },
          attrs.confirmButtonLabel
        ),
      ]);
  },
});

const DraggableStub = defineComponent({
  props: ['modelValue'],
  setup(props, { slots }) {
    return () =>
      h(
        'div',
        (props.modelValue || []).map((element, index) =>
          slots.item?.({ element, index })
        )
      );
  },
});

const SchedulingFormFieldGroupStub = defineComponent({
  name: 'SchedulingFormFieldGroupStub',
  setup(_props, { attrs, slots }) {
    return () =>
      h('section', {}, [
        h('h2', {}, attrs.title),
        slots.default?.(),
        slots.headerActions?.(),
      ]);
  },
});

const pipelineFixture = ({
  id = 17,
  name = 'Sales',
  isDefault = true,
} = {}) => {
  const idOffset = (id - 17) * 100;
  return {
    id,
    name,
    active: true,
    default: isDefault,
    autoCreateDealOnChannelContact: false,
    position: id === 17 ? 0 : 1,
    stages: [
      {
        id: 31 + idOffset,
        pipelineId: id,
        name: 'Lead',
        code: 'lead',
        color: '#E11D48',
        active: true,
        default: true,
        outcome: 'open',
        position: 1,
        transitionReasonOptions: [],
        transitionReasonRequired: false,
      },
      {
        id: 32 + idOffset,
        pipelineId: id,
        name: 'Proposal',
        code: 'proposal',
        color: '#2563EB',
        active: true,
        default: false,
        outcome: 'open',
        position: 2,
        transitionReasonOptions: ['Qualified'],
        transitionReasonRequired: true,
      },
      {
        id: 33 + idOffset,
        pipelineId: id,
        name: 'Won',
        code: 'won',
        color: '#16A34A',
        active: true,
        default: false,
        outcome: 'won',
        position: 3,
        closingReasonOptions: ['Price'],
        closingReasonRequired: true,
      },
      {
        id: 34 + idOffset,
        pipelineId: id,
        name: 'Lost',
        code: 'lost',
        color: '#DC2626',
        active: true,
        default: false,
        outcome: 'lost',
        position: 4,
        closingReasonOptions: [],
        closingReasonRequired: false,
      },
      {
        id: 35 + idOffset,
        pipelineId: id,
        name: 'Paused',
        code: 'paused',
        color: '#7C3AED',
        active: false,
        default: false,
        outcome: 'open',
        position: 5,
        transitionReasonOptions: [],
        transitionReasonRequired: false,
      },
    ],
  };
};

const mountComponent = async ({
  includeInactiveStages = true,
  additionalPipelines = [],
} = {}) => {
  const pipeline = pipelineFixture();
  const allStages = pipeline.stages;
  if (!includeInactiveStages) {
    pipeline.stages = allStages.filter(stage => stage.active);
  }
  mocks.referencesStore = reactive({
    pipelines: [pipeline, ...additionalPipelines],
    ui: { error: null, isLoadingPipelines: false, isSaving: false },
    loadPipelines: vi.fn(() => Promise.resolve()),
    saveStageDraft: vi.fn(() => Promise.resolve(pipeline)),
    saveStage: vi.fn(),
    savePipeline: vi.fn(),
    checkStageDeletion: vi.fn(),
    deleteStage: vi.fn(),
    deletePipeline: vi.fn(),
  });
  const reactivePipeline = mocks.referencesStore.pipelines[0];

  const wrapper = shallowMount(CrmSettings, {
    global: {
      mocks: { $t: key => key, $router: mocks.router },
      stubs: {
        BaseSettingsHeader: true,
        Button: ButtonStub,
        Checkbox: true,
        Dialog: DialogStub,
        Draggable: DraggableStub,
        Input: InputStub,
        SchedulingColorPicker: true,
        SchedulingDrawer: SchedulingDrawerStub,
        SchedulingErrorState: true,
        SchedulingFormFieldGroup: SchedulingFormFieldGroupStub,
        SchedulingSelectField: true,
        SettingsLayout: {
          template:
            '<main><slot name="header" /><slot name="body" /><slot /></main>',
        },
        Spinner: true,
        Switch: true,
        TagInput: true,
        TouchPlanSelectField: true,
      },
    },
  });

  await flushPromises();
  return { allStages, pipeline: reactivePipeline, wrapper };
};

describe('CRM settings stage drafts', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.route.query = {};
  });

  it('keeps stage edits local until one complete draft save', async () => {
    const { pipeline, wrapper } = await mountComponent();

    await wrapper.get('[data-test="edit-stage"]').trigger('click');
    await wrapper
      .get(
        '[data-test="stage-editor-drawer"] input[aria-label="CRM.SETTINGS.STAGES.FORM.NAME"]'
      )
      .setValue('New lead');
    await wrapper.get('[data-test="apply-stage-edit"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).not.toHaveBeenCalled();
    expect(mocks.referencesStore.saveStage).not.toHaveBeenCalled();
    expect(pipeline.stages[0].name).toBe('Lead');
    expect(wrapper.text()).toContain('New lead');

    await wrapper.get('[data-test="save-stage-draft"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).toHaveBeenCalledTimes(1);
    expect(mocks.referencesStore.saveStageDraft).toHaveBeenCalledWith(
      17,
      expect.objectContaining({
        deleted_stage_ids: [],
        stages: expect.arrayContaining([
          expect.objectContaining({ id: 31, name: 'New lead' }),
          expect.objectContaining({
            id: 32,
            transition_reason_options: ['Qualified'],
            transition_reason_required: true,
          }),
        ]),
        terminal_stages: expect.arrayContaining([
          expect.objectContaining({
            id: 33,
            closing_reason_options: ['Price'],
            closing_reason_required: true,
          }),
        ]),
      })
    );
  });

  it('discards a local edit without sending a stage update', async () => {
    const { wrapper } = await mountComponent();

    await wrapper.get('[data-test="edit-stage"]').trigger('click');
    await wrapper
      .get(
        '[data-test="stage-editor-drawer"] input[aria-label="CRM.SETTINGS.STAGES.FORM.NAME"]'
      )
      .setValue('Temporary name');
    await wrapper.get('[data-test="apply-stage-edit"]').trigger('click');
    await flushPromises();
    expect(wrapper.text()).toContain('Temporary name');

    await wrapper.get('[data-test="cancel-stage-draft"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).not.toHaveBeenCalled();
    expect(wrapper.text()).toContain('Lead');
    expect(wrapper.text()).not.toContain('Temporary name');
  });

  it('creates a stage in the local draft and includes it in the same save request', async () => {
    const { wrapper } = await mountComponent();

    await wrapper.get('[data-test="add-stage-draft"]').trigger('click');
    await wrapper
      .get(
        '[data-test="stage-editor-drawer"] input[aria-label="CRM.SETTINGS.STAGES.FORM.NAME"]'
      )
      .setValue('Follow-up');
    await wrapper.get('[data-test="apply-stage-edit"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).not.toHaveBeenCalled();
    expect(wrapper.text()).toContain('Follow-up');

    await wrapper.get('[data-test="save-stage-draft"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).toHaveBeenCalledTimes(1);
    const [, payload] = mocks.referencesStore.saveStageDraft.mock.calls[0];
    expect(payload.stages).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: 'Follow-up',
          active: true,
          transition_reason_options: [],
          transition_reason_required: false,
        }),
      ])
    );
    expect(
      payload.stages.find(stage => stage.name === 'Follow-up').id
    ).toBeUndefined();
  });

  it('marks a confirmed removal in the draft and waits for its atomic save', async () => {
    const { wrapper } = await mountComponent();
    mocks.referencesStore.checkStageDeletion.mockResolvedValue({
      canDelete: true,
      dealCount: 0,
      stageId: 31,
    });

    await wrapper.get('[data-test="delete-stage-draft"]').trigger('click');
    await flushPromises();
    await wrapper
      .get(
        '[data-test="stage-delete-dialog"] [data-test="confirm-delete-stage"]'
      )
      .trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.deleteStage).not.toHaveBeenCalled();
    expect(mocks.referencesStore.saveStageDraft).not.toHaveBeenCalled();
    expect(
      wrapper
        .findAll('[data-test="edit-stage"]')
        .some(button => button.text().includes('Lead'))
    ).toBe(false);

    await wrapper.get('[data-test="save-stage-draft"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).toHaveBeenCalledTimes(1);
    const [, payload] = mocks.referencesStore.saveStageDraft.mock.calls[0];
    expect(payload.deleted_stage_ids).toEqual([31]);
    expect(payload.stages.map(stage => stage.id)).not.toContain(31);
  });

  it('refreshes the clean draft when the same pipeline gains inactive stages', async () => {
    const { allStages, wrapper, pipeline } = await mountComponent({
      includeInactiveStages: false,
    });

    expect(
      wrapper
        .findAll('[data-test="edit-stage"]')
        .some(button => button.text().includes('Paused'))
    ).toBe(false);

    pipeline.stages = allStages;
    await nextTick();

    expect(
      wrapper
        .findAll('[data-test="edit-stage"]')
        .some(button => button.text().includes('Paused'))
    ).toBe(true);

    await wrapper.get('[data-test="edit-stage"]').trigger('click');
    await wrapper
      .get(
        '[data-test="stage-editor-drawer"] input[aria-label="CRM.SETTINGS.STAGES.FORM.NAME"]'
      )
      .setValue('Updated lead');
    await wrapper.get('[data-test="apply-stage-edit"]').trigger('click');
    await wrapper.get('[data-test="save-stage-draft"]').trigger('click');
    await flushPromises();

    const [, payload] = mocks.referencesStore.saveStageDraft.mock.calls[0];
    expect(payload.stages.map(stage => stage.id)).toContain(35);
  });

  it('keeps dirty local edits through a pipeline refresh until the draft is cancelled', async () => {
    const { wrapper, pipeline } = await mountComponent();

    await wrapper.get('[data-test="edit-stage"]').trigger('click');
    await wrapper
      .get(
        '[data-test="stage-editor-drawer"] input[aria-label="CRM.SETTINGS.STAGES.FORM.NAME"]'
      )
      .setValue('Local draft');
    await wrapper.get('[data-test="apply-stage-edit"]').trigger('click');
    await flushPromises();

    pipeline.stages = [
      ...pipeline.stages.map(stage =>
        stage.id === 31 ? { ...stage, name: 'Server lead' } : stage
      ),
      {
        ...pipeline.stages[0],
        id: 36,
        name: 'Server-added stage',
        code: 'server_added',
        active: false,
        default: false,
        position: 6,
      },
    ];
    await nextTick();

    const stageNames = wrapper
      .findAll('[data-test="edit-stage"]')
      .map(button => button.find('span').text());
    expect(stageNames).toContain('Local draft');
    expect(stageNames).not.toContain('Server-added stage');

    await wrapper.get('[data-test="cancel-stage-draft"]').trigger('click');
    await nextTick();

    const refreshedStageButtons = wrapper.findAll('[data-test="edit-stage"]');
    const refreshedStageNames = refreshedStageButtons.map(button =>
      button.find('span').text()
    );
    expect(refreshedStageNames).toContain('Server lead');
    expect(refreshedStageNames).toContain('Server-added stage');
    expect(refreshedStageNames).not.toContain('Local draft');
    const inactiveStageButton = refreshedStageButtons.find(
      button => button.find('span').text() === 'Server-added stage'
    );
    expect(inactiveStageButton.text()).toContain('CRM.GENERAL.INACTIVE');
  });

  it('creates a route-requested stage in that pipeline draft', async () => {
    const supportPipeline = pipelineFixture({
      id: 18,
      name: 'Support',
      isDefault: false,
    });
    mocks.route.query = { action: 'create-stage', pipelineId: '18' };
    const { wrapper } = await mountComponent({
      additionalPipelines: [supportPipeline],
    });

    await wrapper
      .get(
        '[data-test="stage-editor-drawer"] input[aria-label="CRM.SETTINGS.STAGES.FORM.NAME"]'
      )
      .setValue('Escalation');
    await wrapper.get('[data-test="apply-stage-edit"]').trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('Escalation');
    await wrapper.get('[data-test="save-stage-draft"]').trigger('click');
    await flushPromises();

    expect(mocks.referencesStore.saveStageDraft).toHaveBeenCalledWith(
      18,
      expect.objectContaining({
        stages: expect.arrayContaining([
          expect.objectContaining({ name: 'Escalation' }),
        ]),
      })
    );
  });
});
