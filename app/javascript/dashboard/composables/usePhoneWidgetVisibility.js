import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { isEmployeeOwnCall, useCallsStore } from 'dashboard/stores/calls';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';

// { [accountId]: true } for the accounts where the employee hid the phone.
export const PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY =
  'phone_widget_hidden_accounts';

const hiddenAccountsFrom = uiSettings => {
  const value = uiSettings?.[PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY];
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value
    : {};
};

/**
 * Whether the phone widget is on screen. The employee's choice is saved per
 * account in the UI settings; the employee's own call (incoming, active or an
 * outbound call being started) shows the phone anyway until the employee
 * hides it for that call, and afterwards the saved choice applies again.
 * Info-only call cards never bring a hidden phone back: calls a colleague took
 * (inboxes that show calls handled by other operators), calls the AI voice
 * agent handles and in-progress calls nobody here claimed (see
 * isEmployeeOwnCall).
 */
export function usePhoneWidgetVisibility() {
  const { uiSettings, updateUISettings } = useUISettings();
  const accountId = useMapGetter('getCurrentAccountId');
  const currentUser = useMapGetter('getCurrentUser');
  const callsStore = useCallsStore();
  const phoneWidgetStore = usePhoneWidgetStore();

  const accountKey = computed(() => String(accountId.value ?? ''));
  const isHiddenByUser = computed(
    () => hiddenAccountsFrom(uiSettings.value)[accountKey.value] === true
  );
  const ownIncomingCalls = computed(() =>
    (callsStore.incomingCalls || []).filter(call =>
      isEmployeeOwnCall(call, currentUser.value?.id)
    )
  );
  const hasCallActivity = computed(() =>
    Boolean(
      callsStore.hasActiveCall ||
        ownIncomingCalls.value.length > 0 ||
        phoneWidgetStore.preparingOutboundCalls > 0
    )
  );
  const isShownForCall = computed(
    () => hasCallActivity.value && !phoneWidgetStore.callDismissed
  );
  const isVisible = computed(
    () => isShownForCall.value || !isHiddenByUser.value
  );

  const saveHidden = hidden => {
    const hiddenAccounts = { ...hiddenAccountsFrom(uiSettings.value) };
    if (hidden) {
      hiddenAccounts[accountKey.value] = true;
    } else {
      delete hiddenAccounts[accountKey.value];
    }
    updateUISettings({ [PHONE_WIDGET_HIDDEN_UI_SETTINGS_KEY]: hiddenAccounts });
  };

  // Only the UI is hidden: SIP registration and calls keep running.
  const hide = () => {
    if (hasCallActivity.value) phoneWidgetStore.setCallDismissed(true);
    if (!isHiddenByUser.value) saveHidden(true);
  };

  const show = () => {
    phoneWidgetStore.setCallDismissed(false);
    if (isHiddenByUser.value) saveHidden(false);
  };

  const toggle = () => (isVisible.value ? hide() : show());

  return {
    hasCallActivity,
    isHiddenByUser,
    isVisible,
    ownIncomingCalls,
    hide,
    show,
    toggle,
  };
}
