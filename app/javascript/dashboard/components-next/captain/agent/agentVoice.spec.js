import { describe, expect, it } from 'vitest';
import {
  VOICE_CHANNEL_TYPE,
  isVoiceAgent,
  voiceInboxesForAgent,
} from './agentVoice';

const voiceInbox = (id, assistantId) => ({
  id,
  name: `Voice ${id}`,
  channel_type: VOICE_CHANNEL_TYPE,
  captain_assistant: assistantId ? { id: assistantId, name: 'Agent' } : null,
});

const textInbox = (id, assistantId) => ({
  id,
  name: `Chat ${id}`,
  channel_type: 'Channel::Whatsapp',
  captain_assistant: assistantId ? { id: assistantId, name: 'Agent' } : null,
});

describe('isVoiceAgent', () => {
  it('is true when a voice channel answers with the agent', () => {
    expect(
      isVoiceAgent({ id: 7 }, [textInbox(1, 7), voiceInbox(2, 7)])
    ).toBe(true);
  });

  it('compares ids as numbers', () => {
    expect(isVoiceAgent({ id: '7' }, [voiceInbox(2, 7)])).toBe(true);
    expect(isVoiceAgent({ id: 7 }, [voiceInbox(2, '7')])).toBe(true);
  });

  it('ignores text channels bound to the agent', () => {
    expect(isVoiceAgent({ id: 7 }, [textInbox(1, 7)])).toBe(false);
  });

  it('ignores voice channels bound to another agent or to none', () => {
    expect(isVoiceAgent({ id: 7 }, [voiceInbox(2, 8), voiceInbox(3)])).toBe(
      false
    );
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
    expect(isVoiceAgent(null, [voiceInbox(2, 7)])).toBe(false);
    expect(isVoiceAgent({ id: 7 }, undefined)).toBe(false);
    expect(isVoiceAgent({ id: 7 }, null)).toBe(false);
  });

  it('lists only the voice channels of the agent', () => {
    expect(
      voiceInboxesForAgent({ id: 7 }, [
        voiceInbox(2, 7),
        voiceInbox(3, 8),
        textInbox(4, 7),
      ]).map(inbox => inbox.id)
    ).toEqual([2]);
  });
});
