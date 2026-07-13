import { shallowMount } from '@vue/test-utils';
import { computed, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const testState = vi.hoisted(() => ({
  uiSettings: null,
  updateUISettings: vi.fn(),
  dispatch: vi.fn(),
  currentUser: null,
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: testState.uiSettings,
    updateUISettings: testState.updateUISettings,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: testState.dispatch }),
  useStoreGetters: () => ({
    getCurrentUser: computed(() => testState.currentUser),
  }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/helper/scriptHelpers', () => ({
  initializeAudioAlerts: vi.fn(),
}));

import AudioAlertTone from './AudioAlertTone.vue';
import AudioNotifications from './AudioNotifications.vue';

const mountComponent = () =>
  shallowMount(AudioNotifications, {
    global: {
      mocks: { $t: key => key },
    },
  });

describe('AudioNotifications', () => {
  beforeEach(() => {
    testState.uiSettings = ref({
      notification_tone: 'ding',
      enable_audio_alerts: 'none',
      always_play_audio_alert: false,
      alert_if_unread_assigned_conversation_exist: false,
    });
    testState.currentUser = { id: 1, ui_settings: testState.uiSettings.value };
    testState.updateUISettings.mockReset();
    testState.dispatch.mockReset();
  });

  it('renders incoming-call ringtone before the notification tone with 091 as default', () => {
    const wrapper = mountComponent();
    const toneSelectors = wrapper.findAllComponents(AudioAlertTone);

    expect(toneSelectors).toHaveLength(2);
    expect(toneSelectors[0].props()).toMatchObject({
      value: 'universfield-ringtone-091-496417.mp3',
      name: 'incomingCallRingtone',
      audioPath: '/audio/ringtone',
    });
    expect(toneSelectors[0].props('label')).toBe(
      'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.RINGTONE.TITLE'
    );
    expect(toneSelectors[1].props()).toMatchObject({
      value: 'ding',
      name: 'alertTone',
      audioPath: '/audio/dashboard',
    });
  });

  it('loads the saved ringtone and persists a new selection', async () => {
    testState.uiSettings.value.incoming_call_ringtone =
      'universfield-ringtone-066-496266';
    const wrapper = mountComponent();
    const ringtoneSelector = wrapper.findAllComponents(AudioAlertTone)[0];

    expect(ringtoneSelector.props('value')).toBe(
      'universfield-ringtone-066-496266.mp3'
    );

    ringtoneSelector.vm.$emit('change', 'universfield-ringtone-028-380250.mp3');
    await wrapper.vm.$nextTick();

    expect(testState.updateUISettings).toHaveBeenCalledWith({
      incoming_call_ringtone: 'universfield-ringtone-028-380250.mp3',
    });
  });
});
