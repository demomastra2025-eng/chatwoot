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

import AudioAlertCondition from './AudioAlertCondition.vue';
import AudioAlertEvent from './AudioAlertEvent.vue';
import AudioAlertTone from './AudioAlertTone.vue';
import AudioNotifications from './AudioNotifications.vue';

const TONES_KEY_PREFIX =
  'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.TONES';

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

  describe('message tone', () => {
    const toneSelector = wrapper =>
      wrapper.findAllComponents(AudioAlertTone)[1];

    it('offers exactly the six tones with their labels', () => {
      const tones = toneSelector(mountComponent()).props('tones');

      expect(tones).toEqual([
        { value: 'ding', label: `${TONES_KEY_PREFIX}.DING` },
        { value: 'ping', label: `${TONES_KEY_PREFIX}.PING` },
        { value: 'duet', label: `${TONES_KEY_PREFIX}.DUET` },
        { value: 'bipbop', label: `${TONES_KEY_PREFIX}.BIPBOP` },
        { value: 'signal', label: `${TONES_KEY_PREFIX}.SIGNAL` },
        { value: 'softbell', label: `${TONES_KEY_PREFIX}.SOFTBELL` },
      ]);
    });

    it('shows bipbop for a user who never chose a tone', () => {
      delete testState.uiSettings.value.notification_tone;

      expect(toneSelector(mountComponent()).props('value')).toBe('bipbop');
    });

    it.each(['bell', 'chime', 'magic', 'drumroll', 'unknown', null])(
      'shows bipbop instead of the removed or unknown tone %s',
      tone => {
        testState.uiSettings.value.notification_tone = tone;

        expect(toneSelector(mountComponent()).props('value')).toBe('bipbop');
      }
    );

    it('shows the saved tone and does not write anything on load', () => {
      testState.uiSettings.value.notification_tone = 'softbell';

      expect(toneSelector(mountComponent()).props('value')).toBe('softbell');
      expect(testState.updateUISettings).not.toHaveBeenCalled();
    });

    it('persists only the chosen tone', async () => {
      delete testState.uiSettings.value.enable_audio_alerts;
      const wrapper = mountComponent();

      toneSelector(wrapper).vm.$emit('change', 'duet');
      await wrapper.vm.$nextTick();

      expect(testState.updateUISettings).toHaveBeenCalledTimes(1);
      expect(testState.updateUISettings).toHaveBeenCalledWith({
        notification_tone: 'duet',
      });
    });
  });

  describe('message events', () => {
    const eventSelector = wrapper => wrapper.findComponent(AudioAlertEvent);

    it('shows assigned and unassigned ticked for a user who never chose', () => {
      delete testState.uiSettings.value.enable_audio_alerts;

      expect(eventSelector(mountComponent()).props('value')).toBe(
        'assigned+unassigned'
      );
    });

    it.each([undefined, null, ''])(
      'treats the empty value %j as never chosen',
      value => {
        testState.uiSettings.value.enable_audio_alerts = value;

        expect(eventSelector(mountComponent()).props('value')).toBe(
          'assigned+unassigned'
        );
      }
    );

    it('keeps an explicit none off', () => {
      testState.uiSettings.value.enable_audio_alerts = 'none';

      expect(eventSelector(mountComponent()).props('value')).toBe('none');
    });

    it('shows the saved selection', () => {
      testState.uiSettings.value.enable_audio_alerts = 'notme+unassigned';

      expect(eventSelector(mountComponent()).props('value')).toBe(
        'notme+unassigned'
      );
    });

    it('persists the selection the user makes', async () => {
      delete testState.uiSettings.value.enable_audio_alerts;
      const wrapper = mountComponent();

      eventSelector(wrapper).vm.$emit('update', 'unassigned');
      await wrapper.vm.$nextTick();

      expect(testState.updateUISettings).toHaveBeenCalledWith({
        enable_audio_alerts: 'unassigned',
      });
    });
  });

  describe('conditions', () => {
    it('plays only while the tab is inactive by default', () => {
      delete testState.uiSettings.value.always_play_audio_alert;
      delete testState.uiSettings.value
        .alert_if_unread_assigned_conversation_exist;
      const wrapper = mountComponent();
      const [tabCondition, unreadCondition] = wrapper
        .findComponent(AudioAlertCondition)
        .props('items');

      expect(tabCondition.model).toBe(true);
      expect(unreadCondition.model).toBeFalsy();
    });
  });
});
