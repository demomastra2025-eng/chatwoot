import { ref } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import {
  isCallHandledByAnotherOperator,
  useCallsStore,
} from 'dashboard/stores/calls';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import {
  PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY,
  usePhoneWidgetVisibility,
} from './usePhoneWidgetVisibility';

const { settingsState, accountState, userState } = vi.hoisted(() => ({
  settingsState: { settings: null, update: vi.fn() },
  accountState: { id: null },
  userState: { user: null },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: settingsState.settings,
    updateUISettings: settingsState.update,
  }),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: getter =>
    getter === 'getCurrentUser' ? userState.user : accountState.id,
}));
vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: { endClientCall: vi.fn() },
}));

const ringingCall = (callSid = 'sipuni:incoming-1') => ({
  callSid,
  callDirection: 'inbound',
  provider: 'sipuni',
  status: 'ringing',
});

describe('usePhoneWidgetVisibility', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    accountState.id = ref(7);
    userState.user = ref({ id: 1 });
    settingsState.settings = ref({});
    settingsState.update.mockReset().mockImplementation(next => {
      settingsState.settings.value = {
        ...settingsState.settings.value,
        ...next,
      };
    });
  });

  it('shows the phone by default and ignores malformed saved values', () => {
    settingsState.settings.value = {
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: [7],
    };
    const { isVisible, isHiddenByUser } = usePhoneWidgetVisibility();

    expect(isHiddenByUser.value).toBe(false);
    expect(isVisible.value).toBe(true);
  });

  it('saves the hidden phone for the current account and restores it', () => {
    settingsState.settings.value = {
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 3: true },
    };
    const { isVisible, toggle } = usePhoneWidgetVisibility();

    toggle();
    expect(settingsState.update).toHaveBeenLastCalledWith({
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 3: true, 7: true },
    });
    expect(isVisible.value).toBe(false);

    accountState.id.value = 3;
    expect(isVisible.value).toBe(false);
    accountState.id.value = 9;
    expect(isVisible.value).toBe(true);
    accountState.id.value = 7;

    toggle();
    expect(settingsState.update).toHaveBeenLastCalledWith({
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 3: true },
    });
    expect(isVisible.value).toBe(true);
  });

  it('shows a hidden phone during calls and while an outbound call starts', () => {
    settingsState.settings.value = {
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 7: true },
    };
    const callsStore = useCallsStore();
    const phoneWidgetStore = usePhoneWidgetStore();
    const { isVisible, hasCallActivity } = usePhoneWidgetVisibility();
    expect(isVisible.value).toBe(false);

    phoneWidgetStore.beginOutboundCall();
    expect(hasCallActivity.value).toBe(true);
    expect(isVisible.value).toBe(true);
    phoneWidgetStore.finishOutboundCall();
    expect(isVisible.value).toBe(false);

    callsStore.addCall(ringingCall());
    expect(isVisible.value).toBe(true);
    callsStore.setCallActive('sipuni:incoming-1', 'sipuni');
    expect(callsStore.hasActiveCall).toBe(true);
    expect(isVisible.value).toBe(true);

    callsStore.dismissCall('sipuni:incoming-1', 'sipuni');
    expect(isVisible.value).toBe(false);
    expect(settingsState.update).not.toHaveBeenCalled();
  });

  it('hides the phone for the current call and keeps that choice afterwards', () => {
    const callsStore = useCallsStore();
    const phoneWidgetStore = usePhoneWidgetStore();
    const { isVisible, hide } = usePhoneWidgetVisibility();
    callsStore.addCall(ringingCall());
    expect(isVisible.value).toBe(true);

    hide();

    expect(phoneWidgetStore.callDismissed).toBe(true);
    expect(settingsState.update).toHaveBeenCalledWith({
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 7: true },
    });
    expect(isVisible.value).toBe(false);
  });

  it('keeps a hidden phone hidden while a colleague handles a call', () => {
    settingsState.settings.value = {
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 7: true },
    };
    const callsStore = useCallsStore();
    const { isVisible, hasCallActivity, ownIncomingCalls } =
      usePhoneWidgetVisibility();

    // The inbox shows calls handled by other operators: the calls store keeps
    // an info card for the call operator 99 took.
    callsStore.handleCallStatusChanged({
      callSid: 'sipuni:other-1',
      provider: 'sipuni',
      status: 'in_progress',
      callDirection: 'inbound',
      inboxId: 43,
      accountId: 7,
      operatorClaim: { user_id: 99 },
      currentUserId: 1,
      showCallsHandledByOtherOperators: true,
    });

    expect(callsStore.incomingCalls).toHaveLength(1);
    expect(ownIncomingCalls.value).toEqual([]);
    expect(hasCallActivity.value).toBe(false);
    expect(isVisible.value).toBe(false);

    // The employee's own call still brings the phone back.
    callsStore.addCall(ringingCall('sipuni:own-1'));
    expect(ownIncomingCalls.value.map(call => call.callSid)).toEqual([
      'sipuni:own-1',
    ]);
    expect(isVisible.value).toBe(true);
  });

  it.each([
    ['another operator took it', { user_id: 99 }, 'CALL_ALREADY_CLAIMED', true],
    ['the claim has no operator', null, 'CALL_ALREADY_CLAIMED', true],
    [
      'the employee took it elsewhere',
      { userId: 1 },
      'CALL_ALREADY_CLAIMED',
      false,
    ],
    ['it is still ringing', { user_id: 99 }, undefined, false],
    ['it is in progress unclaimed', null, 'CALL_IN_PROGRESS', false],
  ])(
    'tells whether a call belongs to a colleague when %s',
    (_, operatorClaim, browserJoinUnsupportedReason, expected) => {
      expect(
        isCallHandledByAnotherOperator(
          { ...ringingCall(), operatorClaim, browserJoinUnsupportedReason },
          1
        )
      ).toBe(expected);
    }
  );

  it('shows the phone again from a dismissed call', () => {
    settingsState.settings.value = {
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: { 7: true },
    };
    const callsStore = useCallsStore();
    const phoneWidgetStore = usePhoneWidgetStore();
    const { isVisible, toggle } = usePhoneWidgetVisibility();
    callsStore.addCall(ringingCall());
    toggle();
    expect(phoneWidgetStore.callDismissed).toBe(true);
    expect(isVisible.value).toBe(false);

    toggle();

    expect(phoneWidgetStore.callDismissed).toBe(false);
    expect(settingsState.update).toHaveBeenLastCalledWith({
      [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: {},
    });
    expect(isVisible.value).toBe(true);
  });
});
