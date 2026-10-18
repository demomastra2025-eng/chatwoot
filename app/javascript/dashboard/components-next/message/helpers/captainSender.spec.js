import { describe, expect, it } from 'vitest';
import {
  councilCaption,
  councilContributors,
  isCaptainAssistantSender,
} from './captainSender';

describe('isCaptainAssistantSender', () => {
  it('detects the push payload type of a Captain agent', () => {
    expect(
      isCaptainAssistantSender({ id: 7, type: 'captain_assistant' }, null)
    ).toBe(true);
  });

  it('falls back to the message sender type', () => {
    expect(isCaptainAssistantSender({ id: 7 }, 'captain_assistant')).toBe(true);
    expect(isCaptainAssistantSender(null, 'Captain::Assistant')).toBe(true);
  });

  it('prefers the sender payload type over the message sender type', () => {
    expect(
      isCaptainAssistantSender({ type: 'user' }, 'captain_assistant')
    ).toBe(false);
  });

  it('ignores users, contacts and missing senders', () => {
    expect(isCaptainAssistantSender({ type: 'user' }, 'User')).toBe(false);
    expect(isCaptainAssistantSender(null, 'Contact')).toBe(false);
    expect(isCaptainAssistantSender(null, null)).toBe(false);
    expect(isCaptainAssistantSender(undefined, undefined)).toBe(false);
  });
});

describe('councilContributors', () => {
  it('reads camelCase contributors from content attributes', () => {
    expect(
      councilContributors({
        contentAttributes: {
          councilContributors: [
            { id: 1, name: 'Айгерим', avatarUrl: 'https://cdn.test/a.png' },
            { id: 2, name: 'Бота' },
          ],
        },
      })
    ).toEqual([
      { id: 1, name: 'Айгерим', avatarUrl: 'https://cdn.test/a.png' },
      { id: 2, name: 'Бота', avatarUrl: '' },
    ]);
  });

  it('reads snake_case contributors and avatar urls', () => {
    expect(
      councilContributors({
        contentAttributes: {
          council_contributors: [
            { id: 3, name: 'Doctor', avatar_url: 'https://cdn.test/d.png' },
          ],
        },
      })
    ).toEqual([{ id: 3, name: 'Doctor', avatarUrl: 'https://cdn.test/d.png' }]);
  });

  it('falls back to additional attributes when content attributes have none', () => {
    expect(
      councilContributors({
        contentAttributes: { councilContributors: [] },
        additionalAttributes: {
          council_contributors: [{ id: 4, name: 'Sales' }],
        },
      })
    ).toEqual([{ id: 4, name: 'Sales', avatarUrl: '' }]);
  });

  it('prefers content attributes over additional attributes', () => {
    expect(
      councilContributors({
        contentAttributes: { councilContributors: [{ id: 1, name: 'A' }] },
        additionalAttributes: { councilContributors: [{ id: 2, name: 'B' }] },
      }).map(contributor => contributor.name)
    ).toEqual(['A']);
  });

  it('drops entries without a name and removes duplicate ids', () => {
    expect(
      councilContributors({
        contentAttributes: {
          councilContributors: [
            { id: 1, name: 'A' },
            { id: 2, name: '  ' },
            { id: 3 },
            null,
            'B',
            { id: '1', name: 'A again' },
            { id: 5, name: ' C ' },
            { name: 'D' },
            { name: 'D' },
          ],
        },
      })
    ).toEqual([
      { id: 1, name: 'A', avatarUrl: '' },
      { id: 5, name: 'C', avatarUrl: '' },
      { id: null, name: 'D', avatarUrl: '' },
    ]);
  });

  it('returns an empty list for regular messages', () => {
    expect(councilContributors({})).toEqual([]);
    expect(councilContributors()).toEqual([]);
    expect(
      councilContributors({
        contentAttributes: null,
        additionalAttributes: { councilContributors: 'A, B' },
      })
    ).toEqual([]);
  });
});

describe('councilCaption', () => {
  it('joins the contributor names', () => {
    expect(
      councilCaption([
        { id: 1, name: 'A' },
        { id: 2, name: 'B' },
        { id: 3, name: 'C' },
        { id: 4, name: 'D' },
      ])
    ).toBe('A, B, C, D');
  });

  it('returns an empty string without contributors', () => {
    expect(councilCaption([])).toBe('');
    expect(councilCaption(null)).toBe('');
  });
});
