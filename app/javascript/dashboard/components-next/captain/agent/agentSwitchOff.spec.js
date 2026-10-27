import { describe, expect, it } from 'vitest';
import {
  enabledAgentsCount,
  isAgentActive,
  switchOffWarnings,
} from './agentSwitchOff';
import { VOICE_CHANNEL_TYPE } from './agentVoice';

const agent = (id, active = true, voiceInboxIds = []) => ({
  id,
  active,
  voice_inbox_ids: voiceInboxIds,
});

const voiceInbox = (id, phone = '+77010000000') => ({
  id,
  name: `Voice ${id}`,
  phone_number: phone,
  channel_type: VOICE_CHANNEL_TYPE,
});

describe('agentSwitchOff', () => {
  it('counts the agents that are on, an agent with no flag being on', () => {
    expect(isAgentActive({ id: 1 })).toBe(true);
    expect(isAgentActive(agent(1, false))).toBe(false);
    expect(enabledAgentsCount([agent(1), agent(2, false), { id: 3 }])).toBe(2);
    expect(enabledAgentsCount(undefined)).toBe(0);
  });

  it('has nothing to warn about when another agent stays on', () => {
    const agents = [agent(1), agent(2)];
    expect(
      switchOffWarnings({ agent: agents[0], agents, inboxes: [] })
    ).toEqual([]);
  });

  it('warns that the AI stops when the last agent that is on is switched off', () => {
    const agents = [agent(1), agent(2, false)];
    expect(
      switchOffWarnings({ agent: agents[0], agents, inboxes: [] })
    ).toEqual([{ key: 'CAPTAIN.GALLERY.CONFIRM_DISABLE_LAST', params: {} }]);
  });

  it('does not warn about the last agent when the agent is already off', () => {
    const agents = [agent(1, false)];
    expect(
      switchOffWarnings({ agent: agents[0], agents, inboxes: [] })
    ).toEqual([]);
  });

  it('warns about the phone numbers the agent answers, first', () => {
    const agents = [agent(1, true, [5, 6])];
    const inboxes = [
      voiceInbox(5, '+7701'),
      voiceInbox(6, '+7702'),
      voiceInbox(7),
    ];

    expect(switchOffWarnings({ agent: agents[0], agents, inboxes })).toEqual([
      {
        key: 'CAPTAIN.GALLERY.CONFIRM_DISABLE_VOICE',
        params: { numbers: '+7701, +7702' },
      },
      { key: 'CAPTAIN.GALLERY.CONFIRM_DISABLE_LAST', params: {} },
    ]);
  });

  it('names a number by its channel name when it has no phone number', () => {
    const agents = [agent(1, true, [5]), agent(2)];
    const inboxes = [{ ...voiceInbox(5), phone_number: '' }];

    expect(switchOffWarnings({ agent: agents[0], agents, inboxes })).toEqual([
      {
        key: 'CAPTAIN.GALLERY.CONFIRM_DISABLE_VOICE',
        params: { numbers: 'Voice 5' },
      },
    ]);
  });
});
