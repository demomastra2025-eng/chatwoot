require 'rails_helper'

RSpec.describe Whatsapp::IncomingWebhookMessageDispatch do
  let(:inbox) { instance_double(Inbox) }
  let(:params) { { entry: [] } }

  it 'passes a prepared attachment to the Cloud incoming service' do
    attachment = instance_double(Whatsapp::CloudMediaDownload)
    channel = instance_double(Channel::Whatsapp, provider: 'whatsapp_cloud', inbox: inbox)
    service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: :processed)

    expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(
      inbox: inbox,
      params: params,
      require_prepared_attachment: true,
      prepared_attachment: attachment
    ).and_return(service)

    expect(described_class.new(channel: channel, params: params, prepared_attachment: attachment).perform).to eq(:processed)
  end

  it 'preserves the outgoing echo option for Cloud events' do
    channel = instance_double(Channel::Whatsapp, provider: 'whatsapp_cloud', inbox: inbox)
    service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: :processed)

    expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(
      inbox: inbox,
      params: params,
      require_prepared_attachment: true,
      outgoing_echo: true
    ).and_return(service)

    expect(described_class.new(channel: channel, params: params, outgoing_echo: true).perform).to eq(:processed)
  end

  it 'preserves the legacy provider path' do
    channel = instance_double(Channel::Whatsapp, provider: 'whatsapp', inbox: inbox)
    service = instance_double(Whatsapp::IncomingMessageService, perform: :processed)

    expect(Whatsapp::IncomingMessageService).to receive(:new).with(inbox: inbox, params: params).and_return(service)
    expect(described_class.new(channel: channel, params: params).perform).to eq(:processed)
  end
end
