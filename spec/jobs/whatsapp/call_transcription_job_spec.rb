require 'rails_helper'

RSpec.describe Whatsapp::CallTranscriptionJob, type: :job do
  let(:call) { create(:call, :whatsapp, transcript: transcript) }
  let(:transcript) { nil }

  before do
    call.recording.attach(io: StringIO.new('recording-data'), filename: 'call.ogg', content_type: 'audio/ogg')
  end

  it 'does not retranscribe calls that already have a transcript' do
    call.update!(transcript: 'already transcribed')

    expect(Whatsapp::CallTranscriptionService).not_to receive(:new)

    described_class.perform_now(call.id)
  end

  it 'transcribes calls with an attached recording and no transcript' do
    service = instance_double(Whatsapp::CallTranscriptionService, perform: { success: true })
    allow(Whatsapp::CallTranscriptionService).to receive(:new).with(call).and_return(service)

    described_class.perform_now(call.id)

    expect(service).to have_received(:perform)
  end
end
