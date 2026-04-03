import { describe, expect, it } from 'vitest';

import {
  getEditableResourcePhotoUrl,
  getResourceDisplayPhoto,
} from './resourcePhotos';

describe('resourcePhotos', () => {
  it('prefers the specialist photo for display when it exists', () => {
    expect(
      getResourceDisplayPhoto(
        { photoUrl: 'https://cdn.example.com/specialist.png' },
        { thumbnail: 'https://cdn.example.com/user.png' }
      )
    ).toBe('https://cdn.example.com/specialist.png');
  });

  it('falls back to the linked user thumbnail for display only', () => {
    expect(
      getResourceDisplayPhoto(
        { photoUrl: '' },
        { thumbnail: 'https://cdn.example.com/user.png' }
      )
    ).toBe('https://cdn.example.com/user.png');
  });

  it('keeps persisted photo_url separate from the linked user thumbnail', () => {
    expect(
      getEditableResourcePhotoUrl({
        photoUrl: '',
        userId: 42,
      })
    ).toBe('');
  });
});
