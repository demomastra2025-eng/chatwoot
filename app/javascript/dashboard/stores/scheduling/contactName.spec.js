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

  it('strips structured lastName and middleName from a full-name payload when firstName is omitted or concatenated', () => {
    expect(
      schedulingContactNameParts({
        name: 'Асет Хамзаулы Серикович',
        lastName: 'Хамзаулы',
        middleName: 'Серикович',
      })
    ).toEqual({
      firstName: 'Асет',
      lastName: 'Хамзаулы',
      middleName: 'Серикович',
    });

    expect(
      schedulingContactNameParts({
        firstName: 'Асет Хамзаулы',
        lastName: 'Хамзаулы',
        middleName: '',
        fullName: 'Асет Хамзаулы',
      })
    ).toEqual({
      firstName: 'Асет',
      lastName: 'Хамзаулы',
      middleName: '',
    });
  });

  it('does not move middleName into lastName when lastName is blank on a two-word fullName', () => {
    expect(
      schedulingContactNameParts({
        firstName: 'Асет',
        lastName: '',
        middleName: 'Серикович',
        fullName: 'Асет Серикович',
      })
    ).toEqual({
      firstName: 'Асет',
      lastName: '',
      middleName: 'Серикович',
    });
  });
});
