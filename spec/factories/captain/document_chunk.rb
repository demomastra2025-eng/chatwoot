FactoryBot.define do
  factory :captain_document_chunk, class: 'Captain::DocumentChunk' do
    account
    assistant { association(:captain_assistant, account: account) }
    document { association(:captain_document, account: account, assistant: assistant) }
    sequence(:chunk_index) { |index| index }
    content { 'Captain knowledge source chunk' }
  end
end
