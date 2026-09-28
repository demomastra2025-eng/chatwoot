import { normalizeDialNumber } from '../phoneDialNumber';

describe('normalizeDialNumber', () => {
  it.each([
    ['+77011234567', '+77011234567'],
    ['+7 (701) 123-45-67', '+77011234567'],
    ['8 (701) 123-45-67', '+77011234567'],
    ['8-701-123-45-67', '+77011234567'],
    ['87011234567', '+77011234567'],
    ['77011234567', '+77011234567'],
    ['7 701 123 45 67', '+77011234567'],
    ['701 123 45 67', '+77011234567'],
    ['+7 701 123 45 67', '+77011234567'],
    ['8 701 123–45–67', '+77011234567'],
    ['  +7 701 123 45 67\n', '+77011234567'],
    ['+7 701 123 45 67\r\n', '+77011234567'],
    ['tel:+77011234567', '+77011234567'],
  ])('normalizes %j to E.164', (input, expected) => {
    expect(normalizeDialNumber(input)).toBe(expected);
  });

  it('extracts the number from a copied contact line with trailing text', () => {
    expect(normalizeDialNumber('+7 701 123 45 67 Айгерим')).toBe(
      '+77011234567'
    );
    expect(
      normalizeDialNumber('8 (701) 123-45-67, перезвонить после 15:00')
    ).toBe('+77011234567');
    expect(normalizeDialNumber('Телефон: 8 701 123 45 67\nEmail: a@b.kz')).toBe(
      '+77011234567'
    );
  });

  it('dials the first number when several lines were copied', () => {
    expect(normalizeDialNumber('87011234567\n87027654321')).toBe(
      '+77011234567'
    );
  });

  it('keeps international numbers entered with a plus', () => {
    expect(normalizeDialNumber('+49 30 901820')).toBe('+4930901820');
  });

  it.each([
    [''],
    [null],
    [undefined],
    ['   '],
    ['+7 701'],
    ['12345'],
    ['без номера'],
  ])('returns an empty string for %j', input => {
    expect(normalizeDialNumber(input)).toBe('');
  });
});
