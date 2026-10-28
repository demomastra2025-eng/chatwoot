import { getLoginRedirectURL, getCredentialsFromEmail } from '../AuthHelper';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

describe('#URL Helpers', () => {
  describe('getLoginRedirectURL', () => {
    it('should return correct Account URL if account id is present', () => {
      expect(
        getLoginRedirectURL({
          ssoAccountId: '7500',
          user: {
            accounts: [{ id: 7500, name: 'Test Account 7500' }],
          },
        })
      ).toBe('/app/accounts/7500/dashboard');
    });

    it('should return communication threads URL when account id has communication threads enabled', () => {
      expect(
        getLoginRedirectURL({
          ssoAccountId: '7500',
          user: {
            accounts: [
              {
                id: 7500,
                name: 'Test Account 7500',
                features: { [FEATURE_FLAGS.COMMUNICATION_THREADS]: true },
              },
            ],
          },
        })
      ).toBe('/app/accounts/7500/communication_threads?status=open');
    });

    it('should return correct conversation URL if account id and conversationId is present', () => {
      expect(
        getLoginRedirectURL({
          ssoAccountId: '7500',
          ssoConversationId: '752',
          user: {
            accounts: [{ id: 7500, name: 'Test Account 7500' }],
          },
        })
      ).toBe('/app/accounts/7500/conversations/752');
    });

    it('should return default URL if account id is not present', () => {
      expect(getLoginRedirectURL({ ssoAccountId: '7500', user: {} })).toBe(
        '/app/'
      );
      expect(
        getLoginRedirectURL({
          ssoAccountId: '7500',
          user: {
            accounts: [{ id: '7501', name: 'Test Account 7501' }],
          },
        })
      ).toBe('/app/accounts/7501/dashboard');
      expect(getLoginRedirectURL('7500', null)).toBe('/app/');
    });
  });

  describe('getCredentialsFromEmail', () => {
    it('derives only the display name from a standard email', () => {
      expect(getCredentialsFromEmail('john@company.com')).toEqual({
        fullName: 'John',
      });
    });

    it('never derives a company name from a public email domain', () => {
      expect(getCredentialsFromEmail('jane@mail.example.org')).toEqual({
        fullName: 'Jane',
      });
    });

    it('should split by dots and capitalize each word', () => {
      expect(getCredentialsFromEmail('john.doe@acme.co')).toEqual({
        fullName: 'John Doe',
      });
    });

    it('should omit everything after + in the local part', () => {
      expect(getCredentialsFromEmail('user+tag@startup.io')).toEqual({
        fullName: 'User',
      });
    });

    it('should split by underscores and hyphens', () => {
      expect(getCredentialsFromEmail('first_last@my-company.com')).toEqual({
        fullName: 'First Last',
      });
    });
  });
});
