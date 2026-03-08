import { buildPortalArticleURL, buildPortalURL } from '../portalHelper';

describe('PortalHelper', () => {
  describe('buildPortalURL', () => {
    it('returns the correct url', () => {
      window.chatwootConfig = {
        hostURL: 'https://one-link.kz',
        helpCenterURL: 'https://one-link.kz',
      };
      expect(buildPortalURL('handbook')).toEqual(
        'https://one-link.kz/hc/handbook'
      );
      window.chatwootConfig = {};
    });
  });

  describe('buildPortalArticleURL', () => {
    it('returns the correct url', () => {
      window.chatwootConfig = {
        hostURL: 'https://one-link.kz',
        helpCenterURL: 'https://one-link.kz',
      };
      expect(
        buildPortalArticleURL('handbook', 'culture', 'fr', 'article-slug')
      ).toEqual('https://one-link.kz/hc/handbook/articles/article-slug');
      window.chatwootConfig = {};
    });

    it('returns the correct url with custom domain', () => {
      window.chatwootConfig = {
        hostURL: 'https://one-link.kz',
        helpCenterURL: 'https://one-link.kz',
      };
      expect(
        buildPortalArticleURL(
          'handbook',
          'culture',
          'fr',
          'article-slug',
          'custom-domain.dev'
        )
      ).toEqual('https://custom-domain.dev/hc/handbook/articles/article-slug');
    });

    it('handles https in custom domain correctly', () => {
      window.chatwootConfig = {
        hostURL: 'https://one-link.kz',
        helpCenterURL: 'https://one-link.kz',
      };
      expect(
        buildPortalArticleURL(
          'handbook',
          'culture',
          'fr',
          'article-slug',
          'https://custom-domain.dev'
        )
      ).toEqual('https://custom-domain.dev/hc/handbook/articles/article-slug');
    });

    it('uses hostURL when helpCenterURL is not available', () => {
      window.chatwootConfig = {
        hostURL: 'https://one-link.kz',
        helpCenterURL: '',
      };
      expect(
        buildPortalArticleURL('handbook', 'culture', 'fr', 'article-slug')
      ).toEqual('https://one-link.kz/hc/handbook/articles/article-slug');
    });
  });
});
