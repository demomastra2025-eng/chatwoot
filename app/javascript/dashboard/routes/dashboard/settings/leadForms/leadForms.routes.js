import { frontendURL } from '../../../../helper/URLHelper';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/lead-forms'),
      redirect: to => ({ name: 'lead_forms_index', params: to.params }),
    },
  ],
};
