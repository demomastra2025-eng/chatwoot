import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import AudioAlertEvent from './AudioAlertEvent.vue';

const COMBINATIONS_KEY =
  'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.ALERT_COMBINATIONS';

const mountComponent = value =>
  mount(AudioAlertEvent, {
    props: { value, label: 'Events' },
    global: {
      mocks: { $t: key => key },
      stubs: {
        CheckBox: {
          props: ['id', 'isChecked'],
          emits: ['update'],
          template: `<input type="checkbox" :id="id" :checked="isChecked"
            @change="$emit('update', null, $event.target.checked)" />`,
        },
      },
    },
  });

const checkedEvents = wrapper =>
  ['assigned', 'unassigned', 'notme'].filter(
    event => wrapper.get(`#checkbox-${event}`).element.checked
  );

describe('AudioAlertEvent', () => {
  it('ticks assigned and unassigned for the default selection', () => {
    const wrapper = mountComponent('assigned+unassigned');

    expect(checkedEvents(wrapper)).toEqual(['assigned', 'unassigned']);
    expect(wrapper.text()).toContain(`${COMBINATIONS_KEY}.ASSIGNED+UNASSIGNED`);
  });

  it('ticks nothing for none', () => {
    const wrapper = mountComponent('none');

    expect(checkedEvents(wrapper)).toEqual([]);
    expect(wrapper.text()).toContain(`${COMBINATIONS_KEY}.NONE`);
  });

  it('writes the sorted selection when a box is changed', async () => {
    const wrapper = mountComponent('assigned+unassigned');

    await wrapper.get('#checkbox-notme').setValue(true);
    await wrapper.setProps({ value: 'assigned+notme+unassigned' });
    await wrapper.get('#checkbox-unassigned').setValue(false);

    expect(wrapper.emitted('update')).toEqual([
      ['assigned+notme+unassigned'],
      ['assigned+notme'],
    ]);
  });

  it('writes none when the last box is cleared', async () => {
    const wrapper = mountComponent('unassigned');

    await wrapper.get('#checkbox-unassigned').setValue(false);

    expect(wrapper.emitted('update')).toEqual([['none']]);
  });
});
