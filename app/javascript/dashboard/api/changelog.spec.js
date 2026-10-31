import axios from 'axios';
import changelogAPI from './changelog';

vi.mock('axios', () => ({ default: { get: vi.fn(), create: vi.fn() } }));

describe('OneLink news feed', () => {
  it('keeps the sidebar response contract without contacting the upstream vendor', async () => {
    await expect(changelogAPI.fetchFromHub()).resolves.toEqual({
      data: { posts: [] },
    });
    expect(axios.get).not.toHaveBeenCalled();
  });
});
