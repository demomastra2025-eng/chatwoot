import {
  cleanSearchText,
  parsePhoneQuery,
  phoneFragments,
  phoneMatchesQuery,
} from '../phoneSearch';

describe('phoneSearch', () => {
  describe('cleanSearchText', () => {
    it('turns exotic spaces into plain ones and drops invisible marks', () => {
      expect(cleanSearchText('Иван\u00A0Иванов\u2009x\u202Fy')).toBe(
        'Иван Иванов x y'
      );
      expect(cleanSearchText('\u200E+7 707\u200F 281\u202A 70\u202C 60')).toBe(
        '+7 707 281 70 60'
      );
      expect(cleanSearchText('＋７ ７０７')).toBe('+7 707');
      expect(cleanSearchText(null)).toBe('');
    });
  });

  describe('parsePhoneQuery', () => {
    it('reads the digits of any format', () => {
      [
        '87072817060',
        '8-707-281-70-60',
        '8 (707) 281.70.60',
        '８７０７２８１７０６０',
        '\u200E8 707 281 70 60\u200F',
      ].forEach(text => {
        expect(parsePhoneQuery(text)).toBe('87072817060');
      });
    });

    it('is null for text that is not a phone number', () => {
      ['', ' ', '+', 'Иван', '12ab34', 'a@b.kz 7072817060', null].forEach(
        text => {
          expect(parsePhoneQuery(text)).toBeNull();
        }
      );
    });

    it('is null below 4 digits and above 15 digits', () => {
      expect(parsePhoneQuery('707')).toBeNull();
      expect(parsePhoneQuery('+7 70')).toBeNull();
      expect(parsePhoneQuery('7'.repeat(16))).toBeNull();
      expect(parsePhoneQuery('7'.repeat(15))).toBe('7'.repeat(15));
      expect(parsePhoneQuery('7071')).toBe('7071');
    });
  });

  describe('phoneFragments', () => {
    it('adds the digits without a leading 7, 8 or 0 when 4 or more remain', () => {
      expect(phoneFragments('87072817060')).toEqual([
        '87072817060',
        '7072817060',
      ]);
      expect(phoneFragments('7072')).toEqual(['7072']);
      expect(phoneFragments('70728')).toEqual(['70728', '0728']);
      expect(phoneFragments('2817060')).toEqual(['2817060']);
    });
  });

  describe('phoneMatchesQuery', () => {
    const stored = '+77072817060';

    it('matches a number typed in any format', () => {
      [
        '87072817060',
        '+77072817060',
        '7 707 281 70 60',
        '+7 (707) 281-70-60',
        '707 281 70 60',
        '8-707-281-70-60',
        '07072817060',
        '2817060',
        '707281',
        '+7\u00A0707\u00A0281\u00A070\u00A060',
        '\u200E+7 707 281 70 60\u200F',
      ].forEach(text => {
        expect(phoneMatchesQuery(stored, text)).toBe(true);
      });
    });

    it('matches a number that is still being typed, stored with +7 or with 8', () => {
      ['+77072817060', '87072817060'].forEach(storedNumber => {
        ['+7 (707) 281-70-60', '8 707 281 70 60', '707 281 70 60'].forEach(
          format => {
            for (let length = 1; length <= format.length; length += 1) {
              const typed = format.slice(0, length);
              const digits = parsePhoneQuery(typed);
              const contained =
                digits && storedNumber.replace(/\D/g, '').includes(digits);
              if (digits && (digits.length >= 5 || contained)) {
                expect(phoneMatchesQuery(storedNumber, typed)).toBe(true);
              }
            }
          }
        );
      });
    });

    it('does not match a different number, a short input or an empty phone', () => {
      expect(phoneMatchesQuery(stored, '87012345678')).toBe(false);
      expect(phoneMatchesQuery(stored, '2817061')).toBe(false);
      expect(phoneMatchesQuery(stored, '707')).toBe(false);
      expect(phoneMatchesQuery(stored, 'Асель')).toBe(false);
      expect(phoneMatchesQuery('', '87072817060')).toBe(false);
      expect(phoneMatchesQuery(null, '87072817060')).toBe(false);
    });

    it('matches numbers of other countries by the last 10 digits and contained digits', () => {
      const ukrainian = '+380501234567';
      [
        '+38 (050) 123-45-67',
        '0501234567',
        '050 123 45 67',
        '38050123456',
      ].forEach(text => {
        expect(phoneMatchesQuery(ukrainian, text)).toBe(true);
      });
      expect(phoneMatchesQuery(stored, '+1 707 281 7060')).toBe(true);
    });
  });
});
