import { frontendURL } from '../../../../helper/URLHelper';
import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/security'),
      redirect: to => ({
        name: 'general_settings_index',
        params: { accountId: to.params.accountId },
      }),
      meta: {
        permissions: ['administrator'],
        installationTypes: [
          INSTALLATION_TYPES.CLOUD,
          INSTALLATION_TYPES.ENTERPRISE,
        ],
        featureFlag: FEATURE_FLAGS.SAML,
      },
    },
  ],
};
