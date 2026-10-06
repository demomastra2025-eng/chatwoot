import { shallowMount } from '@vue/test-utils';

import AutomationActionInput from './AutomationActionInput.vue';

const actionTypes = [
  { key: 'create_touch', label: 'Create touch', inputType: 'touch' },
  {
    key: 'apply_touch_plan',
    label: 'Legacy touch plan',
    inputType: null,
    legacyOnly: true,
  },
];

const optionsFor = actionName =>
  AutomationActionInput.computed.actionTypesAsOptions.call({
    actionTypes,
    action_name: actionName,
  });

describe('AutomationActionInput', () => {
  it('hides legacy-only actions from new action selectors', () => {
    expect(optionsFor('create_touch')).toEqual([
      {
        id: 'create_touch',
        name: 'Create touch',
      },
    ]);
  });

  it('shows the legacy label and replaces it with an inline reminder action', () => {
    const wrapper = shallowMount(AutomationActionInput, {
      props: {
        modelValue: { action_name: 'apply_touch_plan', action_params: [7] },
        actionTypes,
      },
    });

    expect(wrapper.find('[data-testid="legacy-plan-action"]').text()).toBe(
      'Legacy touch plan'
    );
    expect(wrapper.findComponent({ name: 'SingleSelect' }).exists()).toBe(
      false
    );

    wrapper.vm.onActionNameChange({ id: 'create_touch' });
    expect(wrapper.emitted('update:modelValue')[0][0].action_name).toBe(
      'create_touch'
    );
    expect(wrapper.emitted('resetAction')).toHaveLength(1);
  });

  it('renders a legacy action as a read-only row with a replacement action', () => {
    expect(optionsFor('apply_touch_plan')).toEqual([
      { id: 'create_touch', name: 'Create touch' },
    ]);
    expect(
      AutomationActionInput.computed.isLegacyPlanAction.call({
        action_name: 'apply_touch_plan',
      })
    ).toBe(true);
    expect(
      AutomationActionInput.computed.legacyActionLabel.call({
        actionTypes,
      })
    ).toBe('Legacy touch plan');
    expect(
      AutomationActionInput.computed.createTouchLabel.call({
        actionTypes,
      })
    ).toBe('Create touch');
  });
});
