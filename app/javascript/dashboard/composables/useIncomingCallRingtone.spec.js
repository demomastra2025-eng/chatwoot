import { mount } from '@vue/test-utils';
import { defineComponent, nextTick, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const testState = vi.hoisted(() => ({
  uiSettings: null,
  setSourceState: vi.fn(),
  removeSource: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: testState.uiSettings }),
}));

vi.mock('dashboard/helper/AudioAlerts/IncomingCallRingtone', () => ({
  default: {
    setSourceState: testState.setSourceState,
    removeSource: testState.removeSource,
  },
}));

import { useIncomingCallRingtone } from './useIncomingCallRingtone';

const mountComposable = (isActive, source = 'voice') =>
  mount(
    defineComponent({
      setup() {
        useIncomingCallRingtone(source, isActive);
        return () => null;
      },
    })
  );

describe('useIncomingCallRingtone', () => {
  beforeEach(() => {
    testState.uiSettings = ref({});
    testState.setSourceState.mockReset();
    testState.removeSource.mockReset();
  });

  it('registers the source with the profile ringtone and reacts to changes', async () => {
    const isActive = ref(false);
    const wrapper = mountComposable(isActive);

    expect(testState.setSourceState).toHaveBeenLastCalledWith('voice', {
      active: false,
      tone: 'universfield-ringtone-091-496417.mp3',
    });

    testState.uiSettings.value = {
      incoming_call_ringtone: 'universfield-ringtone-028-380250',
    };
    isActive.value = true;
    await nextTick();

    expect(testState.setSourceState).toHaveBeenLastCalledWith('voice', {
      active: true,
      tone: 'universfield-ringtone-028-380250.mp3',
    });

    wrapper.unmount();
    expect(testState.removeSource).toHaveBeenCalledWith('voice');
  });

  it('starts enabled and stops only the voice ringtone when turned off', async () => {
    const voice = mountComposable(ref(true));
    const whatsapp = mountComposable(ref(true), 'whatsapp');
    expect(testState.setSourceState).toHaveBeenCalledWith(
      'voice',
      expect.objectContaining({ active: true })
    );

    testState.uiSettings.value = { voice_call_ringtone_enabled: false };
    await nextTick();
    expect(testState.setSourceState).toHaveBeenCalledWith(
      'voice',
      expect.objectContaining({ active: false })
    );
    expect(testState.setSourceState).toHaveBeenCalledWith(
      'whatsapp',
      expect.objectContaining({ active: true })
    );

    testState.uiSettings.value = { voice_call_ringtone_enabled: true };
    await nextTick();
    expect(testState.setSourceState).toHaveBeenCalledWith(
      'voice',
      expect.objectContaining({ active: true })
    );
    voice.unmount();
    whatsapp.unmount();
  });

  it('keeps ringing when a newer call list takes over the source before the old one unmounts', () => {
    // The standalone call cards give way to the phone widget's call list: the
    // new list reports the ringing call first, then the old cards unmount.
    const standaloneCards = mountComposable(ref(true));
    const phoneCallList = mountComposable(ref(true));
    testState.setSourceState.mockClear();

    standaloneCards.unmount();

    expect(testState.removeSource).not.toHaveBeenCalled();
    expect(testState.setSourceState).not.toHaveBeenCalled();

    phoneCallList.unmount();
    expect(testState.removeSource).toHaveBeenCalledOnce();
    expect(testState.removeSource).toHaveBeenCalledWith('voice');
  });

  it('removes the source when its only reporter unmounts', () => {
    const wrapper = mountComposable(ref(true));

    wrapper.unmount();

    expect(testState.removeSource).toHaveBeenCalledWith('voice');
  });
});
