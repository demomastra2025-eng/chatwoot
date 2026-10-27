require 'rails_helper'

RSpec.describe Captain::ImageReading::LegacyDescriptions do
  let(:account) { create(:account) }
  let(:message) { create(:message, account: account) }
  let(:cache) { Captain::ImageRecognitionService::CACHE_KEY }
  let(:reader_key) { Captain::ImageRecognitionService::READER_KEY }
  let(:backup_dir) { Dir.mktmpdir }
  let(:legacy) { described_class.new }
  let!(:old_one) { image(meta: { cache => 'Анализ: гемоглобин 134' }) }
  let!(:new_one) { image(meta: { cache => 'Приём 12.10', reader_key => 'ordinary' }) }
  let!(:no_text) { image(meta: {}) }

  def image(meta: {}, **attributes)
    defaults = { account_id: account.id, file_type: :image, external_url: 'https://cdn.example.com/p.jpg', meta: meta }
    message.attachments.create!(defaults.merge(attributes))
  end

  after { FileUtils.remove_entry(backup_dir) }

  describe '#counts' do
    it 'counts the descriptions without a reader mark, and those of them whose image can be read again' do
      image(meta: { cache => 'Файл удалён' }, external_url: nil) # no file, no link: nothing to read again

      expect(legacy.counts).to eq(legacy: 2, to_forget: 1)
    end

    it 'leaves out an image that is purged' do
      image(meta: { cache => 'Удалённое фото', 'file_purged_at' => Time.current.iso8601 })

      expect(legacy.counts).to eq(legacy: 2, to_forget: 1)
    end

    it 'changes nothing' do
      expect { legacy.counts }.not_to(change { old_one.reload.meta })
    end
  end

  describe '#forget!' do
    it 'forgets the old description and keeps one that a reader made' do
      result = legacy.forget!(backup_dir: backup_dir)

      expect(result).to include(count: 1)
      expect(old_one.reload.meta).not_to have_key(cache)
      expect(new_one.reload.meta).to include(cache => 'Приём 12.10', reader_key => 'ordinary')
      expect(no_text.reload.meta).to eq({})
    end

    it 'writes the backup first, readable by its owner only, with the text it forgets' do
      path = legacy.forget!(backup_dir: backup_dir).fetch(:backup)

      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(JSON.parse(File.read(path))).to eq([{ 'id' => old_one.id, 'description' => 'Анализ: гемоглобин 134' }])
    end

    it 'finds nothing to forget the second time' do
      legacy.forget!(backup_dir: backup_dir)

      expect(legacy.forget!(backup_dir: backup_dir)).to include(count: 0)
    end

    it 'needs a place for the backup' do
      expect { legacy.forget!(backup_dir: nil) }.to raise_error(ArgumentError, /BACKUP_DIR/)
      expect(old_one.reload.meta).to have_key(cache)
    end
  end

  describe '#restore!' do
    it 'puts the forgotten descriptions back' do
      path = legacy.forget!(backup_dir: backup_dir).fetch(:backup)

      expect(legacy.restore!(path)).to eq(1)
      expect(old_one.reload.meta).to include(cache => 'Анализ: гемоглобин 134')
    end

    it 'does not overwrite a description that the image has got since' do
      path = legacy.forget!(backup_dir: backup_dir).fetch(:backup)
      old_one.update!(meta: { cache => 'Новое описание', reader_key => 'handwriting' })

      expect(legacy.restore!(path)).to eq(0)
      expect(old_one.reload.meta).to include(cache => 'Новое описание')
    end
  end
end
