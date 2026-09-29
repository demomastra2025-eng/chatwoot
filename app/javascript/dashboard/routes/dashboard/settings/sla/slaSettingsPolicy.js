import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';

export const SLA_SETTINGS_POLICY = Object.freeze({
  permissions: ['administrator'],
  featureFlag: FEATURE_FLAGS.SLA,
  installationTypes: [INSTALLATION_TYPES.CLOUD, INSTALLATION_TYPES.ENTERPRISE],
});

// Keep the route reachable when `shouldShow` exposes the premium SLA paywall
// on Cloud before the account feature flag is enabled.
export const SLA_SETTINGS_ROUTE_META = Object.freeze({
  permissions: SLA_SETTINGS_POLICY.permissions,
});

export const canAccessSLASettings = shouldShow =>
  shouldShow(
    SLA_SETTINGS_POLICY.featureFlag,
    SLA_SETTINGS_POLICY.permissions,
    SLA_SETTINGS_POLICY.installationTypes
  );
