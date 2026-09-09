import { accountSettingsMatch } from './accountSettings';

describe('accountSettingsMatch', () => {
  const expectedSettings = {
    workspace_timezone: 'Asia/Almaty',
    workspace_breaks: [
      { days: [1, 2, 3], start_time: '13:00', end_time: '14:00' },
    ],
  };

  it('accepts the echoed settings contract regardless of object key order', () => {
    const account = {
      settings: {
        workspace_breaks: [
          { end_time: '14:00', start_time: '13:00', days: [1, 2, 3] },
        ],
        workspace_timezone: 'Asia/Almaty',
      },
    };

    expect(accountSettingsMatch(account, expectedSettings)).toBe(true);
  });

  it('rejects a successful response that silently omitted a requested setting', () => {
    const account = {
      settings: { workspace_timezone: 'Asia/Almaty' },
    };

    expect(accountSettingsMatch(account, expectedSettings)).toBe(false);
  });
});
