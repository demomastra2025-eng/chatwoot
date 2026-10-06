require 'rails_helper'

RSpec.describe Search::MessageQuery do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:base) { account.messages.where(inbox_id: inbox.id) }

  def message(content, minutes_ago = 0, **attributes)
    create(:message, account: account, inbox: inbox, content: content, created_at: minutes_ago.minutes.ago, **attributes)
  end

  def found(text, **options)
    described_class.new(text).newest(base, limit: 15, **options).rows.map(&:first)
  end

  describe 'what is a match' do
    # The owner's decision: the typed text is looked for literally, no stemming, no word forms.
    let!(:past) { message('Мы записали вас на среду') }
    let!(:noun) { message('Ваша запись подтверждена') }
    let!(:infinitive) { message('Хотите записаться на приём?') }
    let!(:unrelated) { message('Где находится клиника?') }

    it 'does not find another word form: "записаться" does not find "записали" or "запись"' do
      expect(found('записаться')).to eq([infinitive.id])
      expect(found('записали')).to eq([past.id])
      expect(found('запись')).to eq([noun.id])
    end

    it 'finds the typed text as a start of a word, inside a word and at the end of a word' do
      aggregate_failures do
        expect(found('запис')).to contain_exactly(past.id, noun.id, infinitive.id)
        expect(found('писа')).to contain_exactly(past.id, infinitive.id)
        expect(found('ться')).to eq([infinitive.id])
        expect(found('на приём')).to eq([infinitive.id])
        expect(found('вас на среду')).to eq([past.id])
      end
    end

    it 'ignores the case' do
      expect(found('ЗАПИСАЛИ')).to eq([past.id])
      expect(found('клиника')).to eq([unrelated.id])
      expect(found('КЛИНИКА?')).to eq([unrelated.id])
    end

    it 'treats е and ё as the same letter in both directions, also with several in one text' do
      with_yo = message('Нужен приём врача, номер счёта 5')
      with_ye = message('Нужен прием врача, номер счета 7')

      aggregate_failures do
        expect(found('приём')).to contain_exactly(with_yo.id, with_ye.id, infinitive.id)
        expect(found('прием')).to contain_exactly(with_yo.id, with_ye.id, infinitive.id)
        expect(found('ПРИЁМ врача')).to contain_exactly(with_yo.id, with_ye.id)
        expect(found('номер счёта')).to contain_exactly(with_yo.id, with_ye.id)
        expect(found('номер счета')).to contain_exactly(with_yo.id, with_ye.id)
        expect(found('номер счета 7')).to eq([with_ye.id])
      end
    end

    it 'does not take %, _, \\ or regular expression characters for operators' do
      special = message('Скидка 50% (акция) [VIP] _тест_ a.b')
      message('Скидка 500 акция VIP xтестx axb')

      aggregate_failures do
        expect(found('50%')).to eq([special.id])
        expect(found('_тест_')).to eq([special.id])
        expect(found('(акция)')).to eq([special.id])
        expect(found('[vip]')).to eq([special.id])
        expect(found('a.b')).to eq([special.id])
        expect(found('(а|б)')).to be_empty
        expect(found('скидка 5\\')).to be_empty
      end
    end

    it 'finds nothing for a text of 1 or 2 characters, which would match nearly every message' do
      expect(found('за')).to be_empty
      expect(found('я')).to be_empty
      expect(described_class.new('за')).not_to be_searchable
      expect(described_class.new('зап')).to be_searchable
    end

    it 'cleans the text like every other search box' do
      expect(found("зап\u0000иса\u200Bли")).to eq([past.id])
      expect(found("вас\u00A0на\u2009среду")).to eq([past.id])
    end
  end

  # The typed text has to occur in the message as typed: characters that Unicode compatibility folding (NFKC) would
  # rewrite on the way in must still be found.
  describe 'characters that stay as they are typed' do
    it 'finds №, an ellipsis, a superscript and a trademark sign' do
      certificate = message('Нужна справка №123')
      wait = message('Подождите… пожалуйста')
      area = message('Площадь 50 м² в центре')
      brand = message('Купили Acme™ вчера')
      message('Нужна справка No123 и ждите... и 50 м2 и AcmeTM')

      aggregate_failures do
        expect(found('№123')).to eq([certificate.id])
        expect(found('справка №123')).to eq([certificate.id])
        expect(found('Подождите…')).to eq([wait.id])
        expect(found('50 м²')).to eq([area.id])
        expect(found('Acme™')).to eq([brand.id])
      end
    end

    it 'finds a text typed with full-width characters as its plain ASCII' do
      plain = message('Код ABC-123 принят')

      expect(found('ＡＢＣ－１２３')).to eq([plain.id])
    end
  end

  # The old phrase search found the words in any order of separators: a comma, a line break, two spaces, a no-break space.
  describe 'words separated by punctuation, a line break or repeated spaces' do
    let!(:comma) { message('Добрый день, хочу записаться к кардиологу') }
    let!(:line_break) { message("Добрый день,\nхочу записаться к кардиологу", 1) }
    let!(:spaces) { message('здравствуйте   меня зовут Иван', 2) }
    let!(:no_break) { message("Добрый\u00A0день хочу узнать цену", 3) }
    let!(:bang) { message('Добрый день! Как к вам попасть?', 4) }
    let!(:dash) { message('Добрый день - хочу записаться', 5) }

    it 'finds the words however they are separated' do
      aggregate_failures do
        expect(found('добрый день хочу')).to contain_exactly(comma.id, line_break.id, no_break.id, dash.id)
        expect(found('добрый день, хочу')).to contain_exactly(comma.id, line_break.id, no_break.id, dash.id)
        expect(found('здравствуйте меня зовут')).to eq([spaces.id])
        expect(found('день хочу записаться к')).to contain_exactly(comma.id, line_break.id)
        expect(found('добрый день как к вам')).to eq([bang.id])
      end
    end

    it 'still needs the words to follow each other and the other characters to be there as typed' do
      aggregate_failures do
        expect(found('хочу добрый день')).to be_empty
        expect(found('день записаться')).to be_empty
        expect(found('день - хочу')).to eq([dash.id])
        expect(found('день — хочу')).to be_empty
      end
    end

    # Everything the long-standing phrase search (whole words, to_tsquery with <->) finds, the literal search finds too.
    it 'finds everything the old phrase search found' do
      legacy = lambda do |text|
        words = text.split.map { |word| word.gsub(/[^[:alnum:]_]/, '') }.reject(&:empty?)
        base.where("to_tsvector('english'::regconfig, COALESCE(messages.content, '')) @@ to_tsquery('english'::regconfig, ?)", words.join(' <-> '))
            .pluck(:id)
      end
      queries = ['добрый день хочу', 'добрый день, хочу', 'здравствуйте меня', 'здравствуйте, меня зовут', 'день хочу записаться к',
                 'добрый день как к вам', 'добрый день! как', 'хочу записаться']

      aggregate_failures do
        queries.each do |text|
          old_ids = legacy.call(text)

          expect(old_ids).not_to be_empty, "the legacy search should find something for #{text.inspect}"
          expect(found(text)).to include(*old_ids), "expected #{text.inspect} to lose nothing the old search found"
        end
      end
    end
  end

  describe 'the order and the pages' do
    let!(:messages) { Array.new(20) { |index| message("Нужна справка №#{index}", index) } }

    it 'returns the newest matches first and pages through them with the offset' do
      expect(found('справка')).to eq(messages.first(15).map(&:id))
      expect(found('справка', offset: 15)).to eq(messages.last(5).map(&:id))
      expect(found('справка', offset: 20)).to be_empty
    end

    it 'does not go beyond the newest MAX_RESULTS matches' do
      stub_const("#{described_class}::MAX_RESULTS", 17)

      expect(found('справка', offset: 15).size).to eq(2)
      expect(found('справка', offset: 17)).to be_empty
    end

    it 'looks only inside the relation it is given' do
      other_inbox = create(:inbox, account: account)
      create(:message, account: account, inbox: other_inbox, content: 'Нужна справка в другом ящике')
      create(:message, content: 'Нужна справка в другом аккаунте')

      expect(found('справка').size).to eq(15)
      expect(described_class.new('справка').newest(base, limit: 50).rows.size).to eq(20)
    end
  end

  describe 'the two steps' do
    let(:query) { described_class.new('справка') }

    before do
      stub_const("#{described_class}::RECENT_ROWS", 4)
      Array.new(6) { |index| message("Нужна справка №#{index}", 100 + index) }  # old, matching
      Array.new(4) { |index| message("Что-то другое #{index}", index) }         # newest, not matching
    end

    it 'finds the page among the newest messages first, and falls back to the index for what lies further back' do
      allow(query).to receive(:indexed_rows).and_call_original

      result = query.newest(base, limit: 3)

      expect(query).to have_received(:indexed_rows).once
      expect(result.rows.size).to eq(3)
      expect(result.partial).to be(false)
    end

    it 'does not use the index when the newest messages fill the page' do
      4.times { |index| message("Свежая справка №#{index}", 0) } # created last, so the newest of all
      allow(query).to receive(:indexed_rows).and_call_original

      result = query.newest(base, limit: 3)

      expect(query).not_to have_received(:indexed_rows)
      expect(result.rows.size).to eq(3)
    end

    it 'gives the same newest-first answer through either step' do
      through_index = query.newest(base, limit: 6).rows.map(&:first)

      stub_const("#{described_class}::RECENT_ROWS", 1000)
      through_recent = described_class.new('справка').newest(base, limit: 6).rows.map(&:first)

      expect(through_index).to eq(through_recent)
      expect(through_index).to eq(base.where('content ILIKE ?', '%справка%').reorder(created_at: :desc, id: :desc).limit(6).pluck(:id))
    end
  end

  describe 'the time limit' do
    let!(:old_match) { message('Нужна справка', 100) }

    before { stub_const("#{described_class}::RECENT_ROWS", 2) }

    it 'gives up a step that takes too long and says so, instead of waiting for the database default' do
      stub_const("#{described_class}::TIMEOUT", '60ms')
      slow = base.where('pg_sleep(0.3) IS NOT NULL')

      result = nil
      expect { result = described_class.new('справка').newest(slow, limit: 5) }.not_to raise_error

      expect(result.rows).to be_empty
      expect(result.partial).to be(true)
    end

    it 'keeps what the first step found when only the second one is cancelled' do
      recent = message('Свежая справка', 1)
      query = described_class.new('справка')
      allow(query).to receive(:indexed_rows).and_raise(ActiveRecord::QueryCanceled)

      result = query.newest(base, limit: 5)

      expect(result.rows.map(&:first)).to eq([recent.id, old_match.id])
      expect(result.partial).to be(true)
    end

    it 'puts the statement timeout and the plan setting back after a successful search' do
      before_values = %w[statement_timeout enable_indexscan].map { |name| ActiveRecord::Base.connection.select_value("SHOW #{name}") }

      described_class.new('справка').newest(base, limit: 5)

      after_values = %w[statement_timeout enable_indexscan].map { |name| ActiveRecord::Base.connection.select_value("SHOW #{name}") }
      expect(after_values).to eq(before_values)
    end

    it 'leaves the connection usable after a cancelled statement' do
      stub_const("#{described_class}::TIMEOUT", '60ms')
      described_class.new('справка').newest(base.where('pg_sleep(0.3) IS NOT NULL'), limit: 5)

      expect(account.messages.count).to eq(1)
      expect(ActiveRecord::Base.connection.select_value('SHOW statement_timeout')).not_to eq('60ms')
    end
  end

  describe 'the index' do
    it 'is answered from the trigram index on the text, for the literal and for the е/ё condition' do
      plans = {}
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute('SET LOCAL enable_seqscan = off')
        ActiveRecord::Base.connection.execute('SET LOCAL enable_indexscan = off')
        %w[справка приём].each do |text|
          plans[text] = Message.where(described_class.new(text).condition).explain.inspect
        end
      end

      expect(plans.values).to all(include('index_messages_on_content'))
    end
  end
end
