import { describe, expect, it } from 'vitest';
import {
  VOICE_CHANNEL_TYPE,
  isVoiceAgent,
  voiceInboxesForAgent,
} from './agentVoice';

const voiceInbox = id => ({
  id,
  name: `Voice ${id}`,
  channel_type: VOICE_CHANNEL_TYPE,
});

const textInbox = id => ({
  id,
  name: `Chat ${id}`,
  channel_type: 'Channel::Whatsapp',
});

// The voice numbers that name the agent come from the agent itself.
const agent = (id, voiceInboxIds = []) => ({
  id,
  voice_inbox_ids: voiceInboxIds,
});

describe('isVoiceAgent', () => {
  it('is true when a voice channel answers with the agent', () => {
    expect(isVoiceAgent(agent(7, [2]), [textInbox(1), voiceInbox(2)])).toBe(
      true
    );
  });

  it('compares ids as numbers', () => {
    expect(isVoiceAgent(agent(7, ['2']), [voiceInbox(2)])).toBe(true);
    expect(isVoiceAgent(agent(7, [2]), [voiceInbox('2')])).toBe(true);
  });

  it('ignores a text channel, which names no agent', () => {
    expect(isVoiceAgent(agent(7, [1]), [textInbox(1)])).toBe(false);
  });

  it('ignores voice channels that name another agent or none', () => {
    expect(isVoiceAgent(agent(7), [voiceInbox(2), voiceInbox(3)])).toBe(false);
    expect(isVoiceAgent(agent(7, [3]), [voiceInbox(2)])).toBe(false);
  });

  it('does not treat populated voice settings as a voice binding', () => {
    expect(
      isVoiceAgent(
        { id: 7, config: { voice_settings: { provider: 'gemini-live' } } },
        []
      )
    ).toBe(false);
  });

  it('tolerates a missing agent or inbox list', () => {
    expect(isVoiceAgent(null, [voiceInbox(2)])).toBe(false);
    expect(isVoiceAgent(agent(7, [2]), undefined)).toBe(false);
    expect(isVoiceAgent(agent(7, [2]), null)).toBe(false);
  });

  it('lists only the voice channels of the agent', () => {
    expect(
      voiceInboxesForAgent(agent(7, [2, 4]), [
        voiceInbox(2),
        voiceInbox(3),
        textInbox(4),
      ]).map(inbox => inbox.id)
    ).toEqual([2]);
  });
});
