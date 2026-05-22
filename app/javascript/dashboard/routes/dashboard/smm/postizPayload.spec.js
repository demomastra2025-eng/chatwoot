import { buildPostizPostPayload, normalizePostizDate } from './postizPayload';

describe('postizPayload', () => {
  it('builds a valid draft payload when date is empty', () => {
    const payload = buildPostizPostPayload(
      {
        content: 'test',
        date: '',
        integrationId: 'cmpfkskxd0001nu7rfhl7kxkz',
        type: 'draft',
      },
      new Date('2026-05-21T10:00:00.000Z')
    );

    expect(payload).toEqual({
      type: 'draft',
      date: '2026-05-21T10:00:00.000Z',
      shortLink: false,
      tags: [],
      posts: [
        {
          integration: { id: 'cmpfkskxd0001nu7rfhl7kxkz' },
          value: [{ content: 'test', image: [] }],
          settings: {},
        },
      ],
    });
  });

  it('normalizes datetime-local input to an ISO date string', () => {
    expect(normalizePostizDate('2026-05-21T15:30')).toMatch(
      /^2026-05-21T\d{2}:30:00\.000Z$/
    );
  });

  it('includes uploaded media in the Postiz image array', () => {
    const payload = buildPostizPostPayload({
      content: 'with media',
      date: '2026-05-21T10:00:00.000Z',
      integrationId: 'ig-1',
      media: [{ id: 'media-1', path: 'https://cdn.example.com/a.png' }],
      type: 'schedule',
    });

    expect(payload.posts[0].value[0].image).toEqual([
      { id: 'media-1', path: 'https://cdn.example.com/a.png' },
    ]);
  });
});
