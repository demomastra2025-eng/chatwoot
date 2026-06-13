import Cookies from 'js-cookie';
import { DEFAULT_REDIRECT_URL } from 'dashboard/constants/globals';
import { frontendURL } from 'dashboard/helper/URLHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

export const hasAuthCookie = () => {
  return !!Cookies.get('cw_d_session_info');
};

const getDefaultAccount = ({ ssoAccountId, user }) => {
  const { accounts = [], account_id: accountId = null } = user || {};
  const ssoAccount = accounts.find(
    account => String(account.id) === String(ssoAccountId)
  );

  if (ssoAccount) return ssoAccount;

  return (
    accounts.find(account => String(account.id) === String(accountId)) ||
    accounts[0]
  );
};

const getAccountPath = account => (account ? `accounts/${account.id}` : '');

const hasCommunicationThreads = account =>
  Boolean(account?.features?.[FEATURE_FLAGS.COMMUNICATION_THREADS]);

const getDefaultAccountPath = account => {
  const accountPath = getAccountPath(account);
  if (!accountPath) return '';

  return hasCommunicationThreads(account)
    ? `${accountPath}/communication_threads?status=open`
    : `${accountPath}/dashboard`;
};

const capitalize = str =>
  str
    .split(/[._-]+/)
    .map(word => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');

export const getCredentialsFromEmail = email => {
  const [localPart, domain] = email.split('@');
  const namePart = localPart.split('+')[0];
  return {
    fullName: capitalize(namePart),
    accountName: capitalize(domain.split('.')[0]),
  };
};

export const getLoginRedirectURL = ({
  ssoAccountId,
  ssoConversationId,
  user,
}) => {
  const account = getDefaultAccount({ ssoAccountId, user });
  const accountPath = getAccountPath(account);
  if (accountPath) {
    if (ssoConversationId) {
      return frontendURL(`${accountPath}/conversations/${ssoConversationId}`);
    }
    return frontendURL(getDefaultAccountPath(account));
  }
  return DEFAULT_REDIRECT_URL;
};
