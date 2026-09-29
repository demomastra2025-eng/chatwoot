import campaignsRoutes from './campaigns.routes';

const findChild = name =>
  campaignsRoutes.routes
    .flatMap(route => route.children || [])
    .find(route => route.name === name);

describe('outbound routes', () => {
  it('opens WhatsApp templates as its own settings entry on the templates page', () => {
    const quickReplies = findChild('outbound_templates_index');
    const whatsAppTemplates = findChild('outbound_whatsapp_templates_index');

    expect(whatsAppTemplates.path).toBe('templates/whatsapp');
    expect(whatsAppTemplates.component).toBe(quickReplies.component);
    expect(whatsAppTemplates.meta).toBe(quickReplies.meta);
  });

  it('keeps touches as a page', () => {
    expect(findChild('outbound_touches_index').component).toBeDefined();
  });
});
