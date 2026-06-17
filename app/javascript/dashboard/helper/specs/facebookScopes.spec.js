import { buildFacebookLoginScopes } from 'dashboard/helper/facebookScopes';

describe('buildFacebookLoginScopes', () => {
  it('builds Messenger-only Facebook Page scopes by default', () => {
    expect(buildFacebookLoginScopes()).toBe(
      'pages_manage_metadata,business_management,pages_messaging,pages_show_list,pages_read_engagement'
    );
    expect(buildFacebookLoginScopes()).not.toContain('instagram_basic');
    expect(buildFacebookLoginScopes()).not.toContain(
      'instagram_manage_messages'
    );
  });

  it('includes Instagram scopes only when requested', () => {
    expect(buildFacebookLoginScopes({ includeInstagramScopes: true })).toBe(
      'pages_manage_metadata,business_management,pages_messaging,pages_show_list,pages_read_engagement,instagram_basic,instagram_manage_messages'
    );
  });
});
