# frozen_string_literal: true

# Helpers for the specs of the handoff and closing notices (Captain::CustomerNoticeService).
module CustomerNoticeHelpers
  NOTICE_MODEL = 'openai/gpt-6-luna'

  # Saves the workspace handoff or closing message; key is 'handoff_message' or 'resolution_message'. The fields
  # (enabled:, mode:, text:, instruction:) default to an enabled fixed message without text.
  def configure_notice(account, key, **fields)
    message = { 'enabled' => true, 'mode' => 'fixed', 'text' => '', 'instruction' => '' }.merge(fields.stringify_keys)
    Captain::AccountSettings.new(account).update!('handoff' => { key => message })
  end

  # The `customer_notice` model slot resolves and answers with `text`, or raises `error`.
  def stub_notice_model(text = 'Сотрудник продолжит диалог с вами.', error: nil)
    allow(Llm::Config).to receive(:model_for).and_call_original
    allow(Llm::Config).to receive(:model_for).with(feature: 'customer_notice', account: anything, fallback: nil).and_return(NOTICE_MODEL)
    allow(Llm::Runtime).to receive(:chat).and_call_original
    stub = allow(Llm::Runtime).to receive(:chat).with(hash_including(feature: :customer_notice))
    error ? stub.and_raise(error) : stub.and_return(Struct.new(:content).new(text))
  end
end

RSpec.configure { |config| config.include CustomerNoticeHelpers }
