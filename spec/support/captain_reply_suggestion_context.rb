# frozen_string_literal: true

# A reply suggestion can start only when the model of the task has a provider key. This gives the specs one.
RSpec.shared_context 'with a configured reply suggestion model' do
  before do
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::Config).to receive(:provider_for_model).and_return('openai')
    allow(Llm::Config).to receive(:api_key).and_return('test-key')
  end
end
