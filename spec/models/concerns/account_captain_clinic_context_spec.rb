require 'rails_helper'

# The clinic context of an account: the "# Clinic" block of every external AI agent, kept in internal_attributes.
RSpec.describe AccountCaptainClinicContext do
  let(:account) { create(:account, internal_attributes: { 'captain_benchmark_source' => false }) }
  let(:text) { "Клиника:\n- МО «Әлия», г. Актобе.\n- ИИН пациента в карточке: [ИИН пациента](field://contact.identifier)" }

  it 'is empty for a clinic that has none' do
    expect(create(:account).captain_clinic_context).to eq('')
  end

  it 'is stored in internal_attributes with Windows line ends and blank edges removed, next to the other keys' do
    account.update!(captain_clinic_context: "  Клиника:\r\n- МО «Әлия».\r\n\n")

    expect(account.reload.captain_clinic_context).to eq("Клиника:\n- МО «Әлия».")
    expect(account.internal_attributes).to eq('captain_benchmark_source' => false, 'captain_clinic_context' => "Клиника:\n- МО «Әлия».")
  end

  it 'removes the key when it is cleared' do
    account.update!(captain_clinic_context: text)
    account.update!(captain_clinic_context: '  ')

    expect(account.reload.internal_attributes).to eq('captain_benchmark_source' => false)
  end

  it 'accepts 6 000 characters and a link to a contact field' do
    account.captain_clinic_context = "#{text}\n#{'я' * (6000 - text.length - 1)}"

    expect(account).to be_valid
  end

  describe 'what it refuses' do
    def errors_for(value)
      account.captain_clinic_context = value
      account.valid?
      account.errors.details[:captain_clinic_context].pluck(:error)
    end

    it 'refuses a text longer than 6 000 characters' do
      expect(errors_for('я' * 6001)).to eq([:too_long])
      expect(account.errors.full_messages).to include('Контекст клиники слишком длинное (максимум 6000 символов)')
    end

    it 'refuses a link to a tool or a skill: the text is shared by every agent' do
      expect(errors_for('Запись: [@Запись](tool://create_appointment).')).to eq([:tool_link])
      expect(errors_for('Скрипт: [Скрипт](skill://abc/summary).')).to eq([:tool_link])
      expect(account.errors.full_messages.join).to include('не может ссылаться на инструменты и навыки')
    end

    it 'refuses a link to a field that is not a contact field' do
      expect(errors_for('Сделка: [Сделка](field://deal.title).')).to eq([:field_link])
      expect(errors_for('Запись: [Запись](field://appointment.summary).')).to eq([:field_link])
      expect(account.errors.full_messages.join).to include('может ссылаться только на поля контакта')
    end

    it 'does not save a refused text' do
      expect(account.update(captain_clinic_context: 'Запись: [@Запись](tool://create_appointment).')).to be(false)

      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'does not check again the text that is already stored, so other changes of the account still save' do
      account.update_columns(internal_attributes: { 'captain_clinic_context' => 'я' * 6001 }) # rubocop:disable Rails/SkipsModelValidations
      account.reload

      expect(account.update(name: 'Новое имя', captain_clinic_context: 'я' * 6001)).to be(true)
    end
  end

  it 'gives the reasons of a refusal without an account, for the prompts-v2 rake' do
    expect(Account.captain_clinic_context_errors(text)).to eq([])
    expect(Account.captain_clinic_context_errors("#{'я' * 6001} [x](tool://handoff) [y](field://task.title)"))
      .to eq([[:too_long, { count: 6000 }], [:tool_link, {}], [:field_link, {}]])
  end
end
