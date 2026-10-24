require 'rails_helper'

RSpec.describe WhatsappWeb::DeliveryFailureReason do
  let(:request_error) { WhatsappWeb::Providers::EvolutionService::RequestError }

  def error_with(message:, body:, status: 400)
    request_error.new(message, status: status, body: body)
  end

  describe '.reason_for' do
    it 'reports an unroutable recipient without leaking the technical detail' do
      error = WhatsappWeb::Providers::EvolutionService::UnroutableRecipientError.new(
        'WhatsApp Web recipient is still a provisional @lid identity for conversation 95934'
      )

      expect(described_class.reason_for(error)).to eq('Не удалось определить номер получателя')
    end

    context 'when the gateway refused a send to a hidden @lid id' do
      let(:lid_error_class) { WhatsappWeb::Providers::EvolutionService::LidRecipientRequestError }
      let(:refusal_body) do
        { 'status' => 400, 'error' => 'Bad Request', 'response' => { 'message' => [{ 'jid' => '1@lid', 'exists' => false }] } }
      end

      it 'reports an unroutable recipient so that the retry service picks the message up' do
        error = lid_error_class.new('Evolution request failed with status 400', status: 400, body: refusal_body)

        reason = described_class.reason_for(error)

        expect(reason).to eq('Не удалось определить номер получателя')
        expect(described_class.unroutable_recipient?(reason)).to be(true)
      end

      it 'reports an unroutable recipient for every permanent refusal status while the channel is open' do
        channel = instance_double(Channel::WhatsappWeb, connection_state: 'open')

        [400, 404, 410, 422].each do |status|
          error = lid_error_class.new('Bad Request', status: status, body: {})

          expect(described_class.reason_for(error, channel: channel)).to eq(described_class::UNROUTABLE_RECIPIENT)
        end
      end

      it 'blames the lost session instead when the refusal says so or the channel is disconnected' do
        closed_channel = instance_double(Channel::WhatsappWeb, connection_state: 'close')
        closed_error = lid_error_class.new(
          'Error: Connection Closed',
          status: 400,
          body: { 'status' => 400, 'error' => 'Bad Request', 'response' => { 'message' => ['Error: Connection Closed'] } }
        )
        bare_error = lid_error_class.new('Bad Request', status: 400, body: {})

        expect(described_class.reason_for(closed_error)).to eq(described_class::DISCONNECTED)
        expect(described_class.reason_for(bare_error, channel: closed_channel)).to eq(described_class::DISCONNECTED)
      end

      it 'keeps the generic reason for the same refusal of a phone or group recipient' do
        error = error_with(message: 'Bad Request', body: refusal_body)

        expect(described_class.reason_for(error)).to eq(described_class::GENERIC)
      end
    end

    it 'maps a closed gateway connection to the reconnect hint' do
      error = error_with(
        message: 'Error: Connection Closed',
        body: { 'status' => 400, 'error' => 'Bad Request', 'response' => { 'message' => ['Error: Connection Closed'] } }
      )

      expect(described_class.reason_for(error)).to eq('WhatsApp отключён — переподключите номер в настройках канала')
    end

    it 'maps a logged out instance to the reconnect hint even when only the body mentions it' do
      error = error_with(message: 'Bad Request', body: { 'status' => 401, 'response' => { 'message' => ['Session logged out'] } }, status: 401)

      expect(described_class.reason_for(error)).to eq('WhatsApp отключён — переподключите номер в настройках канала')
    end

    it 'maps a missing instance to the reconnect hint' do
      error = error_with(
        message: 'The "onelink-waweb-48_77000000000" instance does not exist',
        body: { 'status' => 404 },
        status: 404
      )

      expect(described_class.reason_for(error)).to eq('WhatsApp отключён — переподключите номер в настройках канала')
    end

    it 'maps a missing group to a clear group message' do
      error = error_with(
        message: 'Bad Request',
        body: { 'status' => 404, 'error' => 'Bad Request', 'message' => ['Group not found'] },
        status: 404
      )

      expect(described_class.reason_for(error)).to eq('Группа не найдена в WhatsApp (возможно, номер удалили из группы)')
    end

    it 'replaces a bare HTTP reason with the generic reason' do
      ['Bad Request', 'Not Found', 'Forbidden', 'Unprocessable Entity'].each do |phrase|
        expect(described_class.reason_for(error_with(message: phrase, body: {}))).to eq('Не удалось отправить сообщение в WhatsApp')
      end
    end

    context 'when the channel is known to be disconnected' do
      let(:channel) { instance_double(Channel::WhatsappWeb, connection_state: 'close') }

      it 'explains a vanished group and a bare Bad Request by the lost session' do
        group_error = error_with(message: 'Bad Request', body: { 'message' => ['Group not found'] }, status: 404)
        bare_error = error_with(message: 'Bad Request', body: {})

        expect(described_class.reason_for(group_error, channel: channel)).to eq(described_class::DISCONNECTED)
        expect(described_class.reason_for(bare_error, channel: channel)).to eq(described_class::DISCONNECTED)
      end

      it 'keeps an informative provider message' do
        error = error_with(message: 'Message is older than 15 minutes', body: {})

        expect(described_class.reason_for(error, channel: channel)).to eq('Message is older than 15 minutes')
      end
    end

    it 'does not blame the session for a missing group while the channel is open' do
      channel = instance_double(Channel::WhatsappWeb, connection_state: 'open')
      error = error_with(message: 'Bad Request', body: { 'message' => ['Group not found'] }, status: 404)

      expect(described_class.reason_for(error, channel: channel)).to eq(described_class::GROUP_NOT_FOUND)
    end

    it 'keeps an informative provider message that is not covered by a mapping' do
      error = error_with(message: 'Message is older than 15 minutes', body: {})

      expect(described_class.reason_for(error)).to eq('Message is older than 15 minutes')
    end
  end

  describe '.unroutable_recipient?' do
    it 'recognises the Russian reason and the legacy English fragment' do
      expect(described_class.unroutable_recipient?('Не удалось определить номер получателя')).to be(true)
      expect(described_class.unroutable_recipient?('WhatsApp Web recipient is still a provisional @lid identity for conversation 1')).to be(true)
      expect(described_class.unroutable_recipient?('Bad Request')).to be(false)
      expect(described_class.unroutable_recipient?(nil)).to be(false)
    end
  end
end
