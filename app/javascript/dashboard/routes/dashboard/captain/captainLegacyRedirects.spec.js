import { describe, expect, it } from 'vitest';
import {
  AGENT_PAGE_TABS,
  AI_SETTINGS_SECTION_HASHES,
  navigationPathRouteName,
  redirectNavigationPath,
  redirectToAgentPage,
  redirectToAgents,
  redirectToAiSettings,
  redirectToChannels,
} from './captainLegacyRedirects';

const legacyRoute = (params = {}, query = { source: 'legacy' }) => ({
  params: { accountId: '1', ...params },
  query,
});

describe('captainLegacyRedirects', () => {
  describe('navigationPathRouteName', () => {
    it.each([
      ['knowledge_base', 'captain_assistants_responses_index'],
      ['documents', 'captain_assistants_documents_index'],
      ['tools', 'captain_tools_index'],
      ['channels', 'captain_channels_index'],
    ])('maps the short name %s to %s', (navigationPath, routeName) => {
      expect(navigationPathRouteName(navigationPath)).toBe(routeName);
    });

    it.each([
      [
        'captain_assistants_responses_index',
        'captain_assistants_responses_index',
      ],
      [
        'captain_assistants_documents_index',
        'captain_assistants_documents_index',
      ],
      ['captain_tools_index', 'captain_tools_index'],
      ['captain_assistants_channels_index', 'captain_channels_index'],
      ['captain_assistants_inboxes_index', 'captain_channels_index'],
    ])('maps the former sidebar target %s to %s', (navigationPath, name) => {
      expect(navigationPathRouteName(navigationPath)).toBe(name);
    });

    it.each([
      'captain_assistants_settings_index',
      'captain_assistants_prompts_index',
      'captain_assistants_playground_index',
      'captain_assistants_follow_ups_index',
      'unknown',
      '',
      undefined,
      'constructor',
      '__proto__',
    ])('sends %s to the agents gallery', navigationPath => {
      expect(navigationPathRouteName(navigationPath)).toBe(
        'captain_agents_index'
      );
    });
  });

  it('redirects the former navigation page and keeps the query', () => {
    expect(
      redirectNavigationPath(legacyRoute({ navigationPath: 'documents' }))
    ).toEqual({
      name: 'captain_assistants_documents_index',
      params: { accountId: '1' },
      query: { source: 'legacy' },
    });
  });

  it('redirects to the gallery with the account only', () => {
    expect(redirectToAgents(legacyRoute({ assistantId: '2' }))).toEqual({
      name: 'captain_agents_index',
      params: { accountId: '1' },
      query: { source: 'legacy' },
    });
  });

  describe('redirectToAgentPage', () => {
    it('opens the default tab of the agent page', () => {
      expect(redirectToAgentPage()(legacyRoute({ assistantId: '2' }))).toEqual({
        name: 'captain_agent_show',
        params: { accountId: '1', assistantId: '2' },
        query: { source: 'legacy' },
      });
    });

    it('opens the requested tab and keeps the rest of the query', () => {
      expect(
        redirectToAgentPage(AGENT_PAGE_TABS.CHECK)(
          legacyRoute({ assistantId: '2' })
        )
      ).toEqual({
        name: 'captain_agent_show',
        params: { accountId: '1', assistantId: '2' },
        query: { source: 'legacy', tab: 'check' },
      });
    });

    it('opens the follow-ups tab without an old query', () => {
      expect(
        redirectToAgentPage(AGENT_PAGE_TABS.FOLLOW_UPS)({
          params: { accountId: '1', assistantId: 5 },
        })
      ).toEqual({
        name: 'captain_agent_show',
        params: { accountId: '1', assistantId: '5' },
        query: { tab: 'follow-ups' },
      });
    });

    it('opens the gallery when the old link has no numeric agent id', () => {
      expect(
        redirectToAgentPage(AGENT_PAGE_TABS.CHECK)(
          legacyRoute({ assistantId: 'agents' })
        )
      ).toEqual({
        name: 'captain_agents_index',
        params: { accountId: '1' },
        query: { source: 'legacy' },
      });
    });
  });

  it('redirects to the channels page', () => {
    expect(redirectToChannels(legacyRoute({ assistantId: '2' }))).toEqual({
      name: 'captain_channels_index',
      params: { accountId: '1' },
      query: { source: 'legacy' },
    });
  });

  it.each([
    [AI_SETTINGS_SECTION_HASHES.SAFETY, '#safety'],
    [AI_SETTINGS_SECTION_HASHES.HANDOFF, '#handoff'],
  ])('redirects to the AI settings section %s', (hash, expectedHash) => {
    expect(
      redirectToAiSettings(hash)(legacyRoute({ assistantId: '2' }))
    ).toEqual({
      name: 'captain_ai_settings_index',
      params: { accountId: '1' },
      query: { source: 'legacy' },
      hash: expectedHash,
    });
  });

  it('redirects to the AI settings page without a section', () => {
    expect(redirectToAiSettings()(legacyRoute())).toEqual({
      name: 'captain_ai_settings_index',
      params: { accountId: '1' },
      query: { source: 'legacy' },
    });
  });
});
