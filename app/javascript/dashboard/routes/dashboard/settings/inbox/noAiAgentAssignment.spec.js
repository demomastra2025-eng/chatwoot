import { describe, expect, it } from 'vitest';
import Settings from './Settings.vue';

// AI agents are created and configured in «ИИ-агенты» and switched on for a
// channel only in «ИИ-агенты → Каналы». The channel settings and the channel
// creation flow do not offer them. The voice agent editor is hidden for now.

const BOT_TAB = 'bot-configuration';
const AI_AGENT_REFERENCE =
  /captain|assistant|bot-configuration|botconfiguration|ai-agent|ai_agent/i;

const wizardSources = import.meta.glob(
  [
    './ChannelList.vue',
    './ChannelFactory.vue',
    './InboxChannels.vue',
    './AddAgents.vue',
    './FinishSetup.vue',
    './channels/**/*.vue',
    './inbox.routes.js',
    './inboxDialog.routes.js',
    './helpers/inboxFlowRoutes.js',
  ],
  { query: '?raw', import: 'default', eager: true }
);

const settingsTabKeys = (overrides = {}) =>
  Settings.computed.tabs
    .call({
      $t: key => key,
      accountId: 1,
      inbox: {},
      isFeatureEnabledonAccount: () => true,
      isAVoiceChannel: false,
      isAWebWidgetInbox: false,
      isATwilioChannel: false,
      isALineChannel: false,
      isAPIInbox: false,
      isAWhatsAppWebInbox: false,
      isAnEmailChannel: false,
      shouldShowWhatsAppConfiguration: false,
      ...overrides,
    })
    .map(tab => tab.key);

describe('channel settings: no AI agent assignment', () => {
  it.each([
    ['a plain text channel', {}],
    ['a website widget', { isAWebWidgetInbox: true }],
    ['a Twilio channel', { isATwilioChannel: true }],
    ['a Line channel', { isALineChannel: true }],
    ['an API channel', { isAPIInbox: true }],
    ['an email channel', { isAnEmailChannel: true }],
    ['a WhatsApp Cloud channel', { shouldShowWhatsAppConfiguration: true }],
  ])(
    'has no AI agent tab for %s even with the AI section enabled',
    (_, ctx) => {
      const keys = settingsTabKeys(ctx);

      expect(keys).toContain('inbox-settings');
      expect(keys).not.toContain(BOT_TAB);
      keys.forEach(key => expect(key).not.toMatch(AI_AGENT_REFERENCE));
    }
  );

  it('hides the voice agent editor on voice channels too', () => {
    expect(settingsTabKeys({ isAVoiceChannel: true })).not.toContain(BOT_TAB);
  });
});

describe('channel creation flow: no AI agent assignment', () => {
  it('scans the wizard pages, channel forms and routes', () => {
    const paths = Object.keys(wizardSources);

    expect(paths).toEqual(
      expect.arrayContaining([
        './ChannelList.vue',
        './ChannelFactory.vue',
        './AddAgents.vue',
        './FinishSetup.vue',
        './inbox.routes.js',
        './inboxDialog.routes.js',
      ])
    );
    expect(paths.some(path => path.startsWith('./channels/'))).toBe(true);
  });

  it.each(Object.keys(wizardSources))('%s does not mention AI agents', path => {
    expect(wizardSources[path]).not.toMatch(AI_AGENT_REFERENCE);
  });
});
