import advancedFilters from './advancedFilters.json';
import agentMgmt from './agentMgmt.json';
import attributesMgmt from './attributesMgmt.json';
import auditLogs from './auditLogs.json';
import automation from './automation.json';
import bulkActions from './bulkActions.json';
import campaign from './campaign.json';
import cannedMgmt from './cannedMgmt.json';
import chatlist from './chatlist.json';
import companies from './companies.json';
import components from './components.json';
import contact from './contact.json';
import contactFilters from './contactFilters.json';
import crm from './crm.json';
import conversation from './conversation.json';
import csatMgmt from './csatMgmt.json';
import customRole from './customRole.json';
import datePicker from './datePicker.json';
import emoji from './emoji.json';
import general from './general.json';
import generalSettings from './generalSettings.json';
import helpCenter from './helpCenter.json';
import inbox from './inbox.json';
import inboxMgmt from './inboxMgmt.json';
import integrationApps from './integrationApps.json';
import integrations from './integrations.json';
import labelsMgmt from './labelsMgmt.json';
import login from './login.json';
import macros from './macros.json';
import report from './report.json';
import resetPassword from './resetPassword.json';
import search from './search.json';
import russianScheduling from '../ru/scheduling.json';
import kazakhScheduling from './scheduling.json';
import setNewPassword from './setNewPassword.json';
import settings from './settings.json';
import signup from './signup.json';
import sla from './sla.json';
import teamsSettings from './teamsSettings.json';
import whatsappTemplates from './whatsappTemplates.json';
import contentTemplates from './contentTemplates.json';
import mfa from './mfa.json';
import yearInReview from './yearInReview.json';

const mergeCatalog = (base, overrides) =>
  Object.entries(overrides).reduce(
    (catalog, [key, value]) => {
      const baseValue = catalog[key];
      const mergeNested =
        value &&
        baseValue &&
        typeof value === 'object' &&
        typeof baseValue === 'object' &&
        !Array.isArray(value) &&
        !Array.isArray(baseValue);

      return {
        ...catalog,
        [key]: mergeNested ? mergeCatalog(baseValue, value) : value,
      };
    },
    { ...base }
  );

const scheduling = mergeCatalog(russianScheduling, kazakhScheduling);

export default {
  ...advancedFilters,
  ...agentMgmt,
  ...attributesMgmt,
  ...auditLogs,
  ...automation,
  ...bulkActions,
  ...campaign,
  ...cannedMgmt,
  ...chatlist,
  ...companies,
  ...components,
  ...contact,
  ...contactFilters,
  ...crm,
  ...conversation,
  ...csatMgmt,
  ...customRole,
  ...datePicker,
  ...emoji,
  ...general,
  ...generalSettings,
  ...helpCenter,
  ...inbox,
  ...inboxMgmt,
  ...integrationApps,
  ...integrations,
  ...labelsMgmt,
  ...login,
  ...macros,
  ...report,
  ...resetPassword,
  ...search,
  ...scheduling,
  ...setNewPassword,
  ...settings,
  ...signup,
  ...sla,
  ...teamsSettings,
  ...whatsappTemplates,
  ...contentTemplates,
  ...mfa,
  ...yearInReview,
};
