import { beforeEach, describe, expect, it, vi } from 'vitest';

const audioHelper = vi.hoisted(() => ({ set: vi.fn() }));

vi.mock('../AudioAlerts/DashboardAudioNotificationHelper', () => ({
  default: audioHelper,
}));

import { initializeAudioAlerts } from '../scriptHelpers';

const appliedSettings = async user => {
  initializeAudioAlerts(user);
  await vi.waitFor(() => expect(audioHelper.set).toHaveBeenCalledTimes(1));
  return audioHelper.set.mock.calls[0][0];
};

describe('initializeAudioAlerts', () => {
  beforeEach(() => {
    audioHelper.set.mockClear();
  });

  it('turns sounds on for a user who never chose, with bipbop', async () => {
    const user = { id: 1, ui_settings: {} };

    expect(await appliedSettings(user)).toEqual({
      currentUser: user,
      audioAlertType: 'assigned+unassigned',
      audioAlertTone: 'bipbop',
      alwaysPlayAudioAlert: false,
      alertIfUnreadConversationExist: false,
    });
  });

  it('applies the same defaults while ui_settings are not loaded yet', async () => {
    expect(await appliedSettings({ id: 1 })).toMatchObject({
      audioAlertType: 'assigned+unassigned',
      audioAlertTone: 'bipbop',
    });
  });

  it('keeps an explicit none off', async () => {
    const settings = await appliedSettings({
      id: 1,
      ui_settings: { enable_audio_alerts: 'none' },
    });

    expect(settings.audioAlertType).toBe('none');
  });

  it('keeps the chosen events, tone and flags', async () => {
    const settings = await appliedSettings({
      id: 1,
      ui_settings: {
        enable_audio_alerts: 'assigned+notme',
        notification_tone: 'softbell',
        always_play_audio_alert: true,
        alert_if_unread_assigned_conversation_exist: true,
      },
    });

    expect(settings).toMatchObject({
      audioAlertType: 'assigned+notme',
      audioAlertTone: 'softbell',
      alwaysPlayAudioAlert: true,
      alertIfUnreadConversationExist: true,
    });
  });

  it('plays bipbop for a tone that is no longer offered', async () => {
    const settings = await appliedSettings({
      id: 1,
      ui_settings: { notification_tone: 'bell' },
    });

    expect(settings.audioAlertTone).toBe('bipbop');
  });
});
