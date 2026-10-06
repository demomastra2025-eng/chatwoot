require 'rails_helper'

RSpec.describe Search::QueryText do
  describe '.clean' do
    it 'turns exotic spaces into plain ones' do
      # no-break, thin, narrow no-break, ideographic and a tab
      expect(described_class.clean("Иван\u00A0Иванов\u2009Петрович\u202Fx\u3000y\tz")).to eq('Иван Иванов Петрович x y z')
    end

    it 'drops direction marks, zero-width characters and other invisible format characters' do
      expect(described_class.clean("\u200E+7 707\u200F 281\u202A 70\u202C 60\u2060\uFEFF")).to eq('+7 707 281 70 60')
    end

    it 'drops a NUL byte and other control characters, which PostgreSQL would reject' do
      expect(described_class.clean("Ива\u0000н\u0007")).to eq('Иван')
    end

    it 'scrubs invalid UTF-8' do
      expect(described_class.clean("Ива\xFFн")).to eq('Иван')
    end

    it 'composes a decomposed letter, as pasted from some systems' do
      expect(described_class.clean("\u0418\u0306сай, Се\u0308мен")).to eq("\u0419сай, С\u0451мен")
    end

    it 'keeps full-width characters as typed' do
      expect(described_class.clean('＋７ ７０７')).to eq('＋７ ７０７')
      expect(described_class.clean('ＡＢｃ！（１）')).to eq('ＡＢｃ！（１）')
    end

    # NFKC would rewrite these: the typed text has to stay as it is stored in the messages.
    it 'leaves characters that people type on purpose as they are: №, an ellipsis, a superscript, a trademark sign, ligatures' do
      aggregate_failures do
        expect(described_class.clean('справка №123')).to eq('справка №123')
        expect(described_class.clean('ждите…')).to eq('ждите…')
        expect(described_class.clean('50 м²')).to eq('50 м²')
        expect(described_class.clean('Brand™')).to eq('Brand™')
        expect(described_class.clean('ﬁne ½ ㎏ ①')).to eq('ﬁne ½ ㎏ ①')
      end
    end

    it 'strips and bounds the text' do
      expect(described_class.clean("  \n a \n ")).to eq('a')
      expect(described_class.clean('я' * 500).length).to eq(described_class::MAX_LENGTH)
    end

    it 'handles nil' do
      expect(described_class.clean(nil)).to eq('')
    end
  end

  describe '.like_pattern' do
    it 'escapes the LIKE wildcards so that they are searched for literally' do
      expect(described_class.like_pattern('50%_off\\')).to eq('%50\\%\\_off\\\\%')
    end
  end

  describe '.yo_regexp' do
    it 'makes е and ё interchangeable, whatever the case, in every position' do
      expect(described_class.yo_regexp('Семён Киселев')).to eq('С[её]м[её]н Кис[её]л[её]в')
    end

    it 'escapes the regular expression operators' do
      expect(described_class.yo_regexp('а.б (в) [г] {д} ^е$ ж|з \\ и*к+л?')).to eq(
        'а\\.б \\(в\\) \\[г\\] \\{д\\} \\^[её]\\$ ж\\|з \\\\ и\\*к\\+л\\?'
      )
    end
  end

  describe '.literal_regexp and .gap?' do
    it 'lets a space between words match any run of non-letters, and nothing else' do
      expect(described_class.literal_regexp('добрый день хочу')).to eq('добрый[^[:alnum:]]+д[её]нь[^[:alnum:]]+хочу')
      expect(described_class.gap?('добрый день')).to be(true)
      expect(described_class.gap?('добрый')).to be(false)
    end

    it 'does not require the sentence punctuation that is typed next to a space' do
      expect(described_class.literal_regexp('день, хочу')).to eq('д[её]нь[^[:alnum:]]+хочу')
      expect(described_class.literal_regexp('ждите… пожалуйста!')).to eq('ждит[её][^[:alnum:]]+пожалуйста!')
    end

    it 'keeps every other character as typed, also next to a space' do
      expect(described_class.literal_regexp('справка №123')).to eq('справка[^[:alnum:]]+№123')
      expect(described_class.literal_regexp('(акция) 50%')).to eq('\\(акция\\)[^[:alnum:]]+50%')
      expect(described_class.literal_regexp('ждите…')).to eq('ждит[её]…')
    end

    it 'keeps е and ё interchangeable' do
      expect(described_class.literal_regexp('счёт врача')).to eq('сч[её]т[^[:alnum:]]+врача')
    end
  end
end
