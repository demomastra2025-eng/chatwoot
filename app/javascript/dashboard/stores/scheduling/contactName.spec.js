import { describe, expect, it } from 'vitest';

import { schedulingContactNameParts } from './contactName';

describe('schedulingContactNameParts', () => {
  it('preserves explicit structured name fields', () => {
    expect(
      schedulingContactNameParts({
        firstName: 'Айжан',
        lastName: 'Касымова',
        middleName: 'Ерлановна',
        fullName: 'Айжан Касымова Ерлановна',
      })
    ).toEqual({
      firstName: 'Айжан',
      lastName: 'Касымова',
      middleName: 'Ерлановна',
    });
  });

  it('splits a two-part full name when the surname field is empty', () => {
    expect(
      schedulingContactNameParts({
        firstName: 'Айжан Касымова',
        fullName: 'Айжан Касымова',
        lastName: '',
      })
    ).toEqual({
      firstName: 'Айжан',
      lastName: 'Касымова',
      middleName: '',
    });
  });

  it('does not guess the structure of an ambiguous three-part name', () => {
    expect(
      schedulingContactNameParts({
        fullName: 'Касымова Айжан Ерлановна',
      })
    ).toEqual({
      firstName: 'Касымова Айжан Ерлановна',
      lastName: '',
      middleName: '',
    });
  });
});
