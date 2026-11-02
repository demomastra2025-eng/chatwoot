import { mergeLocaleParts } from '../mergeLocaleParts';
import en from '../en';
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
import designSystem from './designSystem.json';
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
import ruScheduling from '../ru/scheduling.json';
import kkScheduling from './scheduling.json';
import setNewPassword from './setNewPassword.json';

const scheduling = {
  SCHEDULING: {
    ...ruScheduling.SCHEDULING,
    VIEWS: {
      ...ruScheduling.SCHEDULING.VIEWS,
      ...kkScheduling.SCHEDULING.VIEWS,
    },
    TOOLBAR: {
      ...ruScheduling.SCHEDULING.TOOLBAR,
      ...kkScheduling.SCHEDULING.TOOLBAR,
    },
    CALENDAR: {
      ...ruScheduling.SCHEDULING.CALENDAR,
      ...kkScheduling.SCHEDULING.CALENDAR,
    },
    PATIENT_SEARCH: kkScheduling.SCHEDULING.PATIENT_SEARCH,
    CONTACT: {
      ...ruScheduling.SCHEDULING.CONTACT,
      ...kkScheduling.SCHEDULING.CONTACT,
    },
    ERRORS: {
      ...ruScheduling.SCHEDULING.ERRORS,
      ...kkScheduling.SCHEDULING.ERRORS,
    },
    APPOINTMENT_FORM: {
      ...ruScheduling.SCHEDULING.APPOINTMENT_FORM,
      ERRORS: {
        ...ruScheduling.SCHEDULING.APPOINTMENT_FORM.ERRORS,
        ...kkScheduling.SCHEDULING.APPOINTMENT_FORM.ERRORS,
      },
    },
  },
};
import settings from './settings.json';
import whatsappUsage from './whatsappUsage.json';
import signup from './signup.json';
import sla from './sla.json';
import teamsSettings from './teamsSettings.json';
import whatsappCall from './whatsappCall.json';
import whatsappTemplates from './whatsappTemplates.json';
import contentTemplates from './contentTemplates.json';
import mfa from './mfa.json';
import yearInReview from './yearInReview.json';

export default mergeLocaleParts(
  en,
  advancedFilters,
  agentMgmt,
  attributesMgmt,
  auditLogs,
  automation,
  bulkActions,
  campaign,
  cannedMgmt,
  chatlist,
  companies,
  components,
  contact,
  contactFilters,
  crm,
  conversation,
  csatMgmt,
  customRole,
  datePicker,
  designSystem,
  emoji,
  general,
  generalSettings,
  helpCenter,
  inbox,
  inboxMgmt,
  integrationApps,
  integrations,
  labelsMgmt,
  login,
  macros,
  report,
  resetPassword,
  search,
  scheduling,
  setNewPassword,
  settings,
  whatsappUsage,
  signup,
  sla,
  teamsSettings,
  whatsappCall,
  whatsappTemplates,
  contentTemplates,
  mfa,
  yearInReview
);
