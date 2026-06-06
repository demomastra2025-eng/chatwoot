import {
  hasPermissions,
  getUserPermissions,
  getCurrentAccount,
} from './permissionsHelper';

import {
  CONVERSATION_ACCESS_PERMISSIONS,
  CONTACT_ACCESS_PERMISSIONS,
  CRM_DEAL_VIEW_PERMISSIONS,
  CRM_SETTINGS_MANAGE_PERMISSION,
  CRM_SETTINGS_VIEW_PERMISSION,
  CRM_TASK_VIEW_PERMISSIONS,
  REPORTS_PERMISSIONS,
  PORTAL_PERMISSIONS,
} from 'dashboard/constants/permissions.js';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

const withRouteAccountFeatures = (userAccount, accountFeatureSource = null) => {
  if (!userAccount || !accountFeatureSource?.features) {
    return userAccount;
  }

  return {
    ...userAccount,
    features: {
      ...(userAccount.features || {}),
      ...accountFeatureSource.features,
    },
  };
};

const isFeatureEnabled = (account, featureFlag) => {
  return Boolean(account?.features?.[featureFlag]);
};

export const routeIsAccessibleFor = (
  route,
  userPermissions = [],
  currentAccount = null
) => {
  const {
    meta: { permissions: routePermissions = [], featureFlag = null } = {},
  } = route;
  return (
    hasPermissions(routePermissions, userPermissions) &&
    (!featureFlag || isFeatureEnabled(currentAccount, featureFlag))
  );
};

export const defaultRedirectPage = (
  to,
  permissions,
  user = null,
  accountFeatureSource = null
) => {
  const { accountId } = to.params;
  const currentAccount = withRouteAccountFeatures(
    (user && getCurrentAccount(user, Number(accountId))) || null,
    accountFeatureSource
  );

  const permissionRoutes = [
    {
      permissions: CONVERSATION_ACCESS_PERMISSIONS,
      path: 'dashboard',
    },
    { permissions: CONTACT_ACCESS_PERMISSIONS, path: 'contacts' },
    { permissions: [REPORTS_PERMISSIONS], path: 'reports/overview' },
    { permissions: [PORTAL_PERMISSIONS], path: 'portals' },
    {
      permissions: CRM_DEAL_VIEW_PERMISSIONS,
      path: 'crm/deals',
      enabled: isFeatureEnabled(currentAccount, FEATURE_FLAGS.CRM_DEALS),
    },
    {
      permissions: CRM_TASK_VIEW_PERMISSIONS,
      path: 'crm/tasks',
      enabled: isFeatureEnabled(currentAccount, FEATURE_FLAGS.CRM_TASKS),
    },
    {
      permissions: [
        CRM_SETTINGS_VIEW_PERMISSION,
        CRM_SETTINGS_MANAGE_PERMISSION,
      ],
      path: 'settings/crm',
      enabled:
        isFeatureEnabled(currentAccount, FEATURE_FLAGS.CRM_DEALS) ||
        isFeatureEnabled(currentAccount, FEATURE_FLAGS.CRM_TASKS),
    },
  ];

  const route = permissionRoutes.find(
    ({ permissions: routePermissions, enabled = true }) =>
      enabled && hasPermissions(routePermissions, permissions)
  );

  return `accounts/${accountId}/${route ? route.path : 'dashboard'}`;
};

const validateActiveAccountRoutes = (to, user, accountFeatureSource = null) => {
  // If the current account is active, then check for the route permissions
  const accountDashboardURL = `accounts/${to.params.accountId}/dashboard`;

  // If the user is trying to access suspended route, redirect them to dashboard
  if (to.name === 'account_suspended') {
    return accountDashboardURL;
  }

  const currentAccount = withRouteAccountFeatures(
    getCurrentAccount(user, Number(to.params.accountId)),
    accountFeatureSource
  );
  const userPermissions = getUserPermissions(user, to.params.accountId);

  const isAccessible = routeIsAccessibleFor(
    to,
    userPermissions,
    currentAccount
  );
  // If the route is not accessible for the user, return to dashboard screen
  return isAccessible
    ? null
    : defaultRedirectPage(to, userPermissions, user, accountFeatureSource);
};

export const validateLoggedInRoutes = (
  to,
  user,
  accountFeatureSource = null
) => {
  const currentAccount = withRouteAccountFeatures(
    getCurrentAccount(user, Number(to.params.accountId)),
    accountFeatureSource
  );
  // If current account is missing, either user does not have
  // access to the account or the account is deleted, return to login screen
  if (!currentAccount) {
    return `app/login`;
  }

  const isCurrentAccountActive = currentAccount.status === 'active';

  if (isCurrentAccountActive) {
    return validateActiveAccountRoutes(to, user, accountFeatureSource);
  }

  // If the current account is not active, then redirect the user to the suspended screen
  if (to.name !== 'account_suspended') {
    return `accounts/${to.params.accountId}/suspended`;
  }

  // Proceed to the route if none of the above conditions are met
  return null;
};

export const isAConversationRoute = (
  routeName,
  includeBase = false,
  includeExtended = true
) => {
  const baseRoutes = [
    'home',
    'conversation_mentions',
    'conversation_unattended',
    'inbox_dashboard',
    'label_conversations',
    'team_conversations',
    'folder_conversations',
    'conversation_participating',
    'communication_threads_dashboard',
  ];
  const extendedRoutes = [
    'inbox_conversation',
    'conversation_through_mentions',
    'conversation_through_unattended',
    'conversation_through_inbox',
    'conversations_through_label',
    'conversations_through_team',
    'conversations_through_folders',
    'conversation_through_participating',
    'communication_thread_conversation',
  ];

  const routes = [
    ...(includeBase ? baseRoutes : []),
    ...(includeExtended ? extendedRoutes : []),
  ];

  return routes.includes(routeName);
};

export const getConversationDashboardRoute = routeName => {
  switch (routeName) {
    case 'inbox_conversation':
      return 'home';
    case 'conversation_through_mentions':
      return 'conversation_mentions';
    case 'conversation_through_unattended':
      return 'conversation_unattended';
    case 'conversations_through_label':
      return 'label_conversations';
    case 'conversations_through_team':
      return 'team_conversations';
    case 'conversations_through_folders':
      return 'folder_conversations';
    case 'conversation_through_participating':
      return 'conversation_participating';
    case 'conversation_through_inbox':
      return 'inbox_dashboard';
    case 'communication_thread_conversation':
      return 'communication_threads_dashboard';
    default:
      return null;
  }
};

export const isAInboxViewRoute = (routeName, includeBase = false) => {
  const baseRoutes = ['inbox_view'];
  const extendedRoutes = ['inbox_view_conversation'];
  const routeNames = includeBase
    ? [...baseRoutes, ...extendedRoutes]
    : extendedRoutes;
  return routeNames.includes(routeName);
};

export const isNotificationRoute = routeName =>
  routeName === 'notifications_index';
