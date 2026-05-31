# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ToolRiskPolicy do
  def tool_with(method_name, metadata)
    Class.new do
      define_method(method_name) { metadata }
      define_method(:name) { metadata[:id] || metadata['id'] || 'spec_tool' }
    end.new
  end

  def hash_like_tool(metadata)
    Class.new do
      define_method(:to_h) { metadata }
      define_method(:name) { metadata[:id] || metadata['id'] || 'spec_tool' }
    end.new
  end

  it 'treats tools without metadata as mutating by default' do
    tool = instance_double(RubyLLM::Tool, name: 'unknown_tool')

    expect(described_class.mutating?(tool)).to be(true)
    expect(described_class.read_only?(tool)).to be(false)
  end

  it 'classifies explicit read-only metadata as safe to execute in parallel' do
    tool = tool_with(:metadata, { read_only: true, risk_level: 'low' })

    expect(described_class.mutating?(tool)).to be(false)
    expect(described_class.read_only?(tool)).to be(true)
  end

  it 'classifies mutating and non-idempotent metadata as unsafe for duplicate execution' do
    tool = tool_with(:tool_definition, { risk_level: 'high', idempotent: false })

    expect(described_class.mutating?(tool)).to be(true)
    expect(described_class.read_only?(tool)).to be(false)
  end

  it 'prefers explicit mutating flags over conflicting read-only hints' do
    tool = hash_like_tool('read_only' => true, 'mutating' => true, 'risk_level' => 'low')

    expect(described_class.mutating?(tool)).to be(true)
    expect(described_class.read_only?(tool)).to be(false)
  end
end
