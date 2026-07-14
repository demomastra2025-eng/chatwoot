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

  it('keeps the current legacy action visible for existing rules', () => {
    expect(optionsFor('apply_touch_plan')).toEqual([
      {
        id: 'create_touch',
        name: 'Create touch',
      },
      {
        id: 'apply_touch_plan',
        name: 'Legacy touch plan',
      },
    ]);
  });
});
