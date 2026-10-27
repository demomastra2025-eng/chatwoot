import { describe, expect, it } from 'vitest';

import { extractMatrixErrors, isTextChannel } from '../captainChannelMatrix';

describe('captainChannelMatrix helpers', () => {
  describe('isTextChannel', () => {
    it('treats every channel except voice as a text channel', () => {
      expect(isTextChannel('Channel::Whatsapp')).toBe(true);
      expect(isTextChannel('Channel::Telegram')).toBe(true);
      expect(isTextChannel('Channel::Voice')).toBe(false);
    });
  });

  describe('extractMatrixErrors', () => {
    it('reads the 422 error list', () => {
      const errors = extractMatrixErrors({
        response: {
          status: 422,
          data: {
            errors: [
              {
                inbox_id: '5',
                assistant_id: null,
                code: 'INVALID_CHANNEL',
                message: 'Channel not found',
              },
              'Plain text error',
            ],
          },
        },
      });

      expect(errors).toEqual([
        {
          inbox_id: 5,
          assistant_id: null,
          code: 'INVALID_CHANNEL',
          message: 'Channel not found',
        },
        {
          inbox_id: null,
          assistant_id: null,
          code: '',
          message: 'Plain text error',
        },
      ]);
    });

    it('turns any other failure into one general error', () => {
      expect(
        extractMatrixErrors({ response: { status: 500, data: {} } })
      ).toEqual([
        {
          inbox_id: null,
          assistant_id: null,
          code: 'HTTP_500',
          message: '',
        },
      ]);
      expect(extractMatrixErrors(new Error('offline'))[0].code).toBe(
        'NETWORK_ERROR'
      );
    });
  });
});
