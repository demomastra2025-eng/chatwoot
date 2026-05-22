import {
  buildCalendarDays,
  filterPosts,
  flattenAnalytics,
  monthRange,
  summarizePosts,
} from './smmHelpers';

describe('smmHelpers', () => {
  it('builds an ISO month range for Postiz calendar queries', () => {
    expect(monthRange(new Date('2026-05-15T12:00:00.000Z'))).toEqual({
      startDate: new Date(2026, 4, 1).toISOString(),
      endDate: new Date(2026, 5, 0, 23, 59, 59).toISOString(),
    });
  });

  it('places posts into a 42-day calendar grid by publish date', () => {
    const days = buildCalendarDays(new Date('2026-05-15T12:00:00.000Z'), [
      { id: 'post-1', publishDate: '2026-05-21T10:00:00.000Z' },
    ]);

    expect(days).toHaveLength(42);
    expect(days.find(day => day.key === '2026-05-21').posts).toEqual([
      { id: 'post-1', publishDate: '2026-05-21T10:00:00.000Z' },
    ]);
  });

  it('summarizes and filters posts', () => {
    const posts = [
      { id: '1', content: 'Launch', state: 'QUEUE', integration: { id: 'ig' } },
      {
        id: '2',
        content: 'Draft idea',
        state: 'DRAFT',
        integration: { id: 'x' },
      },
      {
        id: '3',
        content: 'Done',
        state: 'PUBLISHED',
        integration: { id: 'ig' },
      },
    ];

    expect(summarizePosts(posts)).toMatchObject({
      draft: 1,
      published: 1,
      scheduled: 1,
      total: 3,
    });
    expect(
      filterPosts(posts, { channelId: 'ig', query: 'launch', status: 'queue' })
    ).toEqual([posts[0]]);
  });

  it('flattens Postiz analytics arrays and keyed objects', () => {
    expect(
      flattenAnalytics([
        {
          label: 'followers',
          data: [
            { date: '2026-05-20', total: '10' },
            { date: '2026-05-21', total: '12' },
          ],
        },
      ])
    ).toEqual([
      {
        label: 'followers',
        percentageChange: undefined,
        points: [
          { date: '2026-05-20', total: '10' },
          { date: '2026-05-21', total: '12' },
        ],
        total: '12',
      },
    ]);

    expect(flattenAnalytics({ followers: 12 })[0]).toMatchObject({
      label: 'followers',
      total: 12,
    });
  });
});
