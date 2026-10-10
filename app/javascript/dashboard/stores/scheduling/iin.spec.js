import { describe, expect, it } from 'vitest';
import {
  isValidPatientIin,
  normalizePatientIin,
  parseIinMetadata,
} from './iin';

describe('scheduling patient IIN', () => {
  it('reuses checksum validation without truncating a longer identifier', () => {
    expect(isValidPatientIin('940720300129')).toBe(true);
    expect(isValidPatientIin('170102500010')).toBe(true);
    expect(isValidPatientIin('170102500011')).toBe(false);
    expect(normalizePatientIin('1701025000101')).toBe('1701025000101');
    expect(isValidPatientIin('1701025000101')).toBe(false);
  });

  it('decodes existing date and gender rules and rejects invalid calendar data', () => {
    expect(parseIinMetadata('170102500010')).toMatchObject({
      valid: true,
      birthDate: '2017-01-02',
      gender: 'male',
    });
    expect(parseIinMetadata('940720400129')).toMatchObject({
      valid: true,
      birthDate: '1994-07-20',
      gender: 'female',
    });
    expect(parseIinMetadata('991332500010')).toEqual({
      valid: false,
      reason: 'date',
    });
    expect(parseIinMetadata('170102700010')).toEqual({
      valid: false,
      reason: 'format',
    });
    expect(parseIinMetadata('170102000010')).toEqual({
      valid: false,
      reason: 'foreign',
    });
  });
});
