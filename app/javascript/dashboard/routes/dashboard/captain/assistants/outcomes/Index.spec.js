/* eslint-disable vue/one-component-per-file */
import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock(
  'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue',
  () => ({
    default: defineComponent({ name: 'SettingsHeader', template: '<div />' }),
  })
);

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    name: 'ButtonStub',
    inheritAttrs: false,
    props: {
      label: { type: String, default: '' },
      disabled: Boolean,
    },
    emits: ['click'],
    setup(props, { attrs, emit }) {
      return () =>
        h(
          'button',
          {
            ...attrs,
            disabled: props.disabled,
            onClick: () => emit('click'),
          },
          props.label
        );
    },
  }),
}));

vi.mock('dashboard/components-next/switch/Switch.vue', () => ({
  default: defineComponent({
    name: 'SwitchStub',
    inheritAttrs: false,
    props: {
      modelValue: Boolean,
      disabled: Boolean,
    },
    emits: ['update:modelValue'],
    setup(props, { attrs, emit }) {
      return () =>
        h('input', {
          ...attrs,
          type: 'checkbox',
          checked: props.modelValue,
          disabled: props.disabled,
          onChange: event => emit('update:modelValue', event.target.checked),
        });
    },
  }),
}));

const { default: OutcomesForm } = await import('./Index.vue');
const mountComponent = (config = {}) =>
  mount(OutcomesForm, {
    props: {
      assistant: { id: 58, config },
      handoffEnabled: config.handoff_enabled !== false,
    },
  });

describe('Captain assistant outcome settings form', () => {
  it('enables both capabilities by default and exposes stable reasons', async () => {
    const wrapper = mountComponent();

    expect(wrapper.findAll('[data-testid="outcome-reason-row"]')).toHaveLength(
      11
    );
    expect(
      wrapper.find('[data-testid="outcome-toggle-handoffReasons"]').exists()
    ).toBe(false);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config).toMatchObject({
      auto_completion_enabled: true,
    });
    expect(payload.assistant.config).not.toHaveProperty('handoff_enabled');
    expect(
      payload.assistant.config.outcome_reason_settings.completion_reasons
    ).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: 'goal_achieved', active: true }),
        expect.objectContaining({ id: 'other', active: true }),
      ])
    );
  });

  it('hides handoff reasons when the existing capability is disabled', async () => {
    const wrapper = mountComponent({ handoff_enabled: false });

    expect(
      wrapper.find('[data-testid="outcome-section-handoffReasons"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .get('[data-testid="outcome-section-completionReasons"]')
        .find('[data-testid="outcome-reason-row"]')
        .exists()
    ).toBe(true);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config).not.toHaveProperty('handoff_enabled');
  });

  it('hides completion reasons when automatic completion is disabled', async () => {
    const wrapper = mountComponent({ auto_completion_enabled: false });

    expect(
      wrapper
        .get('[data-testid="outcome-section-completionReasons"]')
        .find('[data-testid="outcome-reason-row"]')
        .exists()
    ).toBe(false);

    const payload = await wrapper.vm.buildPayload();
    expect(payload.assistant.config.auto_completion_enabled).toBe(false);
  });

  it('keeps reason ids stable when labels are renamed', async () => {
    const wrapper = mountComponent({
      outcome_reason_settings: {
        completion_reasons: [{ id: 'goal_achieved', label: 'Old label' }],
        handoff_reasons: [{ id: 'low_confidence', label: 'Needs human' }],
      },
    });

    const completionInput = wrapper
      .get('[data-testid="outcome-section-completionReasons"]')
      .get('input:not([type="checkbox"])');
    await completionInput.setValue('Renamed label');

    const payload = await wrapper.vm.buildPayload();
    expect(
      payload.assistant.config.outcome_reason_settings.completion_reasons
    ).toEqual(
      expect.arrayContaining([
        { id: 'goal_achieved', label: 'Renamed label', active: true },
        expect.objectContaining({ id: 'other', active: true }),
      ])
    );
  });

  it('preserves an unsaved reason label during a background assistant refresh', async () => {
    const wrapper = mountComponent({
      outcome_reason_settings: {
        completion_reasons: [{ id: 'goal_achieved', label: 'Saved label' }],
      },
    });
    const completionInput = wrapper
      .get('[data-testid="outcome-section-completionReasons"]')
      .get('input:not([type="checkbox"])');
    await completionInput.setValue('Unsaved draft');

    await wrapper.setProps({
      assistant: {
        id: 58,
        config: {
          outcome_reason_settings: {
            completion_reasons: [
              { id: 'goal_achieved', label: 'Background value' },
            ],
          },
        },
      },
    });

    expect(completionInput.element.value).toBe('Unsaved draft');
  });

  it('does not allow removing or disabling the required other fallback', () => {
    const wrapper = mountComponent();
    const otherRows = wrapper.findAll('[data-reason-id="other"]');

    expect(otherRows).toHaveLength(2);
    expect(
      otherRows.every(
        row =>
          !row.find('[data-testid="outcome-remove"]').exists() &&
          row.get('input[type="checkbox"]').attributes('disabled') !== undefined
      )
    ).toBe(true);
  });

  it('validates empty reasons only while their capability is enabled', async () => {
    const wrapper = mountComponent();
    await wrapper
      .get('[data-testid="outcome-add-completionReasons"]')
      .trigger('click');

    expect(await wrapper.vm.buildPayload()).toBeNull();

    await wrapper
      .get('[data-testid="outcome-toggle-completionReasons"]')
      .setValue(false);
    const payload = await wrapper.vm.buildPayload();
    expect(payload).not.toBeNull();
    expect(
      payload.assistant.config.outcome_reason_settings.completion_reasons
    ).not.toEqual(
      expect.arrayContaining([expect.objectContaining({ label: '' })])
    );
  });
});

