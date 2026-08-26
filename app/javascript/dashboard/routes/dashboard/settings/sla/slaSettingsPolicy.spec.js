import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import {
  canAccessSLASettings,
  SLA_SETTINGS_POLICY,
  SLA_SETTINGS_ROUTE_META,
} from './slaSettingsPolicy';

describe('SLA settings policy', () => {
  it('uses the same feature, permission, and installation gates for navigation', () => {
    const shouldShow = vi.fn().mockReturnValue(false);

    expect(canAccessSLASettings(shouldShow)).toBe(false);
    expect(shouldShow).toHaveBeenCalledWith(
      'sla',
      ['administrator'],
      [INSTALLATION_TYPES.CLOUD, INSTALLATION_TYPES.ENTERPRISE]
    );
    expect(SLA_SETTINGS_POLICY).toEqual({
      permissions: ['administrator'],
      featureFlag: 'sla',
      installationTypes: [
        INSTALLATION_TYPES.CLOUD,
        INSTALLATION_TYPES.ENTERPRISE,
      ],
    });
    expect(SLA_SETTINGS_ROUTE_META).toEqual({
      permissions: ['administrator'],
    });
  });
});
