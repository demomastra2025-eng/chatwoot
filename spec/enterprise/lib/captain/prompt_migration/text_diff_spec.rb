# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptMigration::TextDiff do
  it 'gives a unified diff with context' do
    diff = described_class.unified("a\nb\nc\nd", "a\nB\nc\nd\ne", label: 'description')

    expect(diff).to eq("--- description (current)\n+++ description (proposed)\n@@ -1 +1 @@\n a\n-b\n+B\n c\n d\n+e")
    expect(described_class.unified('same', 'same', label: 'x')).to eq('')
  end
end
