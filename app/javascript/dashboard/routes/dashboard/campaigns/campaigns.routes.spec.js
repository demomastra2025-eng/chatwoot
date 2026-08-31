import campaignsRoutes from './campaigns.routes';

const outboundRoutes = campaignsRoutes.routes.find(route =>
  route.path.endsWith('/outbound')
).children;

describe('campaign routes', () => {
  it('exposes separate quick reply and WhatsApp template URLs', () => {
    const quickRepliesRoute = outboundRoutes.find(
      route => route.name === 'outbound_templates_index'
    );
    const whatsAppTemplatesRoute = outboundRoutes.find(
      route => route.name === 'outbound_whatsapp_templates_index'
    );

    expect(quickRepliesRoute.path).toBe('templates');
    expect(whatsAppTemplatesRoute.path).toBe('templates/whatsapp');
    expect(whatsAppTemplatesRoute.component).toBe(quickRepliesRoute.component);
    expect(whatsAppTemplatesRoute.meta).toBe(quickRepliesRoute.meta);
  });
});
