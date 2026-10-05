import { describe, expect, it } from 'vitest';

import assistantStore, { isInternalAssistant } from './assistant';

const agent = { id: 3, name: 'Мөлдір', usage_mode: 'external_agent' };
const otherAgent = { id: 9, name: 'Арман', usage_mode: 'external_agent' };
const helper = { id: 5, name: 'Team helper', usage_mode: 'internal_assistant' };

describe('captain assistants store', () => {
  describe('isInternalAssistant', () => {
    it('is true only for the internal assistant kind', () => {
      expect(isInternalAssistant(helper)).toBe(true);
      expect(isInternalAssistant(agent)).toBe(false);
      expect(isInternalAssistant({ id: 1 })).toBe(false);
      expect(isInternalAssistant(undefined)).toBe(false);
    });
  });

  describe('getRecords', () => {
    it('lists AI agents only, newest first, and hides the internal assistants', () => {
      const records = assistantStore.getters.getRecords({
        records: [agent, helper, otherAgent],
      });

      expect(records.map(record => record.id)).toEqual([9, 3]);
    });

    it('is empty for an account that only has an internal assistant', () => {
      expect(assistantStore.getters.getRecords({ records: [helper] })).toEqual(
        []
      );
    });

    it('does not reorder or drop the stored rows', () => {
      const records = [agent, helper, otherAgent];

      assistantStore.getters.getRecords({ records });

      expect(records).toEqual([agent, helper, otherAgent]);
    });

    it('keeps an agent whose record has no kind', () => {
      const legacy = { id: 2, name: 'Legacy' };

      expect(assistantStore.getters.getRecords({ records: [legacy] })).toEqual([
        legacy,
      ]);
    });
  });

  describe('getRecord', () => {
    const state = { records: [agent, helper] };

    it('returns an AI agent by its id', () => {
      expect(assistantStore.getters.getRecord(state)(3)).toEqual(agent);
      expect(assistantStore.getters.getRecord(state)('3')).toEqual(agent);
    });

    it('treats an internal assistant like a missing record', () => {
      expect(assistantStore.getters.getRecord(state)(5)).toEqual({});
    });

    it('returns an empty record for an unknown id', () => {
      expect(assistantStore.getters.getRecord(state)(404)).toEqual({});
    });
  });

  it('keeps the other getters of the store factory', () => {
    expect(assistantStore.getters).toHaveProperty('getUIFlags');
    expect(assistantStore.getters).toHaveProperty('getMeta');
  });
});
