export const INBOX_FLOW_ROUTE_NAMES = {
  settings: {
    list: 'settings_inbox_list',
    new: 'settings_inbox_new',
    page: 'settings_inboxes_page_channel',
    agents: 'settings_inboxes_add_agents',
    finish: 'settings_inbox_finish',
    show: 'settings_inbox_show',
  },
  dialog: {
    list: 'dialog_inbox_new',
    new: 'dialog_inbox_new',
    page: 'dialog_inboxes_page_channel',
    agents: 'dialog_inboxes_add_agents',
    finish: 'dialog_inbox_finish',
    show: 'dialog_inbox_show',
  },
};

const DIALOG_INBOX_ROUTE_PREFIX = 'dialog_inbox';
const INBOX_FLOW_QUERY_KEY = 'inboxFlow';
const DIALOG_INBOX_FLOW_QUERY_VALUE = 'dialogs';

export const isDialogInboxRoute = route => {
  if (!route?.name) {
    return false;
  }

  if (route.meta?.inboxFlow === 'dialogs') {
    return true;
  }

  return route.name.startsWith(DIALOG_INBOX_ROUTE_PREFIX);
};

export const getInboxFlowRouteNames = route =>
  route?.query?.[INBOX_FLOW_QUERY_KEY] === DIALOG_INBOX_FLOW_QUERY_VALUE ||
  isDialogInboxRoute(route)
    ? INBOX_FLOW_ROUTE_NAMES.dialog
    : INBOX_FLOW_ROUTE_NAMES.settings;

export const getInboxFlowRouteName = (route, key) => {
  const flowRoutes = getInboxFlowRouteNames(route);
  return flowRoutes?.[key];
};
