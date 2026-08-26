import { frontendURL } from '../../../../helper/URLHelper';

const redirectToWorkspaceSLA = to => ({
  name: 'workspace_sla_settings_index',
  params: to.params,
  query: to.query,
});

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/sla'),
      name: 'sla_wrapper',
      redirect: redirectToWorkspaceSLA,
    },
    {
      path: frontendURL('accounts/:accountId/settings/sla/list'),
      name: 'sla_list',
      redirect: redirectToWorkspaceSLA,
    },
  ],
};
