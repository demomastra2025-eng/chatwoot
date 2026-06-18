import Settings from './Settings.vue';

describe('Inbox Settings WhatsApp tabs', () => {
  it('shows WhatsApp Flows between templates and account health for WhatsApp Cloud inboxes', () => {
    const tabs = Settings.computed.tabs.call({
      accountId: 8,
      inbox: { provider: 'whatsapp_cloud' },
      isFeatureEnabledonAccount: () => false,
      isAVoiceChannel: false,
      isAWebWidgetInbox: false,
      isATwilioChannel: false,
      isALineChannel: false,
      isAPIInbox: false,
      isAWhatsAppWebInbox: false,
      isAnEmailChannel: false,
      shouldShowWhatsAppConfiguration: true,
      $t: key => key,
    });

    expect(tabs.map(tab => tab.key)).toEqual(
      expect.arrayContaining([
        'whatsapp-templates',
        'whatsapp-flows',
        'whatsapp-health',
      ])
    );
    expect(tabs.findIndex(tab => tab.key === 'whatsapp-flows')).toBe(
      tabs.findIndex(tab => tab.key === 'whatsapp-templates') + 1
    );
  });
});
