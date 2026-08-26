import { frontendURL } from '../../../../helper/URLHelper';

const redirectToAdditionalFields = (to, tab) => ({
  name: 'workspace_additional_fields_settings_index',
  params: to.params,
  query: {
    ...to.query,
    tab,
  },
});

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/custom-attributes'),
      redirect: to => redirectToAdditionalFields(to, 'conversation_attribute'),
    },
    {
      path: frontendURL('accounts/:accountId/settings/custom-attributes/list'),
      name: 'attributes_list',
      redirect: to => redirectToAdditionalFields(to, 'conversation_attribute'),
    },
    {
      path: frontendURL('accounts/:accountId/settings/contacts'),
      redirect: to => redirectToAdditionalFields(to, 'contact_attribute'),
    },
    {
      path: frontendURL('accounts/:accountId/settings/contacts/fields'),
      name: 'contact_fields_settings_index',
      redirect: to => redirectToAdditionalFields(to, 'contact_attribute'),
    },
    {
      path: frontendURL('accounts/:accountId/settings/contacts/tags'),
      name: 'contact_tags_settings_index',
      redirect: to => ({ name: 'labels_list', params: to.params }),
    },
    {
      path: frontendURL('accounts/:accountId/settings/companies'),
      redirect: to => redirectToAdditionalFields(to, 'company_attribute'),
    },
    {
      path: frontendURL('accounts/:accountId/settings/companies/fields'),
      name: 'company_fields_settings_index',
      redirect: to => redirectToAdditionalFields(to, 'company_attribute'),
    },
  ],
};