const HANDOFF = 'handoffReasons';
const COMPLETION = 'completionReasons';

const sectionOf = (wrapper, type) =>
  wrapper.get(`[data-testid="outcome-section-${type}"]`);
const rowsOf = section => section.findAll('[data-testid="outcome-reason-row"]');
const idsOf = section =>
  rowsOf(section).map(row => row.attributes('data-reason-id'));
const labelInputsOf = section =>
  section.findAll('input:not([type="checkbox"])');
// Tag, input type and classes of every control in a row, without its content.
const rowSignature = row =>
  [...row.element.children].map(
    child =>
      `${child.tagName.toLowerCase()}|${child.getAttribute('type')}|${child.className}`
  );
const reasonIds = reasons => reasons.map(reason => reason.id);
const payloadIds = async (wrapper, key) => {
  const payload = await wrapper.vm.buildPayload();
  return reasonIds(payload.assistant.config.outcome_reason_settings[key]);
};

describe('Captain assistant outcome settings: consistent reason lists', () => {
  it('renders the handoff and completion lists with the same structure', () => {
    const wrapper = mountComponent();
    const handoff = sectionOf(wrapper, HANDOFF);
    const completion = sectionOf(wrapper, COMPLETION);

    expect(handoff.classes()).toEqual(completion.classes());

    [HANDOFF, COMPLETION].forEach(type => {
      const header = sectionOf(wrapper, type).get(
        '[data-testid="outcome-reasons-header"]'
      );
      const addButton = header.get(`[data-testid="outcome-add-${type}"]`);

      expect(addButton.text()).toBe('CAPTAIN.ASSISTANTS.OUTCOMES.ADD');
      expect(header.element.lastElementChild).toBe(addButton.element);
    });
    expect(
      handoff.get('[data-testid="outcome-reasons-header"]').classes()
    ).toEqual(
      completion.get('[data-testid="outcome-reasons-header"]').classes()
    );

    const handoffRows = rowsOf(handoff);
    const completionRows = rowsOf(completion);
    const userRowSignature = rowSignature(completionRows[0]);
    const systemRowSignature = rowSignature(completionRows.at(-1));

    expect(userRowSignature).toHaveLength(4);
    expect(systemRowSignature).toHaveLength(3);
    handoffRows.slice(0, -1).forEach(row => {
      expect(rowSignature(row)).toEqual(userRowSignature);
    });
    completionRows.slice(0, -1).forEach(row => {
      expect(rowSignature(row)).toEqual(userRowSignature);
    });
    expect(rowSignature(handoffRows.at(-1))).toEqual(systemRowSignature);
    [...handoffRows, ...completionRows].forEach(row => {
      expect(row.classes()).toEqual(completionRows[0].classes());
    });
  });

  it('keeps the big completion toggle in the completion card only', () => {
    const wrapper = mountComponent();

    expect(
      sectionOf(wrapper, COMPLETION)
        .find('[data-testid="outcome-toggle-completionReasons"]')
        .exists()
    ).toBe(true);
    expect(
      sectionOf(wrapper, HANDOFF)
        .find('[data-testid="outcome-toggle-completionReasons"]')
        .exists()
    ).toBe(false);
  });

  it('shows Other last in both lists by default', async () => {
    const wrapper = mountComponent();

    expect(idsOf(sectionOf(wrapper, HANDOFF)).at(-1)).toBe('other');
    expect(idsOf(sectionOf(wrapper, COMPLETION)).at(-1)).toBe('other');
    expect(await payloadIds(wrapper, 'handoff_reasons')).toEqual(
      idsOf(sectionOf(wrapper, HANDOFF))
    );
    expect(await payloadIds(wrapper, 'completion_reasons')).toEqual(
      idsOf(sectionOf(wrapper, COMPLETION))
    );
  });

  it('puts Other last in both lists whatever order the API returns', async () => {
    const reasons = ids => ids.map(id => ({ id, label: id, active: true }));
    const wrapper = mountComponent({
      outcome_reason_settings: {
        completion_reasons: reasons(['other', 'first', 'second']),
        handoff_reasons: reasons(['first', 'other', 'second', 'third']),
      },
    });

    expect(idsOf(sectionOf(wrapper, COMPLETION))).toEqual([
      'first',
      'second',
      'other',
    ]);
    expect(idsOf(sectionOf(wrapper, HANDOFF))).toEqual([
      'first',
      'second',
      'third',
      'other',
    ]);
    expect(await payloadIds(wrapper, 'completion_reasons')).toEqual([
      'first',
      'second',
      'other',
    ]);
    expect(await payloadIds(wrapper, 'handoff_reasons')).toEqual([
      'first',
      'second',
      'third',
      'other',
    ]);
  });

  it('puts Other last for reasons that come from the legacy status options', () => {
    const wrapper = mount(OutcomesForm, {
      props: {
        assistant: { id: 58, config: {} },
        legacyReasons: {
          resolved: { options: ['Legacy done'] },
          open: { options: ['Legacy human', 'Legacy angry'] },
        },
      },
    });

    expect(idsOf(sectionOf(wrapper, COMPLETION))).toEqual([
      'legacy_completion_1',
      'other',
    ]);
    expect(idsOf(sectionOf(wrapper, HANDOFF))).toEqual([
      'legacy_handoff_1',
      'legacy_handoff_2',
      'other',
    ]);
  });

  const expectNewReasonsBeforeOther = async (wrapper, type) => {
    const section = sectionOf(wrapper, type);
    const before = idsOf(section);
    const userReasons = before.slice(0, -1);
    const addButton = section.get(`[data-testid="outcome-add-${type}"]`);
    await addButton.trigger('click');
    await addButton.trigger('click');

    const after = idsOf(section);
    expect(after).toHaveLength(before.length + 2);
    expect(after.slice(0, userReasons.length)).toEqual(userReasons);
    expect(after.at(-1)).toBe('other');
    expect(after[userReasons.length]).toMatch(/^custom_/);
    expect(after[userReasons.length + 1]).toMatch(/^custom_/);

    const rows = rowsOf(section);
    const unsavedRow = rows[userReasons.length];
    const unsavedInput = unsavedRow.get('input:not([type="checkbox"])');
    expect(unsavedInput.element.value).toBe('');
    expect(unsavedInput.attributes('placeholder')).toBe(
      'CAPTAIN.ASSISTANTS.OUTCOMES.PLACEHOLDER'
    );
    expect(rowSignature(unsavedRow)).toEqual(rowSignature(rows[0]));
    expect(unsavedRow.classes()).toEqual(rows[0].classes());
  };

  it('adds a new unsaved reason after the user reasons and before Other in both lists', async () => {
    const wrapper = mountComponent();

    await expectNewReasonsBeforeOther(wrapper, HANDOFF);
    await expectNewReasonsBeforeOther(wrapper, COMPLETION);
  });

  it('keeps a new reason before Other when the completion list only has Other', async () => {
    const wrapper = mountComponent({
      outcome_reason_settings: {
        completion_reasons: [{ id: 'other', label: 'Other', active: true }],
      },
    });
    const completion = sectionOf(wrapper, COMPLETION);

    expect(idsOf(completion)).toEqual(['other']);

    await completion
      .get('[data-testid="outcome-add-completionReasons"]')
      .trigger('click');
    expect(idsOf(completion)[0]).toMatch(/^custom_completion_/);
    expect(idsOf(completion).at(-1)).toBe('other');

    await labelInputsOf(completion)[0].setValue('Brand new reason');
    expect(await payloadIds(wrapper, 'completion_reasons')).toEqual([
      expect.stringMatching(/^custom_completion_/),
      'other',
    ]);
  });

  it('saves new reasons between the user reasons and Other in both lists', async () => {
    const wrapper = mountComponent();
    const addAndName = async type => {
      const section = sectionOf(wrapper, type);
      await section.get(`[data-testid="outcome-add-${type}"]`).trigger('click');
      await labelInputsOf(section).at(-2).setValue(`New ${type}`);
    };

    await addAndName(HANDOFF);
    await addAndName(COMPLETION);

    const payload = await wrapper.vm.buildPayload();
    const { completion_reasons: completion, handoff_reasons: handoff } =
      payload.assistant.config.outcome_reason_settings;

    [completion, handoff].forEach(list => {
      expect(list.at(-1).id).toBe('other');
      expect(list.at(-2).id).toMatch(/^custom_/);
    });
    expect(handoff.at(-2).label).toBe(`New ${HANDOFF}`);
    expect(completion.at(-2).label).toBe(`New ${COMPLETION}`);
  });

  it('locks the system reason and hides its delete button in both lists', async () => {
    const wrapper = mountComponent();
    const expectLockedSystemReason = async type => {
      const section = sectionOf(wrapper, type);
      const rows = rowsOf(section);
      const systemRow = rows.at(-1);

      expect(systemRow.attributes('data-reason-id')).toBe('other');
      expect(systemRow.find('[data-testid="outcome-remove"]').exists()).toBe(
        false
      );
      expect(
        systemRow.get('input[type="checkbox"]').attributes('disabled')
      ).toBeDefined();
      rows.slice(0, -1).forEach(row => {
        expect(row.find('[data-testid="outcome-remove"]').exists()).toBe(true);
        expect(
          row.get('input[type="checkbox"]').attributes('disabled')
        ).toBeUndefined();
      });

      await section.get('[data-testid="outcome-remove"]').trigger('click');
      expect(rowsOf(section)).toHaveLength(rows.length - 1);
      expect(idsOf(section).at(-1)).toBe('other');
    };

    await expectLockedSystemReason(HANDOFF);
    await expectLockedSystemReason(COMPLETION);
  });
});
