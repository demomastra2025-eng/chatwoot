import campaignsRoutes from './campaigns.routes';

const findChild = name =>
  campaignsRoutes.routes
    .flatMap(route => route.children || [])
    .find(route => route.name === name);

describe('outbound routes', () => {
  it('opens WhatsApp templates and WhatsApp Flows as their own settings entries on the templates page', () => {
    const quickReplies = findChild('outbound_templates_index');
    const whatsAppTemplates = findChild('outbound_whatsapp_templates_index');
    const whatsAppFlows = findChild('outbound_whatsapp_flows_index');

    expect(whatsAppTemplates.path).toBe('templates/whatsapp');
    expect(whatsAppTemplates.component).toBe(quickReplies.component);
    expect(whatsAppTemplates.meta).toBe(quickReplies.meta);

    expect(whatsAppFlows.path).toBe('templates/whatsapp-flows');
    expect(whatsAppFlows.component).toBe(quickReplies.component);
    expect(whatsAppFlows.meta).toBe(quickReplies.meta);
  });

  it('keeps touches as a page', () => {
    expect(findChild('outbound_touches_index').component).toBeDefined();
  });
});
