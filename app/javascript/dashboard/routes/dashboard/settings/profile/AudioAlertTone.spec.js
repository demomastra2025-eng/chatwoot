import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import AudioAlertTone from './AudioAlertTone.vue';

const audio = {
  currentTime: 3,
  src: '',
  pause: vi.fn(),
  play: vi.fn().mockResolvedValue(undefined),
};

const mountComponent = props =>
  mount(AudioAlertTone, {
    props,
    global: {
      mocks: { $t: key => key },
      directives: { tooltip: {} },
      stubs: {
        FormSelect: {
          props: ['modelValue', 'name', 'options', 'label'],
          emits: ['update:modelValue'],
          template: '<select :name="name"><slot /></select>',
        },
        Icon: true,
      },
    },
  });

describe('AudioAlertTone', () => {
  beforeEach(() => {
    audio.currentTime = 3;
    audio.src = '';
    audio.pause.mockReset();
    audio.play.mockReset().mockResolvedValue(undefined);
    vi.stubGlobal(
      'Audio',
      vi.fn(() => audio)
    );
  });

  it('previews a ringtone from its configured audio directory', async () => {
    const wrapper = mountComponent({
      value: 'universfield-ringtone-091-496417.mp3',
      label: 'Incoming call sound',
      name: 'incomingCallRingtone',
      audioPath: '/audio/ringtone',
      tones: [
        {
          value: 'universfield-ringtone-091-496417.mp3',
          label: 'Melody 4',
        },
      ],
    });

    await wrapper.get('button').trigger('click');

    expect(audio.pause).toHaveBeenCalledTimes(1);
    expect(audio.currentTime).toBe(0);
    expect(audio.src).toBe(
      '/audio/ringtone/universfield-ringtone-091-496417.mp3'
    );
    expect(audio.play).toHaveBeenCalledTimes(1);
    expect(wrapper.get('select').attributes('name')).toBe(
      'incomingCallRingtone'
    );
  });

  it('falls back to the first allowed option for an invalid stored value', async () => {
    const wrapper = mountComponent({
      value: '../../invalid',
      label: 'Incoming call sound',
      audioPath: '/audio/ringtone',
      tones: [
        {
          value: 'universfield-ringtone-091-496417.mp3',
          label: 'Melody 4',
        },
      ],
    });

    await wrapper.get('button').trigger('click');

    expect(audio.src).toBe(
      '/audio/ringtone/universfield-ringtone-091-496417.mp3'
    );
  });
});
