require 'rails_helper'

RSpec.describe TelegramPersonal::ChatType do
  it 'lets the chat type of the gateway decide and is_group only when it is missing', :aggregate_failures do
    expect(described_class.private?(chat_type: 'private')).to be(true)
    expect(described_class.private?('chat_type' => 'user')).to be(true)
    expect(described_class.private?(chat_type: nil)).to be(true)
    expect(described_class.private?(chat_type: '', is_group: 'false')).to be(true)
    expect(described_class.private?(chat_type: nil, is_group: true)).to be(false)
    expect(described_class.private?(chat_type: 'private', is_group: true)).to be(true)

    expect(described_class.group?(chat_type: 'supergroup')).to be(true)
    expect(described_class.group?('chat_type' => nil, 'is_group' => 'true')).to be(true)
    expect(described_class.group?(chat_type: nil)).to be(false)
    expect(described_class.group?(chat_type: 'private', is_group: true)).to be(false)
  end

  it 'takes a broadcast channel for neither' do
    expect([described_class.private?(chat_type: 'channel'), described_class.group?(chat_type: 'channel', is_group: true)]).to eq([false, false])
  end
end
